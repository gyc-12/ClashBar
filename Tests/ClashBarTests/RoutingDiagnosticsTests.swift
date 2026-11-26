import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ClashBar

final class DiagnosticsTestCore: MihomoControlling, @unchecked Sendable {
    var status: CoreLifecycleStatus { .running(pid: 12345) }
    var isRunning: Bool { true }
    var detectedBinaryPath: String? { nil }
    func validateConfigAsync(configPath: String) async throws {}
    func startAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus { self.status }
    func restartAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus { self.status }
    func stop() {}
    func stopAsync() async {}
}

@MainActor
struct RoutingDiagnosticsTests {
    @Test func pollingKeepsMeasurementTimeAndAcceptsEqualDelayAtNewTime() throws {
        let json = #"{"name":"Auto","all":["DIRECT"],"history":[{"delay":"87","time":"2026-11-22T01:00:00.123456789Z"},{"delay":87,"time":"2026-11-22T01:02:00Z"}]}"#
        let group = try JSONDecoder().decode(ProxyGroup.self, from: Data(json.utf8))
        let once = ProxyLatencySample.merge(api: group.latencyHistory, previous: [])
        let twice = ProxyLatencySample.merge(api: group.latencyHistory, previous: once)
        #expect(once == twice)
        #expect(twice.count == 2 && twice.map(\.delay) == [87, 87])
        #expect(twice[0].time != twice[1].time)
        #expect(twice[0].time != nil)
        #expect(twice.last?.isStale(now: Date(timeIntervalSince1970: 1795310400), interval: 60) == true)
    }

