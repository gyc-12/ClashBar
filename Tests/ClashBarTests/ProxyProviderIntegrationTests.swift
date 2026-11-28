import Darwin
import Foundation
import Network
import Testing

@testable import ClashBar

@MainActor
struct ProxyProviderIntegrationTests {
    private struct Ports: Decodable { let http: UInt16; let first: UInt16; let second: UInt16; let socks: UInt16; let gate: UInt16 }
    private struct RuntimeConnections: Decodable {
        struct Connection: Decodable { let providerChains: [String]? }
        let connections: [Connection]?
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"] != nil))
    func managesSubscriptionsAndMeasuresProviderConnections() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"])
        let environment = try NativeRuleTestEnvironment(realCoreBinary: binary)
        defer { environment.clean() }
        let fixturePath = environment.home.appendingPathComponent("fixture.json")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/probe_proxy_providers.py")
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = [script.path, fixturePath.path]
        try fixture.run()
        defer { if fixture.isRunning { _ = Darwin.kill(fixture.processIdentifier, SIGKILL) } }
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: fixturePath.path) { try await Task.sleep(for: .milliseconds(50)) }
        let ports = try JSONDecoder().decode(Ports.self, from: Data(contentsOf: fixturePath))
        let (apiPort, proxyPort) = try (freePort(), freePort())
        try #require(apiPort != proxyPort)
        let model = environment.model
        let address = "127.0.0.1:\(apiPort)"
        let source = "http://127.0.0.1:\(ports.http)"
        let yaml = """
            mixed-port: \(proxyPort)
            external-controller: \(address)
            mode: rule
            tun: {enable: false, stack: system}
            ipv6: false
            find-process-mode: off
            proxies:
              - {name: bootstrap, type: socks5, server: 127.0.0.1, port: \(ports.socks)}
            proxy-providers:
              A: {type: http, url: '\(source)/first', path: ./a.yaml, interval: 3600}
              B: {type: http, url: '\(source)/second', path: ./b.yaml, interval: 3600}
            proxy-groups:
              - {name: proxy, type: select, proxies: [bootstrap]}
              - {name: us, type: select, proxies: [DIRECT]}
              - {name: First, type: select, use: [A]}
              - {name: Second, type: select, use: [B]}
              - {name: Auto, type: select, include-all-providers: true}
              - {name: Filtered, type: select, include-all-providers: true, filter: '^first$'}
            rules:
              - DST-PORT,\(ports.first),First
              - DST-PORT,\(ports.second),Second
              - MATCH,DIRECT
            """
        let original = Data(yaml.utf8)
        try original.write(to: environment.config)
        model.refreshNativeRuleDocument()
        model.openProxyProviderEditor(.add)
        #expect(model.proxyProviderEditorContext?.willReload == false)
        model.proxyProviderEditorContext = nil
        let offline = try #require(model.nativeProxyProviderDocument)
        #expect(try await model.saveProxyProvider(.add(name: "Offline", url: "\(source)/first", interval: 3600,
                                                      healthCheckURL: nil, groups: []), document: offline, fallback: nil) == false)
        #expect(model.nativeProxyProviderDocument?.activeNames.contains("Offline") == true)
        try original.write(to: environment.config)
        model.refreshNativeRuleDocument()
        model.controller = address
        let client = MihomoAPIService(controller: address, secret: nil)
        let core = model.processManager
        _ = try await core.start(configPath: environment.config.path, controller: address)
        defer { core.stopImmediately() }
        model.rememberAppliedProviderConfig(url: environment.config, data: original)
        let pid = core.status
        for _ in 0..<25 {
            if let summary: ProviderSummary = try? await client.request(.proxyProviders),
               summary.providers["A"]?.proxies?.count == 1, summary.providers["B"]?.proxies?.count == 1 { break }
            try await Task.sleep(for: .milliseconds(60))
        }
        try await client.requestNoResponse(.patchConfigs(body: ["ipv6": .bool(true), "find-process-mode": .string("strict")]))
        let first = try await tunnel(proxyPort: proxyPort, destination: ports.first)
        defer { first.cancel() }
        let second = try await tunnel(proxyPort: proxyPort, destination: ports.second)
        defer { second.cancel() }
        try await send(first, bytes: [1]); try await send(second, bytes: [2])
        #expect(try await receive(first, size: 1) == [1]); #expect(try await receive(second, size: 1) == [2])
        let observed: RuntimeConnections = try await client.request(.connections(interval: nil))
        #expect(observed.connections?.contains { $0.providerChains?.contains("A") == true } == true)
        #expect(observed.connections?.contains { $0.providerChains?.contains("B") == true } == true)

        let old = try #require(model.nativeProxyProviderDocument)
        do {
            _ = try await model.saveProxyProvider(.setEnabled(name: "A", enabled: false), document: old, fallback: nil)
            Issue.record("Expected a fallback requirement")
        } catch { #expect(error as? NativeProxyProviderError == .emptyGroups(["First"])) }
        #expect(try Data(contentsOf: environment.config) == original)
        #expect(try await model.saveProxyProvider(.setEnabled(name: "A", enabled: false), document: old, fallback: .reject))
        let disabled: ProviderSummary = try await client.request(.proxyProviders)
        let groups: ProxyGroupsResponse = try await client.request(.proxies)
        #expect(disabled.providers["A"] == nil)
        do {
            try await client.requestNoResponse(.updateProxyProvider(name: "A"))
            Issue.record("Disabled provider still accepts updates")
        } catch APIError.statusCode(404, _) {}
        #expect(groups.proxies["Auto"]?.all == ["second"])
        #expect(groups.proxies["First"]?.all == ["REJECT"])
        #expect(groups.proxies["Filtered"]?.all == ["REJECT"])
        #expect(model.nativeProxyProviderDocument?.entries.first(where: { $0.name == "A" })?.enabled == false)
        #expect(core.status == pid)
        let configs: [String: JSONValue] = try await client.request(.getConfigs)
        if case .bool(true) = configs["ipv6"] {} else { Issue.record("IPv6 setting was lost") }
        if case .string("strict") = configs["find-process-mode"] {} else { Issue.record("Process mode was lost") }
        if case .int(Int(proxyPort)) = configs["mixed-port"] {} else { Issue.record("Mixed port was lost") }
        let targetContinued = await exchanges(first, value: 3)
        let otherContinued = await exchanges(second, value: 4)
        print("Provider reload connection probe: target A continued=\(targetContinued), retained B continued=\(otherContinued)")
        #expect(!otherContinued)
        let afterDisable = try #require(model.nativeProxyProviderDocument)
        #expect(try await model.saveProxyProvider(.setEnabled(name: "A", enabled: true), document: afterDisable, fallback: nil))
        let restored: ProxyGroupsResponse = try await client.request(.proxies)
        #expect(restored.proxies["Auto"]?.all == ["first", "second"])
        #expect(restored.proxies["First"]?.all == ["first"])
        let afterEnable = try #require(model.nativeProxyProviderDocument)
        #expect(try await model.saveProxyProvider(.edit(name: "A", url: "\(source)/replacement?Token=A%2B"), document: afterEnable, fallback: .reject))
        let changed: ProviderSummary = try await client.request(.proxyProviders)
        #expect(changed.providers["A"]?.proxies?.map(\.name) == ["replacement"])
        #expect(try Data(contentsOf: environment.config) != original)
        let saved = try #require(model.nativeProxyProviderDocument)
        do {
            _ = try await model.saveProxyProvider(.edit(name: "A", url: "\(source)/invalid"), document: saved, fallback: nil)
            Issue.record("Invalid subscription should fail before writing")
        } catch { #expect(error as? NativeProxyProviderError == .sourceFailed) }
        #expect(try Data(contentsOf: environment.config) == saved.data)
        let afterFailure: ProviderSummary = try await client.request(.proxyProviders)
        #expect(afterFailure.providers["A"]?.proxies?.map(\.name) == ["replacement"])
        #expect(core.status == pid)
        do {
            _ = try await model.saveProxyProvider(.edit(name: "A", url: "\(source)/fails-on-apply"), document: saved, fallback: nil)
            Issue.record("Expected runtime verification to fail after the isolated test succeeded")
        } catch { #expect(error as? NativeProxyProviderError == .reloadFailed) }
        #expect(try Data(contentsOf: environment.config) == saved.data)
        #expect(model.nativeProvidersMatchRunningConfig)
        let rolledBack: ProviderSummary = try await client.request(.proxyProviders)
        #expect(rolledBack.providers["A"]?.proxies?.map(\.name) == ["replacement"])
        #expect(core.status == pid)
        let beforeDelete = try #require(model.nativeProxyProviderDocument)
        #expect(try await model.saveProxyProvider(.delete(name: "B"), document: beforeDelete, fallback: .reject))
        #expect(model.nativeProxyProviderDocument?.entries.map(\.name) == ["A"])
        let deleted: ProviderSummary = try await client.request(.proxyProviders)
        #expect(deleted.providers["B"] == nil)

        func apply(_ action: NativeProxyProviderAction) async throws {
            let document = try #require(model.nativeProxyProviderDocument)
            #expect(try await model.saveProxyProvider(action, document: document, fallback: nil))
        }
        try await apply(.group(name: "proxy", members: ["bootstrap", "us"]))
        let nested: ProxyGroupsResponse = try await client.request(.proxies)
        #expect(nested.proxies["proxy"]?.all == ["bootstrap", "us"])
        try await apply(.group(name: "proxy", members: ["bootstrap"]))
        try await apply(.group(name: "us", members: nil))
        let remaining: ProxyGroupsResponse = try await client.request(.proxies)
        #expect(remaining.proxies["us"] == nil)
        let gated = "http://127.0.0.1:\(ports.gate)"
        let customOptions = SubscriptionOptions(prefix: "HK-")
        try await apply(.add(name: "Routed", url: gated + "/first", interval: nil, healthCheckURL: source, groups: [], options: customOptions))
        let result: ProviderSummary = try await client.request(.proxyProviders)
        #expect(result.providers["Routed"]?.proxies?.map(\.name) == ["HK-first"])
        let afterRetry = try #require(model.nativeProxyProviderDocument)
        let root = try NativeProxyProviderService().expandedConfig(afterRetry.data)
        #expect(root["proxy-providers"]?["Routed"]?["proxy"]?.string == "proxy")
        #expect(root["proxy-providers"]?["Routed"]?["interval"]?.int == SubscriptionOptions.defaultInterval)
        try await apply(.edit(name: "Routed", newName: "RenamedRouted", url: gated + "/first", interval: 600,
                              healthCheckURL: source, options: SubscriptionOptions(downloadProxy: "proxy", prefix: "")))
        let afterRename: ProviderSummary = try await client.request(.proxyProviders)
        #expect(afterRename.providers["Routed"] == nil)
        #expect(afterRename.providers["RenamedRouted"]?.proxies?.map(\.name) == ["first"])
        let renamedDoc = try #require(model.nativeProxyProviderDocument)
        do {
            try await apply(.add(name: "Invalid", url: gated + "/invalid", interval: nil, healthCheckURL: source, groups: []))
            Issue.record("Expected both download routes to fail")
        } catch { #expect(error as? NativeProxyProviderError == .retryFailed("proxy")) }
        #expect(try Data(contentsOf: environment.config) == renamedDoc.data)
        #expect(core.status == pid)
    }

    private func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try #require(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } } == 0)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        try #require(result == 0)
        return UInt16(bigEndian: address.sin_port)
    }

    private func tunnel(proxyPort: UInt16, destination: UInt16) async throws -> NWConnection {
        let port = try #require(NWEndpoint.Port(rawValue: proxyPort))
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        connection.start(queue: .global(qos: .utility))
        let timeout = Task { try await Task.sleep(for: .seconds(5)); connection.cancel() }
        defer { timeout.cancel() }
        try await send(connection, bytes: [5, 1, 0])
        try #require(try await receive(connection, size: 2) == [5, 0])
        try await send(connection, bytes: [5, 1, 0, 1, 127, 0, 0, 1, UInt8(destination >> 8), UInt8(destination & 0xff)])
        let reply = try await receive(connection, size: 4)
        try #require(reply.count == 4 && reply[1] == 0)
        if reply[3] == 1 { _ = try await receive(connection, size: 6) }
        else if reply[3] == 4 { _ = try await receive(connection, size: 18) }
        else { try #require(Bool(false), "Unexpected SOCKS reply") }
        return connection
    }

    private func send(_ connection: NWConnection, bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func receive(_ connection: NWConnection, size: Int) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: size, maximumLength: size) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data.map(Array.init) ?? []) }
            }
        }
    }

    private func exchanges(_ connection: NWConnection, value: UInt8) async -> Bool {
        let timeout = Task { try await Task.sleep(for: .seconds(2)); connection.cancel() }
        defer { timeout.cancel() }
        do {
            try await send(connection, bytes: [value])
            return try await receive(connection, size: 1) == [value]
        } catch { return false }
    }
}
