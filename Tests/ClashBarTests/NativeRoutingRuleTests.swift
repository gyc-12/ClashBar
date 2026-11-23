import Foundation
import Testing
import Yams

@testable import ClashBar

struct NativeRoutingRuleTests {
    @Test(arguments: [
        ("DOMAIN,example.com,HK", "DOMAIN", "example.com", "HK"),
        ("MATCH,DIRECT", "MATCH", "", "DIRECT"),
        ("IP-CIDR,192.0.2.0/24,HK,no-resolve,src", "IP-CIDR", "192.0.2.0/24", "HK"),
        ("AND,((DOMAIN,a.example),(DST-PORT,443)),HK", "AND", "((DOMAIN,a.example),(DST-PORT,443))", "HK"),
        ("SUB-RULE,(NETWORK,tcp),nested", "SUB-RULE", "(NETWORK,tcp)", "nested"),
        (#"DOMAIN-REGEX,^foo\(bar\).com$,HK"#, "DOMAIN-REGEX", #"^foo\(bar\).com$"#, "HK"),
    ])
    func outerCommaParsing(raw: String, type: String, payload: String, target: String) throws {
        let syntax = try #require(NativeRuleSyntax(raw: raw))
        #expect(syntax.type == type)
        #expect(syntax.payload == payload)
        #expect(syntax.target == target)
        let replaced = try syntax.replacingTarget("REJECT")
        #expect(NativeRuleSyntax(raw: replaced)?.target == "REJECT")
        #expect(NativeRuleSyntax(raw: replaced)?.options == syntax.options)
    }

    @Test func logicalPayloadCorrespondenceIncludesNestedOperators() throws {
        let logic = try #require(NativeRuleSyntax(raw: "OR,((DOMAIN,a.example),(NOT,((DST-PORT,443)))),DIRECT"))
        #expect(logic.matchesRuntimePayload("((Domain,a.example) || (NOT,(!(DstPort,443))))"))
        #expect(!logic.matchesRuntimePayload("((Domain,b.example) || (NOT,(!(DstPort,443))))"))
        #expect(NativeRuleSyntax.normalizedType("SubRules") == NativeRuleSyntax.normalizedType("SUB-RULE"))
    }

    @Test func policyReplacementKeepsFormatting() throws {
        let syntax = try #require(NativeRuleSyntax(raw: "IP-CIDR, 192.0.2.0/24, HK ,no-resolve,src"))
        #expect(try syntax.replacingTarget("JP") == "IP-CIDR, 192.0.2.0/24, JP ,no-resolve,src")
        #expect(throws: QuickRuleError.self) { try syntax.replacingTarget("bad,target") }
    }

    @Test func editsOnlyTheSelectedDuplicateAndKeepsComments() throws {
        let yaml = """
            # Header
            proxies: []
            rules:
              # Two identical entries
              - 'DOMAIN,example.com,DIRECT' # first clashbar:custom
              - DOMAIN,example.com,DIRECT # second
              - IP-CIDR,192.0.2.0/24,DIRECT,no-resolve,src
              - MATCH,DIRECT
            tail: &tail {keep: yes} # Keep me
            ref: *tail
            """ + "\n"
        let fixture = try QuickRuleFixture(yaml: yaml)
        defer { fixture.clean() }
        let service = NativeRuleService(homeDirectory: fixture.root)
        let document = try service.read(configURL: fixture.config)
        #expect(document.entries.map(\.isCustom) == [true, false, false, false])
        let edit = try service.prepare(
            document: document, entry: document.entries[1], raw: "DOMAIN,example.com,REJECT", isCustom: true)
        let output = String(decoding: edit.updatedData, as: UTF8.self)
        #expect(
            output
                == yaml.replacingOccurrences(
                    of: "- DOMAIN,example.com,DIRECT # second",
                    with: "- 'DOMAIN,example.com,REJECT' # second clashbar:custom"))
        let updated = try service.read(configURL: fixture.config, data: edit.updatedData)
        #expect(updated.entries.map(\.isCustom) == [true, true, false, false])
        #expect(updated.entries[0].raw == document.entries[0].raw)
        #expect(updated.entries[2].raw == document.entries[2].raw)
    }

