import Foundation

/// A rule's position belongs to its source document, never to a filtered UI list.
struct NativeRuleEntry: Hashable, Identifiable {
    let index: Int
    let raw: String
    let isCustom: Bool
    let sourcePath: String?
    init(index: Int, raw: String, isCustom: Bool, sourcePath: String? = nil) {
        self.index = index
        self.raw = raw
        self.isCustom = isCustom
        self.sourcePath = sourcePath
    }
    var id: String { "\(self.sourcePath ?? "")#\(self.index)" }
    var syntax: NativeRuleSyntax? { NativeRuleSyntax(raw: self.raw) }

    var item: RuleItem {
        RuleItem(
            type: self.syntax?.type ?? "RAW", payload: self.syntax?.payload ?? self.raw,
            proxy: self.syntax?.target, nativeEntry: self)
    }
}

struct NativeRuleDocument: Equatable {
    let configURL: URL
    let originalData: Data
    let entries: [NativeRuleEntry]
    let policies: [String]
    let providerNames: [String]
    let subRuleNames: [String]

    func matchesRuntime(_ rules: [RuleItem]) -> Bool {
        guard self.entries.count == rules.count else { return false }
        return zip(self.entries, rules).allSatisfy { entry, rule in
            guard let syntax = entry.syntax else { return false }
            return NativeRuleSyntax.normalizedType(syntax.type) == NativeRuleSyntax.normalizedType(rule.type ?? "")
                && syntax.matchesRuntimePayload(rule.payload ?? "") && syntax.target == rule.proxy
        }
    }
}

struct NativeRuleEditorContext: Identifiable {
    let id = UUID()
    let document: NativeRuleDocument
    let entry: NativeRuleEntry
    let isSubscription: Bool
}

/// Split the *outer* rule only. Commas inside logical expressions are not policy separators.
struct NativeRuleSyntax: Equatable {
    static let types = [
        "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX", "DOMAIN-WILDCARD",
        "GEOSITE", "GEOIP", "SRC-GEOIP", "IP-ASN", "SRC-IP-ASN", "IP-CIDR", "IP-CIDR6",
        "SRC-IP-CIDR", "IP-SUFFIX", "SRC-IP-SUFFIX", "SRC-PORT", "DST-PORT", "IN-PORT", "DSCP",
        "PROCESS-NAME", "PROCESS-PATH", "PROCESS-NAME-REGEX", "PROCESS-PATH-REGEX",
        "PROCESS-NAME-WILDCARD", "PROCESS-PATH-WILDCARD", "NETWORK", "UID", "IN-TYPE",
        "IN-USER", "IN-NAME", "RULE-SET", "AND", "OR", "NOT", "SUB-RULE", "MATCH",
    ]

    let raw: String
    let type: String
    let payload: String
    let target: String
    let options: [String]
    private let targetRange: NSRange

    var targetsSubRule: Bool { self.type == "SUB-RULE" }
    var supportsNoResolve: Bool {
        ["GEOIP", "IP-ASN", "IP-CIDR", "IP-CIDR6", "IP-SUFFIX", "RULE-SET"].contains(self.type)
    }
    var supportsSource: Bool {
        ["GEOIP", "IP-ASN", "IP-CIDR", "IP-CIDR6", "IP-SUFFIX"].contains(self.type)
    }

