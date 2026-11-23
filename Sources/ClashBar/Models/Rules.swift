import Foundation

struct RulesSummary: Decodable, Equatable {
    static let retainedRuleLimit = 20000

    let rules: [RuleItem]
    let totalCount: Int

    private enum CodingKeys: String, CodingKey {
        case rules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard var rulesContainer = try? container.nestedUnkeyedContainer(forKey: .rules) else {
            self.rules = []
            self.totalCount = 0
            return
        }

        var retained: [RuleItem] = []
        retained.reserveCapacity(min(Self.retainedRuleLimit, rulesContainer.count ?? Self.retainedRuleLimit))

        var totalCount = 0
        while !rulesContainer.isAtEnd {
            let rule = try rulesContainer.decode(RuleItem.self)
            if retained.count < Self.retainedRuleLimit {
                retained.append(rule.index != nil ? rule : RuleItem(type: rule.type, payload: rule.payload, proxy: rule.proxy, index: totalCount, statistics: rule.statistics))
            }
            totalCount += 1
        }

        self.rules = retained
        self.totalCount = totalCount
    }
}

struct RuleItem: Decodable, Hashable, Identifiable {
    let type: String?
    let payload: String?
    let proxy: String?
    let index: Int?
    let nativeEntry: NativeRuleEntry?
    let statistics: RuleStatistics?
    var id: String { nativeEntry.map { "native:\($0.id)" } ?? "runtime:\(index ?? -1):\(type ?? ""):\(payload ?? ""):\(proxy ?? "")" }

    init(type: String?, payload: String?, proxy: String?, index: Int? = nil, nativeEntry: NativeRuleEntry? = nil, statistics: RuleStatistics? = nil) {
        self.type = type; self.payload = payload; self.proxy = proxy
        self.index = index; self.nativeEntry = nativeEntry
        self.statistics = statistics
    }

    private enum CodingKeys: String, CodingKey { case type, payload, proxy, index, extra }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try values.decodeIfPresent(String.self, forKey: .type)
        self.payload = try values.decodeIfPresent(String.self, forKey: .payload)
        self.proxy = try values.decodeIfPresent(String.self, forKey: .proxy)
        self.index = try values.decodeIfPresent(Int.self, forKey: .index)
        self.nativeEntry = nil
        self.statistics = try values.decodeIfPresent(RuleStatistics.self, forKey: .extra)
    }
}

struct RuleStatistics: Decodable, Hashable {
    let hitCount: UInt64?
    let hitAt: Date?
    let missCount: UInt64?
    let missAt: Date?
    let disabled: Bool?

    private enum CodingKeys: String, CodingKey { case hitCount, hitAt, missCount, missAt, disabled }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) -> UInt64? {
            if let value = try? values.decodeIfPresent(UInt64.self, forKey: key) { return value }
            return values.decodeFlexibleString(forKey: key).flatMap(UInt64.init)
        }
        func date(_ key: CodingKeys, count: UInt64?) -> Date? {
            guard let count, count > 0,
                  let raw = values.decodeFlexibleString(forKey: key),
                  let date = ValueFormatter.parseISO8601Date(raw), date.timeIntervalSince1970 > 0 else { return nil }
            return date
        }
        self.hitCount = count(.hitCount)
        self.missCount = count(.missCount)
        self.hitAt = date(.hitAt, count: self.hitCount)
        self.missAt = date(.missAt, count: self.missCount)
        self.disabled = values.decodeFlexibleBool(forKey: .disabled)
    }
}
