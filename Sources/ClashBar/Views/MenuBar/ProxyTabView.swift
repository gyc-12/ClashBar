import SwiftUI

// swiftlint:disable:next type_name
private typealias T = MenuBarLayoutTokens

struct ProxyTabView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    @EnvironmentObject var proxyStore: ProxyStore
    @EnvironmentObject var trafficStore: TrafficStore
    @EnvironmentObject var connectionsStore: ConnectionsStore
    @ObservedObject var rootViewModel: ProxyGroupsViewModel

    @AppStorage("clashbar.proxy.group.sort_nodes_by_latency") var sortGroupNodesByLatency: Bool = false
    @AppStorage("clashbar.proxy.group.show_latency_history") var showLatencyHistory: Bool = false
    @AppStorage("clashbar.proxy.group.hide_hidden") var hideHiddenProxyGroups: Bool = true
    @AppStorage("clashbar.proxy.providers.collapsed") var isProxyProvidersCollapsed: Bool = false
    @AppStorage("clashbar.proxy.traffic.show_chart") var showTrafficChart: Bool = false

    @State var hoveredProviderName: String?
    @State var hoveredProxyGroupName: String?
    @FocusState var focusedProxyGroupName: String?

    var body: some View {
        self.proxyTabBody
    }
}

struct ConfigSwitcherMenu: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    let dismiss: () -> Void
    static let width = MenuBarLayoutTokens.contentWidth

    private struct ConfigMenuItemContext: Identifiable {
        let name: String
        let isRemote: Bool
        let isSelected: Bool
        let remoteState: RemoteConfigMenuState
        let remoteSubtitle: String?
        let boundSSIDs: [String]
        let currentSSID: String?
        let isCurrentSSIDBound: Bool
        let showsPermissionAction: Bool
        let remoteSubscriptionURL: String?
        let itemHelpText: String?
        let ssidBadgeText: String?
        let ssidBadgeHelpText: String?

        var id: String { name }
        var showsSSIDActions: Bool { currentSSID != nil || showsPermissionAction || !boundSSIDs.isEmpty }
        var showsRemoteCopyAction: Bool { remoteSubscriptionURL != nil }
    }

    private func configMenuLeadingSymbol(for context: ConfigMenuItemContext) -> String {
        context.isRemote ? "link" : "doc.text"
    }

    private func configMenuLeadingTint(for context: ConfigMenuItemContext) -> Color {
        context.isRemote
            ? self.nativePurple.opacity(T.Opacity.solid)
            : self.nativeInfo.opacity(T.Opacity.solid)
    }

    private func configMenuRemoteSubtitle(state: RemoteConfigMenuState) -> String? {
        ValueFormatter.remoteConfigMenuStatusLine(
            autoUpdateEnabled: state.autoUpdateEnabled,
            nextUpdateAt: state.nextUpdateAt,
            lastUpdateAt: state.updatedAt,
            language: self.appViewModel.uiLanguage)
            ?? state.updatedAt.map(ValueFormatter.dateTime)
    }

    private func configMenuSSIDBadgeText(for ssids: [String]) -> String? {
        guard !ssids.isEmpty else { return nil }
        let joined = ssids.joined(separator: ", ")
        if joined.count <= 22 {
            return joined
        }
        guard let firstSSID = ssids.first else { return nil }
        let remainingCount = ssids.count - 1
        guard remainingCount > 0 else { return firstSSID }
        return "\(firstSSID) +\(remainingCount)"
    }

    private func configMenuSSIDBadgeTint(for context: ConfigMenuItemContext) -> Color {
        context.isCurrentSSIDBound
            ? self.nativePositive.opacity(T.Opacity.solid)
            : self.nativeInfo.opacity(T.Opacity.solid)
    }

    private func configMenuItemHelpText(ssidHelpText: String?, remoteSubtitle: String?) -> String? {
        let parts = [ssidHelpText, remoteSubtitle]
            .compactMap { $0?.trimmedNonEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    }

    private func makeConfigMenuItemContext(for name: String) -> ConfigMenuItemContext {
        let remoteSubscription = self.appViewModel.remoteConfigSubscriptions[name]
        let isRemote = remoteSubscription != nil
        let remoteState = self.appViewModel.remoteConfigMenuState(for: name)
        let remoteSubtitle = isRemote ? self.configMenuRemoteSubtitle(state: remoteState) : nil
        let normalizedConfigFileName = name.trimmed
        let boundSSIDs = self.appViewModel.ssidStrategyRules
            .filter { $0.configFileName == normalizedConfigFileName }
            .map(\.ssid)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let currentSSID = self.appViewModel.ssidStrategyCurrentSSID?.trimmedNonEmpty
        let isCurrentSSIDBound = currentSSID.map { boundSSIDs.contains($0) } ?? false
        let showsPermissionAction = self.appViewModel.ssidStrategyEnabled
            && currentSSID == nil
            && self.appViewModel.ssidStrategyAuthorizationStatus == .notDetermined
        let ssidBadgeHelpText = boundSSIDs.isEmpty
            ? nil
            : self.tr("ui.quick.ssid.bound_label", boundSSIDs.joined(separator: ", "))

        return ConfigMenuItemContext(
            name: name,
            isRemote: isRemote,
            isSelected: name == self.appViewModel.selectedConfigName,
            remoteState: remoteState,
            remoteSubtitle: remoteSubtitle,
            boundSSIDs: boundSSIDs,
            currentSSID: currentSSID,
            isCurrentSSIDBound: isCurrentSSIDBound,
            showsPermissionAction: showsPermissionAction,
            remoteSubscriptionURL: remoteSubscription?.urlString.trimmedNonEmpty,
            itemHelpText: self.configMenuItemHelpText(
                ssidHelpText: ssidBadgeHelpText,
                remoteSubtitle: remoteSubtitle),
            ssidBadgeText: self.configMenuSSIDBadgeText(for: boundSSIDs),
            ssidBadgeHelpText: ssidBadgeHelpText)
    }

    private func ssidStrategyMenuStatusText() -> String {
        self.appViewModel.isSSIDStrategyAuthorized
            ? self.appViewModel.ssidStrategyCurrentSSIDText()
            : self.tr("ui.quick.configs.location_permission", self.appViewModel.ssidStrategyAuthorizationStatusText())
    }

    private func ssidStrategyMenuUsageHint() -> String {
        self.tr("ui.quick.ssid.usage_hint")
    }

    private func configMenuItemContexts() -> [ConfigMenuItemContext] {
        self.appViewModel.availableConfigFileNames
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { self.makeConfigMenuItemContext(for: $0) }
    }

    private func configMenuItem(for context: ConfigMenuItemContext) -> some View {
        ConfigMenuItemView(
            title: context.name,
            leadingSymbol: self.configMenuLeadingSymbol(for: context),
            leadingTint: self.configMenuLeadingTint(for: context),
            selected: context.isSelected,
            subtitle: context.isRemote ? context.remoteSubtitle : nil,
            itemHelpText: context.itemHelpText,
            ssidBadgeText: context.ssidBadgeText,
            ssidBadgeTint: self.configMenuSSIDBadgeTint(for: context),
            ssidBadgeHelpText: context.ssidBadgeHelpText,
            refreshPhase: context.isRemote ? context.remoteState.phase : nil,
            refreshHelpText: [self.tr("ui.action.refresh"), context.remoteSubtitle]
                .compactMap { $0?.trimmedNonEmpty }
                .joined(separator: "\n"),
            refreshingAccessibilityLabel: self.tr("ui.quick.remote.refreshing"),
            refreshFailedHelpText: self.tr("ui.quick.remote.refresh_failed"))
        {
            dismiss()
            Task { await self.appViewModel.selectConfigFile(named: context.name) }
        } onRefresh: {
            Task { await self.appViewModel.refreshRemoteConfigFile(named: context.name) }
        }
        .contextMenu {
            if let currentSSID = context.currentSSID {
                Button(
                    context.isCurrentSSIDBound
                        ? self.tr("ui.quick.ssid.unbind_current_named", currentSSID)
                        : self.tr("ui.quick.ssid.bind_current_named", currentSSID))
                {
                    self.appViewModel.toggleCurrentSSIDBinding(for: context.name)
                }
            } else if context.showsPermissionAction {
                Button(self.tr("ui.quick.ssid.request_permission")) {
                    self.appViewModel.refreshSSIDStrategyState(requestAuthorizationIfNeeded: true)
                }
            }

            ForEach(context.boundSSIDs, id: \.self) { ssid in
                Button(self.tr("ui.quick.ssid.unbind_named", ssid)) {
                    self.appViewModel.removeSSIDStrategyBinding(ssid: ssid)
                }
            }

            if context.showsSSIDActions {
                Divider()
            }

            if let urlString = context.remoteSubscriptionURL {
                Button(self.tr("ui.action.copy_subscription_url")) {
                    self.appViewModel.copyTextToPasteboard(urlString)
                }
            }

            if context.showsSSIDActions || context.showsRemoteCopyAction {
                Divider()
            }
            Button(role: .destructive) {
                Task { await self.appViewModel.deleteConfigFile(named: context.name) }
            } label: {
                Text(self.tr("ui.action.delete"))
            }
        }
    }

    var body: some View {
        let contexts = self.configMenuItemContexts()
        VStack(alignment: .leading, spacing: T.space8) {
            Label(tr("ui.quick.switch_config"), systemImage: "doc.on.doc")
                .font(.app(size: T.FontSize.title3, weight: .semibold))
                .padding(.horizontal, T.space4).padding(.vertical, T.space2)
            configSection("ui.quick.configs.local_section", items: contexts.filter { !$0.isRemote })
            configSection("ui.quick.configs.remote_section", items: contexts.filter(\.isRemote))
            VStack(alignment: .leading, spacing: T.space4) {
                AppSectionHeader(tr("ui.quick.configs.manage")) {
                    Button {
                        dismiss()
                        appViewModel.showSelectedConfigInFinder()
                    } label: {
                        Label(tr("ui.quick.show_in_finder"), systemImage: "folder").font(.app(size: T.FontSize.subheadline))
                    }.buttonStyle(.link)
                }
                Grid(alignment: .leading, horizontalSpacing: T.space6, verticalSpacing: T.space6) {
                    GridRow {
                        actionButton("ui.quick.import_local_config", symbol: "square.and.arrow.down") { appViewModel.importLocalConfigFile() }
                        actionButton("ui.quick.configs.import_link", symbol: "link.badge.plus") { Task { await appViewModel.importRemoteConfigFile() } }
                    }
                    GridRow {
                        actionButton("ui.quick.reload_config_list", symbol: "arrow.clockwise") { appViewModel.reloadConfigFileList() }
                        actionButton("ui.quick.update_remote_configs", symbol: "arrow.triangle.2.circlepath") { Task { await appViewModel.updateAllRemoteConfigFiles() } }
                    }
                }
            }.appSectionCard(padding: T.space8)
            HStack(spacing: T.space8) {
                IconBadge(symbol: "wifi", tint: appViewModel.ssidStrategyEnabled ? nativeTeal : nativeSecondaryLabel)
                VStack(alignment: .leading, spacing: T.space2) {
                    Text(tr("ui.quick.configs.wifi")).font(.app(size: T.FontSize.callout, weight: .semibold))
                    Text(ssidStrategyMenuStatusText()).font(.app(size: T.FontSize.subheadline)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: T.space4)
                Toggle(tr("ui.quick.configs.wifi"), isOn: $appViewModel.ssidStrategyEnabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).help(ssidStrategyMenuUsageHint())
            }.appSectionCard(padding: T.space10)
        }
    }

    @ViewBuilder private func configSection(_ key: String, items: [ConfigMenuItemContext]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: T.space2) {
                AppSectionHeader(tr(key), count: String(items.count))
                ForEach(items) { configMenuItem(for: $0) }
            }.appSectionCard(padding: T.space8)
        }
    }

    private func actionButton(_ key: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button { dismiss(); action() } label: {
            HStack(spacing: T.space6) {
                Image(systemName: symbol).foregroundStyle(nativeSecondaryLabel).frame(width: T.rowLeadingIcon)
                Text(tr(key)).font(.app(size: T.FontSize.callout)).lineLimit(2)
            }.frame(maxWidth: .infinity, minHeight: T.compactRowHeight, alignment: .leading)
        }.appBorderedButtonStyle()
    }
}