    init?(raw: String) {
        guard !raw.contains(where: { $0.isNewline }) else { return nil }
        var ranges: [Range<String.Index>] = []
        var start = raw.startIndex
        var depth = 0
        var escaped = false
        for index in raw.indices {
            let character = raw[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            guard depth >= 0 else { return nil }
            if character == ",", depth == 0 {
                ranges.append(start..<index)
                start = raw.index(after: index)
            }
        }
        guard depth == 0 else { return nil }
        ranges.append(start..<raw.endIndex)
        let fields = ranges.map { String(raw[$0]).trimmingCharacters(in: .whitespaces) }
        guard let type = fields.first?.uppercased(), !type.isEmpty else { return nil }
        let minimum = type == "MATCH" ? 2 : 3
        var targetIndex = fields.count - 1
        while targetIndex >= minimum, ["no-resolve", "src"].contains(fields[targetIndex]) { targetIndex -= 1 }
        guard targetIndex == minimum - 1, !fields[targetIndex].isEmpty else {
            return nil
        }
        let targetSlice = raw[ranges[targetIndex]]
        let leading = targetSlice.prefix(while: { $0.isWhitespace }).count
        let trailing = targetSlice.reversed().prefix(while: { $0.isWhitespace }).count
        let lower = raw.index(ranges[targetIndex].lowerBound, offsetBy: leading)
        let upper = raw.index(ranges[targetIndex].upperBound, offsetBy: -trailing)
        self.raw = raw
        self.type = type
        self.payload = type == "MATCH" ? "" : fields[1]
        self.target = fields[targetIndex]
        self.options = Array(fields.dropFirst(targetIndex + 1))
        self.targetRange = NSRange(lower..<upper, in: raw)
    }

    func replacingTarget(_ target: String) throws -> String {
        guard let range = Range(self.targetRange, in: self.raw), Self.validTarget(target) else {
            throw QuickRuleError.invalidPolicy
        }
        return self.raw.replacingCharacters(in: range, with: target)
    }

    static func validTarget(_ target: String) -> Bool {
        !target.isEmpty && target == target.trimmingCharacters(in: .whitespacesAndNewlines)
            && !target.contains(",")
            && !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func normalizedType(_ type: String) -> String {
        let normalized = type.uppercased().replacingOccurrences(of: "-", with: "")
        return normalized == "SUBRULES" ? "SUBRULE" : normalized
    }

    func matchesRuntimePayload(_ payload: String) -> Bool {
        if ["AND", "OR", "NOT"].contains(self.type) {
            guard let expected = Self.logicalRuntimePayload(type: self.type, payload: self.payload) else {
                return false
            }
            return Self.normalizeLogicalRuntime(expected) == Self.normalizeLogicalRuntime(payload)
        }
        if ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD"].contains(self.type) {
            return self.payload.lowercased() == payload.lowercased()
        }
        return self.payload == payload
    }

    /// mihomo exposes parsed logical rules as `(RuleType,payload)` joined with && / ||.
    private static func logicalRuntimePayload(type: String, payload: String) -> String? {
        guard payload.hasPrefix("("), payload.hasSuffix(")") else { return nil }
        let inner = String(payload.dropFirst().dropLast())
        guard let subRules = Self.outerParts(inner) else { return nil }
        var rendered: [String] = []
        for subRule in subRules {
            let subRule = subRule.trimmingCharacters(in: .whitespaces)
            guard subRule.hasPrefix("("), subRule.hasSuffix(")"),
                let fields = Self.outerParts(String(subRule.dropFirst().dropLast())), fields.count >= 2
            else { return nil }
            let subType = fields[0].trimmingCharacters(in: .whitespaces).uppercased()
            var value = fields[1].trimmingCharacters(in: .whitespaces)
            if ["AND", "OR", "NOT"].contains(subType) {
                guard let nested = Self.logicalRuntimePayload(type: subType, payload: value) else { return nil }
                value = nested
            } else if ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD"].contains(subType) {
                value = value.lowercased()
            }
            rendered.append("(\(Self.normalizedType(subType)),\(value))")
        }
        if type == "NOT" { return rendered.count == 1 ? "(!\(rendered[0]))" : nil }
        return "(" + rendered.joined(separator: type == "AND" ? " && " : " || ") + ")"
    }

    private static func normalizeLogicalRuntime(_ payload: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"(?<=\()[A-Za-z][A-Za-z0-9-]*(?=,)"#)
        var output = payload
        for match in regex.matches(in: payload, range: NSRange(payload.startIndex..., in: payload)).reversed() {
            if let range = Range(match.range, in: output) {
                output.replaceSubrange(range, with: Self.normalizedType(String(output[range])))
            }
        }
        return output.replacingOccurrences(of: " && ", with: "&&").replacingOccurrences(of: " || ", with: "||")
    }

    private static func outerParts(_ text: String) -> [String]? {
        var depth = 0
        var escaped = false
        var start = text.startIndex
        var parts: [String] = []
        for index in text.indices {
            let character = text[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            guard depth >= 0 else { return nil }
            if character == ",", depth == 0 {
                parts.append(String(text[start..<index]))
                start = text.index(after: index)
            }
        }
        guard depth == 0 else { return nil }
        return parts + [String(text[start...])]
    }
}
