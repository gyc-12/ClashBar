import AppKit
import Foundation
import SwiftUI
import Testing
import Yams

@testable import ClashBar

struct NativeProxyProviderTests {
    private let service = NativeProxyProviderService()
    private let url = URL(fileURLWithPath: "/tmp/provider-fixture.yaml")

    private func document(_ text: String) throws -> NativeProxyProviderDocument {
        try service.read(configURL: url, data: Data(text.utf8))
    }

    @Test func suspensionRestoresReferencesAcrossSeveralProviders() throws {
        let original = try document("""
            # Keep this comment.
            proxy-providers:
              one: {type: http, url: 'https://example.com/a?Token=A%2B', path: ./one.yaml, future: {flag: true}}
              two: {type: file, path: ./two.yaml}
              three: {type: file, path: ./three.yaml}
            proxy-groups:
              - name: Explicit
                type: select
                use: [one, two, three]
              - {name: Automatic, type: select, include-all: true}
            rules:
              - MATCH,Automatic # clashbar:custom
            """.replacingOccurrences(of: "\n", with: "\r\n"))
        let first = try service.prepare(.setEnabled(name: "one", enabled: false), in: original)
        let second = try service.prepare(.setEnabled(name: "two", enabled: false), in: first.document)
        #expect(second.document.activeNames == ["three"])
        #expect(second.document.entries.first(where: { $0.name == "one" })?.url == "https://example.com/a?Token=A%2B")
        let text = String(decoding: second.file.updatedData, as: UTF8.self)
        #expect(text.contains("# clashbar:disabled-proxy-providers begin\r\n"))
        #expect(text.contains("# Keep this comment."))
        #expect(text.contains("MATCH,Automatic # clashbar:custom"))
        let expanded = try service.expandedConfig(second.file.updatedData)
        #expect(expanded["proxy-groups"]?.array()[0]["use"]?.array(of: String.self) == ["three"])
        let restoredOne = try service.prepare(.setEnabled(name: "one", enabled: true), in: second.document)
        let restored = try service.prepare(.setEnabled(name: "two", enabled: true), in: restoredOne.document)
        let config = try service.expandedConfig(restored.file.updatedData)
        #expect(try service.providerFields(config).map(\.0) == ["one", "two", "three"])
        #expect(config["proxy-groups"]?.array()[0]["use"]?.array(of: String.self) == ["one", "two", "three"])
        #expect(config["proxy-providers"]?["one"]?["future"]?["flag"]?.bool == true)
        #expect(!String(decoding: restored.file.updatedData, as: UTF8.self).contains("disabled-proxy-providers"))
    }

