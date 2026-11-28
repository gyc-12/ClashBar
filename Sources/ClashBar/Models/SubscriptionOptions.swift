import Foundation

struct SubscriptionOptions: Equatable {
    static let defaultInterval = 3600
    static let defaultHealthURL = "https://cp.cloudflare.com"
    static let defaultHealthInterval = 300
    static let defaultAgents = ["clash-verge/v2.2.3", "ClashMetaForAndroid/2.11.2.Meta", "ClashforWindows/0.19.23", "clash.meta", "mihomo"]
    var healthEnabled = true
    var healthInterval = Self.defaultHealthInterval
    var downloadProxy = "DIRECT"
    var userAgents = Self.defaultAgents
    var prefix = ""

    static func fallbackRetryGroup(in document: NativeProxyProviderDocument) -> String? {
        let matches = document.groups.map(\.name).filter { $0.caseInsensitiveCompare("proxy") == .orderedSame }
        if let route = matches.first(where: { $0 == "proxy" }) ?? (matches.count == 1 ? matches.first : nil) {
            return route
        }
        let keywords = ["proxies", "节点选择", "手动切换", "选择节点", "全球代理", "选择出口"]
        return document.groups.first(where: { group in
            keywords.contains { group.name.localizedCaseInsensitiveContains($0) }
        })?.name
    }
}

extension NativeProxyProviderAction {
    func retryRoute(in document: NativeProxyProviderDocument) -> (Self, String)? {
        guard case let .add(name, url, interval, healthURL, groups, options) = self,
              options.downloadProxy == "DIRECT",
              let route = SubscriptionOptions.fallbackRetryGroup(in: document) else { return nil }
        var updated = options
        updated.downloadProxy = route
        return (.add(name: name, url: url, interval: interval, healthCheckURL: healthURL, groups: groups, options: updated), route)
    }
}
