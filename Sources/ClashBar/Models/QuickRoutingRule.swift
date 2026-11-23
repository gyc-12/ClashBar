import Darwin
import Foundation

enum QuickRuleType: String, Codable, CaseIterable, Identifiable {
    case domain = "DOMAIN"
    case domainSuffix = "DOMAIN-SUFFIX"
    case ipv4 = "IP-CIDR"
    case ipv6 = "IP-CIDR6"
    case processName = "PROCESS-NAME"
    case processPath = "PROCESS-PATH"

    var id: String { self.rawValue }
    var isIP: Bool { self == .ipv4 || self == .ipv6 }
    var isProcess: Bool { self == .processName || self == .processPath }
    static var destinationTypes: [Self] { self.allCases.filter { !$0.isProcess } }
}

enum QuickRuleError: LocalizedError {
    case invalidTarget, invalidRuleText, invalidPolicy, invalidConfig, contextChanged
    case recoveryFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidTarget: "Invalid domain, IP address or CIDR."
        case .invalidRuleText: "Enter one native rule without line breaks or control characters."
        case .invalidPolicy: "The selected policy is unavailable in this configuration."
        case .invalidConfig: "The configuration must be a YAML mapping with a list of rules."
        case .contextChanged: "The selected configuration changed. Open the rule editor again."
        case .recoveryFailed(let path): "Could not restore the previous state. Backup: \(path)"
        }
    }
}

struct QuickRuleTarget: Hashable, Identifiable {
    let type: QuickRuleType
    let value: String
    var id: String { "\(self.type.rawValue):\(self.value)" }

