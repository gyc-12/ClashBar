import Foundation
import Yams

struct ApplicationRuleService {
    let homeDirectory: URL

    static func processMode(in data: Data, runtime: [String: JSONValue] = [:]) throws -> String {
        if let value = runtime["find-process-mode"]?.foundationObject as? String { return value.lowercased() }
        guard let document = try Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any]
        else { throw QuickRuleError.invalidConfig }
        guard let mode = document["find-process-mode"], !(mode is NSNull) else { return "strict" }
        if let value = mode as? String { return value.lowercased() }
        // Yams uses YAML 1.1 and decodes unquoted `off` as false; mihomo uses it as a mode string.
        if let value = mode as? Bool, !value { return "off" }
        throw QuickRuleError.invalidConfig
    }

    func prepare(rule: QuickRoutingRule, document: NativeRuleDocument, enableProcessLookup: Bool) throws -> NativeRuleEdit {
        guard rule.type.isProcess else { throw ApplicationRoutingError.invalidProcess }
        guard document.policies.contains(rule.policy) else { throw QuickRuleError.invalidPolicy }
        guard try Data(contentsOf: document.configURL) == document.originalData else { throw QuickRuleError.contextChanged }
        if !enableProcessLookup, try Self.processMode(in: document.originalData) == "off" {
            throw ApplicationRoutingError.processLookupDisabled
        }
        let native = NativeRuleService(homeDirectory: self.homeDirectory)
        var data = try native.prepend(rule: rule, document: document)
        if enableProcessLookup { data = try native.enablingProcessLookup(in: data, configURL: document.configURL) }
        return NativeRuleEdit(configURL: document.configURL, originalConfig: document.originalData,
                              targetURL: document.configURL.resolvingSymlinksInPath(), originalData: document.originalData,
                              updatedData: data, provider: nil)
    }
}
