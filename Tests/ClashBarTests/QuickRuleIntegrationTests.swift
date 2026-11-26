import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
import Yams

@testable import ClashBar

@MainActor
struct QuickRuleIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"] != nil))
    func nativeRulesAndProviderReloadWithRealCore() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"])
        let port = try self.availablePort()
        let fixture = try QuickRuleFixture(
            yaml: """
                mixed-port: 0
                external-controller: 127.0.0.1:\(port)
                mode: rule
                log-level: silent
                proxies: []
                rule-providers:
                  local: {type: file, behavior: classical, path: ./local.yaml}
                rules:
                  - RULE-SET,local,DIRECT
                  - MATCH,DIRECT
                """
        )
        defer { fixture.clean() }
        try Data("payload: ['DOMAIN,existing.example']\n".utf8).write(
            to: fixture.root.appendingPathComponent("local.yaml")
        )
        let core = Process()
        core.executableURL = URL(fileURLWithPath: binary)
        core.arguments = ["-d", fixture.root.path, "-f", fixture.config.path]
        core.standardOutput = FileHandle.nullDevice
        core.standardError = FileHandle.nullDevice
        try core.run()
        defer {
            if core.isRunning {
                core.terminate()
                core.waitUntilExit()
            }
        }
        let client = MihomoAPIService(controller: "127.0.0.1:\(port)", secret: nil)
        var ready = false
        for _ in 0..<60 {
            if let _: VersionInfo = try? await client.request(.version) {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(ready)
        let edit = try fixture.edit()
        try await client.requestNoResponse(.patchConfigs(body: ["mode": .string("global")]))
        let settings = EditableSettingsSnapshot(
            mode: .global,
            allowLan: false,
            ipv6: false,
            tcpConcurrent: false,
            tunEnabled: false,
            logLevel: "silent",
            port: "0",
            socksPort: "0",
            mixedPort: "0",
            redirPort: "0",
            tproxyPort: "0"
        )
        let payload = try fixture.service.reloadPayload(edit.updatedData, settings: settings)
        let previousPayload = try fixture.service.reloadPayload(edit.originalData, settings: settings)
        _ = try await fixture.service.commit(
            edit,
            validate: { path in
                try await self.validate(binary: binary, root: fixture.root, config: path)
            },
            didWrite: {},
            apply: {
                try await client.requestNoResponse(.putConfigs(force: false, path: "", payload: payload))
            },
            restoreRuntime: {
                try await client.requestNoResponse(.putConfigs(force: false, path: "", payload: previousPayload))
            }
        )
        let runtime: ConfigSnapshot = try await client.request(.getConfigs)
        #expect(runtime.mode == "global")
        let rules: RulesSummary = try await client.request(.rules)
        #expect(rules.rules.first?.payload == "example.com")
        #expect(rules.rules.first?.proxy == "REJECT")

        let context = try fixture.context()
        let providerEdit = try fixture.service.prepare(
            rule: QuickRoutingRule(type: .ipv6, target: "2001:db8::1", policy: "DIRECT"),
            context: context,
            providerName: "local"
        )
        _ = try await fixture.service.commit(
            providerEdit,
            validate: { path in
                try await self.validate(binary: binary, root: fixture.root, config: path)
            },
            didWrite: {},
            apply: {
                try await client.requestNoResponse(.updateRuleProvider(name: "local"))
            },
            restoreRuntime: {
                try await client.requestNoResponse(.updateRuleProvider(name: "local"))
            }
        )
        let providers: ProviderSummary = try await client.request(.ruleProviders)
        #expect(providers.providers["local"]?.ruleCount == 2)
        // The final on-disk files still pass bare-core validation, independent of this App.
        try await self.validate(binary: binary, root: fixture.root, config: fixture.config.path)
        core.terminate()
        core.waitUntilExit()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLASHBAR_TEST_RENDER_DIR"] != nil))
    func renderEditorForVisualReview() throws {
        let directory = URL(
            fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CLASHBAR_TEST_RENDER_DIR"])
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try QuickRuleFixture(
            yaml: """
                proxies: []
                proxy-groups: [{name: 香港节点, type: select, proxies: [DIRECT]}]
                rules: ['MATCH,DIRECT']
                """
        )
        defer { fixture.clean() }
        let base = try fixture.context()
        let context = QuickRuleEditorContext(
            configURL: base.configURL,
            target: QuickRuleTarget(type: .domain, value: "api.example.com"),
            policies: base.policies,
            originalConfig: base.originalConfig,
            providers: base.providers,
            isSubscription: true,
            notice: "请确认域名及目标策略。"
        )
        // Isolate configuration and defaults; never discover the user's running core.
        #expect(L10n.t("ui.quick_rule.title", language: .en) == "Add Routing Rule")
        let environment = try NativeRuleTestEnvironment()
        defer { environment.model.cancelPolling(); environment.clean() }
        let model = environment.model
        model.controller = "127.0.0.1:1"
        model.statusBarDisplayMode = .iconOnly
        for language in AppLanguage.allCases {
            model.uiLanguage = language
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let content = QuickRuleEditorView(context: context)
                    .environmentObject(model).environment(\.colorScheme, scheme)
                    .defaultAppStorage(model.defaults)
                    .background(Color(nsColor: .windowBackgroundColor))
                let size = CGSize(width: MenuBarLayoutTokens.Sheet.width, height: MenuBarLayoutTokens.Sheet.height)
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                defer { window.contentView = nil; window.close() }
                window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                let host = NSHostingView(rootView: content)
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("quick-rule-\(language.rawValue)-\(name).png"))
            }
        }
    }

    private func validate(binary: String, root: URL, config: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-d", root.path, "-f", config, "-t"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<100 {
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        guard process.terminationStatus == 0 else { throw CocoaError(.validationMissingMandatoryProperty) }
    }

    private func availablePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        guard bound == 0 else { throw CocoaError(.fileReadUnknown) }
        var length = size
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0 else { throw CocoaError(.fileReadUnknown) }
        return UInt16(bigEndian: address.sin_port)
    }
}
