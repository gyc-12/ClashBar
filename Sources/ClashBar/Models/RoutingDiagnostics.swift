import Foundation
import Yams

struct ProxyLatencySample: Decodable, Equatable, Hashable {
    let delay: Int
    let time: Date?
    let testURL: String?

    init(delay: Int, time: Date? = nil, testURL: String? = nil) {
        self.delay = delay
        self.time = time
        self.testURL = testURL
    }

    private enum CodingKeys: String, CodingKey { case delay, time }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.delay = values.decodeFlexibleInt(forKey: .delay) ?? -1
        self.time = values.decodeFlexibleString(forKey: .time).flatMap(ValueFormatter.parseISO8601Date)
        self.testURL = nil
    }

    static func merge(api: [Self], previous: [Self]) -> [Self] {
        let validAPI = api.filter { $0.delay >= 0 }
        guard !validAPI.isEmpty else { return Array(previous.suffix(ProxyDelayHistory.limit)) }
        // If the newest API reading has no timestamp, its age is unknown. Do
        // not borrow the timestamp of an older local measurement for that value.
        if validAPI.last?.time == nil { return Array(validAPI.suffix(ProxyDelayHistory.limit)) }
        let dated = (previous + api).filter { $0.time != nil && $0.delay >= 0 }
        // A request may finish just before the next poll. Preserve its URL when
        // the core later returns the same measurement without that information.
        var unique: [Date: Self] = [:]
        for sample in dated {
            guard let time = sample.time else { continue }
            if let old = unique[time], old.testURL != nil, sample.testURL == nil { continue }
            unique[time] = sample
        }
        return Array(unique.values.sorted { $0.time! < $1.time! }.suffix(ProxyDelayHistory.limit))
    }

    func isStale(now: Date, interval: Int?) -> Bool {
        guard let time else { return false }
        return now.timeIntervalSince(time) > max(60, Double(interval ?? 300) * 2)
    }
}

struct ProxyHealthcheckSettings: Equatable {
    let url: String?
    let interval: Int?
    let lazy: Bool?

    static func read(data: Data) -> [String: Self] {
        guard let text = String(data: data, encoding: .utf8),
              let root = try? Yams.load(yaml: text) as? [String: Any],
              let groups = root["proxy-groups"] as? [[String: Any]] else { return [:] }
        var result: [String: Self] = [:]
        for group in groups {
            guard let name = group["name"] as? String else { continue }
            let type = (group["type"] as? String)?.lowercased()
            let automatic = ["url-test", "fallback", "load-balance"].contains(type ?? "")
            let configured = (group["interval"] as? Int) ?? (group["interval"] as? String).flatMap(Int.init)
            result[name] = Self(
                url: (group["url"] as? String).trimmedNonEmpty,
                interval: configured.positiveOrNil,
                lazy: (group["lazy"] as? Bool) ?? (automatic ? true : nil))
        }
        return result
    }
}

enum ConnectionRuleMatcher {
    static func candidates(for connection: ConnectionSummary, in rules: [RuleItem]) -> [RuleItem] {
        guard let type = connection.rule.trimmedNonEmpty else { return [] }
        let normalized = NativeRuleSyntax.normalizedType(type)
        let payload = connection.rulePayload ?? ""
        return rules.filter { rule in
            guard NativeRuleSyntax.normalizedType(rule.type ?? "") == normalized else { return false }
            if let syntax = rule.nativeEntry?.syntax { return syntax.matchesRuntimePayload(payload) }
            if ["DOMAIN", "DOMAINSUFFIX", "DOMAINKEYWORD"].contains(normalized) {
                return rule.payload.trimmedOrEmpty.lowercased() == payload.lowercased()
            }
            return rule.payload.trimmedOrEmpty == payload
        }
    }
}