    @Test func lastProviderNeedsExplicitFallbackAndDisabledLinkDoesNotChangeRuntime() throws {
        let original = try document("""
            proxy-providers: {only: {type: http, url: 'https://example.com/old', path: ./old.yaml, header: {X-Test: [abc]}}}
            proxy-groups:
              - {name: Fixed, type: select, use: [only]}
              - {name: Auto, type: select, include-all-providers: true}
            rules: ['MATCH,Fixed']
            """)
        #expect(throws: NativeProxyProviderError.emptyGroups(["Auto", "Fixed"])) {
            try service.prepare(.setEnabled(name: "only", enabled: false), in: original)
        }
        let disabled = try service.prepare(.setEnabled(name: "only", enabled: false), in: original, fallback: .reject)
        #expect(disabled.document.activeNames.isEmpty)
        let revised = try service.prepare(.edit(name: "only", url: "https://example.com/new?Token=A%2B"), in: disabled.document)
        #expect(!revised.changesRuntime)
        #expect(revised.freshSource)
        let restored = try service.prepare(.setEnabled(name: "only", enabled: true), in: revised.document)
        let config = try service.expandedConfig(restored.file.updatedData)
        let provider = config["proxy-providers"]?["only"]
        #expect(provider?["header"]?["X-Test"]?.array(of: String.self) == ["abc"])
        #expect(provider?["path"]?.string?.starts(with: "./proxies/clashbar-") == true)
        #expect(provider?["url"]?.string == "https://example.com/new?Token=A%2B")
        #expect(config["proxy-groups"]?.array()[0]["use"]?.array(of: String.self) == ["only"])
    }

    @Test func aliasAndMergeEditsDoNotChangeOtherFields() throws {
        let original = try document("""
            template: &source {type: http, url: https://example.com/original, override: {additional-prefix: 'HK '}}
            shared: &providers {'true': {<<: *source}, another: *source}
            <<: {proxy-providers: *providers}
            proxy-groups: [{name: '12', type: select, proxies: [DIRECT], use: ['true', another]}]
            """)
        let edit = try service.prepare(.edit(name: "true", url: "https://example.com/new"), in: original)
        let config = try service.expandedConfig(edit.file.updatedData)
        #expect(config["shared"]?["another"]?["url"]?.string == "https://example.com/original")
        #expect(try service.providerFields(config).first?.1["url"]?.string == "https://example.com/new")
        let suspended = try service.prepare(.setEnabled(name: "true", enabled: false), in: edit.document)
        let restored = try service.prepare(.setEnabled(name: "true", enabled: true), in: suspended.document)
        #expect(restored.document.groups[0].use == ["true", "another"])
    }

    @Test func externalChangeToSavedUsesConflictsAndDeleteDropsRecovery() throws {
        let original = try document("""
            proxy-providers: {one: {type: file, path: one}, two: {type: file, path: two}}
            proxy-groups:
              - name: Group
                type: select
                use: [one, two]
                proxies: [DIRECT]
            """)
        let disabled = try service.prepare(.setEnabled(name: "one", enabled: false), in: original)
        let source = String(decoding: disabled.file.updatedData, as: UTF8.self)
        let changed = source.replacingOccurrences(of: "    use: ['two']", with: "    use: []")
        #expect(changed != source)
        let edited = try document(changed)
        #expect(throws: NativeProxyProviderError.conflict) {
            try service.prepare(.setEnabled(name: "one", enabled: true), in: edited)
        }
        let deleted = try service.prepare(.delete(name: "one"), in: disabled.document)
        #expect(!deleted.changesRuntime)
        #expect(deleted.document.entries.map(\.name) == ["two"])
        #expect(!String(decoding: deleted.file.updatedData, as: UTF8.self).contains("disabled-proxy-providers"))
    }

    @Test func addFirstSubscriptionKeepsExistingConfiguration() throws {
        let original = try document("# note\nrules:\n  - MATCH,DIRECT # clashbar:custom\n")
        let added = try service.prepare(.add(name: "新加坡", url: "https://example.com/list", interval: 1800,
                                            healthCheckURL: nil, groups: []), in: original)
        #expect(added.document.activeNames == ["新加坡"])
        #expect(String(decoding: added.file.updatedData, as: UTF8.self).contains("# clashbar:custom"))
        #expect(throws: NativeProxyProviderError.invalidURL) {
            try service.prepare(.edit(name: "新加坡", url: "file:///tmp/list"), in: added.document)
        }
    }
}

@MainActor
struct ProxyProviderViewModelTests {
    @Test func stoppedCoreShowsNativeEntriesAndRejectsStaleWrites() async throws {
        let environment = try NativeRuleTestEnvironment()
        defer { environment.clean() }
        let model = environment.model
        #expect(model.canManageProxyProviders)
        model.openProxyProviderEditor(.add)
        #expect(model.proxyProviderEditorContext?.document.entries.isEmpty == true)
        #expect(model.proxyProviderEditorContext?.willReload == false)
        let original = Data("proxy-providers: {Office: {type: inline, payload: []}}\nrules: ['MATCH,DIRECT']\n".utf8)
        try original.write(to: environment.config)
        model.refreshNativeProxyProviderDocument()
        let document = try #require(model.nativeProxyProviderDocument)
        #expect(model.proxyProvidersDetail.isEmpty)
        #expect(document.activeNames == ["Office"])
        let external = original + Data("# edited externally\n".utf8)
        try external.write(to: environment.config)
        do {
            _ = try await model.saveProxyProvider(.setEnabled(name: "Office", enabled: false), document: document, fallback: nil)
            Issue.record("Expected snapshot conflict")
        } catch QuickRuleError.contextChanged {}
        #expect(try Data(contentsOf: environment.config) == external)
        let updated = try #require(model.nativeProxyProviderDocument)
        #expect(try await model.saveProxyProvider(.setEnabled(name: "Office", enabled: false), document: updated, fallback: nil) == false)
        #expect(model.nativeProxyProviderDocument?.entries.first?.enabled == false)
        #expect(model.configFileSignatureSnapshot[environment.config.lastPathComponent] != nil)
        #expect(!model.pendingConfigChangeRestart && !model.isQuickRuleSaving)
    }

