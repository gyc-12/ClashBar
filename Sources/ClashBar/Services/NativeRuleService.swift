import Foundation
import Yams

/// The comment is provenance only; every rule remains executable by standalone mihomo.
struct NativeRuleService {
    static let customMarker = "clashbar:custom"
    let homeDirectory: URL

    func read(configURL: URL, data: Data? = nil) throws -> NativeRuleDocument {
        let data = try data ?? Data(contentsOf: configURL)
        let dictionary = try self.dictionary(data)
        let root = try self.root(data)
        let rules = try self.ruleStrings(dictionary)
        let comments = self.sourceComments(root: root, data: data, rules: rules)
        let entries = rules.enumerated().map { index, raw in
            NativeRuleEntry(
                index: index, raw: raw,
                isCustom: comments[index]?.components(separatedBy: .whitespaces)
                    .contains(Self.customMarker) == true,
                sourcePath: configURL.standardizedFileURL.resolvingSymlinksInPath().path)
        }
        return NativeRuleDocument(
            configURL: configURL, originalData: data, entries: entries,
            policies: try QuickRuleService(homeDirectory: self.homeDirectory).policies(in: data),
            providerNames: (dictionary["rule-providers"] as? [String: Any] ?? [:]).keys.sorted(),
            subRuleNames: (dictionary["sub-rules"] as? [String: Any] ?? [:]).keys.sorted())
    }

