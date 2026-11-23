import AppKit
import Foundation
import SwiftUI
import Testing
import Yams

@testable import ClashBar

struct ApplicationRoutingTests {
    @Test func exactTargetsKeepCaseAndSpacesAndCannotInjectRules() throws {
        let path = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let rule = try QuickRoutingRule(type: .processPath, target: path, policy: "开发组")
        #expect(rule.line == "PROCESS-PATH,\(path),开发组")
        #expect(try QuickRoutingRule(type: .processName, target: "Google Chrome Helper (Renderer)", policy: "DIRECT").target
                == "Google Chrome Helper (Renderer)")
        for target in ["", "relative/path", "https://example.com", "/tmp/x,REJECT", "/tmp/x\n", "/tmp/x\\y", "/tmp/x(", "/tmp/"] {
            #expect(throws: ApplicationRoutingError.self) { try QuickRoutingRule(type: .processPath, target: target, policy: "DIRECT") }
        }
        #expect(throws: ApplicationRoutingError.self) { try QuickRoutingRule(type: .processName, target: "/bin/curl", policy: "DIRECT") }
        #expect(!QuickRuleType.destinationTypes.contains(.processName))
        #expect(!QuickRuleType.destinationTypes.contains(.processPath))
        let provider = LocalRuleProvider(name: "domains", url: URL(fileURLWithPath: "/tmp/unused"), behavior: "domain",
                                         format: "text", policies: ["DIRECT"], originalData: Data())
        #expect(!provider.supports(.processName) && !provider.supports(.processPath))
    }

    @Test func observedProcessesAreExplicitAndDeduplicatedByPath() {
        func connection(_ id: String, process: String?, path: String?) -> ConnectionSummary {
            ConnectionSummary(id: id, upload: nil, download: nil, start: nil, rule: nil, rulePayload: nil, chains: nil,
                metadata: ConnectionMetadata(network: "tcp", sourceIP: nil, destinationIP: nil, host: "chrome.example",
                                             process: process, processPath: path))
        }
        let candidates = ApplicationRoutingCandidate.observed(in: [
            connection("1", process: "Chrome", path: "/Applications/A.app/Chrome"),
            connection("2", process: "Chrome", path: "/Applications/A.app/Chrome"),
            connection("3", process: "Chrome", path: "/Applications/B.app/Chrome"),
            connection("4", process: nil, path: nil),
            connection("5", process: nil, path: "/usr/bin/curl"),
            connection("6", process: "curl", path: "not/absolute"),
        ])
        #expect(candidates.count == 4)
        #expect(candidates.filter { $0.processName == "Chrome" }.count == 2)
        #expect(candidates.contains { $0.processName == "curl" && $0.processPath == nil })
        #expect(candidates.first { $0.processName == "curl" && $0.processPath != nil }?.preferredType == .processPath)
        #expect(candidates.contains { $0.matches("B.app") })
    }

    @Test func catalogReadsExecutableRatherThanDisplayNameAndSkipsNestedBundles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func makeApp(_ url: URL, displayName: String, executable: String) throws {
            let macOS = url.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            let info = ["CFBundleName": displayName, "CFBundleDisplayName": displayName,
                        "CFBundleExecutable": executable, "CFBundleIdentifier": "test.\(UUID().uuidString)", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Contents/Info.plist"))
            let binary = macOS.appendingPathComponent(executable)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        let app = root.appendingPathComponent("Utilities/Example.app")
        try makeApp(app, displayName: "展示名称", executable: "Actual Executable")
        try makeApp(app.appendingPathComponent("Contents/Helpers/Hidden.app"), displayName: "Helper", executable: "Helper")
        let catalog = ApplicationCatalogService(roots: [root, root]).scan()
        #expect(catalog.count == 1)
        #expect(catalog.first?.name == "展示名称" && catalog.first?.processName == "Actual Executable")
        #expect(catalog.first?.processPath?.hasSuffix("Contents/MacOS/Actual Executable") == true)
        #expect(throws: ApplicationRoutingError.self) { try ApplicationCatalogService.application(at: root) }
    }

    @Test(arguments: [
        "find-process-mode: off\n# keep\nrules:\n  - PROCESS-NAME,curl,DIRECT\n  - PROCESS-NAME,curl,DIRECT\n  - PROCESS-PATH,/usr/bin/curl,DIRECT\n  - DOMAIN,keep.example,DIRECT # keep comment\n  - MATCH,DIRECT\n",
        "{find-process-mode: off, rules: ['PROCESS-NAME,curl,DIRECT', 'MATCH,DIRECT']}\n",
        "base: &mode off\nfind-process-mode: *mode\nrules: ['MATCH,DIRECT']\n",
        "---\r\nrules:\r\n  - MATCH,DIRECT\r\n...\r\n",
    ])
    func savesNativeRuleAndExplicitModeWithoutChangingOtherFields(yaml: String) throws {
        let fixture = try QuickRuleFixture(yaml: yaml)
        defer { fixture.clean() }
        let native = NativeRuleService(homeDirectory: fixture.root)
        let document = try native.read(configURL: fixture.config)
        let rule = try QuickRoutingRule(type: .processName, target: "curl", policy: "REJECT")
        let edit = try ApplicationRuleService(homeDirectory: fixture.root).prepare(rule: rule, document: document, enableProcessLookup: true)
        let updated = try native.read(configURL: fixture.config, data: edit.updatedData)
        #expect(updated.entries.first?.raw == "PROCESS-NAME,curl,REJECT")
        #expect(updated.entries.first?.isCustom == true)
        #expect(updated.entries.filter { $0.syntax?.type == "PROCESS-NAME" && $0.syntax?.payload == "curl" }.count == 1)
        #expect(updated.entries.dropFirst().map(\.raw) == document.entries.filter {
            $0.syntax?.type != "PROCESS-NAME" || $0.syntax?.payload != "curl"
        }.map(\.raw))
        let before = try #require(try Yams.load(yaml: yaml) as? [String: Any])
        var after = try #require(try Yams.load(yaml: String(decoding: edit.updatedData, as: UTF8.self)) as? [String: Any])
        #expect(after["find-process-mode"] as? String == "strict")
        after["find-process-mode"] = before["find-process-mode"]
        after["rules"] = before["rules"]
        #expect(NSDictionary(dictionary: after).isEqual(to: before))
        #expect(try Data(contentsOf: fixture.config) == document.originalData)
    }

    @Test func explicitModeWinsWhileOtherRuntimeSettingsAndRollbackKeepTheirValues() throws {
        let fixture = try QuickRuleFixture(yaml: "find-process-mode: off\nmode: rule\nmixed-port: 0\ntun: {enable: false}\nrules: ['MATCH,DIRECT']\n")
        defer { fixture.clean() }
        let document = try NativeRuleService(homeDirectory: fixture.root).read(configURL: fixture.config)
        let service = ApplicationRuleService(homeDirectory: fixture.root)
        let rule = try QuickRoutingRule(type: .processPath, target: "/usr/bin/curl", policy: "DIRECT")
        #expect(throws: ApplicationRoutingError.self) { try service.prepare(rule: rule, document: document, enableProcessLookup: false) }
        let edit = try service.prepare(rule: rule, document: document, enableProcessLookup: true)
        let runtime: [String: JSONValue] = ["find-process-mode": .string("off"), "mode": .string("global"),
            "mixed-port": .int(9098), "tun": .object(["enable": .bool(false), "stack": .string("gvisor"), "mtu": .int(9000)])]
        let payload = try fixture.service.reloadPayload(edit.updatedData, runtime: runtime, settingsFromFile: ["find-process-mode"])
        let applied = try #require(try Yams.load(yaml: payload) as? [String: Any])
        #expect(applied["find-process-mode"] as? String == "strict")
        #expect(applied["mixed-port"] as? Int == 9098 && applied["mode"] as? String == "global")
        #expect((applied["tun"] as? [String: Any])?["mtu"] as? Int == 9000)
        let rollback = try #require(try Yams.load(yaml: fixture.service.reloadPayload(edit.originalData, runtime: runtime)) as? [String: Any])
        #expect(rollback["find-process-mode"] as? String == "off")
        #expect(rollback["mixed-port"] as? Int == 9098)
    }
}