    @Test func remoteTargetHasNoNativeManagement() throws {
        let environment = try NativeRuleTestEnvironment()
        defer { environment.clean() }
        let model = environment.model
        let machine = RemoteMachine(name: "Test", host: "127.0.0.1", port: 1)
        model.remoteMachineStore.addMachine(machine)
        model.remoteMachineStore.selectTarget(.remote(machine))
        model.refreshNativeProxyProviderDocument()
        #expect(model.isRemoteTarget)
        #expect(!model.canManageProxyProviders)
        #expect(model.nativeProxyProviderDocument == nil)
        model.openProxyProviderEditor(.add)
        #expect(model.proxyProviderEditorContext == nil)
    }

    @Test func successfulEmptySummaryClearsExistingProviderNodes() throws {
        let environment = try NativeRuleTestEnvironment()
        defer { environment.clean() }
        let model = environment.model
        let provider = try JSONDecoder().decode(ProviderDetail.self, from: Data("""
            {"name":"Office","vehicleType":"HTTP","proxies":[{"name":"stale","type":"Socks5","history":[{"delay":12}]}]}
            """.utf8))
        let groups = ProxyGroupsResponse(proxies: ["Select": ProxyGroup(name: "Select", all: ["DIRECT"])])
        model.applyProxyGroupsResponse(groups, proxyProviders: ["Office": provider])
        #expect(model.proxyNodeTypes["stale"] == "Socks5")
        model.applyProxyGroupsResponse(groups, proxyProviders: nil)
        #expect(model.proxyProvidersDetail["Office"] != nil)
        model.applyProxyGroupsResponse(groups, proxyProviders: [:])
        #expect(model.proxyProvidersDetail.isEmpty)
        #expect(model.proxyNodeTypes["stale"] == nil)
        #expect(model.proxyLatencyHistory["stale"] == nil)
    }
}

@MainActor
struct ProxyProviderVisualTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLASHBAR_TEST_RENDER_DIR"] != nil))
    func renderProxyProviderManagement() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CLASHBAR_TEST_RENDER_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let environment = try NativeRuleTestEnvironment()
        defer { environment.clean() }
        let model = environment.model
        let service = NativeProxyProviderService()
        let original = try service.read(configURL: environment.config, data: Data("""
            proxy-providers:
              Office: {type: http, url: 'https://example.com/office'}
              Travel: {type: http, url: 'https://example.com/travel'}
            proxy-groups:
              - {name: Personal, type: select, use: [Office, Travel]}
            rules: ['MATCH,Personal']
            """.utf8))
        let disabled = try service.prepare(.setEnabled(name: "Travel", enabled: false), in: original)
        try disabled.document.data.write(to: environment.config)
        model.refreshNativeRuleDocument()
        let context = ProxyProviderEditorContext(document: disabled.document, operation: .add, entry: nil,
                                                isSubscription: true, willReload: true)
        model.controller = "127.0.0.1:1"
        model.statusBarDisplayMode = .iconOnly
        for language in AppLanguage.allCases {
            model.uiLanguage = language
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                try render(ProxyProviderEditorView(context: context).environmentObject(model).defaultAppStorage(model.defaults),
                           size: CGSize(width: MenuBarLayoutTokens.Sheet.width, height: 460), scheme: scheme,
                           path: directory.appendingPathComponent("provider-editor-\(language.rawValue)-\(name).png"))
                try render(ScrollView {
                    ProxyTabView(rootViewModel: ProxyGroupsViewModel())
                        .environmentObject(model).environmentObject(model.proxyStore)
                        .environmentObject(model.trafficStore).environmentObject(model.connectionsStore)
                }.defaultAppStorage(model.defaults), size: CGSize(width: MenuBarLayoutTokens.contentWidth, height: 680), scheme: scheme,
                           path: directory.appendingPathComponent("provider-list-\(language.rawValue)-\(name).png"))
            }
        }
    }

    private func render<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, path: URL) throws {
        let frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: path)
    }
}
