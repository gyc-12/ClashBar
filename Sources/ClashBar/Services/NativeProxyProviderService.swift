import Foundation
import Yams

struct NativeProxyProvider: Equatable, Identifiable {
    let name: String
    let type: String
    let url: String?
    let enabled: Bool
    var id: String { name }
}

struct NativeProxyProviderGroup: Equatable, Identifiable {
    let name: String
    let automatic: Bool
    let use: [String]
    var id: String { name }
}

struct NativeProxyProviderDocument: Equatable {
    let configURL: URL
    let data: Data
    let entries: [NativeProxyProvider]
    let groups: [NativeProxyProviderGroup]

    var activeNames: Set<String> { Set(entries.filter(\.enabled).map(\.name)) }

    func affectedGroups(for name: String) -> [String] {
        groups.filter { $0.automatic || $0.use.contains(name) }.map(\.name)
    }
}

enum NativeProxyProviderAction {
    case add(name: String, url: String, interval: Int?, healthCheckURL: String?, groups: Set<String>)
    case edit(name: String, url: String)
    case setEnabled(name: String, enabled: Bool)
    case delete(name: String)
}

enum NativeProxyProviderError: Error, Equatable {
    case invalidConfig, invalidName, invalidURL, invalidInterval, conflict, unavailable, sourceFailed, reloadFailed
    case emptyGroups([String])
}

struct NativeProxyProviderEdit {
    let file: NativeRuleEdit
    let document: NativeProxyProviderDocument
    let affectedGroups: [String]
    let probeProvider: String?
    let freshSource: Bool
    let changesRuntime: Bool
}

struct NativeProxyProviderService {
    enum Fallback: String, CaseIterable, Identifiable {
        case direct = "DIRECT"
        case reject = "REJECT"
        var id: String { rawValue }
    }

    private static let begin = "# clashbar:disabled-proxy-providers begin"
    private static let end = "# clashbar:disabled-proxy-providers end"
    private static let providersKey = "proxy-providers"
    private static let groupsKey = "proxy-groups"

    private struct Parsed {
        let source: Node
        var root: Node
        let body: [String]
        let newline: String
        var suspended: Node
        var layouts: Node
        var temporaryProxies: Node
        var order: [String]

        var definitions: Node { root[NativeProxyProviderService.providersKey] ?? Node([] as [(Node, Node)], .implicit, .block) }
        var groups: [Node] { root[NativeProxyProviderService.groupsKey]?.array() ?? [] }
    }

    func read(configURL: URL, data: Data? = nil) throws -> NativeProxyProviderDocument {
        let data = try data ?? Data(contentsOf: configURL)
        return try makeDocument(configURL: configURL, data: data, parsed: parse(data))
    }

    private func makeDocument(configURL: URL, data: Data, parsed: Parsed) throws -> NativeProxyProviderDocument {
        let active = try fields(parsed.definitions).map { try entry($0.0, $0.1, enabled: true) }
        let inactive = try fields(parsed.suspended).map { try entry($0.0, $0.1, enabled: false) }
        let entries = (active + inactive.filter { candidate in !active.contains(where: { $0.name == candidate.name }) }).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let groups = try parsed.groups.map { group in
            guard let name = group["name"]?.string else { throw NativeProxyProviderError.invalidConfig }
            return NativeProxyProviderGroup(name: name, automatic: automatic(group),
                                            use: try strings(lookup(parsed.layouts, name) ?? group["use"]))
        }
        return NativeProxyProviderDocument(configURL: configURL, data: data, entries: entries, groups: groups)
    }

