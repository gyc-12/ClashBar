import Foundation
import Testing
import Yams

@testable import ClashBar

struct QuickRoutingRuleTests {
    @Test(arguments: [
        ("https://EXAMPLE.com:8443/a?q=1#x", "DOMAIN", "example.com"),
        ("api.example.com.", "DOMAIN", "api.example.com"),
        ("https://例子.测试/path", "DOMAIN", "xn--fsqu00a.xn--0zwm56d"),
        ("192.0.2.1:443", "IP-CIDR", "192.0.2.1/32"),
        ("192.0.2.0/24", "IP-CIDR", "192.0.2.0/24"),
        ("[2001:db8::1]:443", "IP-CIDR6", "2001:db8::1/128"),
        ("https://[2001:db8::1]/", "IP-CIDR6", "2001:db8::1/128"),
        ("2001:db8::/48", "IP-CIDR6", "2001:db8::/48"),
    ])
    func normalize(input: String, type: String, value: String) {
        let target = QuickRuleTarget.parse(input)
        #expect(target?.type.rawValue == type)
        #expect(target?.value == value)
    }

    @Test(arguments: [
        "", "file:///etc/hosts", "chrome://settings", "about:blank", "example.com,REJECT", "bad domain",
        "*.example.com", "999.1.2.3", "192.0.2.1/33", "::1/129", "evil\n.com", "foo@bar.com", "foo:99999", "-foo.com",
        "foo..com",
    ])
    func rejectMalformed(input: String) { #expect(QuickRuleTarget.parse(input) == nil) }

    @Test func logsSelectOnlyDestinations() {
        let log = #"[TCP] 127.0.0.1:52010 --> api.example.com:443 match DomainSuffix(example.com) using Proxy[HK]"#
        #expect(QuickRuleTarget.from(log: log).map(\.value) == ["api.example.com"])
        #expect(
            QuickRuleTarget.from(log: "[TCP] 127.0.0.1:4 --> [2001:db8::1]:443 error").map(\.value) == [
                "2001:db8::1/128"
            ]
        )
        #expect(
            QuickRuleTarget.from(log: "dial tcp 192.0.2.1:443: connection refused").map(\.value) == ["192.0.2.1/32"]
        )
        #expect(
            QuickRuleTarget.from(log: "lookup example.com on 127.0.0.1:53: no such host").map(\.value) == [
                "example.com"
            ]
        )
        #expect(QuickRuleTarget.from(log: "version 1.2.3; updating rules.example.com; source=127.0.0.1").isEmpty)
    }

    @Test func sourceRulesRetainScope() {
        #expect(
            QuickRuleTarget.from(rule: RuleItem(type: "DomainSuffix", payload: "example.com", proxy: "DIRECT"))?.type
                == .domainSuffix
        )
        #expect(QuickRuleTarget.from(rule: RuleItem(type: "RuleSet", payload: "example.com", proxy: "DIRECT")) == nil)
        #expect(QuickRuleTarget.from(rule: RuleItem(type: "DomainKeyword", payload: "google", proxy: "DIRECT")) == nil)
        #expect(
            QuickRuleTarget.from(rule: RuleItem(type: "IPCIDR", payload: "2001:db8::/32", proxy: "DIRECT"))?.type
                == .ipv6
        )
    }

    @Test func noScriptInjectionOrUnsupportedBrowser() {
        #expect(BrowserTabService.script(for: "com.apple.Safari")?.contains("current tab") == true)
        #expect(BrowserTabService.script(for: "com.google.Chrome")?.contains("active tab") == true)
        #expect(BrowserTabService.script(for: "org.mozilla.firefox") == nil)
        #expect(BrowserTabService.script(for: "com.apple.Safari\" & do shell script") == nil)
    }
}

struct QuickRuleFixture {
    let root: URL
    let config: URL
    let service: QuickRuleService

