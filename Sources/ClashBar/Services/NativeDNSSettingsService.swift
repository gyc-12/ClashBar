import Foundation
import Yams

struct NativeDNSSnapshot: Equatable, Sendable {
    let configURL: URL
    let data: Data
    let dnsEnabled: Bool
    let dnsIPv6: Bool
    let enhancedMode: String?
    let fakeIPRange: String?
    let fakeIPRange6: String?
    let tunEnabled: Bool
}

struct NativeDNSSettingsService {
    func read(configURL: URL, data: Data? = nil) throws -> NativeDNSSnapshot {
        let content = try data ?? Data(contentsOf: configURL)
        guard let text = String(data: content, encoding: .utf8),
              let root = try? Yams.compose(yaml: text), root.mapping != nil else {
            throw QuickRuleError.invalidConfig
        }
        let dns = root["dns"]
        let tun = root["tun"]
        return NativeDNSSnapshot(
            configURL: configURL,
            data: content,
            dnsEnabled: flag(dns?["enable"]),
            dnsIPv6: flag(dns?["ipv6"]),
            enhancedMode: dns?["enhanced-mode"]?.string?.trimmedNonEmpty,
            fakeIPRange: dns?["fake-ip-range"]?.string?.trimmedNonEmpty,
            fakeIPRange6: dns?["fake-ip-range6"]?.string?.trimmedNonEmpty,
            tunEnabled: flag(tun?["enable"]))
    }

    func prepareDNSIPv6(_ enabled: Bool, snapshot: NativeDNSSnapshot) throws -> NativeRuleEdit {
        guard let text = String(data: snapshot.data, encoding: .utf8),
              let root = try? Yams.compose(yaml: text), let rootMap = root.mapping else {
            throw QuickRuleError.invalidConfig
        }
        let current = flag(root["dns"]?["ipv6"])
        if current == enabled && root["dns"]?["ipv6"] != nil {
            return NativeRuleEdit(
                configURL: snapshot.configURL, originalConfig: snapshot.data,
                targetURL: snapshot.configURL.resolvingSymlinksInPath(),
                originalData: snapshot.data, updatedData: snapshot.data, provider: nil)
        }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: newline)
        let boolText = enabled ? "true" : "false"
        var patched = false

        if let dnsPair = rootMap.first(where: { $0.key.string == "dns" }),
           let dnsKeyMark = dnsPair.key.mark,
           let dnsMap = dnsPair.value.mapping, dnsMap.style != .flow {
            if let ipv6Pair = dnsMap.first(where: { $0.key.string == "ipv6" }),
               let mark = ipv6Pair.key.mark, lines.indices.contains(mark.line - 1) {
                let indent = String(repeating: " ", count: max(0, mark.column - 1))
                let rawLine = lines[mark.line - 1]
                let comment = inlineComment(in: rawLine)
                lines[mark.line - 1] = "\(indent)ipv6: \(boolText)\(comment)"
                patched = true
            } else if let firstChild = dnsMap.first?.key.mark, lines.indices.contains(firstChild.line - 1) {
                let indent = String(repeating: " ", count: max(2, firstChild.column - 1))
                lines.insert("\(indent)ipv6: \(boolText)", at: firstChild.line - 1)
                patched = true
            } else if lines.indices.contains(dnsKeyMark.line - 1) {
                let indent = String(repeating: " ", count: max(0, dnsKeyMark.column - 1) + 2)
                lines.insert("\(indent)ipv6: \(boolText)", at: dnsKeyMark.line)
                patched = true
            }
        } else if rootMap.first(where: { $0.key.string == "dns" }) == nil {
            if lines.last == "" {
                lines.insert(contentsOf: ["dns:", "  ipv6: \(boolText)"], at: max(0, lines.count - 1))
            } else {
                lines.append(contentsOf: ["dns:", "  ipv6: \(boolText)"])
            }
            patched = true
        }

        let updatedData: Data
        if patched {
            let candidate = Data(lines.joined(separator: newline).utf8)
            guard let reparsed = try? Yams.compose(yaml: String(decoding: candidate, as: UTF8.self)),
                  flag(reparsed["dns"]?["ipv6"]) == enabled else {
                throw QuickRuleError.invalidConfig
            }
            updatedData = candidate
        } else {
            // Flow-style dns mapping fallback: mutate the dns node and re-emit only the dns section if possible, or whole YAML.
            var mutableRoot = root
            var dnsNode = root["dns"] ?? Node([] as [(Node, Node)], .implicit, .block)
            dnsNode["ipv6"] = Node(boolText, Tag(.bool))
            mutableRoot["dns"] = dnsNode
            guard let serialized = try? Yams.serialize(node: mutableRoot, width: -1, allowUnicode: true) else {
                throw QuickRuleError.invalidConfig
            }
            updatedData = Data(serialized.utf8)
        }

        return NativeRuleEdit(
            configURL: snapshot.configURL, originalConfig: snapshot.data,
            targetURL: snapshot.configURL.resolvingSymlinksInPath(),
            originalData: snapshot.data, updatedData: updatedData, provider: nil)
    }

    private func flag(_ node: Node?) -> Bool {
        node?.bool ?? ["true", "1", "yes", "on"].contains(node?.string?.lowercased() ?? "")
    }

    private func inlineComment(in line: String) -> String {
        guard let hashIndex = line.firstIndex(of: "#") else { return "" }
        let prefix = line[..<hashIndex]
        let trailingSpaces = prefix.reversed().prefix(while: { $0 == " " || $0 == "\t" })
        return String(trailingSpaces.reversed()) + String(line[hashIndex...])
    }
}
