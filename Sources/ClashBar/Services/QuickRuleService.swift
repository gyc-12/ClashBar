import Darwin
import Foundation
import Yams

struct LocalRuleProvider: Identifiable, Equatable {
    let name: String
    let url: URL
    let behavior: String
    let format: String
    let policies: [String]
    let originalData: Data
    var id: String { self.name }

    func supports(_ type: QuickRuleType) -> Bool {
        self.behavior == "classical" || (self.behavior == "domain" && [.domain, .domainSuffix].contains(type))
            || (self.behavior == "ipcidr" && type.isIP)
    }

    func entry(for rule: QuickRoutingRule) throws -> String {
        guard self.supports(rule.type) else { throw QuickRuleError.invalidTarget }
        switch self.behavior {
        case "domain": return (rule.type == .domainSuffix ? "+." : "") + rule.target
        case "ipcidr": return rule.target
        default: return "\(rule.type.rawValue),\(rule.target)\(rule.type.isIP ? ",no-resolve" : "")"
        }
    }
}

struct NativeRuleEdit {
    let configURL: URL
    let originalConfig: Data
    let targetURL: URL
    let originalData: Data
    let updatedData: Data
    let provider: LocalRuleProvider?

    var hasChanges: Bool { self.originalData != self.updatedData }

    func checkUnchanged() throws {
        guard try Data(contentsOf: self.configURL) == self.originalConfig,
            try Data(contentsOf: self.targetURL) == self.originalData
        else { throw QuickRuleError.contextChanged }
    }
}

/// Edits only native mihomo files. No private rule database or generated runtime config.
struct QuickRuleService {
    let homeDirectory: URL

