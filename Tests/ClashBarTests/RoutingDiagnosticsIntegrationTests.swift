import Darwin
import Foundation
import Testing

@testable import ClashBar

@MainActor
struct RoutingDiagnosticsIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"] != nil))
    func realCoreSuppliesMeasurementTimesRuleHitsAndConnectionEndpointsWithoutRestart() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"])
        var ports = Set<UInt16>()
        while ports.count < 3 { ports.insert(try self.availablePort()) }
        let ordered = ports.sorted()
        let apiPort = ordered[0], proxyPort = ordered[1], httpPort = ordered[2]
        let fixture = try QuickRuleFixture(yaml: """
            mixed-port: \(proxyPort)
            external-controller: 127.0.0.1:\(apiPort)
            mode: rule
            log-level: silent
            find-process-mode: always
            tun: {enable: false}
            proxy-groups:
              - {name: Auto, type: url-test, proxies: [DIRECT], url: 'http://127.0.0.1:\(httpPort)/check', interval: 120, lazy: false}
            rules:
              - NETWORK,tcp,Auto
              - MATCH,DIRECT
            """)
        defer { fixture.clean() }
        let originalData = try Data(contentsOf: fixture.config)
        let core = Process()
        core.executableURL = URL(fileURLWithPath: binary)
        core.arguments = ["-d", fixture.root.path, "-f", fixture.config.path]
        core.standardOutput = FileHandle.nullDevice
        core.standardError = FileHandle.nullDevice
        try core.run()
        defer { if core.isRunning { core.terminate(); core.waitUntilExit() } }
        let pid = core.processIdentifier
        let client = MihomoAPIService(controller: "127.0.0.1:\(apiPort)", secret: nil)
        var ready = false
        for _ in 0..<100 {
            if let _: VersionInfo = try? await client.request(.version) { ready = true; break }
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(ready)
        let readyFile = fixture.root.appendingPathComponent("ready")
        let doneFile = fixture.root.appendingPathComponent("done")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/probe_routing_diagnostics.py")
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        probe.arguments = [script.path, String(httpPort), String(proxyPort), readyFile.path, doneFile.path]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        defer {
            try? Data().write(to: doneFile)
            if probe.isRunning { probe.terminate(); probe.waitUntilExit() }
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: readyFile.path) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(FileManager.default.fileExists(atPath: readyFile.path))
        let measured: GroupDelayMeasurement = try await client.request(
            .groupDelay(name: "Auto", url: "http://127.0.0.1:\(httpPort)/check", timeout: 2000))
        #expect((measured.values["DIRECT"] ?? 0) > 0)
        let proxies: ProxyGroupsResponse = try await client.request(.proxies)
        let sample = try #require(proxies.proxies["DIRECT"]?.latencyHistory.last)
        #expect(sample.time != nil)
        let next: ProxyGroupsResponse = try await client.request(.proxies)
        #expect(next.proxies["DIRECT"]?.latencyHistory.last?.time == sample.time)
        let rules: RulesSummary = try await client.request(.rules)
        #expect((rules.rules[0].statistics?.hitCount ?? 0) > 0)
        #expect(rules.rules[0].statistics?.hitAt != nil)
        let connections: ConnectionsSnapshot = try await client.request(.connections(interval: nil))
        let held = try #require(connections.connections.first { $0.metadata?.destinationPort == String(httpPort) })
        #expect(held.metadata?.sourcePort != nil)
        #expect(held.metadata?.destinationIP == "127.0.0.1")
        #expect(held.chains?.contains("Auto") == true)
        #expect(ConnectionRuleMatcher.candidates(for: held, in: rules.rules).count == 1)
        #expect(core.isRunning && core.processIdentifier == pid)
        #expect(try Data(contentsOf: fixture.config) == originalData)
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
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        guard result == 0 else { throw CocoaError(.fileReadUnknown) }
        var length = size
        let read = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard read == 0 else { throw CocoaError(.fileReadUnknown) }
        return UInt16(bigEndian: address.sin_port)
    }
}
