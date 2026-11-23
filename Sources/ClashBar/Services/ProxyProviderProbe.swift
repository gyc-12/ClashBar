import CryptoKit
import Darwin
import Foundation
import Yams

struct ProxyProviderProbeResult: Sendable {
    let nodes: [String: [String]]
    let groups: [String: ProxyGroup]
}

/// Uses mihomo's actual subscription parser and group filters without opening any proxy listeners.
struct ProxyProviderProbe {
    let binary: String
    let home: URL

    func inspect(_ edit: NativeProxyProviderEdit) async throws -> ProxyProviderProbeResult {
        let service = NativeProxyProviderService()
        let root = try service.expandedConfig(edit.file.updatedData)
        let active = try service.providerFields(root)
        let suspended = try edit.probeProvider.flatMap { try service.suspendedDefinition($0, data: edit.file.updatedData) }
        var definitions = active
        if let name = edit.probeProvider, let suspended { definitions.append((name, suspended)) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clashbar-provider-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = UUID().uuidString
        var config: Node = ["external-controller": "127.0.0.1:0", "secret": Node(secret), "log-level": "info"]
        for key in ["proxies", "proxy-groups", "hosts", "ipv6", "tls"] { config[key] = root[key] }
        // A disabled source is validated in isolation so it cannot become a member of automatic groups.
        if suspended != nil {
            definitions = definitions.filter { $0.0 == edit.probeProvider }
            config["proxy-groups"] = Node([] as [Node])
            // Preserve named fetch adapters by keeping the original groups if the source explicitly needs one.
            if let proxy = suspended?["proxy"]?.string, proxy != "DIRECT", proxy != "" {
                definitions = active + definitions
                config["proxy-groups"] = root["proxy-groups"]
            }
        }
        // New links must populate their assigned cache. Fallback payloads can't prove they loaded.
        var freshPath: URL?
        for index in definitions.indices {
            let (name, values) = definitions[index]
            var value = values
            let type = value["type"]?.string
            if type == "http" || type == "file" {
                let target = directory.appendingPathComponent("provider-\(index).yaml")
                let isNewSource = edit.freshSource && name == edit.probeProvider
                if !isNewSource, let original = Self.cacheURL(of: value, home: home)?.resolvingSymlinksInPath(),
                   (try? original.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                   FileManager.default.isReadableFile(atPath: original.path) {
                    // Always copy the contents into the probe directory; never share a live cache path.
                    try FileManager.default.copyItem(at: original, to: target)
                } else if type == "file" {
                    throw NativeProxyProviderError.sourceFailed
                }
                value["path"] = Node(target.lastPathComponent)
                value["interval"] = 0
                if isNewSource { freshPath = target }
            }
            value["health-check"] = ["enable": falseNode]
            definitions[index].1 = value
        }
        config["proxy-providers"] = Node(definitions.map { (Node($0.0, Tag(.str), .singleQuoted), $0.1) })
        // Run group filtering with the original group options; direct any automatic health check to loopback.
        if let groups = config["proxy-groups"]?.array() {
            config["proxy-groups"] = Node(groups.map { original in
                var group = original
                group["url"] = "http://127.0.0.1:1/"
                group["interval"] = 86400
                return group
            })
        }
        let configFile = directory.appendingPathComponent("config.yaml")
        let log = directory.appendingPathComponent("probe.log")
        try Data(try service.renderConfig(config).utf8).write(to: configFile)
        guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw NativeProxyProviderError.sourceFailed
        }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.currentDirectoryURL = directory
        process.arguments = ["-d", directory.path, "-f", configFile.path]
        // Do not inherit core override flags, hooks, or environment proxy settings.
        process.environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("CLASH_") && !key.lowercased().hasSuffix("_proxy")
        }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        defer {
            // Foundation reaps Process children. Waiting synchronously can block the AppKit run loop
            // that delivers process termination notifications.
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        let expected = Set(definitions.map(\.0))
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(25)
        var client: MihomoAPIService?
        while clock.now < deadline, process.isRunning {
            try Task.checkCancellation()
            let text = try? String(contentsOf: log, encoding: .utf8)
            if let text, expected.contains(where: { text.contains("initial proxy provider \($0) error:") }) {
                throw NativeProxyProviderError.sourceFailed
            }
            if client == nil, let text,
               let range = text.range(of: "RESTful API listening at: 127.0.0.1:"),
               let port = UInt16(text[range.upperBound...].prefix(while: \.isNumber)), port > 0 {
                client = MihomoAPIService(controller: "127.0.0.1:\(port)", secret: secret)
            }
            if let client, let summary: ProviderSummary = try? await client.request(.proxyProviders) {
                let nodes = summary.providers.filter { expected.contains($0.key) }.mapValues { ($0.proxies ?? []).map(\.name) }
                let ready = nodes.keys.count == expected.count && nodes.values.allSatisfy { !$0.isEmpty }
                let loadedSource = freshPath.map { FileManager.default.fileExists(atPath: $0.path) } ?? true
                if ready && loadedSource, let groups: ProxyGroupsResponse = try? await client.request(.proxies) {
                    return ProxyProviderProbeResult(nodes: nodes, groups: groups.proxies)
                }
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw NativeProxyProviderError.sourceFailed
    }

    static func cacheURL(of values: Node, home: URL) -> URL? {
        if let path = values["path"]?.string, !path.isEmpty {
            return path.hasPrefix("/") ? URL(fileURLWithPath: path) : home.appendingPathComponent(path).standardizedFileURL
        }
        guard values["type"]?.string == "http", let url = values["url"]?.string else { return nil }
        let filename = Insecure.MD5.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        return home.appendingPathComponent("proxies/\(filename)")
    }

    private var falseNode: Node { Node("false", Tag(.bool)) }
}