    @Test func markerIsACommentAndCanBeRemoved() throws {
        let fixture = try QuickRuleFixture(
            yaml: "rules:\n  - 'DOMAIN,clashbar:custom,DIRECT' # user note\n  - 'MATCH,DIRECT' # keep clashbar:custom\n"
        )
        defer { fixture.clean() }
        let service = NativeRuleService(homeDirectory: fixture.root)
        let doc = try service.read(configURL: fixture.config)
        #expect(doc.entries.map(\.isCustom) == [false, true])
        let edit = try service.prepare(document: doc, entry: doc.entries[1], raw: doc.entries[1].raw, isCustom: false)
        let output = String(decoding: edit.updatedData, as: UTF8.self)
        #expect(output.contains("# keep"))
        #expect(!output.contains("# keep clashbar:custom"))
        #expect(
            try service.read(configURL: fixture.config, data: edit.updatedData).entries.map(\.raw)
                == doc.entries.map(\.raw))
    }

    @Test(arguments: [
        "rules: ['DOMAIN,a.example,DIRECT', 'MATCH,DIRECT']\n",
        "{rules: ['DOMAIN,a.example,DIRECT', 'MATCH,DIRECT'], keep: 42}\n",
        "base: &rules ['DOMAIN,a.example,DIRECT', 'MATCH,DIRECT']\nrules: *rules\nother: *rules\n",
        "rules:\n  - &first DOMAIN,a.example,DIRECT\n  - MATCH,DIRECT\ncopy: *first\n",
        "rules:\n  - >-\n    DOMAIN,a.example,DIRECT\n  - MATCH,DIRECT\n",
        "rules:\r\n  - DOMAIN,a.example,DIRECT\r\n  - MATCH,DIRECT\r\n",
    ])
    func specialYAMLRemainsEquivalent(yaml: String) throws {
        let fixture = try QuickRuleFixture(yaml: yaml)
        defer { fixture.clean() }
        let service = NativeRuleService(homeDirectory: fixture.root)
        let doc = try service.read(configURL: fixture.config)
        let edit = try service.prepare(
            document: doc, entry: doc.entries[0], raw: "DOMAIN,a.example,REJECT", isCustom: true)
        var expected = try #require(Yams.load(yaml: yaml) as? [String: Any])
        expected["rules"] = ["DOMAIN,a.example,REJECT", "MATCH,DIRECT"]
        let actual = try #require(Yams.load(yaml: String(decoding: edit.updatedData, as: UTF8.self)) as? [String: Any])
        #expect(NSDictionary(dictionary: actual).isEqual(to: expected))
        #expect(try service.read(configURL: fixture.config, data: edit.updatedData).entries[0].isCustom)
        if yaml.contains("\r\n") { #expect(String(decoding: edit.updatedData, as: UTF8.self).contains("\r\n")) }
    }

    @Test(arguments: [
        "rules:\n  - &first 'DOMAIN,a.example,DIRECT' # clashbar:custom\n  - MATCH,DIRECT\ncopy: *first\n",
        "rules: [\n  'DOMAIN,a.example,DIRECT', # clashbar:custom\n  'MATCH,DIRECT'\n]\n",
        "rules:\n  - >- # clashbar:custom\n    DOMAIN,a.example,DIRECT\n  - MATCH,DIRECT\n",
        "base: &base\n  rules:\n    - DOMAIN,a.example,DIRECT # clashbar:custom\n    - MATCH,DIRECT\n<<: *base\n",
    ])
    func customMarkerSurvivesSpecialYAMLExpansion(yaml: String) throws {
        let fixture = try QuickRuleFixture(yaml: yaml)
        defer { fixture.clean() }
        let service = NativeRuleService(homeDirectory: fixture.root)
        let document = try service.read(configURL: fixture.config)
        #expect(document.entries[0].isCustom)
        let edit = try service.prepare(
            document: document, entry: document.entries[1], raw: "MATCH,REJECT", isCustom: false)
        #expect(try service.read(configURL: fixture.config, data: edit.updatedData).entries[0].isCustom)
    }

    @Test func quickAddRetainsCustomProvenanceAndComments() throws {
        let fixture = try QuickRuleFixture(
            yaml: "rules:\n  - DOMAIN,old.example,DIRECT # note clashbar:custom\n  - MATCH,DIRECT # final\n")
        defer { fixture.clean() }
        let edit = try fixture.edit()
        let service = NativeRuleService(homeDirectory: fixture.root)
        let doc = try service.read(configURL: fixture.config, data: edit.updatedData)
        #expect(doc.entries.map(\.isCustom) == [true, true, false])
        #expect(String(decoding: edit.updatedData, as: UTF8.self).contains("# final"))
    }

    @Test func externalEditPreventsOverwrite() throws {
        let fixture = try QuickRuleFixture()
        defer { fixture.clean() }
        let service = NativeRuleService(homeDirectory: fixture.root)
        let doc = try service.read(configURL: fixture.config)
        try Data("rules: ['MATCH,REJECT']".utf8).write(to: fixture.config)
        #expect(throws: QuickRuleError.self) {
            try service.prepare(document: doc, entry: doc.entries[0], raw: "MATCH,REJECT", isCustom: false)
        }
    }

    @Test func nativeRuntimeCorrespondenceDoesNotGuessByIndex() throws {
        let fixture = try QuickRuleFixture()
        defer { fixture.clean() }
        let doc = try NativeRuleService(homeDirectory: fixture.root).read(configURL: fixture.config)
        #expect(doc.matchesRuntime([RuleItem(type: "Match", payload: "", proxy: "DIRECT", index: 0)]))
        #expect(!doc.matchesRuntime([RuleItem(type: "Match", payload: "", proxy: "REJECT", index: 0)]))
        #expect(!doc.matchesRuntime([]))
    }

    @Test func preservesActualRuntimeTunAndPorts() throws {
        let fixture = try QuickRuleFixture(
            yaml: "mixed-port: 7890\ntun: {enable: false, stack: system, mtu: 1500}\nrules: ['MATCH,DIRECT']")
        defer { fixture.clean() }
        let runtime = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(
                #"{"mixed-port":9876,"mode":"global","tun":{"enable":true,"stack":"gvisor","mtu":9000,"dns-hijack":["any:53"],"auto-route":true},"ipv6":true}"#
                    .utf8))
        let payload = try fixture.service.reloadPayload(Data(contentsOf: fixture.config), runtime: runtime)
        let parsed = try #require(Yams.load(yaml: payload) as? [String: Any])
        let tun = try #require(parsed["tun"] as? [String: Any])
        #expect(tun["stack"] as? String == "gvisor")
        #expect(tun["enable"] as? Bool == true)
        #expect(tun["mtu"] as? Int == 9000)
        #expect(parsed["mixed-port"] as? Int == 9876)
        #expect(parsed["rules"] as? [String] == ["MATCH,DIRECT"])
    }
}

@MainActor
struct NativeRulePresentationTests {
    @Test func customFilteringAndGroupingRetainSourceIdentities() {
        let items = [
            NativeRuleEntry(index: 3, raw: "DOMAIN,a.example,DIRECT", isCustom: true),
            NativeRuleEntry(index: 7, raw: "DOMAIN,a.example,DIRECT", isCustom: false),
            NativeRuleEntry(index: 9, raw: "MATCH,REJECT", isCustom: true),
        ].map(\.item)
        let model = RulesViewModel()
        model.customOnly = true
        model.groupByPolicy = true
        model.updateVisibleRules(items: items, providers: [:])
        #expect(model.output.rules.map { $0.nativeEntry?.index } == [3, 9])
        #expect(model.output.groups.flatMap(\.rules).count == 2)
        model.filterText = "a.example"
        model.updateVisibleRules(items: items, providers: [:])
        #expect(model.output.rules.first?.nativeEntry?.index == 3)
        #expect(items[0].id != items[1].id)
    }
}
