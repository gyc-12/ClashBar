import Foundation
import Yams

struct NativeProxyProvider: Equatable, Identifiable {
    let name: String
    let type: String
    let url: String?
    let enabled: Bool
    let interval: Int?
    let healthCheckURL: String?
    let options: SubscriptionOptions
    var id: String { name }
}

struct NativeProxyProviderGroup: Equatable, Identifiable {
    let name: String
    let automatic: Bool
    let use: [String]
    let members: [String]
    var id: String { name }
}

struct NativeProxyProviderDocument: Equatable {
    let configURL: URL
    let data: Data
    let entries: [NativeProxyProvider]
    let groups: [NativeProxyProviderGroup]
    let staticNodes: [String]

    static let builtInPolicies = ["DIRECT", "REJECT", "REJECT-DROP", "PASS"]

    var memberChoices: [String] { groups.map(\.name) + staticNodes + Self.builtInPolicies }

    var activeNames: Set<String> { Set(entries.filter(\.enabled).map(\.name)) }

    func affectedGroups(for name: String) -> [String] {
        groups.filter { $0.automatic || $0.use.contains(name) }.map(\.name)
    }
}

enum NativeProxyProviderAction {
    case add(name: String, url: String, interval: Int?, healthCheckURL: String?, groups: Set<String>, options: SubscriptionOptions = .init())
    case edit(name: String, newName: String? = nil, url: String, interval: Int? = nil, healthCheckURL: String? = nil, options: SubscriptionOptions? = nil)
    case setEnabled(name: String, enabled: Bool)
    case delete(name: String)
    case group(name: String, members: [String]?)
}