    init(yaml: String = "proxies: []\nrules: ['MATCH,DIRECT']\n") throws {
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("clashbar-tests-\(UUID().uuidString)")
        let directory = self.root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.config = directory.appendingPathComponent("test.yaml")
        try Data(yaml.utf8).write(to: self.config)
        self.service = QuickRuleService(homeDirectory: self.root)
    }

    func clean() { try? FileManager.default.removeItem(at: self.root) }

    func context() throws -> QuickRuleEditorContext {
        let data = try Data(contentsOf: self.config)
        return QuickRuleEditorContext(
            configURL: self.config,
            target: nil,
            policies: try self.service.policies(in: data),
            originalConfig: data,
            providers: try self.service.localProviders(in: data, configURL: self.config),
            isSubscription: false,
            notice: nil
        )
    }

    func edit(provider: String? = nil) throws -> NativeRuleEdit {
        try self.service.prepare(
            rule: QuickRoutingRule(type: .domain, target: "example.com", policy: "REJECT"),
            context: self.context(),
            providerName: provider
        )
    }
}

@MainActor
struct NativeRulePersistenceTests {
    enum Failure: Error { case rejected }

    @Test func nativeEditRetainsOtherSectionsAndReplacesDuplicate() throws {
        let fixture = try QuickRuleFixture(
            yaml: """
                # User configuration
                proxies: []
                base: &base {type: select, proxies: [DIRECT]}
                proxy-groups:
                  - <<: *base
                    name: 'HK #1'
                rules:
                  - DOMAIN,example.com,DIRECT
                  - DOMAIN-SUFFIX,example.com,DIRECT
                  - MATCH,DIRECT
                # DNS comment
                dns: {enable: false} # retained
                """
        )
        defer { fixture.clean() }
        let edit = try fixture.edit()
        let text = String(decoding: edit.updatedData, as: UTF8.self)
        #expect(text.hasPrefix("# User configuration\nproxies: []\nbase: &base"))
        #expect(text.contains("- <<: *base"))
        #expect(text.contains("# DNS comment\ndns: {enable: false} # retained"))
        let doc = try #require(try Yams.load(yaml: text) as? [String: Any])
        #expect(
            doc["rules"] as? [String] == [
                "DOMAIN,example.com,REJECT", "DOMAIN-SUFFIX,example.com,DIRECT", "MATCH,DIRECT",
            ]
        )
        #expect(try Data(contentsOf: fixture.config) == edit.originalData)
        #expect(try fixture.service.policies(in: edit.originalConfig).contains("HK #1"))
    }

    @Test(arguments: [
        "proxies: []\nrules: ['MATCH,DIRECT']\n",
        "proxies: []\nrules: []\n...\n",
        "proxies: []\n...\n",
        "{proxies: [], rules: ['MATCH,DIRECT']}",
        "proxies: []\r\nrules:\r\n  - MATCH,DIRECT\r\n",
        "proxies: []\nrules: &r ['MATCH,DIRECT']\ncopy: *r\n",
        "proxies: []\nshared: &r ['MATCH,DIRECT']\nrules: *r\n",
        "base: &b {rules: ['MATCH,DIRECT']}\n<<: *b\nproxies: []\n",
    ])
    func yamlFormsRemainValid(yaml: String) throws {
        let fixture = try QuickRuleFixture(yaml: yaml)
        defer { fixture.clean() }
        let edit = try fixture.edit()
        let doc = try #require(try Yams.load(yaml: String(decoding: edit.updatedData, as: UTF8.self)) as? [String: Any])
        #expect((doc["rules"] as? [String])?.first == "DOMAIN,example.com,REJECT")
    }

    @Test func rejectsNonListAndDuplicateKeys() throws {
        for yaml in ["rules: nope", "rules: []\nrules: []", "[rules]"] {
            let fixture = try QuickRuleFixture(yaml: yaml)
            defer { fixture.clean() }
            #expect(throws: (any Error).self) { try fixture.edit() }
        }
    }

    @Test func savesPortableFileWithBackupAndCleansStages() async throws {
        let fixture = try QuickRuleFixture(yaml: "proxies: []\nrules: ['MATCH,DIRECT']\n")
        defer { fixture.clean() }
        let edit = try fixture.edit()
        var applied = false
        let backup = try await fixture.service.commit(
            edit,
            validate: { path in
                let original = try Data(contentsOf: fixture.config)
                let staged = try Data(contentsOf: URL(fileURLWithPath: path))
                #expect(original == edit.originalData)
                #expect(staged == edit.updatedData)
            },
            didWrite: {},
            apply: { applied = true },
            restoreRuntime: {}
        )
        #expect(applied)
        #expect(try Data(contentsOf: fixture.config) == edit.updatedData)
        #expect(try Data(contentsOf: #require(backup)) == edit.originalData)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: fixture.config.deletingLastPathComponent().path)
                .allSatisfy { !$0.hasPrefix(".clashbar-check-") }
        )
    }

    @Test func validationFailureDoesNotWrite() async throws {
        let fixture = try QuickRuleFixture()
        defer { fixture.clean() }
        let edit = try fixture.edit()
        await #expect(throws: Failure.self) {
            try await fixture.service.commit(
                edit,
                validate: { _ in throw Failure.rejected },
                didWrite: {},
                apply: { Issue.record("Must not apply") },
                restoreRuntime: {}
            )
        }
        #expect(try Data(contentsOf: fixture.config) == edit.originalData)
    }

    @Test func reloadFailureRestoresFileAndRuntime() async throws {
        let fixture = try QuickRuleFixture()
        defer { fixture.clean() }
        let edit = try fixture.edit()
        var restored = false
        await #expect(throws: Failure.self) {
            try await fixture.service.commit(
                edit,
                validate: { _ in },
                didWrite: {},
                apply: { throw Failure.rejected },
                restoreRuntime: {
                    let restoredData = try Data(contentsOf: fixture.config)
                    #expect(restoredData == edit.originalData)
                    restored = true
                }
            )
        }
        #expect(restored)
        #expect(try Data(contentsOf: fixture.config) == edit.originalData)
    }

    @Test func concurrentChangesAreNeverOverwritten() async throws {
        let fixture = try QuickRuleFixture()
        defer { fixture.clean() }
        let edit = try fixture.edit()
        let external = Data("proxies: []\nrules: []\n# external".utf8)
        await #expect(throws: QuickRuleError.self) {
            try await fixture.service.commit(
                edit,
                validate: { _ in
                    try external.write(to: fixture.config)
                },
                didWrite: {},
                apply: { Issue.record("Must not apply") },
                restoreRuntime: {}
            )
        }
        #expect(try Data(contentsOf: fixture.config) == external)
        let fresh = try fixture.edit()
        await #expect(throws: QuickRuleError.self) {
            try await fixture.service.commit(
                fresh,
                validate: { _ in },
                didWrite: {},
                apply: {
                    try external.write(to: fixture.config)
                    throw Failure.rejected
                },
                restoreRuntime: { Issue.record("Must not reload a concurrent change") }
            )
        }
        #expect(try Data(contentsOf: fixture.config) == external)
    }

    @Test func providersRetainBindingAndUseStagedValidation() async throws {
        let fixture = try QuickRuleFixture(
            yaml: """
                proxies: []
                rule-providers:
                  local: {type: file, behavior: classical, path: ./local.yaml}
                  remote: {type: http, behavior: domain, path: ./remote.yaml, url: 'https://example.com'}
                  outside: {type: file, behavior: domain, path: ../outside.yaml}
                  unused: {type: file, behavior: domain, path: ./unused.yaml}
                  binary: {type: file, behavior: domain, format: mrs, path: ./binary.mrs}
                rules:
                  - RULE-SET,local,DIRECT
                  - MATCH,REJECT
                """
        )
        defer { fixture.clean() }
        let provider = fixture.root.appendingPathComponent("local.yaml")
        try Data("# My local list\npayload: ['DOMAIN,other.com']\n".utf8).write(to: provider)
        #expect(try fixture.context().providers.map(\.name) == ["local"])
        let edit = try fixture.edit(provider: "local")
        #expect(edit.provider?.policies == ["DIRECT"])
        let payload = try #require(
            try Yams.load(yaml: String(decoding: edit.updatedData, as: UTF8.self)) as? [String: Any]
        )
        #expect(payload["payload"] as? [String] == ["DOMAIN,other.com", "DOMAIN,example.com"])
        _ = try await fixture.service.commit(
            edit,
            validate: { path in
                let doc = try #require(
                    try Yams.load(yaml: String(contentsOfFile: path, encoding: .utf8)) as? [String: Any]
                )
                let providers = try #require(doc["rule-providers"] as? [String: [String: Any]])
                let stagedPath = try #require(providers["local"]?["path"] as? String)
                #expect(stagedPath != provider.path)
                #expect(try Data(contentsOf: URL(fileURLWithPath: stagedPath)) == edit.updatedData)
                #expect(try Data(contentsOf: provider) == edit.originalData)
            },
            didWrite: {},
            apply: {},
            restoreRuntime: {}
        )
        #expect(try Data(contentsOf: fixture.config) == edit.originalConfig)
        #expect(try Data(contentsOf: provider) == edit.updatedData)
        #expect(try fixture.edit(provider: "local").hasChanges == false)
    }

    @Test func providerBehaviorAndTextFormat() throws {
        let fixture = try QuickRuleFixture(
            yaml: """
                proxies: []
                rule-providers:
                  domain: {type: file, behavior: domain, format: text, path: ./domains.txt}
                  ip: {type: file, behavior: ipcidr, path: ./ips.yaml}
                rules: ['RULE-SET,domain,DIRECT', 'RULE-SET,ip,REJECT', 'MATCH,DIRECT']
                """
        )
        defer { fixture.clean() }
        try Data("# Domains\r\nother.com".utf8).write(to: fixture.root.appendingPathComponent("domains.txt"))
        try Data("payload: []".utf8).write(to: fixture.root.appendingPathComponent("ips.yaml"))
        let context = try fixture.context()
        let rule = try QuickRoutingRule(type: .domainSuffix, target: "example.com", policy: "DIRECT")
        let edit = try fixture.service.prepare(rule: rule, context: context, providerName: "domain")
        #expect(String(decoding: edit.updatedData, as: UTF8.self) == "# Domains\r\nother.com\r\n+.example.com\r\n")
        #expect(throws: QuickRuleError.self) {
            try fixture.service.prepare(rule: rule, context: context, providerName: "ip")
        }
        let ip = try QuickRoutingRule(type: .ipv6, target: "::1", policy: "REJECT")
        let ipEdit = try fixture.service.prepare(rule: ip, context: context, providerName: "ip")
        #expect(String(decoding: ipEdit.updatedData, as: UTF8.self).contains("::1/128"))
    }

    @Test func reloadPreservesRuntimeSettingsWithoutPersistingThem() throws {
        let fixture = try QuickRuleFixture(
            yaml: "proxies: []\nmode: rule\ntun: {enable: false, stack: mixed}\nrules: []\n"
        )
        defer { fixture.clean() }
        let data = try Data(contentsOf: fixture.config)
        let settings = EditableSettingsSnapshot(
            mode: .global,
            allowLan: true,
            ipv6: true,
            tcpConcurrent: true,
            tunEnabled: true,
            logLevel: "debug",
            port: "0",
            socksPort: "0",
            mixedPort: "8888",
            redirPort: "0",
            tproxyPort: "0"
        )
        let payload = try fixture.service.reloadPayload(data, settings: settings)
        let doc = try #require(try Yams.load(yaml: payload) as? [String: Any])
        #expect(doc["mode"] as? String == "global")
        #expect(doc["mixed-port"] as? Int == 8888)
        #expect((doc["tun"] as? [String: Any])?["stack"] as? String == "mixed")
        #expect((doc["tun"] as? [String: Any])?["enable"] as? Bool == true)
        #expect(try Data(contentsOf: fixture.config) == data)
    }
}