    /// Accept a host, endpoint, CIDR or HTTP(S) URL. Never infer a registrable domain.
    static func parse(_ input: String) -> QuickRuleTarget? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(","),
            !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }

        if text.contains("://") {
            guard let url = URLComponents(string: text),
                ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                let host = url.url?.host(percentEncoded: true)
            else { return nil }
            return self.parse(host)
        }

        let cidrParts = text.split(separator: "/", omittingEmptySubsequences: false)
        if cidrParts.count == 2 {
            guard let address = self.ipAddress(String(cidrParts[0])),
                let prefix = Int(cidrParts[1]), prefix >= 0,
                prefix <= (address.type == .ipv4 ? 32 : 128)
            else { return nil }
            return QuickRuleTarget(type: address.type, value: "\(address.value)/\(prefix)")
        }
        guard cidrParts.count == 1 else { return nil }

        if let address = self.ipAddress(text) {
            return QuickRuleTarget(type: address.type, value: address.value + (address.type == .ipv4 ? "/32" : "/128"))
        }
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let suffix = String(text[text.index(after: close)...])
            guard suffix.isEmpty || self.validPortSuffix(suffix),
                let address = self.ipAddress(String(text[text.index(after: text.startIndex)..<close])),
                address.type == .ipv6
            else { return nil }
            return QuickRuleTarget(type: .ipv6, value: address.value + "/128")
        }
        var host = text
        if let colon = text.lastIndex(of: ":") {
            guard self.validPortSuffix(String(text[colon...])) else { return nil }
            host = String(text[..<colon])
            if let address = self.ipAddress(host) {
                return QuickRuleTarget(type: address.type, value: address.value + "/32")
            }
        }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
            !host.contains(where: { "/\\@?#%:[]".contains($0) }),
            let ascii = URL(string: "https://\(host)")?.host(percentEncoded: true)?.lowercased(),
            ascii.utf8.count <= 253
        else { return nil }
        let labels = ascii.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty,
            labels.allSatisfy({ label in
                !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
            }),
            // Numeric lookalikes must not turn a malformed IP into a domain rule.
            !labels.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return nil }
        return QuickRuleTarget(type: .domain, value: ascii)
    }

    private static func validPortSuffix(_ suffix: String) -> Bool {
        guard suffix.first == ":" else { return false }
        let port = suffix.dropFirst()
        return !port.isEmpty && port.allSatisfy(\.isNumber) && (Int(port).map { (1...65535).contains($0) } ?? false)
    }

    private static func ipAddress(_ text: String) -> QuickRuleTarget? {
        var v4 = in_addr()
        var v6 = in6_addr()
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, text, &v4) == 1 {
            guard inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return QuickRuleTarget(
                type: .ipv4,
                value: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            )
        }
        if inet_pton(AF_INET6, text, &v6) == 1 {
            guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return QuickRuleTarget(
                type: .ipv6,
                value: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            )
        }
        return nil
    }

    static func from(rule: RuleItem) -> QuickRuleTarget? {
        let kind = rule.type?.uppercased().replacingOccurrences(of: "-", with: "")
        guard let payload = rule.payload, let target = self.parse(payload) else { return nil }
        switch kind {
        case "DOMAIN" where target.type == .domain: return target
        case "DOMAINSUFFIX" where target.type == .domain:
            return QuickRuleTarget(type: .domainSuffix, value: target.value)
        case "IPCIDR" where target.type.isIP, "IPCIDR6" where target.type == .ipv6: return target
        default: return nil
        }
    }

    static func from(connection: ConnectionSummary) -> [QuickRuleTarget] {
        self.unique(
            [connection.metadata?.host, connection.metadata?.destinationIP].compactMap { $0.flatMap(self.parse) }
        )
    }

    /// Explicit destination fields only: never scrape arbitrary domains from an entire log line.
    static func from(log: String) -> [QuickRuleTarget] {
        let patterns = [
            #"(?:--?>)\s*(\[[0-9a-fA-F:]+\](?::\d+)?|[^\s,;\"'()]+)"#,
            #"\bdial\s+(?:tcp\d?|udp\d?)\s+(\[[0-9a-fA-F:]+\]:\d+|[^\s,;\"'()]+)"#,
            #"\blookup\s+([^\s,;\"'():]+)"#,
        ]
        return self.unique(
            patterns.flatMap { pattern -> [QuickRuleTarget] in
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
                return regex.matches(in: log, range: NSRange(log.startIndex..., in: log)).compactMap { match in
                    guard let range = Range(match.range(at: 1), in: log) else { return nil }
                    let raw = String(log[range])
                    // A trailing colon is often the separator before a dial error description.
                    let token = raw.hasSuffix(":") && !raw.hasSuffix("::") ? String(raw.dropLast()) : raw
                    return self.parse(token)
                }
            }
        )
    }

    private static func unique(_ items: [QuickRuleTarget]) -> [QuickRuleTarget] {
        var seen: Set<QuickRuleTarget> = []
        return items.filter { seen.insert($0).inserted }
    }
}

struct QuickRoutingRule: Codable, Equatable, Identifiable {
    let type: QuickRuleType
    let target: String
    let policy: String
    var id: String { "\(self.type.rawValue):\(self.target)" }
    var line: String { "\(self.type.rawValue),\(self.target),\(self.policy)\(self.type.isIP ? ",no-resolve" : "")" }

    init(type: QuickRuleType, target: String, policy: String) throws {
        let normalized: String
        if type.isProcess {
            normalized = try ApplicationRoutingCandidate.validatedTarget(target, type: type)
        } else {
            guard let parsed = QuickRuleTarget.parse(target),
            parsed.type == type || (type == .domainSuffix && parsed.type == .domain)
            else { throw QuickRuleError.invalidTarget }
            normalized = parsed.value
        }
        guard !policy.isEmpty, policy == policy.trimmingCharacters(in: .whitespacesAndNewlines),
            !policy.contains(","),
            !policy.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw QuickRuleError.invalidPolicy }
        self.type = type
        self.target = normalized
        self.policy = policy
    }
}

struct QuickRuleEditorContext: Identifiable {
    let id = UUID()
    let configURL: URL
    let target: QuickRuleTarget?
    let policies: [String]
    let originalConfig: Data
    let providers: [LocalRuleProvider]
    let isSubscription: Bool
    let notice: String?
}
