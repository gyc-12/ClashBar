import Foundation

@MainActor
extension AppViewModel {
    func healthcheckSettings(for group: ProxyGroup) -> ProxyHealthcheckSettings {
        var native: ProxyHealthcheckSettings?
        if !self.isRemoteTarget, !self.pendingConfigChangeRestart, self.nativeRulesMatchRuntime,
           let document = self.nativeRuleDocument {
            native = ProxyHealthcheckSettings.read(data: document.originalData)[group.name]
        }
        return ProxyHealthcheckSettings(
            url: group.testUrl ?? native?.url,
            interval: group.interval ?? native?.interval,
            lazy: group.lazy ?? native?.lazy)
    }

    func connectionRuleCandidates(_ connection: ConnectionSummary) -> [RuleItem] {
        // An unapplied local file must never be presented as the source of a
        // live connection. Runtime-only candidates remain useful for diagnosis.
        let source = self.isRemoteTarget || !self.nativeRulesMatchRuntime ? self.ruleItems : self.displayedRuleItems
        return ConnectionRuleMatcher.candidates(for: connection, in: source)
    }

    func navigateToConnectionRules(_ connection: ConnectionSummary) {
        let candidates = self.connectionRuleCandidates(connection)
        self.ruleNavigationIDs = Set(candidates.map(\.id))
        self.pendingConnectionRuleNavigation = true
        self.connectionDetailContext = nil
        self.setActiveMenuTab(.rules)
    }

    func completeConnectionRuleNavigation() {
        guard self.pendingConnectionRuleNavigation else { return }
        self.pendingConnectionRuleNavigation = false
        self.refreshNativeRuleDocument()
        guard self.activeMenuTab == .rules, self.ruleNavigationIDs.count == 1,
              self.nativeRulesMatchRuntime,
              let rule = self.displayedRuleItems.first(where: { self.ruleNavigationIDs.contains($0.id) }),
              let entry = rule.nativeEntry else { return }
        self.openNativeRuleEditor(entry)
    }
}
