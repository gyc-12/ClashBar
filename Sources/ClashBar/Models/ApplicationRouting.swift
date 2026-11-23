import Foundation

enum ApplicationRoutingError: Error {
    case invalidApplication, invalidProcess, processLookupDisabled
}

struct ApplicationRoutingCandidate: Identifiable, Hashable, Sendable {
    let name: String
    let processName: String
    let processPath: String?
    let bundlePath: String?
    var id: String { self.processPath ?? "name:\(self.processName)" }
    var preferredType: QuickRuleType { self.processPath == nil ? .processName : .processPath }
    func target(for type: QuickRuleType) -> String { type == .processPath ? self.processPath ?? "" : self.processName }

    static func validatedTarget(_ input: String, type: QuickRuleType) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard type.isProcess, !value.isEmpty, !value.contains(","), !value.contains("\\"),
            !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            NativeRuleSyntax(raw: "\(type.rawValue),\(value),DIRECT")?.payload == value
        else { throw ApplicationRoutingError.invalidProcess }
        if type == .processPath {
            guard value.hasPrefix("/"), !value.hasSuffix("/") else { throw ApplicationRoutingError.invalidProcess }
        } else if value.contains("/") { throw ApplicationRoutingError.invalidProcess }
        return value
    }

    static func from(connection: ConnectionSummary) -> Self? {
        let metadata = connection.metadata
        let path = metadata?.processPath.flatMap { try? self.validatedTarget($0, type: .processPath) }
        let process = metadata?.process.flatMap { try? self.validatedTarget($0, type: .processName) }
            ?? path.map { URL(fileURLWithPath: $0).lastPathComponent }
        guard let process else { return nil }
        return Self(name: process, processName: process, processPath: path, bundlePath: nil)
    }

    static func observed(in connections: [ConnectionSummary]) -> [Self] {
        var seen: Set<String> = []
        return connections.compactMap { self.from(connection: $0) }.filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func matches(_ search: String) -> Bool {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return keyword.isEmpty || [self.name, self.processName, self.processPath ?? ""].contains {
            $0.localizedStandardContains(keyword)
        }
    }
}

struct ApplicationRuleEditorContext: Identifiable {
    let id = UUID()
    let document: NativeRuleDocument
    let selected: ApplicationRoutingCandidate?
    let observed: [ApplicationRoutingCandidate]
    let processMode: String
    let fileProcessMode: String
    let isSubscription: Bool
}