extension ProxyTabView {
    var proxyTabBody: some View {
        VStack(alignment: .leading, spacing: T.sectionSpacing) {
            self.trafficOverview
            self.proxyQuickRows
            if self.appViewModel.canManageProxyProviders || !self.proxyStore.sortedProxyProviderNames.isEmpty {
                proxyProvidersSection
            }
            proxyGroupsSection
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    var trafficOverview: some View {
        if !self.appViewModel.isRuntimeRunning {
            self.stoppedCoreStatusCard
        } else {
            VStack(alignment: .leading, spacing: T.space6) {
                HStack(spacing: T.space8) {
                    self.compactSpeedItem(symbol: "arrow.down", tint: self.nativePositive,
                                          rate: self.trafficStore.traffic.down,
                                          total: self.trafficStore.displayDownTotal,
                                          label: self.tr("ui.traffic.download"))
                    self.compactSpeedItem(symbol: "arrow.up", tint: self.nativeInfo,
                                          rate: self.trafficStore.traffic.up,
                                          total: self.trafficStore.displayUpTotal,
                                          label: self.tr("ui.traffic.upload"))
                    Spacer(minLength: 0)
                    HStack(spacing: T.space6) {
                        Label("\(self.connectionsStore.connectionsCount)", systemImage: "link")
                            .help(self.tr("ui.traffic.connections", self.connectionsStore.connectionsCount))
                            .accessibilityLabel(self.tr("ui.traffic.connections", self.connectionsStore.connectionsCount))
                        Label(ValueFormatter.bytesInteger(self.trafficStore.memory.inuse), systemImage: "memorychip")
                            .help(self.tr("ui.traffic.memory"))
                            .accessibilityLabel(self.tr("ui.traffic.memory") + ": " + ValueFormatter.bytesInteger(self.trafficStore.memory.inuse))
                    }
                    .font(.appMono(size: T.FontSize.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
                if self.showTrafficChart {
                    TrafficSparklineView(upValues: self.trafficStore.trafficHistoryUp, downValues: self.trafficStore.trafficHistoryDown)
                        .frame(height: 52)
                }
            }
            .appSectionCard(padding: T.space8)
        }
    }

    private var stoppedCoreStatusCard: some View {
        let isRemote = self.appViewModel.isRemoteTarget
        let hasConfig = self.appViewModel.configService.selectedConfig != nil
        let symbol = isRemote ? "network.slash" : hasConfig ? "stop.circle" : "doc.badge.plus"
        let tint = isRemote ? self.nativeWarning : hasConfig ? self.nativeSecondaryLabel : self.nativeInfo
        let titleKey = isRemote ? "ui.proxy.status.remote_unreachable"
            : hasConfig ? "ui.proxy.status.core_stopped" : "ui.proxy.status.no_config"

        return HStack(spacing: T.space8) {
            IconBadge(symbol: symbol, tint: tint, size: 22)
            Text(self.tr(titleKey))
                .font(.app(size: T.FontSize.callout, weight: .medium))
                .foregroundStyle(self.nativePrimaryLabel)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: T.space4)
            if isRemote {
                Button(self.tr("ui.action.refresh")) {
                    Task { await self.appViewModel.refreshFromAPI(includeSlowCalls: true) }
                }
                .appBorderedButtonStyle()
                .controlSize(.small)
            } else if hasConfig {
                Button(self.tr("app.primary.start")) {
                    Task { await self.appViewModel.startCore(trigger: .manual) }
                }
                .appBorderedButtonStyle(prominent: true)
                .controlSize(.small)
                .disabled(self.appViewModel.isCoreActionProcessing)
            } else {
                Button(self.tr("ui.quick.import_local_config")) {
                    self.appViewModel.importLocalConfigFile()
                }
                .appBorderedButtonStyle(prominent: true)
                .controlSize(.small)
            }
        }
        .appSectionCard(padding: T.space8)
    }

    private func compactSpeedItem(symbol: String, tint: Color, rate: Int64, total: Int64, label: String) -> some View {
        let speedText = ValueFormatter.speed(rate)
        let totalText = self.tr("ui.traffic.total", ValueFormatter.bytesCompact(total))
        return HStack(spacing: T.space2) {
            Image(systemName: symbol)
                .font(.app(size: T.FontSize.micro, weight: .bold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(speedText)
                .font(.appMono(size: T.FontSize.callout, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(T.minimumScale)
        }
        .help("\(label): \(speedText) · \(totalText)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(speedText), \(totalText)")
    }

    var proxyQuickRows: some View {
        VStack(spacing: T.space8) {
            HStack(alignment: .top, spacing: T.space10) {
                QuickToggleTile(title: self.tr("ui.quick.system_proxy"),
                                state: self.tr(self.proxyStore.isProxySyncing ? "ui.quick.applying" : self.appViewModel.isSystemProxyEnabled ? "ui.quick.on" : "ui.quick.off"),
                                tint: self.nativeInfo,
                                isOn: Binding(get: { self.appViewModel.isSystemProxyEnabled }, set: { value in
                                    Task { await self.appViewModel.toggleSystemProxy(value) }
                                }), disabled: self.proxyStore.isProxySyncing) {
                    self.systemProxyCompositeIcon
                } accessory: {
                    if let scope = self.systemProxyScopeLabel {
                        Text(scope).foregroundStyle(self.shouldShowSystemProxyRemoteWarning ? self.nativeWarning : self.nativeSecondaryLabel)
                            .help(self.tr("ui.system_proxy.remote_target_warning"))
                    }
                }
                QuickToggleTile(title: self.tr("ui.quick.tun_mode"),
                                state: self.tr(self.appViewModel.isTunSyncing ? "ui.quick.applying" : self.appViewModel.isTunEnabled ? "ui.quick.on" : "ui.quick.off"),
                                tint: self.nativeTeal,
                                isOn: Binding(get: { self.appViewModel.isTunEnabled }, set: { value in
                                    Task { await self.appViewModel.toggleTunMode(value) }
                                }), disabled: !self.appViewModel.isTunToggleEnabled) {
                    IconBadge(symbol: "shield.lefthalf.filled", tint: self.nativeTeal)
                } accessory: {
                    self.tunStackMenu
                }
            }
            if let failure = self.systemProxyInlineFailureText {
                SheetNote(text: failure, tint: self.nativeWarning, symbol: "exclamationmark.triangle")
                    .padding(.horizontal, T.space4)
            }
        }
    }

    private var tunStackMenu: some View {
        Menu {
            ForEach(Self.tunStackOptions, id: \.self) { option in
                let unsupported = option == "mips" && !self.appViewModel.isMipsStackSupported
                Button {
                    Task { await self.appViewModel.selectTunStack(option) }
                } label: {
                    if self.appViewModel.tunStack?.caseInsensitiveCompare(option) == .orderedSame {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
                .disabled(unsupported || !self.appViewModel.isTunToggleEnabled)
                .help(unsupported ? self.tr("app.tun.mips_requires_upgrade", AppViewModel.mipsStackMinimumCoreVersion) : self.tr("ui.quick.tun_stack_switch_hint"))
            }
        } label: {
            HStack(spacing: 3) {
                Text(self.appViewModel.tunStack?.trimmedNonEmpty ?? "system")
                    .font(.appMono(size: T.FontSize.caption))
                Image(systemName: "chevron.down").font(.app(size: 8, weight: .semibold))
            }
            .foregroundStyle(self.appViewModel.isTunEnabled ? self.nativeTeal : self.nativeSecondaryLabel)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(!self.appViewModel.isTunToggleEnabled)
        .help(self.tr("ui.quick.tun_stack_switch_hint"))
        .accessibilityLabel(self.tr("ui.quick.tun_stack"))
    }

    var systemProxyInlineFailureText: String? {
        guard !self.appViewModel.isSystemProxyEnabled else { return nil }
        return self.appViewModel.systemProxyOpenFailureHint?.trimmedNonEmpty
    }

    var systemProxyScopeLabel: String? {
        if self.appViewModel.isSystemProxyUsingRemoteCore {
            return self.tr("ui.machine.remote_label")
        }
        if self.appViewModel.isRemoteTarget {
            return self.tr("ui.machine.local_label")
        }
        return nil
    }

    var shouldShowSystemProxyRemoteWarning: Bool {
        self.appViewModel.isSystemProxyUsingRemoteCore
    }

    static let tunStackOptions = ["system", "gvisor", "mixed", "mips"]

    var systemProxyCompositeIcon: some View {
        ZStack {
            self.systemProxyCompositeIconLayer(
                tint: self.systemProxyHelperInstalledTint,
                alignment: .leading)
            self.systemProxyCompositeIconLayer(
                tint: self.systemProxyHelperProcessTint,
                alignment: .trailing)
        }
        .frame(width: 24, height: 24)
        .background(self.nativeInfo.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(self.systemProxyCompositeIconHelp)
    }

    func systemProxyCompositeIconLayer(tint: Color, alignment: Alignment) -> some View {
        Image(systemName: "network")
            .font(.app(size: T.FontSize.body, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 18, height: 18)
            .mask(alignment: alignment) {
                Rectangle()
                    .frame(width: 9)
            }
    }

    var systemProxyHelperInstalledTint: Color {
        switch self.appViewModel.systemProxyHelperInstalled {
        case .some(true):
            nativePositive.opacity(T.Opacity.solid)
        case .some(false):
            nativeCritical.opacity(T.Opacity.solid)
        case .none:
            nativeSecondaryLabel
        }
    }

    var systemProxyHelperProcessTint: Color {
        switch self.appViewModel.systemProxyHelperProcessRunning {
        case .some(true):
            nativePositive.opacity(T.Opacity.solid)
        case .some(false):
            nativeWarning.opacity(T.Opacity.solid)
        case .none:
            nativeSecondaryLabel
        }
    }

    var systemProxyHelperInstalledHelp: String {
        let value = switch self.appViewModel.systemProxyHelperInstalled {
        case .some(true):
            self.tr("ui.system_proxy.helper_install.ready")
        case .some(false):
            self.tr("ui.system_proxy.helper_install.missing")
        case .none:
            self.tr("ui.common.unknown")
        }
        return "\(self.tr("ui.system_proxy.helper_install")): \(value)"
    }

    var systemProxyHelperProcessHelp: String {
        let value = switch self.appViewModel.systemProxyHelperProcessRunning {
        case .some(true):
            self.tr("ui.system_proxy.helper_process.running")
        case .some(false):
            self.tr("ui.system_proxy.helper_process.stopped")
        case .none:
            self.tr("ui.common.unknown")
        }
        return "\(self.tr("ui.system_proxy.helper_process")): \(value)"
    }

    var systemProxyCompositeIconHelp: String {
        "\(self.systemProxyHelperInstalledHelp)\n\(self.systemProxyHelperProcessHelp)"
    }
}

private struct ConfigMenuItemView: View {
    let title: String
    let leadingSymbol: String
    let leadingTint: Color
    let selected: Bool
    let subtitle: String?
    let itemHelpText: String?
    let ssidBadgeText: String?
    let ssidBadgeTint: Color
    let ssidBadgeHelpText: String?
    let refreshPhase: RemoteConfigRefreshPhase?
    let refreshHelpText: String
    let refreshingAccessibilityLabel: String
    let refreshFailedHelpText: String
    let onSelect: () -> Void
    let onRefresh: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: T.space6) {
            self.selectionButton

            if let refreshPhase, let onRefresh {
                self.refreshControl(phase: refreshPhase, onRefresh: onRefresh)
            }
        }
        .padding(.horizontal, T.space6)
        .padding(.vertical, T.space4)
        .background(
            RoundedRectangle(cornerRadius: T.cornerRadius, style: .continuous)
                .fill(self.rowBackground))
        .contentShape(Rectangle())
        .onHover { self.isHovered = $0 }
    }

    private var selectionButton: some View {
        Button(action: self.onSelect) {
            HStack(alignment: .center, spacing: T.space6) {
                IconBadge(symbol: leadingSymbol, tint: leadingTint, size: 22)

                VStack(alignment: .leading, spacing: T.space1) {
                    Text(self.title)
                        .font(.app(size: T.FontSize.callout, weight: self.selected ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(self.nativePrimaryLabel)
                    if ssidBadgeText != nil || subtitle != nil {
                        HStack(spacing: T.space4) {
                            if let ssidBadgeText {
                                SemanticTag(text: ssidBadgeText, tint: self.ssidBadgeTint, monospaced: false)
                                    .help(self.ssidBadgeHelpText ?? ssidBadgeText)
                            }
                            if let subtitle {
                                Text(subtitle).font(.app(size: T.FontSize.caption)).lineLimit(1)
                                    .truncationMode(.middle).monospacedDigit().foregroundStyle(self.nativeSecondaryLabel)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(self.nativeAccent).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help([title, itemHelpText].compactMap { $0 }.joined(separator: "\n"))
    }

    private func refreshControl(
        phase: RemoteConfigRefreshPhase,
        onRefresh: @escaping () -> Void) -> some View
    {
        let failureTint = self.nativeCritical
        let helpText: String
        let tint: Color
        let baseTint: Color
        let isLoading = phase == .refreshing

        switch phase {
        case .idle:
            helpText = self.refreshHelpText
            tint = self.nativeAccent
            baseTint = self.secondaryTextColor
        case .refreshing:
            helpText = self.refreshingAccessibilityLabel
            tint = self.secondaryTextColor
            baseTint = self.secondaryTextColor
        case .failed:
            helpText = self.refreshFailedHelpText
            tint = failureTint
            baseTint = failureTint.opacity(0.92)
        }

        return CompactAsyncIconButton(
            symbol: "arrow.clockwise",
            tint: tint,
            baseTint: baseTint,
            role: nil,
            isLoading: isLoading,
            size: 20,
            fontSize: T.FontSize.body,
            hierarchicalSymbol: false,
            action: { onRefresh() })
            .help(helpText)
            .accessibilityLabel(helpText)
    }

    private var secondaryTextColor: Color {
        self.nativeSecondaryLabel
    }

    private var rowBackground: Color {
        if selected { return nativeAccent.opacity(isHovered ? T.Opacity.tint : T.Opacity.selection) }
        return isHovered ? Color.primary.opacity(0.06) : .clear
    }
}