    func prepare(document: NativeRuleDocument, entry: NativeRuleEntry, raw: String, isCustom: Bool) throws
        -> NativeRuleEdit
    {
        guard document.entries.indices.contains(entry.index), document.entries[entry.index] == entry,
            try Data(contentsOf: document.configURL) == document.originalData
        else { throw QuickRuleError.contextChanged }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw QuickRuleError.invalidRuleText }
        if let syntax = NativeRuleSyntax(raw: raw) {
            let targets = syntax.targetsSubRule ? document.subRuleNames : document.policies
            guard targets.contains(syntax.target) else { throw QuickRuleError.invalidPolicy }
        }
        var entries = document.entries
        entries[entry.index] = NativeRuleEntry(
            index: entry.index, raw: raw, isCustom: isCustom, sourcePath: entry.sourcePath)
        let updated = try self.rewrite(document: document, entries: entries, changedIndex: entry.index)
        return self.edit(document: document, updated: updated)
    }

    func prepend(rule: QuickRoutingRule, document: NativeRuleDocument) throws -> Data {
        var retained = document.entries.filter { entry in
            guard let syntax = entry.syntax, let type = QuickRuleType(rawValue: syntax.type),
                let previous = try? QuickRoutingRule(type: type, target: syntax.payload, policy: syntax.target)
            else { return true }
            return previous.id != rule.id
        }
        retained.insert(NativeRuleEntry(index: -1, raw: rule.line, isCustom: true), at: 0)
        return try self.rewrite(document: document, entries: retained, changedIndex: nil)
    }

    func enablingProcessLookup(in data: Data, configURL: URL) throws -> Data {
        var intended = try self.dictionary(data)
        intended["find-process-mode"] = "strict"
        let root = try self.root(data)
        let fields = Array(root.mapping!)
        guard fields.filter({ $0.key.string == "find-process-mode" }).count <= 1 else {
            throw QuickRuleError.invalidConfig
        }
        let text = String(decoding: data, as: UTF8.self)
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: newline)
        if let field = fields.first(where: { $0.key.string == "find-process-mode" }),
            field.value.scalar?.anchor == nil, let mark = field.key.mark, mark.column == 1,
            let valueMark = field.value.mark, valueMark.line == mark.line,
            ![.literal, .folded].contains(field.value.scalar?.style), root.mapping?.style != .flow {
            let comment = self.comment(in: String(lines[mark.line - 1].dropFirst(valueMark.column - 1)),
                                       style: field.value.scalar?.style ?? .plain)
            lines[mark.line - 1] = "find-process-mode: strict" + (comment.isEmpty ? "" : " " + comment)
            let candidate = lines.joined(separator: newline)
            if let parsed = try? self.dictionary(Data(candidate.utf8)), NSDictionary(dictionary: parsed).isEqual(to: intended) {
                return Data(candidate.utf8)
            }
        } else if fields.allSatisfy({ $0.key.string != "find-process-mode" }), root["<<"] == nil,
            root.mapping?.style != .flow {
            let candidate = "find-process-mode: strict" + newline + text
            if let parsed = try? self.dictionary(Data(candidate.utf8)), NSDictionary(dictionary: parsed).isEqual(to: intended) {
                return Data(candidate.utf8)
            }
        }
        let document = try self.read(configURL: configURL, data: data)
        let comments = self.sourceComments(root: root, data: data, rules: document.entries.map(\.raw))
        let expanded = try Yams.dump(object: intended, width: -1, allowUnicode: true)
        let expandedData = Data(expanded.utf8)
        let locations = self.locations(root: try self.root(expandedData), data: expandedData, rules: document.entries.map(\.raw))
        var expandedLines = expanded.components(separatedBy: "\n")
        for entry in document.entries {
            guard let location = locations[entry.index] else { throw QuickRuleError.invalidConfig }
            expandedLines[location.line] = location.prefix + (try self.rendered(entry, comment: comments[entry.index] ?? ""))
        }
        return Data(expandedLines.joined(separator: newline).utf8)
    }

    private func edit(document: NativeRuleDocument, updated: Data) -> NativeRuleEdit {
        NativeRuleEdit(
            configURL: document.configURL, originalConfig: document.originalData,
            targetURL: document.configURL.resolvingSymlinksInPath(), originalData: document.originalData,
            updatedData: updated, provider: nil)
    }

    private struct Location {
        let line: Int
        let prefix: String
        let comment: String
    }

    private func dictionary(_ data: Data) throws -> [String: Any] {
        guard let text = String(data: data, encoding: .utf8),
            let dictionary = try Yams.load(yaml: text) as? [String: Any]
        else { throw QuickRuleError.invalidConfig }
        return dictionary
    }

    private func root(_ data: Data) throws -> Node {
        guard let text = String(data: data, encoding: .utf8), let node = try Yams.compose(yaml: text),
            let mapping = node.mapping, mapping.filter({ $0.key.string == "rules" }).count <= 1
        else { throw QuickRuleError.invalidConfig }
        return node
    }

    private func ruleStrings(_ dictionary: [String: Any]) throws -> [String] {
        let value = dictionary["rules"]
        guard value == nil || value is NSNull || value is [String] else { throw QuickRuleError.invalidConfig }
        return value as? [String] ?? []
    }

    private func rulesNode(in root: Node, depth: Int = 0) -> Node? {
        guard depth < 16 else { return nil }
        if let rules = root["rules"] { return rules }
        if let merge = root["<<"] {
            if let sequence = merge.sequence {
                for node in sequence {
                    if let rules = self.rulesNode(in: node, depth: depth + 1) { return rules }
                }
            } else {
                return self.rulesNode(in: merge, depth: depth + 1)
            }
        }
        return nil
    }

    /// Use parser marks, then independently decode each scalar to avoid guessing YAML quoting.
    private func locations(root: Node, data: Data, rules: [String]) -> [Int: Location] {
        guard let sequence = self.rulesNode(in: root)?.sequence, sequence.style != .flow, sequence.count == rules.count
        else {
            return [:]
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: text.contains("\r\n") ? "\r\n" : "\n")
        var result: [Int: Location] = [:]
        for (index, node) in sequence.enumerated() {
            guard let scalar = node.scalar, scalar.anchor == nil, let mark = node.mark,
                mark.line > 0, mark.line <= lines.count,
                ![.literal, .folded].contains(scalar.style)
            else { continue }
            let line = lines[mark.line - 1]
            let scalars = line.unicodeScalars
            guard mark.column > 0, mark.column - 1 <= scalars.count else { continue }
            let start = scalars.index(scalars.startIndex, offsetBy: mark.column - 1)
            let prefix = String(line[..<start])
            guard prefix.trimmingCharacters(in: .whitespaces) == "-" else { continue }
            let tail = String(line[start...])
            guard (try? Yams.load(yaml: "value: " + tail) as? [String: String])?["value"] == rules[index] else {
                continue
            }
            let comment = self.comment(in: tail, style: scalar.style)
            result[index] = Location(line: mark.line - 1, prefix: prefix, comment: comment)
        }
        return result
    }

    /// Read provenance even when a scalar requires equivalent YAML expansion for editing.
    private func sourceComments(root: Node, data: Data, rules: [String]) -> [Int: String] {
        guard let sequence = self.rulesNode(in: root)?.sequence, sequence.count == rules.count else { return [:] }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: text.contains("\r\n") ? "\r\n" : "\n")
        var comments: [Int: String] = [:]
        var lastIndexOnLine: [Int: Int] = [:]
        for (index, node) in sequence.enumerated() {
            if let line = node.mark?.line { lastIndexOnLine[line] = index }
        }
        for (index, node) in sequence.enumerated() {
            guard let scalar = node.scalar, let mark = node.mark, mark.line > 0, mark.line <= lines.count else {
                continue
            }
            // A trailing flow comment belongs only to the final scalar on that line.
            if lastIndexOnLine[mark.line] != index {
                continue
            }
            let line = lines[mark.line - 1]
            guard mark.column > 0, mark.column - 1 <= line.unicodeScalars.count else { continue }
            let start = line.unicodeScalars.index(line.unicodeScalars.startIndex, offsetBy: mark.column - 1)
            let tail = String(line[start...])
            let comment = self.comment(in: tail, style: scalar.style)
            if !comment.isEmpty { comments[index] = comment }
        }
        return comments
    }

    private func comment(in text: String, style: Node.Scalar.Style) -> String {
        var quote: Character? = style == .singleQuoted ? "'" : (style == .doubleQuoted ? "\"" : nil)
        var index = quote.flatMap { text.firstIndex(of: $0) }.map { text.index(after: $0) } ?? text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if quote == "\"", character == "\\" {
                index = next < text.endIndex ? text.index(after: next) : next
                continue
            }
            if let active = quote, character == active {
                if active == "'", next < text.endIndex, text[next] == "'" {
                    index = text.index(after: next)
                    continue
                }
                quote = nil
            } else if quote == nil, character == "#",
                index == text.startIndex || text[text.index(before: index)].isWhitespace
            {
                return String(text[index...])
            }
            index = next
        }
        return ""
    }

    private func rendered(_ entry: NativeRuleEntry, comment: String = "") throws -> String {
        let scalar = try Yams.serialize(node: Node(entry.raw, Tag(.str), .singleQuoted), width: -1, allowUnicode: true)
            .trimmingCharacters(in: .newlines)
        let previousCustom = comment.components(separatedBy: .whitespaces).contains(Self.customMarker)
        var comment = comment
        if previousCustom, !entry.isCustom { comment = comment.replacingOccurrences(of: Self.customMarker, with: "") }
        if entry.isCustom, !previousCustom {
            comment += comment.isEmpty ? "# " + Self.customMarker : " " + Self.customMarker
        }
        comment = comment.trimmingCharacters(in: .whitespaces)
        if comment == "#" { comment = "" }
        return scalar + (comment.isEmpty ? "" : " " + comment)
    }

    private func rewrite(document: NativeRuleDocument, entries: [NativeRuleEntry], changedIndex: Int?) throws -> Data {
        if entries == document.entries { return document.originalData }
        let data = document.originalData
        let text = String(decoding: data, as: UTF8.self)
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: newline)
        let root = try self.root(data)
        let locations = self.locations(root: root, data: data, rules: document.entries.map(\.raw))
        let comments = self.sourceComments(root: root, data: data, rules: document.entries.map(\.raw))
        var intended = try self.dictionary(data)
        intended["rules"] = entries.map(\.raw)

        func valid(_ candidate: String) -> Bool {
            guard let parsed = try? self.dictionary(Data(candidate.utf8)) else { return false }
            return NSDictionary(dictionary: parsed).isEqual(to: intended)
        }

        if let changedIndex, let location = locations[changedIndex] {
            lines[location.line] =
                location.prefix + (try self.rendered(entries[changedIndex], comment: location.comment))
            let candidate = lines.joined(separator: newline)
            if valid(candidate) { return Data(candidate.utf8) }
        } else if changedIndex == nil, !document.entries.isEmpty, locations.count == document.entries.count,
            let first = locations[0]
        {
            let retainedIndices = Set(entries.filter { $0.index >= 0 }.map(\.index))
            for entry in document.entries where !retainedIndices.contains(entry.index) {
                if let location = locations[entry.index] { lines[location.line] = "" }
            }
            let inserted = try entries.filter { $0.index < 0 }.map { first.prefix + (try self.rendered($0)) }
            lines.insert(contentsOf: inserted, at: first.line)
            let candidate = lines.joined(separator: newline)
            if valid(candidate) { return Data(candidate.utf8) }
        }

        // Flow/alias/multiline YAML: expand an equivalent native document, preserving provenance.
        // Changing an anchored list must not silently change other fields that reference it.
        let expanded = try Yams.dump(object: intended, width: -1, allowUnicode: true)
        let expandedRoot = try self.root(Data(expanded.utf8))
        let expandedLocations = self.locations(root: expandedRoot, data: Data(expanded.utf8), rules: entries.map(\.raw))
        var expandedLines = expanded.components(separatedBy: "\n")
        for (index, entry) in entries.enumerated() {
            guard let location = expandedLocations[index] else { throw QuickRuleError.invalidConfig }
            let oldComment = entry.index >= 0 ? comments[entry.index] ?? "" : ""
            expandedLines[location.line] = location.prefix + (try self.rendered(entry, comment: oldComment))
        }
        let candidate = expandedLines.joined(separator: newline)
        guard valid(candidate) else { throw QuickRuleError.invalidConfig }
        return Data(candidate.replacingOccurrences(of: "\n", with: newline).utf8)
    }
}