@MainActor
struct ApplicationRuleViewModelTests {
    @Test func failedApplicationReloadRestoresFileAndOriginalLookupMode() async throws {
        enum Failure: Error { case rejected }
        let fixture = try QuickRuleFixture(yaml: "find-process-mode: off\nrules: ['MATCH,DIRECT']\n")
        defer { fixture.clean() }
        let document = try NativeRuleService(homeDirectory: fixture.root).read(configURL: fixture.config)
        let edit = try ApplicationRuleService(homeDirectory: fixture.root).prepare(
            rule: QuickRoutingRule(type: .processName, target: "curl", policy: "REJECT"),
            document: document, enableProcessLookup: true)
        let runtime: [String: JSONValue] = ["find-process-mode": .string("off"), "mixed-port": .int(9098)]
        let previous = try fixture.service.reloadPayload(edit.originalData, runtime: runtime)
        var restored = false
        await #expect(throws: Failure.self) {
            try await fixture.service.commit(edit, validate: { _ in }, didWrite: {}, apply: {
                #expect(try ApplicationRuleService.processMode(in: Data(contentsOf: fixture.config)) == "strict")
                throw Failure.rejected
            }, restoreRuntime: {
                #expect(try Data(contentsOf: fixture.config) == edit.originalData)
                let settings = try #require(try Yams.load(yaml: previous) as? [String: Any])
                #expect(settings["find-process-mode"] as? String == "off")
                #expect(settings["mixed-port"] as? Int == 9098)
                restored = true
            })
        }
        #expect(restored)
    }

    @Test func stoppedCoreSavesNativeProcessRuleAndRejectsStaleContext() async throws {
        let environment = try NativeRuleTestEnvironment()
        defer { environment.clean() }
        let model = environment.model
        let context = try await model.applicationRuleContext()
        let rule = try QuickRoutingRule(type: .processPath, target: "/usr/bin/curl", policy: "OpenAI")
        let result = try await model.saveApplicationRule(rule, context: context, enableProcessLookup: true)
        #expect(!result.applied && result.backupURL != nil)
        #expect(model.displayedRuleItems.first?.type == "PROCESS-PATH")
        #expect(model.displayedRuleItems.first?.nativeEntry?.isCustom == true)
        #expect(!model.pendingConfigChangeRestart && !model.isQuickRuleSaving)
        #expect(try ApplicationRuleService.processMode(in: Data(contentsOf: environment.config)) == "strict")
        let saved = try Data(contentsOf: environment.config)
        await #expect(throws: QuickRuleError.self) {
            try await model.saveApplicationRule(rule, context: context, enableProcessLookup: true)
        }
        #expect(try Data(contentsOf: environment.config) == saved)
    }

    @Test func remoteAndBusyStatesBlockApplicationEditing() throws {
        let environment = try NativeRuleTestEnvironment()
        defer { environment.clean() }
        let model = environment.model
        model.isQuickRuleSaving = true
        #expect(!model.canEditApplicationRules)
        model.isQuickRuleSaving = false
        model.isOpeningApplicationRules = true
        #expect(!model.canEditApplicationRules)
        model.isOpeningApplicationRules = false
        let machine = RemoteMachine(name: "test", host: "127.0.0.1", port: 1)
        model.remoteMachineStore.addMachine(machine)
        model.remoteMachineStore.selectTarget(.remote(machine))
        #expect(!model.canEditApplicationRules)
        #expect(L10n.t("ui.app_rule.title", language: .en) == "Route by Application")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLASHBAR_TEST_RENDER_DIR"] != nil))
    func renderApplicationRoutingForVisualReview() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CLASHBAR_TEST_RENDER_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let environment = try NativeRuleTestEnvironment()
        defer { environment.clean() }
        let model = environment.model
        let chrome = ApplicationRoutingCandidate(name: "Google Chrome", processName: "Google Chrome",
            processPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", bundlePath: nil)
        let curl = ApplicationRoutingCandidate(name: "curl", processName: "curl", processPath: "/usr/bin/curl", bundlePath: nil)
        let context = ApplicationRuleEditorContext(document: try #require(model.nativeRuleDocument), selected: chrome,
            observed: [chrome, curl], processMode: "off", fileProcessMode: "off", isSubscription: true)
        for language in AppLanguage.allCases {
            model.uiLanguage = language
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let size = CGSize(width: 460, height: 690)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                let view = ApplicationRuleEditorView(context: context, applications: [chrome, curl]).environmentObject(model)
                    .environment(\.colorScheme, scheme).background(scheme == .light ? Color.white : Color.black)
                let host = NSHostingView(rootView: view)
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("app-routing-\(language.rawValue)-\(name).png"))
            }
        }
    }
}
