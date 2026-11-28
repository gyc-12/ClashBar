import SwiftUI

// swiftlint:disable:next type_name
private typealias T = MenuBarLayoutTokens

extension ProxyTabView {
    var proxyProvidersSection: some View {
        let document = appViewModel.nativeProxyProviderDocument
        let entries = Dictionary(uniqueKeysWithValues: (document?.entries ?? []).map { ($0.name, $0) })
        let usingNative = appViewModel.canManageProxyProviders && document != nil
        let providers = usingNative ? (document?.entries.map(\.name) ?? []) : proxyStore.sortedProxyProviderNames
        let usingRuntime = !usingNative || appViewModel.nativeProvidersMatchRunningConfig

        return VStack(alignment: .leading, spacing: T.space6) {
            self.nodesSectionHeader(
                tr("ui.section.proxy_providers"),
                symbol: "externaldrive.fill",
                count: "\(providers.count)")
            {
                if appViewModel.canManageProxyProviders {
                    Button {
                        appViewModel.openProxyProviderEditor(.add)
                    } label: {
                        Image(systemName: "plus")
                            .font(.app(size: T.FontSize.body, weight: .semibold))
                            .frame(width: T.rowLeadingIcon, height: T.rowLeadingIcon)
                    }
                    .buttonStyle(.plain)
                    .disabled(!appViewModel.canStartProxyProviderEdit)
                    .help(tr("ui.proxy_provider.add"))
                    .accessibilityLabel(tr("ui.proxy_provider.add"))
                }
                let label = tr(isProxyProvidersCollapsed ? "ui.action.expand" : "ui.action.collapse")
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isProxyProvidersCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: isProxyProvidersCollapsed ? "chevron.right" : "chevron.down")
                        .font(.app(size: T.FontSize.caption, weight: .semibold))
                        .foregroundStyle(nativeSecondaryLabel)
                        .frame(width: T.rowLeadingIcon, height: T.rowLeadingIcon)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .help(label)
            }

            if let message = appViewModel.nativeProxyProviderError ?? appViewModel.nativeProxyProviderNotice {
                SheetNote(text: message).padding(.horizontal, T.space4)
            }
            if providers.isEmpty && !isProxyProvidersCollapsed {
                SheetNote(text: tr("ui.empty.proxy_providers")).padding(.vertical, T.space8)
            } else if !isProxyProvidersCollapsed {
                VStack(spacing: T.space2) {
                    ForEach(providers, id: \.self) { name in
                        let entry = entries[name]
                        self.proxyProviderRow(name: name,
                            detail: usingRuntime && entry?.enabled != false ? proxyStore.proxyProvidersDetail[name] : nil,
                            entry: entry, usingRuntime: usingRuntime)
                    }
                }
            }
        }
        .appSectionCard()
    }

    func proxyProviderRow(name: String, detail: ProviderDetail?, entry: NativeProxyProvider?, usingRuntime: Bool) -> some View {
        let nodeCount = detail?.proxies?.count ?? 0
        let updatedText = ValueFormatter.relativeTime(from: detail?.updatedAt, language: language)
        let expireSeconds = detail?.subscriptionInfo?.expire
        let expireText = ValueFormatter.daysUntilExpiryShort(from: expireSeconds, language: language)
        let expireColor: Color = expireSeconds == 0 ? nativeSecondaryLabel : nativeWarning
        let upload = detail?.subscriptionInfo?.upload
        let download = detail?.subscriptionInfo?.download
        let total = detail?.subscriptionInfo?.total
        let usedRatio: Double? = {
            guard let total, total > 0, let upload, let download else { return nil }
            let used = upload + download
            return min(max(Double(used) / Double(total), 0), 1)
        }()
        let rowHorizontalPadding = T.space4
        let isUpdating = proxyStore.providerUpdating.contains(name)
        let hovered = hoveredProviderName == name
        let updateTimeWidth: CGFloat = 44

        let hasSubscription = detail?.subscriptionInfo != nil
        let status: String? = if entry?.enabled == false { tr("ui.proxy_provider.disabled") }
            else if entry != nil && !usingRuntime { tr(appViewModel.isRuntimeRunning ? "ui.proxy_provider.pending" : "ui.proxy_provider.stopped") }
            else if entry != nil && nodeCount == 0 { tr("ui.proxy_provider.unloaded") }
            else { nil }

        return VStack(alignment: .leading, spacing: T.space6) {
            HStack(alignment: .center, spacing: T.space6) {
                Image(systemName: "externaldrive.fill")
                    .font(.app(size: T.FontSize.caption, weight: .semibold))
                    .foregroundStyle(nativeTeal.opacity(T.Opacity.solid))
                    .frame(width: T.rowLeadingIcon, height: T.rowLeadingIcon)

                HStack(alignment: .center, spacing: T.space4) {
                    HStack(alignment: .center, spacing: T.space4) {
                        Text(name)
                            .font(.app(size: T.FontSize.body, weight: .semibold))
                            .foregroundStyle(nativePrimaryLabel)
                            .lineLimit(1)
                            .layoutPriority(1)

                        if let status {
                            SemanticTag(text: status, tint: entry?.enabled == false ? nativeSecondaryLabel : nativeWarning, monospaced: false)
                        } else {
                            SemanticTag(text: "\(nodeCount)", tint: nativeTeal).fixedSize()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if detail != nil {
                        Text(updatedText)
                            .font(.app(size: T.FontSize.caption, weight: .regular))
                            .foregroundStyle(nativeTertiaryLabel)
                            .lineLimit(1)
                            .frame(width: updateTimeWidth, alignment: .trailing)
                    }
                }
                .frame(maxWidth: .infinity)

                if detail != nil {
                    Button {
                        Task { await appViewModel.updateProxyProvider(name: name) }
                    } label: {
                        ZStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.app(size: T.FontSize.caption, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(nativeSecondaryLabel)
                                .opacity(isUpdating ? 0 : 1)
                            ProgressView()
                                .scaleEffect(0.5)
                                .opacity(isUpdating ? 1 : 0)
                        }
                        .frame(width: T.rowLeadingIcon, height: T.rowLeadingIcon)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tr("ui.action.refresh"))
                    .disabled(appViewModel.isQuickRuleSaving || isUpdating)
                }
                if let entry {
                    let toggleLabel = tr(entry.enabled ? "ui.proxy_provider.disable" : "ui.proxy_provider.enable")
                    Button {
                        appViewModel.openProxyProviderEditor(entry.enabled ? .disable : .enable, name: name)
                    } label: {
                        Image(systemName: entry.enabled ? "pause.circle" : "play.circle")
                            .foregroundStyle(entry.enabled ? nativeSecondaryLabel : nativeTeal)
                    }
                    .buttonStyle(.borderless)
                    .help(toggleLabel)
                    .accessibilityLabel(toggleLabel)
                    .disabled(!appViewModel.canStartProxyProviderEdit)
                    Menu {
                        Button(tr("ui.proxy_provider.edit")) { appViewModel.openProxyProviderEditor(.edit, name: name) }
                        Button(tr("ui.proxy_provider.delete"), role: .destructive) {
                            appViewModel.openProxyProviderEditor(.delete, name: name)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(tr("ui.proxy_provider.manage"))
                    .disabled(!appViewModel.canStartProxyProviderEdit)
                }
            }

            if hasSubscription {
                VStack(alignment: .leading, spacing: T.space2) {
                    HStack(spacing: 0) {
                        Text(expireText)
                            .font(.app(size: T.FontSize.caption, weight: .regular))
                            .foregroundStyle(expireColor)
                        Spacer(minLength: T.space4)
                        if let upload, let download, let total {
                            let used = upload + download
                            let quotaText =
                                "\(ValueFormatter.bytesCompactNoSpace(used)) / " +
                                "\(ValueFormatter.bytesCompactNoSpace(total))"
                            Text(quotaText)
                                .font(.appMono(size: T.FontSize.caption))
                                .foregroundStyle(nativeSecondaryLabel)
                                .lineLimit(1)
                        }
                    }

                    if let usedRatio {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.065))
                                Capsule()
                                    .fill((usedRatio >= 0.9 ? nativeCritical : usedRatio >= 0.75 ? nativeWarning :
                                            nativeAccent).opacity(T.Opacity.solid))
                                    .frame(width: geo.size.width * usedRatio)
                            }
                        }
                        .frame(height: T.space4)
                    }
                }
                .padding(.leading, T.rowLeadingIcon + T.space6)
                .padding(.trailing, T.rowLeadingIcon + T.space6)
            }
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, T.space6)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: T.cornerRadius, style: .continuous))
        .background(nativeHoverRowBackground(hovered))
        .onHover { hoveredProviderName = self.nextHovered(
            current: hoveredProviderName,
            target: name,
            isHovering: $0) }
    }

    enum ProviderAction {
        case healthcheck
        case refresh

        var symbol: String {
            switch self {
            case .healthcheck: "gauge.with.dots.needle.50percent"
            case .refresh: "arrow.triangle.2.circlepath"
            }
        }

        var labelKey: String {
            switch self {
            case .healthcheck: "ui.action.test_latency"
            case .refresh: "ui.action.refresh"
            }
        }
    }

    func providerActionButton(
        _ kind: ProviderAction,
        isLoading: Bool = false,
        action: @escaping () async -> Void) -> some View
    {
        let tone = kind == .healthcheck ? nativeTeal : nativeInfo
        return self.compactAsyncIconButton(
            symbol: kind.symbol,
            label: tr(kind.labelKey),
            tint: tone.opacity(T.Opacity.solid),
            isLoading: isLoading,
            size: T.rowLeadingIcon,
            fontSize: T.FontSize.caption,
            hierarchicalSymbol: true,
            action: action)
    }

    var proxyGroupsSection: some View {
        let groups = rootViewModel.filteredProxyGroups

        return VStack(alignment: .leading, spacing: T.space6) {
            self.nodesSectionHeader(
                tr("ui.section.proxy_groups"),
                symbol: "point.3.connected.trianglepath.dotted",
                count: "\(groups.count)")
            {
                HStack(spacing: T.space6) {
                    Menu {
                        Button(tr("ui.sites.title")) { appViewModel.showsSiteChecks = true }
                        Toggle(tr("ui.groups.fold"), isOn: $appViewModel.foldTimeoutNodes)
                        if appViewModel.canManageProxyProviders, let document = appViewModel.nativeProxyProviderDocument {
                            Menu(tr("ui.groups.edit")) {
                                ForEach(document.groups) { group in
                                    Button(group.name) { appViewModel.openGroupEditor(group.name) }
                                }
                            }.disabled(!appViewModel.canStartProxyProviderEdit || document.groups.isEmpty)
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(tr("ui.groups.options"))
                    self.compactTopIcon(
                        sortGroupNodesByLatency ? "timer" : "list.number",
                        label: tr(
                            sortGroupNodesByLatency
                                ? "ui.action.sort_nodes_default"
                                : "ui.action.sort_nodes_by_latency"),
                        toneOverride: nativeTeal)
                    {
                        sortGroupNodesByLatency.toggle()
                    }
                    .help(
                        tr(
                            sortGroupNodesByLatency
                                ? "ui.action.sort_nodes_default"
                                : "ui.action.sort_nodes_by_latency"))

                    self.compactTopIcon(
                        showLatencyHistory ? "chart.bar.xaxis" : "chart.bar",
                        label: tr(
                            showLatencyHistory
                                ? "ui.action.hide_latency_history"
                                : "ui.action.show_latency_history"),
                        toneOverride: nativeTeal)
                    {
                        showLatencyHistory.toggle()
                    }
                    .help(
                        tr(
                            showLatencyHistory
                                ? "ui.action.hide_latency_history"
                                : "ui.action.show_latency_history"))

                    self.compactTopIcon(
                        hideHiddenProxyGroups ? "eye.slash" : "eye",
                        label: tr(
                            hideHiddenProxyGroups
                                ? "ui.action.show_hidden_proxy_groups"
                                : "ui.action.hide_hidden_proxy_groups"),
                        toneOverride: nativeIndigo)
                    {
                        hideHiddenProxyGroups.toggle()
                    }
                    .help(
                        tr(
                            hideHiddenProxyGroups
                                ? "ui.action.show_hidden_proxy_groups"
                                : "ui.action.hide_hidden_proxy_groups"))

                    self.compactTopIcon(
                        "gauge",
                        label: tr("ui.action.test_latency"),
                        toneOverride: nativeTeal)
                    {
                        await appViewModel.refreshAllGroupLatencies(includeHiddenGroups: !hideHiddenProxyGroups)
                    }
                    .help(tr("ui.action.test_latency"))
                }
            }

            if groups.isEmpty {
                SheetNote(text: tr("ui.empty.proxy_groups")).padding(.vertical, T.space8)
            } else {
                VStack(spacing: T.space2) {
                    ForEach(groups, id: \.name) { group in
                        self.proxyGroupInlineRow(group)
                    }
                }
            }
        }
        .appSectionCard()
    }

    func proxyGroupInlineRow(_ group: ProxyGroup) -> some View {
        let currentNode = group.now ?? tr("ui.common.na")
        let delaySamples = appViewModel.delaySamples(group: group.name, node: currentNode, fallbackToGroupHistory: true)
        let delayText = appViewModel.delayText(group: group.name, node: currentNode, fallbackToGroupHistory: true)
        let iconURL = self.proxyGroupIconURL(group)
        let hovered = hoveredProxyGroupName == group.name
        let focused = focusedProxyGroupName == group.name
        let testing = proxyStore.groupLatencyLoading.contains(group.name)
        let revealed = hovered || focused || testing

        return HStack(spacing: T.space4) {
            AttachedPopoverMenu(width: 320) { _ in
                GeometryReader { geo in
                    let columns = self.proxyGroupMainColumnWidths(totalWidth: geo.size.width)
                    HStack(spacing: T.space6) {
                        Group {
                            if let iconURL {
                                self.proxyGroupLeadingIcon(iconURL)
                            } else {
                                Image(systemName: "point.3.connected.trianglepath.dotted")
                                    .font(.app(size: T.FontSize.callout)).foregroundStyle(self.nativeIndigo)
                            }
                        }
                        .frame(width: 18).accessibilityHidden(true)
                        Text(group.name)
                            .font(.app(size: T.FontSize.body, weight: .semibold))
                            .foregroundStyle(nativePrimaryLabel).lineLimit(1).truncationMode(.tail)
                            .frame(width: columns.name, alignment: .leading)
                        Text(currentNode)
                            .font(.app(size: T.FontSize.subheadline)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(width: columns.current, alignment: .trailing)
                        self.delayBadge(samples: delaySamples, fallbackText: delayText, showsHistory: showLatencyHistory)
                            .frame(width: columns.delay, alignment: .trailing)
                            .overlay(alignment: .bottomTrailing) {
                                LatencyAgeView(sample: appViewModel.latencySamples(group: group.name, node: currentNode, fallbackToGroupHistory: true).last,
                                               language: language, interval: group.interval)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .offset(y: 12).opacity(revealed ? 1 : 0).accessibilityHidden(!revealed)
                            }
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 40)
                .contentShape(Rectangle())
                .help(group.name + "\n" + currentNode + " · " + delayText)
            } content: { dismiss in
                self.popoverHeader(name: group.name, count: group.all.count) {
                    if let iconURL {
                        // The attached menu has its own hosting controller and needs the icon environment.
                        self.proxyGroupLeadingIcon(iconURL)
                            .environmentObject(self.appViewModel)
                            .environment(\.proxyGroupIconCache, self.appViewModel.proxyGroupIconCache)
                    }
                } trailing: {
                    if appViewModel.canStartProxyProviderEdit && appViewModel.nativeProvidersMatchRunningConfig,
                       appViewModel.nativeProxyProviderDocument?.groups.contains(where: { $0.name == group.name }) == true {
                        Button {
                            dismiss()
                            appViewModel.openGroupEditor(group.name)
                        } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain).help(tr("ui.groups.edit")).accessibilityLabel(tr("ui.groups.edit"))
                    }
                    Button {
                        dismiss()
                        self.appViewModel.proxyGroupDetailName = group.name
                    } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.plain).help(tr("ui.diagnostics.group_details"))
                        .accessibilityLabel(tr("ui.diagnostics.group_details"))
                    self.providerActionButton(.healthcheck, isLoading: testing) {
                        await appViewModel.refreshGroupLatency(group)
                    }
                }
                SheetNote(text: tr("ui.diagnostics.popover_note"))
                    .padding(.horizontal, T.space4).padding(.bottom, T.space6)
                let nodes = sortGroupNodesByLatency ? self.sortedGroupNodes(group) : self.defaultGroupNodes(group)
                let folded = appViewModel.foldedNodes(in: group)
                FoldableNodesList(nodes: nodes, folded: folded, title: tr("ui.groups.timeouts", folded.count), emptyText: tr("ui.common.na")) { node in
                    let samples = appViewModel.delaySamples(group: group.name, node: node)
                    ProxyGroupPopoverNodeItem(title: node, typeText: proxyStore.proxyNodeTypes[node].trimmedNonEmpty,
                                              delayText: appViewModel.delayText(group: group.name, node: node),
                                              delaySamples: samples,
                                              latestSample: appViewModel.latencySamples(group: group.name, node: node).last,
                                              language: language, isTesting: appViewModel.isProxyLatencyTesting(group: group.name, node: node),
                                              selected: node == group.now, testLatencyLabel: tr("ui.action.test_latency"),
                                              onTestLatency: { await appViewModel.refreshProxyLatency(group: group.name, node: node) },
                                              action: {
                                                  dismiss()
                                                  Task { await appViewModel.switchProxy(group: group.name, target: node) }
                                              })
                }
            }
            .focused($focusedProxyGroupName, equals: group.name)
            .accessibilityAction(named: Text(tr("ui.action.test_latency"))) {
                Task { await appViewModel.refreshGroupLatency(group) }
            }
            .contextMenu {
                Button(tr("ui.action.test_latency")) { Task { await appViewModel.refreshGroupLatency(group) } }
                Button(tr("ui.diagnostics.group_details")) { appViewModel.proxyGroupDetailName = group.name }
            }
            self.compactAsyncIconButton(symbol: "gauge", label: tr("ui.action.test_latency"), tint: nativeTeal,
                                        isLoading: testing, size: 22, fontSize: T.FontSize.callout, isRevealed: revealed) {
                await appViewModel.refreshGroupLatency(group)
            }
        }
        .padding(.horizontal, T.space4)
        .background(nativeHoverRowBackground(hovered || focused))
        .onHover { hoveredProxyGroupName = self.nextHovered(current: hoveredProxyGroupName, target: group.name, isHovering: $0) }
    }

    private func proxyGroupMainColumnWidths(totalWidth: CGFloat) -> (name: CGFloat, current: CGFloat, delay: CGFloat) {
        let available = max(0, totalWidth - 18 - T.space6 * 3)
        let delay = min(available, showLatencyHistory ? 78 : 60)
        let name = floor((available - delay) * 0.46)
        return (name, max(0, available - delay - name), delay)
    }

    func proxyGroupLeadingIcon(_ iconURL: URL) -> some View {
        ProxyGroupIconView(url: iconURL)
            .frame(
                width: T.rowLeadingIcon,
                height: T.rowLeadingIcon,
                alignment: .center)
    }

    func proxyGroupIconURL(_ group: ProxyGroup) -> URL? {
        guard let icon = group.icon else { return nil }
        return URL(string: icon)
    }

    func nodesSectionHeader(_ title: String, symbol: String, count: String? = nil,
                            @ViewBuilder trailing: @escaping () -> some View = { EmptyView() }) -> some View {
        AppSectionHeader(title, symbol: symbol, count: count, trailing: trailing)
    }

    func popoverHeader(
        name: String,
        count: Int,
        @ViewBuilder leading: () -> some View = { EmptyView() },
        @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View
    {
        VStack(spacing: 0) {
            HStack(spacing: T.space1) {
                leading()

                Text(name)
                    .font(.app(size: T.FontSize.body, weight: .semibold))
                    .foregroundStyle(nativePrimaryLabel)
                    .lineLimit(1)

                Text("\(count)")
                    .font(.app(size: T.FontSize.caption, weight: .medium))
                    .foregroundStyle(nativeSecondaryLabel)
                    .padding(.horizontal, T.space4)
                    .padding(.vertical, T.space1)
                    .background(nativeBadgeCapsule())

                Spacer(minLength: 0)

                trailing()
            }
            .padding(.horizontal, T.space4)
            .padding(.bottom, T.space2)

            Divider()
                .overlay(nativeSeparator)
                .padding(.bottom, T.space1)
        }
    }

    func orderedUniqueNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        ordered.reserveCapacity(names.count)
        for name in names where !name.isEmpty {
            if seen.insert(name).inserted {
                ordered.append(name)
            }
        }
        return ordered
    }

    func sortedGroupNodes(_ group: ProxyGroup) -> [String] {
        self.sortedNodes(names: group.all, latencyForNode: { appViewModel.delayValue(group: group.name, node: $0) })
    }

    func defaultGroupNodes(_ group: ProxyGroup) -> [String] {
        self.orderedUniqueNames(group.all)
    }

    private func sortedNodes(names: [String], latencyForNode: (String) -> Int?) -> [String] {
        let unique = self.orderedUniqueNames(names)
        let sorted = unique.sorted { lhs, rhs in
            let cmp = self.compareLatency(lhs: latencyForNode(lhs), rhs: latencyForNode(rhs), ascending: true)
            if cmp != .orderedSame {
                return cmp == .orderedAscending
            }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return sorted
    }
}

struct FoldableNodesList<Row: View>: View {
    let nodes: [String]
    let folded: Set<String>
    let title: String
    let emptyText: String
    let row: (String) -> Row

    @State private var frozenNodes: [String]
    @State private var expanded = false

    init(nodes: [String], folded: Set<String>, title: String, emptyText: String, @ViewBuilder row: @escaping (String) -> Row) {
        self.nodes = nodes
        self.folded = folded
        self.title = title
        self.emptyText = emptyText
        self.row = row
        self._frozenNodes = State(initialValue: nodes)
    }

    var body: some View {
        let available = Set(self.nodes)
        let retained = self.frozenNodes.filter(available.contains)
        let known = Set(retained)
        let current = retained + self.nodes.filter { !known.contains($0) }
        if current.isEmpty {
            Text(self.emptyText)
                .font(.app(size: T.FontSize.caption, weight: .regular))
                .foregroundStyle(self.nativeSecondaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, T.space6)
                .padding(.vertical, T.space4)
        } else {
            VStack(spacing: 0) {
                ForEach(current.filter { !folded.contains($0) }, id: \.self) { node in
                    self.row(node)
                }
                if !folded.isEmpty {
                    DisclosureGroup(title, isExpanded: $expanded) {
                        ForEach(current.filter(folded.contains), id: \.self, content: row)
                    }.padding(.vertical, 4)
                }
            }
        }
    }
}

struct ProxyGroupPopoverNodeItem: View {
    let title: String
    let typeText: String?
    let delayText: String
    let delaySamples: [Int]
    let latestSample: ProxyLatencySample?
    let language: AppLanguage
    let isTesting: Bool
    let selected: Bool
    let testLatencyLabel: String
    let onTestLatency: () async -> Void
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @AppStorage("clashbar.proxy.group.show_latency_history") private var showLatencyHistory = false

    var body: some View {
        HStack(spacing: T.space6) {
            Button(action: self.action) {
                HStack(spacing: T.space6) {
                    Image(systemName: self.selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(self.selected ? self.nativeAccent : self.nativeSecondaryLabel)
                        .font(.app(size: T.FontSize.caption)).frame(width: 12).accessibilityHidden(true)
                    Text(self.title)
                        .font(.app(size: T.FontSize.callout, weight: self.selected ? .semibold : .regular))
                        .foregroundStyle(self.nativePrimaryLabel).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let typeText {
                        SemanticTag(text: typeText, tint: self.nativeTeal)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).focused(self.$isFocused)
            .accessibilityAddTraits(self.selected ? .isSelected : [])
            self.delayBadge(samples: self.delaySamples, fallbackText: self.delayText, showsHistory: self.showLatencyHistory)
                .overlay(alignment: .bottomTrailing) {
                    LatencyAgeView(sample: self.latestSample, language: self.language)
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(y: 12).opacity(self.isHovered || self.isFocused || self.isTesting ? 1 : 0)
                        .accessibilityHidden(!self.isHovered && !self.isFocused && !self.isTesting)
                }
            self.compactAsyncIconButton(symbol: "gauge", label: self.testLatencyLabel, tint: self.nativeTeal,
                                        isLoading: self.isTesting, size: 20, fontSize: T.FontSize.caption,
                                        isRevealed: self.isHovered || self.isFocused, action: self.onTestLatency)
        }
        .padding(.horizontal, T.space6).frame(height: 40)
        .background((self.selected ? self.nativeAccent.opacity(0.10) : self.isHovered ? Color.primary.opacity(0.04) : .clear),
                    in: RoundedRectangle(cornerRadius: T.cornerRadius, style: .continuous))
        .onHover { self.isHovered = $0 }
    }
}

extension View {
    fileprivate func delayBadge(samples: [Int], fallbackText: String, showsHistory: Bool) -> some View {
        HStack(spacing: T.space4) {
            if showsHistory { LatencySignalBars(samples: samples, showsHistory: true) }
            LatencyPillBadge(value: samples.last, text: fallbackText)
        }
    }
}

private struct LatencySignalBars: View {
    let samples: [Int]
    let showsHistory: Bool

    private static let barCount = ProxyDelayHistory.limit
    private static let barWidth: CGFloat = 2
    private static let barSpacing: CGFloat = 1.5
    private static let heights: [CGFloat] = [4, 7, 10, 13]

    private var firstVisibleIndex: Int {
        self.showsHistory ? 0 : Self.barCount - 1
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: Self.barSpacing) {
            ForEach(self.firstVisibleIndex..<Self.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.75, style: .continuous)
                    .fill(self.barColor(at: index))
                    .frame(width: Self.barWidth, height: Self.heights[index])
            }
        }
        .frame(height: Self.heights.last, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private func barColor(at index: Int) -> Color {
        let offset = Self.barCount - self.samples.count
        let sampleIndex = index - offset
        guard sampleIndex >= 0, sampleIndex < self.samples.count else {
            return Color(nsColor: .quaternaryLabelColor).opacity(0.35)
        }
        return self.latencyColor(self.samples[sampleIndex])
    }
}
