import SwiftUI

// swiftlint:disable:next type_name
private typealias T = MenuBarLayoutTokens

struct RulesTabView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    @EnvironmentObject var proxyStore: ProxyStore
    @StateObject private var viewModel = RulesViewModel()
    @AppStorage("clashbar.rules.group_by_policy.v1") private var storedGroupByPolicy = false
    @State private var hoveredRuleKey: String?
    @State private var hoveredGroupPolicy: String?
    @State private var expandedPolicies: Set<String> = []

    private var runtimeNavigation: Bool {
        !self.appViewModel.isRemoteTarget && self.appViewModel.ruleNavigationIDs.contains { $0.hasPrefix("runtime:") }
    }

    private var sourceItems: [RuleItem] {
        let ids = self.appViewModel.ruleNavigationIDs
        if !ids.isEmpty, self.proxyStore.ruleItems.contains(where: { ids.contains($0.id) }) {
            return self.proxyStore.ruleItems
        }
        return self.appViewModel.displayedRuleItems
    }

    var body: some View {
        let output = self.viewModel.output
        let visibleRules = output.rules
        let providerLookup = output.providerLookup

        return LazyVStack(alignment: .leading, spacing: T.space8, pinnedViews: [.sectionHeaders]) {
            self.rulesSummary
            Section {
                Group {
                    if visibleRules.isEmpty {
                        self.rulesEmptyState
                    } else if self.viewModel.groupByPolicy {
                        self.groupedRulesList(groups: output.groups, providerLookup: providerLookup)
                    } else {
                        self.flatRulesList(visibleRules: visibleRules, providerLookup: providerLookup)
                    }
                }
                .appSectionCard(padding: T.space4)
            } header: {
                self.rulesToolbar
            }
        }
        .onAppear {
            self.viewModel.groupByPolicy = self.storedGroupByPolicy
            if !self.appViewModel.ruleNavigationIDs.isEmpty { self.resetNavigationFilters() }
            self.appViewModel.refreshNativeRuleDocument()
            self.refreshData()
        }
        .onChange(of: self.appViewModel.nativeRuleDocument) { _ in self.refreshData() }
        .onChange(of: self.appViewModel.selectedConfigName) { _ in self.appViewModel.refreshNativeRuleDocument(); self.refreshData() }
        .onChange(of: self.viewModel.customOnly) { _ in self.refreshData() }
        .onChange(of: self.proxyStore.ruleItems) { _ in self.refreshData() }
        .onChange(of: self.proxyStore.ruleProviders) { _ in self.refreshData() }
        .onChange(of: self.viewModel.filterText) { _ in self.refreshData() }
        .onChange(of: self.viewModel.typeFilter) { _ in self.refreshData() }
        .onChange(of: self.viewModel.policyFilter) { _ in self.refreshData() }
        .onChange(of: self.viewModel.groupByPolicy) { _ in self.refreshData() }
        .onChange(of: self.viewModel.sortByHits) { _ in self.refreshData() }
        .onChange(of: self.appViewModel.ruleNavigationIDs) { _ in
            if !self.appViewModel.ruleNavigationIDs.isEmpty { self.resetNavigationFilters() }
            self.refreshData()
        }
    }

    private var rulesSummary: some View {
        self.tabControlCard {
            HStack(spacing: T.space4) {
                self.rulesStatChip(title: self.tr("ui.rule.stats.rules"), value: "\(self.sourceItems.count)")
                self.rulesStatChip(title: self.tr("ui.rule.stats.sets"),
                                   value: "\(self.appViewModel.isRemoteTarget || self.runtimeNavigation ? self.proxyStore.providerRuleCount : self.appViewModel.nativeRuleDocument?.providerNames.count ?? 0)")
                Spacer(minLength: 0)
                self.compactTopIcon("app.badge", label: self.tr("ui.app_rule.title")) {
                    await self.appViewModel.openApplicationRuleEditor()
                }.disabled(!self.appViewModel.canEditApplicationRules)
                self.compactTopIcon("plus", label: self.tr("ui.quick_rule.add")) {
                    self.appViewModel.openQuickRuleEditor()
                }.disabled(!self.appViewModel.canEditQuickRules)
                self.rulesGroupToggle
                self.compactTopIcon("arrow.down", label: self.tr("ui.diagnostics.sort_hits"),
                                    toneOverride: self.viewModel.sortByHits ? nativeInfo : nil) {
                    self.viewModel.sortByHits.toggle()
                }
                self.rulesRefreshButton
            }
            if self.runtimeNavigation {
                SheetNote(text: self.tr("ui.diagnostics.runtime_only_rules"))
            } else if !self.appViewModel.isRemoteTarget {
                HStack(spacing: T.space6) {
                    Text(self.appViewModel.selectedConfigName).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    SemanticTag(text: self.tr(self.appViewModel.nativeRulesMatchRuntime ? "ui.native_rule.active" : "ui.native_rule.file_only"),
                                tint: self.appViewModel.nativeRulesMatchRuntime ? self.nativeTeal : self.nativeSecondaryLabel, monospaced: false)
                }
                .font(.app(size: T.FontSize.caption)).foregroundStyle(.secondary)
                if let message = self.appViewModel.nativeRuleDocumentError ?? self.appViewModel.nativeRuleSaveNotice {
                    SheetNote(text: message)
                }
            }
            if !self.appViewModel.ruleNavigationIDs.isEmpty {
                HStack {
                    Text(self.tr("ui.diagnostics.navigation_candidates", self.viewModel.output.rules.count))
                    Spacer(minLength: 0)
                    Button(self.tr("ui.diagnostics.clear_navigation")) { self.appViewModel.ruleNavigationIDs = [] }
                }
                .font(.app(size: T.FontSize.caption))
            }
        }
    }

    private var rulesToolbar: some View {
        VStack(spacing: T.space8) {
            self.tabControlCard {
                self.rulesFilterControls
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: 24)
                Text(self.tr("ui.rules.column.target_type")).frame(width: 132, alignment: .leading).padding(.trailing, T.space6)
                Text(self.tr("ui.rules.column.policy")).frame(width: 90, alignment: .leading)
                Text(self.tr("ui.diagnostics.hits_column")).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.app(size: T.FontSize.caption, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, T.space8)
            .padding(.bottom, T.space4)
        }
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: T.cardCornerRadius))
    }

    private var hairline: some View {
        Rectangle()
            .fill(nativeSeparator.opacity(0.45))
            .frame(height: T.stroke)
    }

    private func refreshData() {
        if self.appViewModel.isRemoteTarget { self.viewModel.customOnly = false }
        self.viewModel.updateVisibleRules(
            items: self.sourceItems.filter { self.appViewModel.ruleNavigationIDs.isEmpty || self.appViewModel.ruleNavigationIDs.contains($0.id) },
            providers: self.proxyStore.ruleProviders)
    }

    private func resetNavigationFilters() {
        self.viewModel.filterText = ""
        self.viewModel.typeFilter = .all
        self.viewModel.policyFilter = .all
        self.viewModel.customOnly = false
        self.viewModel.groupByPolicy = false
    }

    private var rulesFilterControls: some View {
        VStack(alignment: .leading, spacing: T.space8) {
            HStack(spacing: T.space4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: T.space4) {
                        ForEach(RulesTypeFilter.allCases) { filter in
                            self.ruleTypeChip(filter)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                self.fractionSummaryBadge(
                    current: self.viewModel.output.rules.count,
                    total: self.sourceItems.count)
            }

            HStack(spacing: T.space6) {
                self.filterTextField(self.tr("ui.placeholder.filter_rule"), text: self.$viewModel.filterText)
                self.rulesPolicyMenu
                if !self.appViewModel.isRemoteTarget && !self.runtimeNavigation {
                    Picker(self.tr("ui.native_rule.source"), selection: self.$viewModel.customOnly) {
                        Text(self.tr("ui.native_rule.all")).tag(false)
                        Text(self.tr("ui.native_rule.custom_short")).tag(true)
                    }.labelsHidden().controlSize(.small).frame(width: 84)
                }
            }
        }
    }

    func ruleTypeChip(_ filter: RulesTypeFilter) -> some View {
        self.filterChip(
            title: self.tr(filter.titleKey),
            count: self.viewModel.output.typeCounts[filter] ?? 0,
            selected: self.viewModel.typeFilter == filter)
        {
            self.viewModel.typeFilter = filter
        }
    }

    var rulesPolicyMenu: some View {
        self.compactSelectionMenu(.init(
            selection: self.viewModel.policyFilter,
            options: self.viewModel.output.policyOptions,
            symbol: "arrow.triangle.branch",
            helpText: self.tr("ui.rules.filter.policy"),
            optionTitle: { $0.isAll ? self.tr("ui.rules.policy.all") : $0.name },
            onSelect: { self.viewModel.policyFilter = $0 }))
    }

    var rulesGroupToggle: some View {
        let grouped = self.viewModel.groupByPolicy
        return self.compactTopIcon(
            grouped ? "rectangle.3.group.fill" : "list.bullet",
            label: self.tr("ui.rules.group.toggle"),
            toneOverride: grouped ? nativeInfo : nil)
        {
            self.viewModel.groupByPolicy.toggle()
            self.storedGroupByPolicy = self.viewModel.groupByPolicy
        }
        .help(self.tr("ui.rules.group.toggle"))
    }

    var rulesEmptyState: some View {
        let key = self.appViewModel.displayedRuleItems.isEmpty ? "ui.empty.rules" : "ui.empty.rules.no_match"
        return Text(self.tr(key))
            .font(.app(size: T.FontSize.body, weight: .regular))
            .foregroundStyle(nativeSecondaryLabel)
            .padding(.horizontal, T.space4)
            .padding(.vertical, T.space8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
    }

    func flatRulesList(visibleRules: [RuleItem], providerLookup: [String: ProviderDetail]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(visibleRules.enumerated()), id: \.element.id) { index, rule in
                self.rulesRow(rule: rule, rowKey: rule.id, providerLookup: providerLookup)

                if index < visibleRules.count - 1 {
                    self.hairline
                }
            }
        }
    }

    func groupedRulesList(groups: [RuleGroup], providerLookup: [String: ProviderDetail]) -> some View {
        VStack(spacing: 0) {
            ForEach(groups) { group in
                self.policyGroupHeader(group)

                self.hairline

                if self.expandedPolicies.contains(group.policy) {
                    ForEach(group.rules) { rule in
                        self.rulesRow(
                            rule: rule,
                            rowKey: rule.id,
                            providerLookup: providerLookup,
                            showsPolicy: false)

                        self.hairline
                    }
                }
            }
        }
    }

    func policyGroupHeader(_ group: RuleGroup) -> some View {
        let expanded = self.expandedPolicies.contains(group.policy)
        let hovered = self.hoveredGroupPolicy == group.policy
        let name = group.policy.trimmedNonEmpty ?? self.tr("ui.common.na")

        return Button {
            self.toggleGroup(group.policy)
        } label: {
            HStack(spacing: 0) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.app(size: T.FontSize.caption, weight: .bold))
                    .foregroundStyle(hovered ? nativePrimaryLabel : nativeSecondaryLabel)
                    .frame(width: 24, alignment: .leading)

                Text(name)
                    .font(.app(size: T.FontSize.body, weight: .semibold))
                    .foregroundStyle(nativePrimaryLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: T.space4)

                Text("\(group.rules.count)")
                    .font(.app(size: T.FontSize.caption, weight: .bold))
                    .foregroundStyle(nativeSecondaryLabel)
                    .padding(.horizontal, T.space6)
                    .padding(.vertical, T.space1)
                    .background(nativeBadgeCapsule())
            }
            .padding(.horizontal, T.space4)
            .frame(height: T.rowHeight)
            .background(nativeHoverRowBackground(hovered))
        }
        .buttonStyle(.plain)
        .onHover { self.hoveredGroupPolicy = self.nextHovered(
            current: self.hoveredGroupPolicy, target: group.policy, isHovering: $0) }
    }

    private func toggleGroup(_ policy: String) {
        if !self.expandedPolicies.insert(policy).inserted {
            self.expandedPolicies.remove(policy)
        }
    }

    func rulesStatChip(title: String, value: String) -> some View {
        HStack(spacing: T.space4) {
            Text(title.uppercased())
                .font(.app(size: T.FontSize.caption, weight: .semibold))
                .foregroundStyle(nativeTertiaryLabel)
            Text(value)
                .font(.app(size: T.FontSize.body, weight: .bold))
                .foregroundStyle(nativePrimaryLabel)
        }
        .padding(.horizontal, T.space6)
        .padding(.vertical, T.space2)
    }

    var rulesRefreshButton: some View {
        self.compactTopIcon(
            "arrow.clockwise",
            label: self.tr("ui.action.refresh"),
            toneOverride: nativeInfo,
            isLoading: self.proxyStore.isRuleProvidersRefreshing)
        {
            self.appViewModel.refreshNativeRuleDocument()
            if self.appViewModel.isRuntimeRunning { await self.appViewModel.refreshProvidersAndRules() }
        }
        .help(self.tr("ui.action.refresh"))
        .opacity(self.proxyStore.isRuleProvidersRefreshing ? 0.6 : 1)
        .contextMenu {
            Button(self.tr("ui.diagnostics.update_rule_providers")) {
                Task { await self.appViewModel.refreshRuleProviders() }
            }.disabled(!self.appViewModel.isRuntimeRunning)
        }
    }

    func rulesRow(
        rule: RuleItem,
        rowKey: String,
        providerLookup: [String: ProviderDetail],
        showsPolicy: Bool = true) -> some View
    {
        let displaysPolicy = showsPolicy || rule.nativeEntry != nil
        let hovered = self.hoveredRuleKey == rowKey
        let typeText = (rule.type.trimmedNonEmpty ?? self.tr("ui.common.na")).uppercased()
        let targetText = rule.payload.trimmedNonEmpty ?? self.tr("ui.common.na")
        let policyText = rule.proxy.trimmedNonEmpty ?? self.tr("ui.common.na")
        let iconSpec = self.ruleTypeIcon(for: typeText)
        let badge = self.rulePolicyBadge(for: policyText)
        let stats = self.ruleStats(payload: targetText, providerLookup: providerLookup)

        return HStack(spacing: 0) {
            Image(systemName: iconSpec.symbol)
                .font(.app(size: T.FontSize.body, weight: .medium))
                .foregroundStyle(iconSpec.color)
                .frame(width: 24, alignment: .leading)

            VStack(alignment: .leading, spacing: T.space1) {
                Text(targetText)
                    .font(.appMono(size: T.FontSize.callout, weight: .medium))
                    .foregroundStyle(nativePrimaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: T.space4) {
                    if let entry = rule.nativeEntry {
                        Text("#\(entry.index + 1)").font(.appMono(size: T.FontSize.micro)).foregroundStyle(.secondary)
                        if entry.isCustom {
                            Image(systemName: "star.fill").font(.app(size: T.FontSize.micro)).foregroundStyle(self.nativeTeal)
                                .help(self.tr("ui.native_rule.custom_short"))
                        }
                    }
                    SemanticTag(text: typeText, tint: iconSpec.color)
                }
            }
            .frame(width: displaysPolicy ? 132 : 132 + 90 + T.space6, alignment: .leading)
            .padding(.trailing, T.space6)

            if displaysPolicy {
                if let entry = rule.nativeEntry, entry.syntax != nil {
                    NativeRulePolicyButton(entry: entry).environmentObject(self.appViewModel)
                        .frame(width: 90, alignment: .leading)
                } else {
                    Text(policyText).font(.app(size: T.FontSize.caption, weight: .medium))
                        .foregroundStyle(badge.color).lineLimit(1).frame(width: 90, alignment: .leading)
                }
            }

            VStack(alignment: .trailing, spacing: T.space1) {
                Text(rule.statistics?.hitCount.map { "\($0)" } ?? "—")
                    .font(.app(size: T.FontSize.body, weight: .regular))
                    .foregroundStyle(rule.statistics != nil ? nativeSecondaryLabel : nativeTertiaryLabel)
                if let date = rule.statistics?.hitAt {
                    LatencyAgeView(sample: ProxyLatencySample(delay: 1, time: date), language: self.language, showsStaleness: false)
                } else if stats.hasProvider {
                    Text(self.tr("ui.diagnostics.provider_entries", stats.count)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(self.ruleStatisticsHelp(rule, providerCount: stats.hasProvider ? stats.count : nil))
            if let entry = rule.nativeEntry {
                Button { self.appViewModel.openNativeRuleEditor(entry) } label: {
                    Image(systemName: "pencil").font(.system(size: 11)).frame(width: 22, height: 24)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(self.tr("ui.native_rule.edit")).disabled(!self.appViewModel.canEditQuickRules)
            }
        }
        .padding(.horizontal, T.space4)
        .frame(height: T.rowHeight)
        .background(nativeHoverRowBackground(hovered))
        .help(rule.nativeEntry?.raw ?? "\(typeText),\(targetText),\(policyText)")
        .onHover { self.hoveredRuleKey = self.nextHovered(
            current: self.hoveredRuleKey, target: rowKey, isHovering: $0) }
        .contextMenu {
            if let statistics = rule.statistics {
                Text(self.tr("ui.diagnostics.hit_count", statistics.hitCount.map { "\($0)" } ?? "—"))
                Text(self.tr("ui.diagnostics.last_hit", statistics.hitAt.map(ValueFormatter.dateTime) ?? "—"))
            }
            if let entry = rule.nativeEntry {
                Button(self.tr("ui.native_rule.edit")) { self.appViewModel.openNativeRuleEditor(entry) }.disabled(!self.appViewModel.canEditQuickRules)
            }
            QuickRuleContextMenu(targets: QuickRuleTarget.from(rule: rule).map { [$0] } ?? [])
        }
    }

    private func ruleStatisticsHelp(_ rule: RuleItem, providerCount: Int?) -> String {
        var lines: [String] = []
        if let statistics = rule.statistics {
            lines.append(self.tr("ui.diagnostics.hit_count", statistics.hitCount.map { "\($0)" } ?? "—"))
            lines.append(self.tr("ui.diagnostics.last_hit", statistics.hitAt.map(ValueFormatter.dateTime) ?? "—"))
            lines.append(self.tr("ui.diagnostics.miss_count", statistics.missCount.map { "\($0)" } ?? "—"))
            lines.append(self.tr("ui.diagnostics.last_miss", statistics.missAt.map(ValueFormatter.dateTime) ?? "—"))
            if statistics.disabled == true { lines.append(self.tr("ui.diagnostics.rule_disabled")) }
        } else { lines.append(self.tr("ui.diagnostics.stats_unavailable")) }
        if let providerCount { lines.append(self.tr("ui.diagnostics.provider_entries", providerCount)) }
        lines.append(self.tr("ui.diagnostics.stats_note"))
        return lines.joined(separator: "\n")
    }

    func ruleTypeIcon(for type: String) -> (symbol: String, color: Color) {
        let lower = type.lowercased().replacingOccurrences(of: "-", with: "")
        if lower.contains("ipcidr") {
            return ("globe.americas.fill", nativeInfo.opacity(T.Opacity.solid))
        }
        if lower.contains("domain") || lower.contains("suffix") || lower.contains("keyword") {
            return ("network", nativeTeal.opacity(T.Opacity.solid))
        }
        if lower.contains("ruleset") {
            return ("list.bullet.rectangle.fill", nativeWarning.opacity(T.Opacity.solid))
        }
        return ("circle.grid.2x2.fill", nativeIndigo.opacity(T.Opacity.solid))
    }

    func rulePolicyBadge(for policy: String) -> (symbol: String?, color: Color) {
        let lower = policy.lowercased()
        if lower.contains("fishy") {
            return (
                symbol: "exclamationmark.triangle.fill",
                color: nativeAccent.opacity(T.Opacity.solid))
        }
        return (
            symbol: nil,
            color: nativeSecondaryLabel)
    }

    func ruleStats(
        payload: String,
        providerLookup: [String: ProviderDetail]) -> (count: Int, updatedText: String?, hasProvider: Bool)
    {
        let payloadTrimmed = payload.trimmed
        guard !payloadTrimmed.isEmpty, payloadTrimmed != self.tr("ui.common.na") else {
            return (count: 0, updatedText: nil, hasProvider: false)
        }

        if let provider = providerLookup[payloadTrimmed.lowercased()] {
            let count = max(0, provider.ruleCount ?? 0)
            return (
                count: count,
                updatedText: ValueFormatter.relativeTime(from: provider.updatedAt, language: self.language),
                hasProvider: true)
        }
        return (count: 0, updatedText: nil, hasProvider: false)
    }
}
