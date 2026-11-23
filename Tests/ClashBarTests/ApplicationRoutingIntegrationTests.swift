import Darwin
import Foundation
import Testing

@testable import ClashBar

/// Optional existing privileged executable, always with an independent process, ports and directory.
private final class ApplicationRoutingPrivilegedTestCore: MihomoControlling, @unchecked Sendable {
    let binary: String
    let process = Process()
    init(binary: String) { self.binary = binary }
    var status: CoreLifecycleStatus { self.process.isRunning ? .running(pid: self.process.processIdentifier) : .stopped }
    var isRunning: Bool { self.process.isRunning }
    var detectedBinaryPath: String? { self.binary }
    func validateConfigAsync(configPath: String) async throws {
        let validation = Process()
        validation.executableURL = URL(fileURLWithPath: self.binary)
        validation.arguments = ["-d", URL(fileURLWithPath: configPath).deletingLastPathComponent().path, "-f", configPath, "-t"]
        validation.standardOutput = FileHandle.nullDevice
        validation.standardError = FileHandle.nullDevice
        try validation.run()
        for _ in 0..<200 {
            if !validation.isRunning { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        if validation.isRunning { validation.terminate() }
        validation.waitUntilExit()
        guard validation.terminationStatus == 0 else { throw QuickRuleError.invalidConfig }
    }
    func startAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus {
        self.process.executableURL = URL(fileURLWithPath: self.binary)
        self.process.arguments = ["-d", URL(fileURLWithPath: configPath).deletingLastPathComponent().path,
                                  "-f", configPath, "-ext-ctl", controller]
        self.process.standardOutput = FileHandle.nullDevice
        self.process.standardError = FileHandle.nullDevice
        try self.process.run()
        return self.status
    }
    private func stopProcess() { if self.process.isRunning { self.process.terminate(); self.process.waitUntilExit() } }
    func stop() { self.stopProcess() }
    func stopAsync() async { self.stopProcess() }
    func restartAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus {
        Issue.record("Application routing must not restart the core")
        throw QuickRuleError.invalidConfig
    }
}

@MainActor
struct ApplicationRoutingIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"] != nil),
          arguments: [QuickRuleType.processName, .processPath])
    func processRulesEnableLookupKeepPIDAndEstablishedTCP(type: QuickRuleType) async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"])
        let privileged = ProcessInfo.processInfo.environment["CLASHBAR_TEST_PROCESS_PRIVILEGES"] == "1"
        let override: (any MihomoControlling)? = privileged ? ApplicationRoutingPrivilegedTestCore(binary: binary) : nil
        let environment = try NativeRuleTestEnvironment(realCoreBinary: privileged ? nil : binary, coreOverride: override)
        let model = environment.model
        defer { model.processManager.stop(); environment.clean() }
        let apiPort = try self.availablePort()
        var proxyPort = try self.availablePort()
        while proxyPort == apiPort { proxyPort = try self.availablePort() }
        let fileMode = type == .processName ? "strict" : "off"
        let yaml = """
            mixed-port: \(proxyPort)
            external-controller: 127.0.0.1:\(apiPort)
            mode: rule
            log-level: debug
            find-process-mode: \(fileMode)
            tun: {enable: false, stack: system, mtu: 1500}
            rules: ['MATCH,DIRECT']
            """
        try Data(yaml.utf8).write(to: environment.config)
        model.externalControllerDisplay = "127.0.0.1:\(apiPort)"
        model.controller = model.externalControllerDisplay
        model.localExternalControllerDisplay = model.externalControllerDisplay
        model.controllerSecret = nil
        if let core = model.processManager as? MihomoProcessManager {
            core.onLog = { line in
                if line.contains("[Process]") { print("Independent core process lookup: \(line)") }
            }
        }
        model.defaults.set(environment.config.path, forKey: model.lastSuccessfulConfigPathKey)
        let status = try await model.processManager.startAsync(configPath: environment.config.path, controller: model.controller)
        guard case .running(let pid) = status else { throw QuickRuleError.invalidConfig }
        let client = MihomoAPIService(controller: "127.0.0.1:\(apiPort)", secret: nil)
        for _ in 0..<100 {
            if let _: VersionInfo = try? await client.request(.version) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let _: VersionInfo = try await client.request(.version)
        // Exercise runtime off with a strict on-disk file, as well as an off on-disk file.
        if fileMode == "strict" {
            try await client.requestNoResponse(.putConfigs(force: false, path: "", payload: yaml.replacingOccurrences(of: "find-process-mode: strict", with: "find-process-mode: off")))
        }
        try await client.requestNoResponse(.patchConfigs(body: ["ipv6": .bool(true), "tcp-concurrent": .bool(true),
            "tun": .object(["enable": .bool(false), "stack": .string("gvisor"), "mtu": .int(9000)])]))
        let originalRuntime: [String: JSONValue] = try await client.request(.getConfigs)
        #expect(originalRuntime["find-process-mode"]?.foundationObject as? String == "off")
        let initialRules: RulesSummary = try await client.request(.rules)
        model.ruleItems = initialRules.rules
        model.refreshNativeRuleDocument()
        let ready = environment.home.appendingPathComponent("app-probe-ready")
        let done = environment.home.appendingPathComponent("app-probe-done")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/probe_application_routing.py")
        let probe = Process()
        let output = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        probe.arguments = [script.path, String(proxyPort), ready.path, done.path, String(apiPort)]
        probe.standardOutput = output
        probe.standardError = output
        try probe.run()
        defer { if probe.isRunning { probe.terminate(); probe.waitUntilExit() } }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: ready.path) || !probe.isRunning { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let identity = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: String])
        let target = try #require(identity[type == .processName ? "process_name" : "process_path"])
        let context = try await model.applicationRuleContext()
        #expect(context.processMode == "off")
        let rule = try QuickRoutingRule(type: type, target: target, policy: "REJECT")
        let originalFile = try Data(contentsOf: environment.config)
        await #expect(throws: ApplicationRoutingError.self) {
            try await model.saveApplicationRule(rule, context: context, enableProcessLookup: false)
        }
        #expect(try Data(contentsOf: environment.config) == originalFile)
        let result = try await model.saveApplicationRule(rule, context: context, enableProcessLookup: true)
        #expect(result.applied && result.backupURL != nil)
        let after: [String: JSONValue] = try await client.request(.getConfigs)
        #expect(after["find-process-mode"]?.foundationObject as? String == "strict")
        #expect(after["mixed-port"]?.foundationObject as? Int == Int(proxyPort))
        #expect(after["ipv6"]?.foundationObject as? Bool == true)
        #expect(after["tcp-concurrent"]?.foundationObject as? Bool == true)
        #expect((after["tun"]?.foundationObject as? NSDictionary) == (originalRuntime["tun"]?.foundationObject as? NSDictionary))
        #expect(model.processManager.isRunning)
        if case .running(let afterPID) = model.processManager.status { #expect(afterPID == pid) }
        else { Issue.record("Core stopped") }
        let rules: RulesSummary = try await client.request(.rules)
        #expect(rules.rules.first?.payload == target && rules.rules.first?.proxy == "REJECT")
        #expect(model.nativeRulesMatchRuntime)
        try await model.processManager.validateConfigAsync(configPath: environment.config.path)
        try Data("done".utf8).write(to: done)
        for _ in 0..<150 {
            if !probe.isRunning { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        if probe.isRunning { probe.terminate() }
        probe.waitUntilExit()
        let report = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        print("Independent application routing probe (\(type.rawValue)): \(report)")
        #expect(probe.terminationStatus == 0)
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
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) } }
        guard bound == 0 else { throw CocoaError(.fileReadUnknown) }
        var length = size
        let read = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        guard read == 0 else { throw CocoaError(.fileReadUnknown) }
        return UInt16(bigEndian: address.sin_port)
    }
}