enum NativeProxyProviderError: Error, Equatable {
    case invalidConfig, invalidName, invalidURL, invalidInterval, conflict, unavailable, sourceFailed, reloadFailed
    case emptyGroups([String])
    case groupCycle, groupReferences([String])
    case invalidOptions, retryFailed(String)
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
                                            use: try strings(lookup(parsed.layouts, name) ?? group["use"]), members: try strings(group["proxies"]))
        }
        return NativeProxyProviderDocument(configURL: configURL, data: data, entries: entries, groups: groups,
            staticNodes: parsed.root["proxies"]?.array().compactMap { $0["name"]?.string } ?? [])
    }

    func prepare(_ action: NativeProxyProviderAction, in document: NativeProxyProviderDocument,
                 fallback: Fallback? = nil, filteredEmptyGroups: Set<String> = [], cacheID: UUID = UUID()) throws -> NativeProxyProviderEdit {
        let original = try parse(document.data)
        var candidate = original
        var definitions = original.definitions
        var groups = original.groups
        let oldGroups = groups
        var name: String
        var originalName: String?
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
        func validateProviderName(_ candidateName: String) throws {
            let reserved = ["default", "GLOBAL", "DIRECT", "REJECT", "REJECT-DROP", "COMPATIBLE", "PASS", "PASS-RULE"]
            guard !candidateName.isEmpty, !candidateName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !reserved.contains(where: { $0.caseInsensitiveCompare(candidateName) == .orderedSame }),
                  lookup(definitions, candidateName) == nil, lookup(candidate.suspended, candidateName) == nil,
                  !groups.contains(where: { $0["name"]?.string == candidateName }) else { throw NativeProxyProviderError.invalidName }
        }
        func validateOptions(_ options: SubscriptionOptions, interval: Int?, allowedProxy: String? = nil) throws {
            if let interval, !(0...Int(Int32.max)).contains(interval) { throw NativeProxyProviderError.invalidInterval }
            guard (1...Int(Int32.max)).contains(options.healthInterval) else { throw NativeProxyProviderError.invalidInterval }
            var validProxies = ["DIRECT"] + document.groups.map(\.name) + document.staticNodes
            if let allowedProxy { validProxies.append(allowedProxy) }
            guard validProxies.contains(options.downloadProxy),
                  !options.prefix.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  options.userAgents.allSatisfy({ !$0.isEmpty && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) })
            else { throw NativeProxyProviderError.invalidOptions }
        }

        switch action {
        case let .group(groupName, members):
            return try prepareGroup(groupName, members: members, document: document, original: original)
        case let .add(rawName, url, interval, healthURL, bindings, options):
            name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            try validateProviderName(name)
            try validateOptions(options, interval: interval ?? SubscriptionOptions.defaultInterval)
            var definition: Node = ["type": scalar("http"), "url": try httpURL(url), "path": cachePath(cacheID)]
            definition["interval"] = Node(String(interval ?? SubscriptionOptions.defaultInterval), Tag(.int))
            definition["health-check"] = ["enable": Node(String(options.healthEnabled), Tag(.bool)),
                "url": try httpURL(healthURL ?? SubscriptionOptions.defaultHealthURL), "interval": Node(String(options.healthInterval), Tag(.int))]
            definition["proxy"] = scalar(options.downloadProxy)
            if !options.userAgents.isEmpty { definition["header"] = ["User-Agent": sequence(options.userAgents)] }
            if !options.prefix.isEmpty { definition["override"] = ["additional-prefix": scalar(options.prefix)] }
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
        case let .edit(target, rawNewName, url, interval, healthURL, options):
            let isActive = lookup(definitions, target) != nil
            let isSuspended = lookup(candidate.suspended, target) != nil
            guard isActive != isSuspended,
                  let initialDefinition = lookup(definitions, target) ?? lookup(candidate.suspended, target)
            else { throw NativeProxyProviderError.conflict }
            let targetName = (rawNewName ?? target).trimmingCharacters(in: .whitespacesAndNewlines)
            let renamed = targetName != target
            if renamed { try validateProviderName(targetName) }
            name = targetName
            originalName = target
            var definition = initialDefinition
            let isHTTP = definition["type"]?.string == "http"
            if isHTTP {
                let normalized = try httpURL(url)
                if normalized.string != definition["url"]?.string {
                    definition["url"] = normalized
                    definition["path"] = cachePath(cacheID)
                    fresh = true
                }
                if let options {
                    let currentEntry = try entry(target, initialDefinition, enabled: isActive)
                    try validateOptions(options, interval: interval, allowedProxy: initialDefinition["proxy"]?.string)
                    if interval != currentEntry.interval {
                        if let interval { definition["interval"] = Node(String(interval), Tag(.int)) }
                        else { remove("interval", from: &definition) }
                    }
                    let healthChanged = options.healthEnabled != currentEntry.options.healthEnabled
                        || healthURL != currentEntry.healthCheckURL
                        || options.healthInterval != currentEntry.options.healthInterval
                    if healthChanged {
                        var healthCheck = definition["health-check"]?.mapping != nil ? definition["health-check"]! : mapping([])
                        healthCheck["enable"] = Node(String(options.healthEnabled), Tag(.bool))
                        if options.healthEnabled {
                            healthCheck["url"] = try httpURL(healthURL ?? SubscriptionOptions.defaultHealthURL)
                            healthCheck["interval"] = Node(String(options.healthInterval), Tag(.int))
                            definition["health-check"] = healthCheck
                        } else if definition["health-check"] != nil || healthURL != nil {
                            if let healthURL { healthCheck["url"] = try httpURL(healthURL) }
                            healthCheck["interval"] = Node(String(options.healthInterval), Tag(.int))
                            definition["health-check"] = healthCheck
                        }
                    }
                    if options.downloadProxy != currentEntry.options.downloadProxy {
                        definition["proxy"] = scalar(options.downloadProxy)
                    }
                    if options.userAgents != currentEntry.options.userAgents {
                        var header = definition["header"]?.mapping != nil ? definition["header"]! : mapping([])
                        if let existingKey = header.mapping?.first(where: { $0.key.string?.caseInsensitiveCompare("User-Agent") == .orderedSame })?.key.string {
                            remove(existingKey, from: &header)
                        }
                        if !options.userAgents.isEmpty {
                            assign(sequence(options.userAgents), named: "User-Agent", in: &header)
                            definition["header"] = header
                        } else if header.mapping?.isEmpty ?? true {
                            remove("header", from: &definition)
                        } else {
                            definition["header"] = header
                        }
                    }
                    if options.prefix != currentEntry.options.prefix {
                        var override = definition["override"]?.mapping != nil ? definition["override"]! : mapping([])
                        if options.prefix.isEmpty {
                            remove("additional-prefix", from: &override)
                            if override.mapping?.isEmpty ?? true { remove("override", from: &definition) }
                            else { definition["override"] = override }
                        } else {
                            assign(scalar(options.prefix), named: "additional-prefix", in: &override)
                            definition["override"] = override
                        }
                    }
                }
            }
            let definitionChanged = !same(initialDefinition, definition)
            if renamed || definitionChanged {
                if isActive {
                    if renamed { remove(target, from: &definitions) }
                    assign(definition, named: name, in: &definitions)
                    probe = name
                } else {
                    if renamed { remove(target, from: &candidate.suspended) }
                    assign(definition, named: name, in: &candidate.suspended)
                    if fresh { probe = name }
                }
                if renamed {
                    candidate.order = candidate.order.map { $0 == target ? name : $0 }
                    var seenLayoutGroups = Set<String>()
                    for index in groups.indices {
                        guard let group = groups[index]["name"]?.string else { throw NativeProxyProviderError.invalidConfig }
                        seenLayoutGroups.insert(group)
                        let use = try strings(lookup(original.layouts, group) ?? groups[index]["use"])
                        guard use.contains(target) else { continue }
                        let logical = try checkLayout(groups[index], group).map { $0 == target ? name : $0 }
                        replaceReferences(logical, in: &groups[index], groupName: group, candidate: &candidate)
                        if groups[index] != oldGroups[index] { affected.insert(group) }
                    }
                    for (group, saved) in try fields(original.layouts) where !seenLayoutGroups.contains(group) {
                        let logical = try strings(saved)
                        guard logical.contains(target) else { continue }
                        assign(sequence(logical.map { $0 == target ? name : $0 }), named: group, in: &candidate.layouts)
                    }
                }
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

        let previousLookupName = originalName ?? name
        if lookup(original.definitions, previousLookupName) != lookup(definitions, name) || previousLookupName != name {
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
        let data = changed ? try render(original: original, candidate: candidate, provider: name, originalProvider: originalName) : document.data
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

    private func prepareGroup(_ name: String, members: [String]?, document: NativeProxyProviderDocument,
                              original: Parsed) throws -> NativeProxyProviderEdit {
        var candidate = original
        var groups = original.groups
        guard let index = groups.firstIndex(where: { $0["name"]?.string == name }) else { throw NativeProxyProviderError.conflict }
        if let members {
            let old = try strings(groups[index]["proxies"])
            let choices = Set(document.memberChoices + old)
            guard Set(members).count == members.count, members.allSatisfy(choices.contains) else { throw NativeProxyProviderError.conflict }
            let group = groups[index]
            let hasProviders = automatic(group) ? !document.activeNames.isEmpty : try !strings(group["use"]).isEmpty
            guard !members.isEmpty || hasProviders || (automaticNodes(group) && !document.staticNodes.isEmpty) else {
                throw NativeProxyProviderError.emptyGroups([name])
            }
            var dependencies = Dictionary(uniqueKeysWithValues: document.groups.map { ($0.name, $0.members) })
            dependencies[name] = members
            var seen = Set<String>()
            var pending = members
            while let target = pending.popLast() {
                guard target != name else { throw NativeProxyProviderError.groupCycle }
                if seen.insert(target).inserted { pending += dependencies[target] ?? [] }
            }
            if old != members {
                if members.isEmpty { remove("proxies", from: &groups[index]) }
                else { groups[index]["proxies"] = sequence(members) }
                remove(name, from: &candidate.temporaryProxies)
            }
        } else {
            var references = document.groups.filter { $0.name != name && $0.members.contains(name) }.map { "proxy-groups → \($0.name)" }
            func inspectRules(_ list: Node?, at path: String) throws {
                for (index, rule) in try strings(list).enumerated() {
                    if let syntax = NativeRuleSyntax(raw: rule), syntax.target == name && !syntax.targetsSubRule {
                        references.append("\(path)[\(index + 1)]")
                    }
                }
            }
            try inspectRules(original.root["rules"], at: "rules")
            for (section, list) in try fields(original.root["sub-rules"] ?? mapping([])) {
                try inspectRules(list, at: "sub-rules.\(section)")
            }
            func inspectAdapters(_ value: Node, path: String) {
                if let map = value.mapping {
                    for (key, child) in map {
                        let field = key.string ?? "?"
                        if ["proxy", "dialer-proxy", "empty-fallback"].contains(field), child.string == name {
                            references.append(path + "." + field)
                        } else { inspectAdapters(child, path: path + "." + field) }
                    }
                } else if let list = value.sequence {
                    for (index, child) in list.enumerated() { inspectAdapters(child, path: "\(path)[\(index + 1)]") }
                }
            }
            for section in ["proxy-groups", "proxies", "proxy-providers", "rule-providers", "listeners"] {
                if let value = original.root[section] { inspectAdapters(value, path: section) }
            }
            inspectAdapters(original.suspended, path: "disabled-proxy-providers")
            guard references.isEmpty else { throw NativeProxyProviderError.groupReferences(references) }
            groups.remove(at: index)
            remove(name, from: &candidate.layouts)
            remove(name, from: &candidate.temporaryProxies)
        }
        candidate.root[Self.groupsKey] = Node(groups, .implicit, .block)
        let data = groups == original.groups ? document.data : try render(original: original, candidate: candidate, provider: "")
        return NativeProxyProviderEdit(file: NativeRuleEdit(configURL: document.configURL, originalConfig: document.data,
            targetURL: document.configURL.resolvingSymlinksInPath(), originalData: document.data, updatedData: data, provider: nil),
            document: try read(configURL: document.configURL, data: data), affectedGroups: members == nil ? [] : [name],
            probeProvider: nil, freshSource: false, changesRuntime: data != document.data)
    }

    private func entry(_ name: String, _ node: Node, enabled: Bool) throws -> NativeProxyProvider {
        guard node.mapping != nil, let type = node["type"]?.string else { throw NativeProxyProviderError.invalidConfig }
        let interval = node["interval"]?.int ?? node["interval"]?.string.flatMap(Int.init)
        let healthCheck = node["health-check"]
        let healthEnabled = healthCheck?["enable"].map(flag) ?? false
        let healthURL = healthCheck?["url"]?.string
        let healthInterval = (healthCheck?["interval"]?.int ?? healthCheck?["interval"]?.string.flatMap(Int.init))
            ?? SubscriptionOptions.defaultHealthInterval
        let downloadProxy = node["proxy"]?.string?.trimmedNonEmpty ?? "DIRECT"
        let agentNode = node["header"]?.mapping?.first(where: { $0.key.string?.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value
        let userAgents: [String] = if let list = agentNode?.sequence {
            list.compactMap(\.string)
        } else if let single = agentNode?.string {
            [single]
        } else {
            []
        }
        let prefix = node["override"]?["additional-prefix"]?.string ?? ""
        return NativeProxyProvider(
            name: name, type: type, url: node["url"]?.string, enabled: enabled, interval: interval,
            healthCheckURL: healthURL,
            options: SubscriptionOptions(
                healthEnabled: healthEnabled, healthInterval: healthInterval, downloadProxy: downloadProxy,
                userAgents: userAgents, prefix: prefix))
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

    private func render(original: Parsed, candidate: Parsed, provider: String, originalProvider: String? = nil) throws -> Data {
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
        let patchProvider = originalProvider ?? provider
        var canPatch = root.mapping?.style != .flow
        if !same(oldDefs, newDefs) {
            if let section = root.mapping?.first(where: { $0.key.string == Self.providersKey }),
               let range = lineRange(of: section.key, among: root, body: body, end: body.count) {
                let providerMap = section.value
                if providerMap.mapping?.style != .flow, let pair = providerMap.mapping?.first(where: { $0.key.string == patchProvider }),
                   let providerRange = lineRange(of: pair.key, among: providerMap, body: body, end: range.upperBound),
                   let indent = pair.key.mark.map({ $0.column - 1 }), indent > 0,
                   !(newDefs.mapping?.isEmpty ?? true) {
                    let replacement = try lookup(newDefs, provider).map { try emitted(mapping([(provider, $0)])) } ?? []
                    mutations.append((providerRange, replacement.map { String(repeating: " ", count: indent) + $0 }))
                } else if providerMap.mapping?.style != .flow, lookup(oldDefs, provider) == nil, originalProvider == nil,
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
            } else if let section = root.mapping?.first(where: { $0.key.string == Self.groupsKey }),
                      let range = lineRange(of: section.key, among: root, body: body, end: body.count),
                      let replacement = candidate.root[Self.groupsKey] {
                let survivors = Set(candidate.groups.compactMap { $0["name"]?.string })
                let raw = section.value.array()
                if !survivors.isEmpty, raw.count == survivors.count + 1, section.value.sequence?.style != .flow,
                   let removed = original.groups.firstIndex(where: { !survivors.contains($0["name"]?.string ?? "") }),
                   let line = raw[removed].mark?.line, body.indices.contains(line - 1),
                   body[line - 1].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                    let next = removed + 1 < raw.count ? (raw[removed + 1].mark?.line ?? line) - 1 : range.upperBound
                    if next > line - 1 { mutations.append((line - 1..<trimmedEnd(body, start: line - 1, end: next), [])) }
                    else { canPatch = false }
                } else {
                    mutations.append((range, try emitted(mapping([(Self.groupsKey, replacement)]))))
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
