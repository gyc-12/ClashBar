import Darwin
import Foundation
import Testing

@testable import ClashBar

@MainActor
struct NativeRuleReloadIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"] != nil))
    func retainsPIDAndEstablishedTCPWhileNewConnectionsUseEditedPolicy() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"])
        let apiPort = try self.availablePort()
        var proxyPort = try self.availablePort()
        while proxyPort == apiPort { proxyPort = try self.availablePort() }
        let fixture = try QuickRuleFixture(
            yaml: """
                mixed-port: \(proxyPort)
                external-controller: 127.0.0.1:\(apiPort)
                mode: rule
                log-level: silent
                ipv6: false
                tcp-concurrent: false
                tun: {enable: false, stack: system, mtu: 1500}
                rules:
                  - NETWORK,tcp,DIRECT
                  - MATCH,DIRECT
                """)
        defer { fixture.clean() }
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
        let pid = core.processIdentifier
        let client = MihomoAPIService(controller: "127.0.0.1:\(apiPort)", secret: nil)
        var ready = false
        for _ in 0..<80 {
            if let _: VersionInfo = try? await client.request(.version) {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(ready)
        try await client.requestNoResponse(
            .patchConfigs(body: [
                "ipv6": .bool(true), "tcp-concurrent": .bool(true),
                "tun": .object(["enable": .bool(false), "stack": .string("gvisor"), "mtu": .int(9000)]),
            ]))
        let runtime: [String: JSONValue] = try await client.request(.getConfigs)
        let service = NativeRuleService(homeDirectory: fixture.root)
        let document = try service.read(configURL: fixture.config)
        let entry = document.entries[0]
        let edit = try service.prepare(
            document: document, entry: entry, raw: try entry.syntax!.replacingTarget("REJECT"), isCustom: entry.isCustom
        )
        let payload = try fixture.service.reloadPayload(edit.updatedData, runtime: runtime)
        let previous = try fixture.service.reloadPayload(edit.originalData, runtime: runtime)
        let probe = Process()
        let output = Pipe()
        let readyFile = fixture.root.appendingPathComponent("probe-ready")
        let doneFile = fixture.root.appendingPathComponent("reload-done")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/probe_native_rule_reload.py")
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        probe.arguments = [script.path, String(proxyPort), readyFile.path, doneFile.path]
        probe.standardOutput = output
        probe.standardError = output
        try probe.run()
        defer {
            if probe.isRunning {
                probe.terminate()
                probe.waitUntilExit()
            }
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: readyFile.path) || !probe.isRunning { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(FileManager.default.fileExists(atPath: readyFile.path))
        _ = try await fixture.service.commit(
            edit,
            validate: { path in
                let validation = Process()
                validation.executableURL = URL(fileURLWithPath: binary)
                validation.arguments = ["-d", fixture.root.path, "-f", path, "-t"]
                validation.standardOutput = FileHandle.nullDevice
                validation.standardError = FileHandle.nullDevice
                try validation.run()
                for _ in 0..<100 {
                    if !validation.isRunning { break }
                    try await Task.sleep(for: .milliseconds(30))
                }
                if validation.isRunning { validation.terminate() }
                validation.waitUntilExit()
                try #require(validation.terminationStatus == 0)
            }, didWrite: {},
            apply: {
                try await client.requestNoResponse(.putConfigs(force: false, path: "", payload: payload))
            },
            restoreRuntime: {
                try await client.requestNoResponse(.putConfigs(force: false, path: "", payload: previous))
            })
        try Data("done".utf8).write(to: doneFile)
        for _ in 0..<100 {
            if !probe.isRunning { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        if probe.isRunning { probe.terminate() }
        probe.waitUntilExit()
        let report = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        print("Independent native rule reload probe: \(report)")
        #expect(probe.terminationStatus == 0)
        #expect(core.isRunning && core.processIdentifier == pid)
        let updated: RulesSummary = try await client.request(.rules)
        #expect(updated.rules.first?.proxy == "REJECT")
        let after: [String: JSONValue] = try await client.request(.getConfigs)
        #expect(
            (after["tun"]?.foundationObject as? NSDictionary) == (runtime["tun"]?.foundationObject as? NSDictionary))
        #expect(after["ipv6"]?.foundationObject as? Bool == true)
        #expect(after["tcp-concurrent"]?.foundationObject as? Bool == true)
        #expect(after["mixed-port"]?.foundationObject as? Int == Int(proxyPort))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"] != nil))
    func specialRulesCorrespondToRuntimeAndValidateAfterPolicyEdits() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"])
        let port = try self.availablePort()
        let fixture = try QuickRuleFixture(
            yaml: """
                mixed-port: 0
                external-controller: 127.0.0.1:\(port)
                log-level: silent
                rule-providers:
                  local: {type: file, behavior: domain, format: text, path: ./domains.txt}
                sub-rules:
                  nested: ['MATCH,DIRECT']
                  another: ['MATCH,REJECT']
                rules:
                  - DOMAIN-SUFFIX,example.com,DIRECT
                  - DST-PORT,443,DIRECT
                  - RULE-SET,local,DIRECT
                  - IP-CIDR,192.0.2.0/24,DIRECT,no-resolve
                  - AND,((DOMAIN,a.example),(DST-PORT,443)),DIRECT
                  - SUB-RULE,(NETWORK,tcp),nested
                  - MATCH,DIRECT
                """)
        defer { fixture.clean() }
        try Data("+.example.com\n".utf8).write(to: fixture.root.appendingPathComponent("domains.txt"))
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
        for _ in 0..<80 {
            if let _: VersionInfo = try? await client.request(.version) {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(ready)
        let service = NativeRuleService(homeDirectory: fixture.root)
        let document = try service.read(configURL: fixture.config)
        let rules: RulesSummary = try await client.request(.rules)
        print("Special rule correspondence: \(rules.rules)")
        #expect(document.matchesRuntime(rules.rules))
        for entry in document.entries {
            let target = entry.syntax?.targetsSubRule == true ? "another" : "REJECT"
            let edit = try service.prepare(
                document: document, entry: entry, raw: try entry.syntax!.replacingTarget(target), isCustom: true)
            let staged = try fixture.service.validationFiles(for: edit)
            defer { staged.files.forEach { try? FileManager.default.removeItem(at: $0) } }
            let validation = Process()
            validation.executableURL = URL(fileURLWithPath: binary)
            validation.arguments = ["-d", fixture.root.path, "-f", staged.config.path, "-t"]
            validation.standardOutput = FileHandle.nullDevice
            validation.standardError = FileHandle.nullDevice
            try validation.run()
            for _ in 0..<100 {
                if !validation.isRunning { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            if validation.isRunning { validation.terminate() }
            validation.waitUntilExit()
            #expect(validation.terminationStatus == 0)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"] != nil))
    func appSaveEntryPointAndDirectoryMonitorDoNotRestartCore() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"])
        let environment = try NativeRuleTestEnvironment(realCoreBinary: binary)
        defer { environment.clean() }
        let model = environment.model
        let controller = "127.0.0.1:\(try self.availablePort())"
        try Data("mixed-port: 0\nlog-level: silent\ntun: {enable: false}\nrules: ['MATCH,DIRECT']\n".utf8).write(
            to: environment.config)
        model.refreshNativeRuleDocument()
        let status = try await model.processManager.startAsync(
            configPath: environment.config.path, controller: controller)
        defer {
            model.stopConfigDirectoryMonitoring()
            if let managed = model.processManager as? MihomoProcessManager {
                managed.onLog = nil
                managed.onTermination = nil
            }
            model.processManager.stopImmediately()
        }
        let client = MihomoAPIService(controller: controller, secret: nil)
        var ready = false
        for _ in 0..<80 {
            if let _: VersionInfo = try? await client.request(.version) {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(ready)
        model.controller = controller
        model.defaults.set(environment.config.path, forKey: model.lastSuccessfulConfigPathKey)
        let initial: RulesSummary = try await client.request(.rules)
        model.ruleItems = initial.rules
        try #require(model.nativeRulesMatchRuntime)
        model.startConfigDirectoryMonitoringIfNeeded()
        let document = try #require(model.nativeRuleDocument)
        let result = try await model.saveNativeRule(
            document: document, entry: document.entries[0], raw: "MATCH,REJECT", isCustom: true)
        #expect(result.applied)
        #expect(model.nativeRulesMatchRuntime)
        try await Task.sleep(for: .milliseconds(700))
        #expect(model.processManager.status == status)
        #expect(!model.pendingConfigChangeRestart)
        let rules: RulesSummary = try await client.request(.rules)
        #expect(rules.rules.first?.proxy == "REJECT")
        let marked = try #require(model.nativeRuleDocument)
        _ = try await model.saveNativeRule(
            document: marked, entry: marked.entries[0], raw: marked.entries[0].raw, isCustom: false)
        #expect(model.processManager.status == status)
        #expect(model.displayedRuleItems.first?.nativeEntry?.isCustom == false)
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
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        guard bound == 0 else { throw CocoaError(.fileReadUnknown) }
        var length = size
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0 else { throw CocoaError(.fileReadUnknown) }
        return UInt16(bigEndian: address.sin_port)
    }
}