    @Test func olderAPIHistoryDoesNotReplaceManualResultAndMissingTimeStaysUnknown() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let manual = ProxyLatencySample(delay: 21, time: date, testURL: "http://127.0.0.1/check")
        let old = ProxyLatencySample(delay: 80, time: date.addingTimeInterval(-30))
        let merged = ProxyLatencySample.merge(api: [old], previous: [manual])
        #expect(merged.last == manual)
        let same = ProxyLatencySample.merge(api: [ProxyLatencySample(delay: 21, time: date)], previous: merged)
        #expect(same.last?.testURL == manual.testURL)
        let noTime = try JSONDecoder().decode(ProxyGroup.self, from: Data(#"{"history":[{"delay":0},{"delay":"30","time":"invalid"}]}"#.utf8))
        #expect(noTime.latencyHistory.count == 2)
        #expect(noTime.latencyHistory.allSatisfy { $0.time == nil })
        #expect(ProxyLatencySample.merge(api: noTime.latencyHistory, previous: [manual]).last?.time == nil)
        #expect(LatencyAgeView(sample: noTime.latencyHistory.last, language: .en).text(now: .now) == "Time unknown")
    }

    @Test func decodesProviderTimesAndOptionalStatisticsWithoutInventingZero() throws {
        let node = try JSONDecoder().decode(ProviderProxyNode.self, from: Data(#"{"name":"Node","history":[{"delay":44,"time":"2026-11-22T01:00:00Z"}]}"#.utf8))
        #expect(node.latencyHistory.first?.time != nil)
        let summary = try JSONDecoder().decode(RulesSummary.self, from: Data(#"{"rules":[{"type":"Match","payload":"","proxy":"DIRECT","extra":{"hitCount":18446744073709551615,"hitAt":"2026-11-22T01:00:00Z","missCount":0,"missAt":"0001-01-01T00:00:00Z"}},{"type":"Domain","payload":"example.com","proxy":"DIRECT"}]}"#.utf8))
        #expect(summary.rules[0].statistics?.hitCount == UInt64.max)
        #expect(summary.rules[0].statistics?.hitAt != nil)
        #expect(summary.rules[0].statistics?.missAt == nil)
        #expect(summary.rules[0].index == 0)
        #expect(summary.rules[1].statistics == nil)
    }

    @Test func decodesConnectionMetadataAndRetainsDuplicateRuleCandidates() throws {
        let connection = try self.connection()
        #expect(connection.metadata?.sourcePort == "52123")
        #expect(connection.metadata?.destinationPort == "443")
        #expect(connection.metadata?.process == "Safari")
        #expect(connection.metadata?.dnsMode == "fake-ip")
        #expect(connection.metadata?.sniffHost == "example.com")
        let rules = [
            NativeRuleEntry(index: 0, raw: "DOMAIN-SUFFIX,EXAMPLE.COM,Group", isCustom: false).item,
            NativeRuleEntry(index: 1, raw: "DOMAIN-SUFFIX,example.com,DIRECT", isCustom: true).item,
            NativeRuleEntry(index: 2, raw: "DOMAIN,example.com,Group", isCustom: false).item,
        ]
        #expect(ConnectionRuleMatcher.candidates(for: connection, in: rules).map(\.nativeEntry?.index) == [0, 1])
    }

    @Test func nativeStatisticsRequireActiveMatchingFileAndSortingIsPresentationOnly() throws {
        let environment = try NativeRuleTestEnvironment(coreOverride: DiagnosticsTestCore())
        defer { environment.clean() }
        let model = environment.model
        model.defaults.set(environment.config.path, forKey: model.lastSuccessfulConfigPathKey)
        let runtime = try self.runtimeRules()
        model.ruleItems = runtime
        #expect(model.nativeRulesMatchRuntime)
        #expect(model.displayedRuleItems[0].statistics?.hitCount == 4)
        let viewModel = RulesViewModel()
        viewModel.sortByHits = true
        viewModel.updateVisibleRules(items: model.displayedRuleItems, providers: [:])
        #expect(viewModel.output.rules.map(\.nativeEntry?.index) == [1, 0, 2])
        #expect(model.nativeRuleDocument?.entries.map(\.index) == [0, 1, 2])
        model.defaults.removeObject(forKey: model.lastSuccessfulConfigPathKey)
        #expect(model.displayedRuleItems.allSatisfy { $0.statistics == nil })
        model.defaults.set(environment.config.path, forKey: model.lastSuccessfulConfigPathKey)
        model.ruleItems = Array(runtime.reversed())
        #expect(model.displayedRuleItems.allSatisfy { $0.statistics == nil })
    }

    @Test func singleRuleNavigationOpensEditorOnlyAfterDismissalAndRemoteRemainsReadOnly() throws {
        let environment = try NativeRuleTestEnvironment(coreOverride: DiagnosticsTestCore())
        defer { environment.clean() }
        let model = environment.model
        model.controller = "127.0.0.1:1"
        model.defaults.set(environment.config.path, forKey: model.lastSuccessfulConfigPathKey)
        model.ruleItems = try self.runtimeRules()
        let connection = try self.connection()
        model.navigateToConnectionRules(connection)
        #expect(model.nativeRuleEditorContext == nil)
        model.completeConnectionRuleNavigation()
        #expect(model.nativeRuleEditorContext?.entry.index == 0)
        model.nativeRuleEditorContext = nil
        model.completeConnectionRuleNavigation()
        #expect(model.nativeRuleEditorContext == nil)
        let machine = RemoteMachine(name: "Test", host: "127.0.0.1", port: 1)
        model.remoteMachineStore.machines = [machine]
        model.remoteMachineStore.activeTargetID = machine.id
        #expect(model.isRemoteTarget)
        model.navigateToConnectionRules(connection)
        model.completeConnectionRuleNavigation()
        #expect(model.nativeRuleEditorContext == nil)
        #expect(model.displayedRuleItems.first?.statistics?.hitCount == 4)
    }

    @Test func localHealthcheckConfigurationAndTargetResetDoNotLeakIntoRemote() throws {
        let environment = try NativeRuleTestEnvironment(coreOverride: DiagnosticsTestCore())
        defer { environment.clean() }
        let model = environment.model
        let yaml = "proxy-groups: [{name: Auto, type: url-test, proxies: [DIRECT], url: 'http://127.0.0.1/check', interval: 120, lazy: false}]\nrules: ['MATCH,DIRECT']\n"
        try Data(yaml.utf8).write(to: environment.config)
        model.refreshNativeRuleDocument()
        model.ruleItems = [RuleItem(type: "Match", payload: "", proxy: "DIRECT", index: 0)]
        model.defaults.set(environment.config.path, forKey: model.lastSuccessfulConfigPathKey)
        let group = ProxyGroup(name: "Auto", type: "URLTest", all: ["DIRECT"])
        #expect(model.healthcheckSettings(for: group).interval == 120)
        #expect(model.healthcheckSettings(for: group).lazy == false)
        let machine = RemoteMachine(name: "Remote", host: "127.0.0.1", port: 1)
        model.remoteMachineStore.machines = [machine]
        model.remoteMachineStore.activeTargetID = machine.id
        #expect(model.healthcheckSettings(for: group).interval == nil)
        model.applyMeasuredNodeDelays(["DIRECT": 22], testURL: "http://127.0.0.1/check")
        #expect(model.proxyLatencyHistory["DIRECT"]?.last?.time != nil)
        model.clearProxyPresentation()
        #expect(model.proxyLatencyHistory.isEmpty && model.proxyDelaySamples.isEmpty)
    }

    private func runtimeRules() throws -> [RuleItem] {
        try JSONDecoder().decode(RulesSummary.self, from: Data(#"{"rules":[{"index":0,"type":"DomainSuffix","payload":"example.com","proxy":"OpenAI","extra":{"hitCount":4,"hitAt":"2026-11-22T01:00:00Z"}},{"index":1,"type":"RuleSet","payload":"examples","proxy":"OpenAI","extra":{"hitCount":100,"hitAt":"2026-11-22T01:02:00Z"}},{"index":2,"type":"Match","payload":"","proxy":"DIRECT","extra":{"hitCount":0}}]}"#.utf8)).rules
    }

    private func connection() throws -> ConnectionSummary {
        try JSONDecoder().decode(ConnectionSummary.self, from: Data(#"{"id":"fixture","upload":1234,"download":56789,"start":"2026-11-22T01:00:00Z","rule":"DomainSuffix","rulePayload":"example.com","chains":["DIRECT","OpenAI"],"metadata":{"network":"tcp","sourceIP":"127.0.0.1","sourcePort":52123,"destinationIP":"1.2.3.4","destinationPort":"443","host":"www.example.com","process":"Safari","processPath":"/Applications/Safari.app/Contents/MacOS/Safari","dnsMode":"fake-ip","sniffHost":"example.com","inboundName":"Mixed"}}"#.utf8))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLASHBAR_TEST_RENDER_DIR"] != nil))
    func renderDiagnosticsForVisualReview() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CLASHBAR_TEST_RENDER_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let environment = try NativeRuleTestEnvironment(coreOverride: DiagnosticsTestCore())
        defer { environment.clean() }
        let model = environment.model
        model.controller = "127.0.0.1:1"
        model.defaults.set(environment.config.path, forKey: model.lastSuccessfulConfigPathKey)
        model.ruleItems = try self.runtimeRules()
        let connection = try self.connection()
        model.connectionsStore.connections = [connection]
        model.proxyGroups = [ProxyGroup(name: "OpenAI", type: "Selector", now: "DIRECT", all: ["DIRECT", "Hong Kong", "US Premium"], testUrl: "https://www.gstatic.com/generate_204", interval: 120, lazy: true)]
        model.applyMeasuredNodeDelays(["DIRECT": 24, "Hong Kong": 89, "US Premium": 152], testURL: "https://www.gstatic.com/generate_204", measuredAt: Date().addingTimeInterval(-180))
        let root = ProxyGroupsViewModel()
        root.updateFilteredProxyGroups(from: model.proxyGroups, hideHiddenGroups: false, currentMode: .rule)
        model.statusBarDisplayMode = .iconOnly
        for language in AppLanguage.allCases {
            model.uiLanguage = language
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let sheetSize = CGSize(width: MenuBarLayoutTokens.Sheet.wideWidth, height: MenuBarLayoutTokens.Sheet.height)
                try self.render(ConnectionDetailView(snapshot: connection).environmentObject(model).environmentObject(model.connectionsStore).environmentObject(model.proxyStore).environment(\.colorScheme, scheme).defaultAppStorage(model.defaults), size: sheetSize, scheme: scheme, path: directory.appendingPathComponent("connection-\(language.rawValue)-\(name).png"))
                try self.render(ProxyGroupDetailView(name: "OpenAI").environmentObject(model).environmentObject(model.proxyStore).environment(\.colorScheme, scheme).defaultAppStorage(model.defaults), size: sheetSize, scheme: scheme, path: directory.appendingPathComponent("group-\(language.rawValue)-\(name).png"))
                try self.render(ScrollView { RulesTabView().environmentObject(model).environmentObject(model.proxyStore) }.environment(\.colorScheme, scheme).defaultAppStorage(model.defaults), size: CGSize(width: MenuBarLayoutTokens.contentWidth, height: 460), scheme: scheme, path: directory.appendingPathComponent("hits-\(language.rawValue)-\(name).png"))
                try self.render(ScrollView { ProxyTabView(rootViewModel: root).environmentObject(model).environmentObject(model.proxyStore).environmentObject(model.trafficStore).environmentObject(model.connectionsStore) }.environment(\.colorScheme, scheme).defaultAppStorage(model.defaults), size: CGSize(width: MenuBarLayoutTokens.contentWidth, height: 680), scheme: scheme, path: directory.appendingPathComponent("proxy-panel-\(language.rawValue)-\(name).png"))
            }
        }
    }

    private func render<Content: View>(_ content: Content, size: CGSize, scheme: ColorScheme, path: URL) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let host = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: path)
    }
}