    func prepare(_ action: NativeProxyProviderAction, in document: NativeProxyProviderDocument,
                 fallback: Fallback? = nil, filteredEmptyGroups: Set<String> = [], cacheID: UUID = UUID()) throws -> NativeProxyProviderEdit {
        let original = try parse(document.data)
        var candidate = original
        var definitions = original.definitions
        var groups = original.groups
        let oldGroups = groups
        var name: String
        var probe: String?
        var fresh = false
        var affected = Set<String>()
        func checkLayout(_ group: Node, _ groupName: String) throws -> [String] {
            let current = try strings(group["use"])
            guard let saved = lookup(original.layouts, groupName) else { return current }
            let logical = try strings(saved)
            guard logical.filter({ lookup(original.suspended, $0) == nil }) == current else {
                throw NativeProxyProviderError.conflict
            }
            return logical
        }

        switch action {
        case let .add(rawName, url, interval, healthURL, bindings):
            name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let reserved = ["default", "GLOBAL", "DIRECT", "REJECT", "REJECT-DROP", "COMPATIBLE", "PASS", "PASS-RULE"]
            guard !name.isEmpty, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !reserved.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }),
                  lookup(definitions, name) == nil, lookup(candidate.suspended, name) == nil,
                  !groups.contains(where: { $0["name"]?.string == name }) else { throw NativeProxyProviderError.invalidName }
            if let interval, !(1...Int(Int32.max)).contains(interval) { throw NativeProxyProviderError.invalidInterval }
            var definition: Node = ["type": scalar("http"), "url": try httpURL(url), "path": cachePath(cacheID)]
            if let interval { definition["interval"] = Node(String(interval), Tag(.int)) }
            if let healthURL { definition["health-check"] = ["enable": trueNode, "url": try httpURL(healthURL)] }
            assign(definition, named: name, in: &definitions)
            candidate.order.append(name)
            var remaining = bindings
            for index in groups.indices {
                guard let group = groups[index]["name"]?.string, remaining.remove(group) != nil else { continue }
                guard !automatic(groups[index]) else { continue }
                let logical = try checkLayout(groups[index], group) + [name]
                replaceReferences(logical, in: &groups[index], groupName: group, candidate: &candidate)
                affected.insert(group)
            }
            guard remaining.isEmpty else { throw NativeProxyProviderError.conflict }
            probe = name
            fresh = true
        case let .edit(target, url):
            name = target
            guard (lookup(definitions, name) == nil) != (lookup(candidate.suspended, name) == nil),
                  var definition = lookup(definitions, name) ?? lookup(candidate.suspended, name), definition["type"]?.string == "http"
            else { throw NativeProxyProviderError.conflict }
            let normalized = try httpURL(url)
            if normalized.string != definition["url"]?.string {
                definition["url"] = normalized
                definition["path"] = cachePath(cacheID)
                if lookup(definitions, name) != nil { assign(definition, named: name, in: &definitions) }
                else { assign(definition, named: name, in: &candidate.suspended) }
                probe = name
                fresh = true
            }
        case let .setEnabled(target, enabled):
            name = target
            if enabled {
                guard lookup(definitions, name) == nil, let definition = lookup(candidate.suspended, name) else {
                    throw NativeProxyProviderError.conflict
                }
                assign(definition, named: name, in: &definitions)
                remove(name, from: &candidate.suspended)
                probe = name
            } else {
                guard lookup(candidate.suspended, name) == nil, let definition = lookup(definitions, name) else {
                    throw NativeProxyProviderError.conflict
                }
                assign(definition, named: name, in: &candidate.suspended)
                remove(name, from: &definitions)
            }
        case let .delete(target):
            name = target
            guard (lookup(definitions, name) == nil) != (lookup(candidate.suspended, name) == nil) else {
                throw NativeProxyProviderError.conflict
            }
            remove(name, from: &definitions)
            remove(name, from: &candidate.suspended)
            candidate.order.removeAll { $0 == name }
        }

        switch action {
        case .setEnabled, .delete:
            var missing = Set(try fields(original.layouts).filter { try strings($0.1).contains(name) }.map(\.0))
            for index in groups.indices {
                guard let group = groups[index]["name"]?.string else { throw NativeProxyProviderError.invalidConfig }
                missing.remove(group)
                let use = try strings(lookup(original.layouts, group) ?? groups[index]["use"])
                guard use.contains(name) else { continue }
                let logical = try checkLayout(groups[index], group)
                if case .delete = action {
                    replaceReferences(logical.filter { $0 != name }, in: &groups[index], groupName: group, candidate: &candidate)
                } else {
                    replaceReferences(logical, in: &groups[index], groupName: group, candidate: &candidate)
                }
                if groups[index] != oldGroups[index] { affected.insert(group) }
            }
            if case .setEnabled(name: _, enabled: true) = action, !missing.isEmpty { throw NativeProxyProviderError.conflict }
            if case .delete = action {
                for group in missing {
                    let remaining = try strings(lookup(original.layouts, group)).filter { $0 != name }
                    if remaining.contains(where: { lookup(candidate.suspended, $0) != nil }) {
                        assign(sequence(remaining), named: group, in: &candidate.layouts)
                    } else { remove(group, from: &candidate.layouts) }
                }
            }
        default: break
        }

        if lookup(original.definitions, name) != lookup(definitions, name) {
            for group in groups where automatic(group) || (try? strings(group["use"]).contains(name)) == true {
                if let groupName = group["name"]?.string { affected.insert(groupName) }
            }
        }
        let hasDefinitions = !(definitions.mapping?.isEmpty ?? true)
        let hasStaticNodes = !(original.root["proxies"]?.array().isEmpty ?? true)
        var blocked: [String] = []
        for index in groups.indices {
            let group = groups[index]
            guard let groupName = group["name"]?.string, affected.contains(groupName) else { continue }
            if case .setEnabled(name: _, enabled: true) = action,
               let installed = lookup(candidate.temporaryProxies, groupName) {
                guard group["proxies"] == installed else { throw NativeProxyProviderError.conflict }
                let hasProvider = automatic(group) ? hasDefinitions : try !strings(group["use"]).isEmpty
                if hasProvider {
                    remove("proxies", from: &groups[index])
                    remove(groupName, from: &candidate.temporaryProxies)
                }
            }
            let noProviders = automatic(group) ? !hasDefinitions : try strings(group["use"]).isEmpty
            let missingSources = (try strings(group["proxies"])).isEmpty
                && noProviders
                && !(automaticNodes(group) && hasStaticNodes)
            if missingSources || filteredEmptyGroups.contains(groupName) {
                if let fallback {
                    groups[index]["empty-fallback"] = scalar(fallback.rawValue)
                    if missingSources {
                        let replacement = sequence([fallback.rawValue])
                        groups[index]["proxies"] = replacement
                        if case .setEnabled(name: _, enabled: false) = action {
                            assign(replacement, named: groupName, in: &candidate.temporaryProxies)
                        }
                    }
                } else if missingSources {
                    if let existing = group["empty-fallback"]?.string, !existing.isEmpty, existing != "COMPATIBLE" {
                        if !automaticNodes(group) {
                            let replacement = sequence([existing])
                            groups[index]["proxies"] = replacement
                            if case .setEnabled(name: _, enabled: false) = action {
                                assign(replacement, named: groupName, in: &candidate.temporaryProxies)
                            }
                        }
                    } else { blocked.append(groupName) }
                }
            }
        }
        if !blocked.isEmpty { throw NativeProxyProviderError.emptyGroups(blocked.sorted()) }

        // Provider ordering survives repeated disable/enable in either order.
        let pairs = try fields(definitions)
        let ranks = Dictionary(uniqueKeysWithValues: candidate.order.enumerated().map { ($0.element, $0.offset) })
        definitions = mapping(pairs.sorted { (ranks[$0.0] ?? .max) < (ranks[$1.0] ?? .max) })
        if original.root[Self.providersKey] != nil || !pairs.isEmpty {
            candidate.root[Self.providersKey] = definitions
        }
        if oldGroups != groups { candidate.root[Self.groupsKey] = Node(groups, .implicit, .block) }
        let changesRuntime = !same(original.root, candidate.root)
        let changed = changesRuntime || original.suspended != candidate.suspended || original.layouts != candidate.layouts
        let data = changed ? try render(original: original, candidate: candidate, provider: name) : document.data
        return NativeProxyProviderEdit(
            file: NativeRuleEdit(configURL: document.configURL, originalConfig: document.data,
                                 targetURL: document.configURL.resolvingSymlinksInPath(), originalData: document.data,
                                 updatedData: data, provider: nil),
            document: try read(configURL: document.configURL, data: data), affectedGroups: affected.sorted(),
            probeProvider: probe, freshSource: fresh, changesRuntime: changesRuntime)
    }

    private func replaceReferences(_ logical: [String], in group: inout Node, groupName: String, candidate: inout Parsed) {
        let live = logical.filter { lookup(candidate.suspended, $0) == nil }
        group["use"] = sequence(live)
        if live.count != logical.count { assign(sequence(logical), named: groupName, in: &candidate.layouts) }
        else { remove(groupName, from: &candidate.layouts) }
    }

    private func entry(_ name: String, _ node: Node, enabled: Bool) throws -> NativeProxyProvider {
        guard node.mapping != nil, let type = node["type"]?.string else { throw NativeProxyProviderError.invalidConfig }
        return NativeProxyProvider(name: name, type: type, url: node["url"]?.string, enabled: enabled)
    }

    private func parse(_ data: Data) throws -> Parsed {
        guard let text = String(data: data, encoding: .utf8) else { throw NativeProxyProviderError.invalidConfig }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: newline)
        // Metadata is always at document level. Indented strings or ordinary comments are ignored.
        var metadata = mapping([])
        if let start = lines.firstIndex(of: Self.begin) {
            guard let end = lines.firstIndex(of: Self.end), start < end,
                  lines.filter({ $0 == Self.begin || $0 == Self.end }).count == 2 else {
                throw NativeProxyProviderError.invalidConfig
            }
            let contents = lines[(start + 1)..<end]
            guard contents.allSatisfy({ $0.hasPrefix("# ") }) else { throw NativeProxyProviderError.invalidConfig }
            metadata = try yaml(contents.map { String($0.dropFirst(2)) }.joined(separator: "\n"))
            lines.removeSubrange(start...end)
        } else if lines.contains(Self.end) { throw NativeProxyProviderError.invalidConfig }
        let source = try yaml(lines.joined(separator: newline))
        let root = try expanded(source)
        let active = try fields(root[Self.providersKey] ?? mapping([])).map(\.0)
        let suspended = metadata["definitions"] ?? mapping([])
        let inactive = try fields(suspended).map(\.0)
        let layouts = metadata["groups"] ?? mapping([])
        for (_, use) in try fields(layouts) { _ = try strings(use) }
        let temporaryProxies = metadata["temporary-proxies"] ?? mapping([])
        for (_, proxies) in try fields(temporaryProxies) { _ = try strings(proxies) }
        let previousOrder = try strings(metadata["order"])
        let known = Set(active + inactive)
        var seen = Set<String>()
        let order = (previousOrder.filter(known.contains) + active + inactive).filter { seen.insert($0).inserted }
        if let groups = root[Self.groupsKey], groups.sequence == nil { throw NativeProxyProviderError.invalidConfig }
        let names = root[Self.groupsKey]?.array().compactMap { $0["name"]?.string } ?? []
        guard Set(names).count == names.count else { throw NativeProxyProviderError.invalidConfig }
        return Parsed(source: source, root: root, body: lines, newline: newline,
                      suspended: suspended, layouts: layouts, temporaryProxies: temporaryProxies, order: order)
    }

    private func render(original: Parsed, candidate: Parsed, provider: String) throws -> Data {
        var metadata: [String] = []
        if !(candidate.suspended.mapping?.isEmpty ?? true) {
            var state: Node = ["definitions": candidate.suspended, "groups": candidate.layouts, "order": sequence(candidate.order)]
            if candidate.temporaryProxies.mapping?.isEmpty == false { state["temporary-proxies"] = candidate.temporaryProxies }
            metadata = [Self.begin] + (try emitted(state)).map { "# " + $0 } + [Self.end]
        }
        func encode(_ body: [String]) -> Data {
            // Put the block before YAML directives/document start and outside all scalar content.
            Data((metadata + body).joined(separator: original.newline).utf8)
        }
        let root = original.source
        let body = original.body
        var mutations: [(Range<Int>, [String])] = []
        let oldDefs = original.definitions
        let newDefs = candidate.definitions
        var canPatch = root.mapping?.style != .flow
        if !same(oldDefs, newDefs) {
            if let section = root.mapping?.first(where: { $0.key.string == Self.providersKey }),
               let range = lineRange(of: section.key, among: root, body: body, end: body.count) {
                let providerMap = section.value
                if providerMap.mapping?.style != .flow, let pair = providerMap.mapping?.first(where: { $0.key.string == provider }),
                   let providerRange = lineRange(of: pair.key, among: providerMap, body: body, end: range.upperBound),
                   let indent = pair.key.mark.map({ $0.column - 1 }), indent > 0,
                   !(newDefs.mapping?.isEmpty ?? true) {
                    let replacement = try lookup(newDefs, provider).map { try emitted(mapping([(provider, $0)])) } ?? []
                    mutations.append((providerRange, replacement.map { String(repeating: " ", count: indent) + $0 }))
                } else if providerMap.mapping?.style != .flow, lookup(oldDefs, provider) == nil,
                          let pair = providerMap.mapping?.first, let indent = pair.key.mark.map({ $0.column - 1 }),
                          indent > 0, let value = lookup(newDefs, provider),
                          lineRange(of: pair.key, among: providerMap, body: body, end: range.upperBound) != nil,
                          candidate.order.last == provider {
                    mutations.append((range.upperBound..<range.upperBound,
                                      try emitted(mapping([(provider, value)])).map { String(repeating: " ", count: indent) + $0 }))
                } else {
                    mutations.append((range, try emitted(mapping([(Self.providersKey, newDefs)]))))
                }
            } else if root[Self.providersKey] == nil && original.root[Self.providersKey] == nil,
                      let first = root.mapping?.first?.key.mark, first.column == 1 {
                mutations.append(((first.line - 1)..<(first.line - 1), try emitted(mapping([(Self.providersKey, newDefs)]))))
            } else { canPatch = false }
        }
        if original.groups != candidate.groups {
            if let section = root.mapping?.first(where: { $0.key.string == Self.groupsKey }),
               let range = lineRange(of: section.key, among: root, body: body, end: body.count),
               section.value.sequence?.style != .flow, section.value.array().count == candidate.groups.count {
                let rawGroups = section.value.array()
                for index in rawGroups.indices where original.groups[index] != candidate.groups[index] {
                    let rawGroup = rawGroups[index]
                    let changed = candidate.groups[index]
                    let next = index + 1 < rawGroups.count ? (rawGroups[index + 1].mark?.line ?? 1) - 1 : range.upperBound
                    guard let first = rawGroup.mark, first.line > range.lowerBound + 1, first.line - 1 < next,
                          body.indices.contains(first.line - 1), first.column >= 3 else { canPatch = false; break }
                    let indentation = String(repeating: " ", count: first.column - 3)
                    guard body[first.line - 1].hasPrefix(indentation + "- ") else { canPatch = false; break }
                    // Patch individual use/fallback fields when they occupy separate block lines.
                    let affected = ["use", "proxies", "empty-fallback"].filter { original.groups[index][$0] != changed[$0] }
                    let end = trimmedEnd(body, start: first.line - 1, end: next)
                    var updatedFields: [(Range<Int>, [String])] = []
                    var additions: [(String, Node)] = []
                    var useFullGroup = rawGroup.mapping?.style == .flow
                    for key in affected {
                        guard let value = changed[key] else { useFullGroup = true; break }
                        if let rawKey = rawGroup.mapping?.first(where: { $0.key.string == key })?.key {
                            guard let subrange = lineRange(of: rawKey, among: rawGroup, body: body, end: end) else {
                                useFullGroup = true; break
                            }
                            updatedFields.append((subrange, try emitted(mapping([(key, value)])).map { indentation + "  " + $0 }))
                        } else { additions.append((key, value)) }
                    }
                    if useFullGroup {
                        mutations.append(((first.line - 1)..<end,
                                          try emitted(Node([changed], .implicit, .block)).map { indentation + $0 }))
                    } else {
                        mutations += updatedFields
                        if !additions.isEmpty {
                            mutations.append((end..<end, try emitted(mapping(additions)).map { indentation + "  " + $0 }))
                        }
                    }
                }
            } else { canPatch = false }
        }
        if canPatch {
            var lines = body
            for (range, replacement) in mutations.sorted(by: {
                if $0.0.lowerBound == $1.0.lowerBound { return $0.0.upperBound > $1.0.upperBound }
                return $0.0.lowerBound > $1.0.lowerBound
            }) {
                lines.replaceSubrange(range, with: replacement)
            }
            let result = encode(lines)
            if let decoded = try? parse(result), same(decoded.root, candidate.root),
               try fields(decoded.definitions).map(\.0) == fields(candidate.definitions).map(\.0) { return result }
        }
        // Do not drop ClashBar rule annotations when a complex document cannot be patched locally.
        guard !body.contains(where: { $0.contains("# " + NativeRuleService.customMarker) }) else {
            throw NativeProxyProviderError.invalidConfig
        }
        let result = try encode(emitted(candidate.root) + [""])
        guard let decoded = try? parse(result), same(decoded.root, candidate.root) else {
            throw NativeProxyProviderError.invalidConfig
        }
        return result
    }

    private func lineRange(of key: Node, among parent: Node, body: [String], end: Int) -> Range<Int>? {
        guard let fields = parent.mapping, let index = fields.firstIndex(where: { $0.key == key }),
              let mark = key.mark, fields.style != .flow, body.indices.contains(mark.line - 1),
              body[mark.line - 1].prefix(mark.column - 1).allSatisfy({ $0 == " " }) else { return nil }
        let next = index + 1 < fields.count ? (fields[index + 1].key.mark?.line ?? 1) - 1 : end
        guard next > mark.line - 1 else { return nil }
        return (mark.line - 1)..<trimmedEnd(body, start: mark.line - 1, end: next)
    }

    private func trimmedEnd(_ lines: [String], start: Int, end: Int) -> Int {
        var end = min(end, lines.count)
        while end > start + 1 {
            let text = lines[end - 1].trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") || text == "..." { end -= 1 } else { break }
        }
        return end
    }

    // Resolve YAML aliases/merges for comparison and fallback emission, preserving native scalar tags and order.
    private func expanded(_ value: Node) throws -> Node {
        if let map = value.mapping {
            var result: [(Node, Node)] = []
            func add(_ key: Node, _ node: Node) {
                if let index = result.firstIndex(where: { $0.0 == key }) { result[index].1 = node }
                else { result.append((key, node)) }
            }
            for (key, merge) in map where key.tag == Tag(.merge) {
                let inputs = merge.sequence.map { Array($0.reversed()) } ?? [merge]
                for input in inputs {
                    guard let fields = try expanded(input).mapping else { throw NativeProxyProviderError.invalidConfig }
                    for (key, node) in fields { add(key, node) }
                }
            }
            for (key, node) in map where key.tag != Tag(.merge) { add(try expanded(key), try expanded(node)) }
            return Node(result, value.tag, .block)
        }
        if let sequence = value.sequence { return Node(try sequence.map(expanded), value.tag, .block) }
        guard let scalar = value.scalar else { throw NativeProxyProviderError.invalidConfig }
        return Node(scalar.string, value.tag, scalar.style)
    }

    private func same(_ lhs: Node, _ rhs: Node) -> Bool {
        if let left = lhs.mapping, let right = rhs.mapping {
            return lhs.tag == rhs.tag && left.count == right.count
                && left.allSatisfy { key, value in right[key].map { same(value, $0) } ?? false }
        }
        if let left = lhs.sequence, let right = rhs.sequence {
            return lhs.tag == rhs.tag && left.count == right.count && zip(left, right).allSatisfy { same($0, $1) }
        }
        return lhs == rhs
    }

    func yaml(_ text: String) throws -> Node {
        do {
            guard let node = try Yams.compose(yaml: text), node.mapping != nil else { throw NativeProxyProviderError.invalidConfig }
            return node
        } catch { throw NativeProxyProviderError.invalidConfig }
    }

    func expandedConfig(_ data: Data) throws -> Node { try parse(data).root }
    func renderConfig(_ node: Node) throws -> String { try Yams.serialize(node: node, width: -1, allowUnicode: true) }
    func providerFields(_ node: Node) throws -> [(String, Node)] { try fields(node[Self.providersKey] ?? mapping([])) }
    func suspendedDefinition(_ name: String, data: Data) throws -> Node? { lookup(try parse(data).suspended, name) }

    private func emitted(_ node: Node) throws -> [String] {
        var result = try renderConfig(node).components(separatedBy: "\n")
        if result.last == "" { result.removeLast() }
        return result
    }

    private func fields(_ node: Node) throws -> [(String, Node)] {
        guard let map = node.mapping else { throw NativeProxyProviderError.invalidConfig }
        var seen = Set<String>()
        return try map.map { key, value in
            guard let name = key.string, seen.insert(name).inserted else { throw NativeProxyProviderError.invalidConfig }
            return (name, value)
        }
    }

    private func strings(_ value: Node?) throws -> [String] {
        guard let value, value.null == nil else { return [] }
        guard let sequence = value.sequence else { throw NativeProxyProviderError.invalidConfig }
        return try sequence.map { node in
            guard let string = node.string else { throw NativeProxyProviderError.invalidConfig }
            return string
        }
    }

    private func lookup(_ map: Node, _ name: String) -> Node? {
        map.mapping?.first(where: { $0.key.string == name })?.value
    }

    private func assign(_ value: Node, named name: String, in map: inout Node) {
        let key = map.mapping?.first(where: { $0.key.string == name })?.key ?? scalar(name)
        map[key] = value
    }

    private func remove(_ name: String, from node: inout Node) {
        node = Node(node.mapping?.filter { $0.key.string != name } ?? [], .implicit, .block)
    }

    private func automatic(_ group: Node) -> Bool { flag(group["include-all"]) || flag(group["include-all-providers"]) }
    private func automaticNodes(_ group: Node) -> Bool { flag(group["include-all"]) || flag(group["include-all-proxies"]) }
    private func flag(_ node: Node?) -> Bool { node?.bool ?? ["true", "1", "yes", "on"].contains(node?.string?.lowercased() ?? "") }
    private func scalar(_ value: String) -> Node { Node(value, Tag(.str), .singleQuoted) }
    private var trueNode: Node { Node("true", Tag(.bool)) }
    private func mapping(_ pairs: [(String, Node)]) -> Node {
        Node(pairs.map { key, value in
            let plain = Node(key)
            return (plain.tag == Tag(.str) ? plain : scalar(key), value)
        }, .implicit, .block)
    }
    private func sequence(_ values: [String]) -> Node { Node(values.map(scalar), .implicit, .flow) }
    private func cachePath(_ cacheID: UUID) -> Node { scalar("./proxies/clashbar-\(cacheID.uuidString.lowercased()).yaml") }

    private func httpURL(_ raw: String) throws -> Node {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let url = URLComponents(string: text)?.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else {
            throw NativeProxyProviderError.invalidURL
        }
        return scalar(text)
    }
}