    func policies(in data: Data) throws -> [String] {
        let document = try self.document(data)
        let groups = (document["proxy-groups"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let proxies = (document["proxies"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let builtins = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE", "COMPATIBLE", "GLOBAL"]
        return builtins
            + Set(groups + proxies).subtracting(builtins)
            .filter { (try? QuickRoutingRule(type: .domain, target: "example.com", policy: $0)) != nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func localProviders(in data: Data, configURL: URL) throws -> [LocalRuleProvider] {
        let document = try self.document(data)
        let definitions = document["rule-providers"] as? [String: [String: Any]] ?? [:]
        let rules = document["rules"] as? [String] ?? []
        return definitions.compactMap { name, definition in
            guard definition["type"] as? String == "file",
                let path = definition["path"] as? String,
                let behavior = definition["behavior"] as? String,
                ["domain", "ipcidr", "classical"].contains(behavior)
            else { return nil }
            let format = definition["format"] as? String ?? "yaml"
            guard ["yaml", "text"].contains(format) else { return nil }
            let url =
                (path.hasPrefix("/") ? URL(fileURLWithPath: path) : self.homeDirectory.appendingPathComponent(path))
                .standardizedFileURL.resolvingSymlinksInPath()
            let root = self.homeDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard url.path.hasPrefix(root), url != configURL.resolvingSymlinksInPath(),
                FileManager.default.isWritableFile(atPath: url.path),
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                let contents = try? Data(contentsOf: url)
            else { return nil }
            let policies = rules.compactMap { line -> String? in
                let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 3, parts[0] == "RULE-SET", parts[1] == name else { return nil }
                return parts[2]
            }
            guard !policies.isEmpty else { return nil }
            return LocalRuleProvider(
                name: name,
                url: url,
                behavior: behavior,
                format: format,
                policies: Array(Set(policies)).sorted(),
                originalData: contents
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func prepare(rule: QuickRoutingRule, context: QuickRuleEditorContext, providerName: String?) throws
        -> NativeRuleEdit
    {
        guard try Data(contentsOf: context.configURL) == context.originalConfig else {
            throw QuickRuleError.contextChanged
        }
        if let providerName {
            guard
                let provider = try self.localProviders(in: context.originalConfig, configURL: context.configURL)
                    .first(where: { $0.name == providerName }),
                context.providers.contains(provider)
            else { throw QuickRuleError.contextChanged }
            let entry = try provider.entry(for: rule)
            let updated: Data
            if provider.format == "text" {
                guard let text = String(data: provider.originalData, encoding: .utf8) else {
                    throw QuickRuleError.invalidConfig
                }
                let existing = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                let newline = text.contains("\r\n") ? "\r\n" : "\n"
                updated =
                    existing.contains(entry)
                    ? provider.originalData
                    : Data((text + (text.hasSuffix("\n") || text.isEmpty ? "" : newline) + entry + newline).utf8)
            } else {
                updated = try self.editSequence(in: provider.originalData, key: "payload") { entries in
                    entries.contains(entry) ? entries : entries + [entry]
                }
            }
            return NativeRuleEdit(
                configURL: context.configURL,
                originalConfig: context.originalConfig,
                targetURL: provider.url,
                originalData: provider.originalData,
                updatedData: updated,
                provider: provider
            )
        }
        guard try self.policies(in: context.originalConfig).contains(rule.policy) else {
            throw QuickRuleError.invalidPolicy
        }
        let native = NativeRuleService(homeDirectory: self.homeDirectory)
        let updated = try native.prepend(rule: rule, document: native.read(configURL: context.configURL, data: context.originalConfig))
        return NativeRuleEdit(
            configURL: context.configURL,
            originalConfig: context.originalConfig,
            targetURL: context.configURL.resolvingSymlinksInPath(),
            originalData: context.originalConfig,
            updatedData: updated,
            provider: nil
        )
    }

    /// Stage a complete candidate without exposing unvalidated edits to the running core.
    func validationFiles(for edit: NativeRuleEdit) throws -> (config: URL, files: [URL]) {
        let config = edit.configURL.deletingLastPathComponent().appendingPathComponent(
            ".clashbar-check-\(UUID().uuidString).yaml"
        )
        var files = [config]
        do {
            if let provider = edit.provider {
                let staged = provider.url.deletingLastPathComponent().appendingPathComponent(
                    ".clashbar-check-\(UUID().uuidString).rules"
                )
                files.append(staged)
                try self.writePrivate(edit.updatedData, to: staged)
                var document = try self.document(edit.originalConfig)
                var definitions = document["rule-providers"] as? [String: [String: Any]] ?? [:]
                definitions[provider.name]?["path"] = staged.path
                document["rule-providers"] = definitions
                try self.writePrivate(Data(try Yams.dump(object: document, allowUnicode: true).utf8), to: config)
            } else {
                try self.writePrivate(edit.updatedData, to: config)
            }
            return (config, files)
        } catch {
            files.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
    }

    /// Preserve current editable runtime settings during a full native config reload.
    func reloadPayload(_ data: Data, settings: EditableSettingsSnapshot) throws -> String {
        var document = try self.document(data)
        document["mode"] = settings.mode.rawValue
        document["allow-lan"] = settings.allowLan
        document["ipv6"] = settings.ipv6
        document["tcp-concurrent"] = settings.tcpConcurrent
        document["log-level"] = settings.logLevel
        for (key, value) in [
            ("port", settings.port), ("socks-port", settings.socksPort), ("mixed-port", settings.mixedPort),
            ("redir-port", settings.redirPort), ("tproxy-port", settings.tproxyPort),
        ] {
            if let port = Int(value), (0...65535).contains(port) { document[key] = port }
        }
        var tun = document["tun"] as? [String: Any] ?? [:]
        tun["enable"] = settings.tunEnabled
        document["tun"] = tun
        return try Yams.dump(object: document, allowUnicode: true)
    }

    /// Merge the actual core settings, including the complete TUN object, into native YAML.
    func reloadPayload(_ data: Data, runtime: [String: JSONValue], settingsFromFile: Set<String> = []) throws -> String {
        var document = try self.document(data)
        let keys = ["mode", "allow-lan", "ipv6", "tcp-concurrent", "log-level", "port", "socks-port",
                    "mixed-port", "redir-port", "tproxy-port", "tun", "bind-address", "find-process-mode",
                    "interface-name", "sniffing", "skip-auth-prefixes", "lan-allowed-ips", "lan-disallowed-ips"]
        for key in keys {
            if settingsFromFile.contains(key) { continue }
            if let value = runtime[key], case .null = value { continue }
            if let value = runtime[key] { document[key] = value.foundationObject }
        }
        if case .object(let values) = runtime["tun"] {
            var tun = values.mapValues(\.foundationObject)
            // GET /configs omits zero values. RawConfig has nonzero defaults for these fields.
            // Explicit zeros prevent reload from resurrecting addresses/options disabled at runtime.
            for (key, zero) in ["inet6-address": [] as [String], "dns-hijack": [] as [String]] where values[key] == nil { tun[key] = zero }
            if values["recvmsgx"] == nil { tun["recvmsgx"] = false }
            if values["processors-per-channel"] == nil { tun["processors-per-channel"] = 0 }
            document["tun"] = tun
        }
        return try Yams.dump(object: document, width: -1, allowUnicode: true)
    }

    @MainActor
    func commit(
        _ edit: NativeRuleEdit,
        validate: (String) async throws -> Void,
        didWrite: () -> Void,
        apply: () async throws -> Void,
        restoreRuntime: () async throws -> Void
    ) async throws -> URL? {
        try edit.checkUnchanged()
        guard edit.hasChanges else {
            try await apply()
            return nil
        }
        let staged = try self.validationFiles(for: edit)
        defer { staged.files.forEach { try? FileManager.default.removeItem(at: $0) } }
        try await validate(staged.config.path)
        try Task.checkCancellation()
        try edit.checkUnchanged()
        let backup = edit.targetURL.deletingLastPathComponent()
            .appendingPathComponent(".\(edit.targetURL.lastPathComponent).clashbar-backup-\(UUID().uuidString)")
        try self.writePrivate(edit.originalData, to: backup)
        try self.replaceFile(edit.updatedData, at: edit.targetURL)
        didWrite()
        do {
            try await apply()
        } catch {
            let applyError = error
            // Never overwrite a concurrent edit, even when recovering from a failed reload.
            guard try Data(contentsOf: edit.targetURL) == edit.updatedData else {
                throw QuickRuleError.recoveryFailed(backup.path)
            }
            do {
                try self.replaceFile(edit.originalData, at: edit.targetURL)
                didWrite()
                try await restoreRuntime()
            } catch {
                throw QuickRuleError.recoveryFailed(backup.path)
            }
            throw applyError
        }
        return backup
    }

    private func replaceFile(_ data: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".clashbar-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] ?? 0o600
        guard
            FileManager.default.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [.posixPermissions: mode]
            )
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func document(_ data: Data) throws -> [String: Any] {
        guard let text = String(data: data, encoding: .utf8), let document = try Yams.load(yaml: text) as? [String: Any]
        else {
            throw QuickRuleError.invalidConfig
        }
        return document
    }

    /// Use the YAML tree to locate the field. Other top-level sections retain their original text,
    /// including comments, anchors, order and quoting. Flow mappings fall back to YAML serialization.
    private func editSequence(in data: Data, key: String, transform: ([String]) -> [String]) throws -> Data {
        guard let text = String(data: data, encoding: .utf8), var root = try Yams.compose(yaml: text),
            let mapping = root.mapping
        else { throw QuickRuleError.invalidConfig }
        let fields = Array(mapping)
        guard fields.filter({ $0.key.string == key }).count <= 1 else { throw QuickRuleError.invalidConfig }
        let existing = try self.document(data)[key]
        guard existing == nil || existing is NSNull || existing is [String] else { throw QuickRuleError.invalidConfig }
        let entries = existing as? [String] ?? []
        let updated = transform(entries)
        guard updated != entries else { return data }
        var intended = try self.document(data)
        intended[key] = updated
        func finish(_ output: String) throws -> Data {
            // A field may define anchors used elsewhere. Verify the entire document before
            // keeping a surgical edit; otherwise emit the equivalent expanded native YAML.
            if let actual = try? Yams.load(yaml: output) as? [String: Any],
                NSDictionary(dictionary: actual).isEqual(to: intended)
            {
                return Data(output.utf8)
            }
            return Data(try Yams.dump(object: intended, allowUnicode: true).utf8)
        }

        var sequence = Node.Sequence(updated.map { Node($0, Tag(.str), .singleQuoted) }, Tag(.seq), .block)
        if case .sequence(let previous) = root[key] { sequence.anchor = previous.anchor }
        let node = Node.sequence(sequence)
        root[key] = node
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let lines = text.components(separatedBy: newline)
        if mapping.style != .flow, root[key]?.anchor == nil,
            let index = fields.firstIndex(where: { $0.key.string == key }),
            let mark = fields[index].key.mark, mark.column == 1
        {
            let start = mark.line - 1
            var end =
                index + 1 < fields.count ? (fields[index + 1].key.mark?.line ?? (lines.count + 1)) - 1 : lines.count
            // Keep trailing comments / document end markers outside the edited field.
            while end > start + 1 {
                let line = lines[end - 1].trimmingCharacters(in: .whitespaces)
                guard line.isEmpty || line.hasPrefix("#") || line == "..." else { break }
                end -= 1
            }
            guard start >= 0, end <= lines.count, end > start else { throw QuickRuleError.invalidConfig }
            let section = try Yams.serialize(node: Node([(Node(key), node)]), allowUnicode: true)
                .trimmingCharacters(in: .newlines).replacingOccurrences(of: "\n", with: newline)
            let output = Array(lines[..<start]) + [section] + Array(lines[end...])
            return try finish(output.joined(separator: newline))
        }
        if mapping.style != .flow, fields.allSatisfy({ $0.key.string != key }), root["<<"] == nil {
            let section = try Yams.serialize(node: Node([(Node(key), node)]), allowUnicode: true)
            // Insert before an explicit YAML document end, if present.
            if let end = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "..." }) {
                return try finish(
                    (Array(lines[..<end]) + [section.trimmingCharacters(in: .newlines)] + Array(lines[end...]))
                        .joined(separator: newline)
                )
            }
            return try finish(
                text + (text.hasSuffix("\n") ? "" : newline) + section.replacingOccurrences(of: "\n", with: newline)
            )
        }
        return try finish(Yams.serialize(node: root, allowUnicode: true))
    }
}
