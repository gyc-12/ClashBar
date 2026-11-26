import AppKit
import Foundation
import SwiftUI
import Testing
import Yams

@testable import ClashBar

final class RuleTestCore: MihomoControlling, @unchecked Sendable {
    var status: CoreLifecycleStatus { .stopped }
    var isRunning: Bool { false }
    var detectedBinaryPath: String? { nil }
    func validateConfigAsync(configPath: String) async throws {
        _ = try Yams.load(yaml: String(contentsOfFile: configPath, encoding: .utf8))
    }
    func startAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus {
        throw QuickRuleError.invalidConfig
    }
    func restartAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus {
        throw QuickRuleError.invalidConfig
    }
    func stop() {}
    func stopAsync() async {}
}

@MainActor
struct NativeRuleTestEnvironment {
    let home: URL
    let defaults: UserDefaults
    let model: AppViewModel
    let config: URL
    init(realCoreBinary: String? = nil, coreOverride: (any MihomoControlling)? = nil) throws {
        self.home = FileManager.default.temporaryDirectory.appendingPathComponent("native-rule-ui-\(UUID().uuidString)")
        let working = WorkingDirectoryManager(homeDirectory: self.home)
        try working.bootstrapDirectories()
        self.config = working.configDirectoryURL.appendingPathComponent("personal.yaml")
        try Data(
            """
            proxy-groups:
              - {name: 香港节点, type: select, proxies: [DIRECT], hidden: true}
              - {name: OpenAI, type: select, proxies: [DIRECT]}
            rule-providers:
              examples: {type: http, behavior: domain, format: mrs, url: 'https://example.com/rules.mrs'}
            rules:
              - DOMAIN-SUFFIX,example.com,OpenAI # clashbar:custom
              - RULE-SET,examples,OpenAI
              - MATCH,DIRECT
            """.utf8
        ).write(to: self.config)
        let configService = ConfigService(
            configManager: ConfigDirectoryManager(workingDirectoryManager: working),
            configImportService: ConfigImportService())
        configService.setConfigDirectory(working.configDirectoryURL)
        configService.selectConfig(self.config)
        self.defaults = UserDefaults(suiteName: "clashbar.native-rule-tests.\(UUID().uuidString)")!
        let session = URLSession(configuration: .ephemeral)
        let core: any MihomoControlling
        if let coreOverride {
            core = coreOverride
        } else if let realCoreBinary {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: realCoreBinary), to: working.managedMihomoBinaryURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: working.managedMihomoBinaryURL.path)
            core = MihomoProcessManager(workingDirectoryManager: working)
        } else {
            core = RuleTestCore()
        }
        let dependencies = AppDependencies(
            processManager: core, configService: configService,
            systemProxyService: SystemProxyService(), tunPermissionService: TunPermissionService(),
            launchAtLoginService: AppLaunchService(), workingDirectoryManager: working,
            networkReachabilityMonitor: NetworkReachabilityMonitor(), ssidMonitorService: SSIDMonitorService(),
            remoteMachineStore: RemoteMachineStore(session: session, defaults: self.defaults),
            proxyGroupIconCache: ProxyGroupIconCache(iconDirectory: working.iconDirectoryURL, session: session),
            clashbarLogStore: AppLogStore(logFileURL: working.logsDirectoryURL.appendingPathComponent("app.log")),
            mihomoLogStore: AppLogStore(logFileURL: working.logsDirectoryURL.appendingPathComponent("core.log")))
        self.model = AppViewModel(dependencies: dependencies, defaults: self.defaults)
        self.model.selectedConfigName = self.config.lastPathComponent
        self.model.refreshNativeRuleDocument()
    }
    func clean() { try? FileManager.default.removeItem(at: self.home) }
}

@MainActor
struct NativeRuleViewModelTests {
    @Test func stoppedCoreShowsRulesAndSavingRemainsNative() async throws {
        let environment = try NativeRuleTestEnvironment()
        defer { environment.clean() }
        let model = environment.model
        #expect(model.canEditQuickRules)
        #expect(model.displayedRuleItems.count == 3)
        #expect(model.ruleItems.isEmpty)
        #expect(!model.nativeRulesMatchRuntime)
        let document = try #require(model.nativeRuleDocument)
        #expect(document.policies.contains("香港节点"))
        let result = try await model.saveNativeRule(
            document: document, entry: document.entries[0], raw: "DOMAIN-SUFFIX,example.com,香港节点", isCustom: true)
        #expect(!result.applied)
        #expect(result.backupURL != nil)
        #expect(model.displayedRuleItems.first?.proxy == "香港节点")
        #expect(model.nativeRuleSavingIndex == nil && !model.isQuickRuleSaving)
        #expect(!model.pendingConfigChangeRestart)
        let text = try String(contentsOf: environment.config, encoding: .utf8)
        #expect(text.contains("# clashbar:custom"))
        #expect(text.contains("RULE-SET,examples,OpenAI"))
        #expect(model.configFileSignatureSnapshot[environment.config.lastPathComponent] != nil)
    }

    @Test func externalChangeRejectsSnapshotAndRefreshesVisibleDocument() async throws {
        let environment = try NativeRuleTestEnvironment()
        defer { environment.clean() }
        let model = environment.model
        let old = try #require(model.nativeRuleDocument)
        try Data("rules: ['MATCH,REJECT']\n".utf8).write(to: environment.config)
        do {
            _ = try await model.saveNativeRule(
                document: old, entry: old.entries[0], raw: "DOMAIN-SUFFIX,example.com,DIRECT", isCustom: true)
            Issue.record("Expected a snapshot conflict")
        } catch {
            if case .contextChanged = error as? QuickRuleError {} else { Issue.record("Unexpected error: \(error)") }
        }
        #expect(model.displayedRuleItems.count == 1)
        #expect(model.displayedRuleItems.first?.proxy == "REJECT")
        #expect(!model.isQuickRuleSaving)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLASHBAR_TEST_RENDER_DIR"] != nil))
    func renderNativeRulesForVisualReview() throws {
        let directory = URL(
            fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CLASHBAR_TEST_RENDER_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let environment = try NativeRuleTestEnvironment()
        defer { environment.clean() }
        let model = environment.model
        let document = try #require(model.nativeRuleDocument)
        let context = NativeRuleEditorContext(document: document, entry: document.entries[1], isSubscription: true)
        model.controller = "127.0.0.1:1"
        model.statusBarDisplayMode = .iconOnly
        for language in AppLanguage.allCases {
            model.uiLanguage = language
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                try self.render(
                    NativeRuleEditorView(context: context).environmentObject(model).environment(\.colorScheme, scheme)
                        .defaultAppStorage(model.defaults),
                    size: CGSize(width: MenuBarLayoutTokens.Sheet.width, height: MenuBarLayoutTokens.Sheet.tallHeight), scheme: scheme,
                    path: directory.appendingPathComponent("native-editor-\(language.rawValue)-\(name).png"))
                try self.render(
                    ScrollView { RulesTabView().environmentObject(model).environmentObject(model.proxyStore) }
                        .environment(
                            \.colorScheme, scheme).defaultAppStorage(model.defaults),
                    size: CGSize(width: MenuBarLayoutTokens.contentWidth, height: 480), scheme: scheme,
                    path: directory.appendingPathComponent("native-rules-\(language.rawValue)-\(name).png"))
            }
        }
    }

    private func render<Content: View>(_ content: Content, size: CGSize, scheme: ColorScheme, path: URL) throws {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
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
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: path)
    }
}
