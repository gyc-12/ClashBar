import SwiftUI

// swiftlint:disable:next type_name
private typealias T = MenuBarLayoutTokens

private struct SettingsSelectionRowConfiguration<Option: Hashable> {
    let title: String
    let symbol: String
    let valueText: String
    let options: [Option]
    let optionTitle: (Option) -> String
    let isSelected: (Option) -> Bool
    let onSelect: (Option) -> Void
}

struct SystemTabView: TranslatingView {
    enum ProxyCommandCopyTarget: Equatable {
        case local
        case currentEndpoint
    }

    @EnvironmentObject var appViewModel: AppViewModel
    @AppStorage("clashbar.proxy.traffic.show_chart") private var showTrafficChart: Bool = false
    @State private var isExceptionsExpanded = false
    @State private var copiedProxyCommandTarget: ProxyCommandCopyTarget?
    @State private var proxyCommandCopyResetTask: Task<Void, Never>?
    @State private var testURLDraft = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func settingsCardHeader(_ title: String, symbol: String) -> some View {
        AppSectionHeader(title, symbol: symbol).padding(.horizontal, T.space4).padding(.bottom, T.space4)
    }

    func settingsRowLabel(symbol: String, title: String, tint: Color? = nil) -> some View {
        HStack(spacing: T.space6) {
            IconBadge(symbol: symbol, tint: tint ?? self.nativeInfo, size: 20)
            Text(title)
                .font(.app(size: T.FontSize.body, weight: .medium))
                .foregroundStyle(nativePrimaryLabel)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func handleCopyProxyCommand(_ target: ProxyCommandCopyTarget, action: () -> Void) {
        action()

        self.proxyCommandCopyResetTask?.cancel()
        self.proxyCommandCopyResetTask = nil

        withAnimation(.snappy(duration: 0.16)) {
            self.copiedProxyCommandTarget = target
        }

        self.proxyCommandCopyResetTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 1_600_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                self.copiedProxyCommandTarget = nil
            }
            self.proxyCommandCopyResetTask = nil
        }
    }

    private func proxyCommandActionButton(
        title: String,
        target: ProxyCommandCopyTarget,
        helpTitle: String,
        helpDetail: String,
        action: @escaping () -> Void) -> some View
    {
        let copied = self.copiedProxyCommandTarget == target
        let foreground = copied
            ? self.nativePositive.opacity(T.Opacity.solid)
            : self.nativeSecondaryLabel
        let iconForeground = copied
            ? self.nativePositive.opacity(T.Opacity.solid)
            : self.nativeTertiaryLabel

        return Button {
            self.handleCopyProxyCommand(target) {
                action()
            }
        } label: {
            HStack(spacing: T.space4) {
                Text(title)
                    .font(.appMono(size: T.FontSize.caption, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(T.minimumScale)
                    .monospacedDigit()
                    .foregroundStyle(foreground)
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.app(size: T.FontSize.caption, weight: .semibold))
                    .foregroundStyle(iconForeground)
            }
            .padding(.horizontal, T.space6)
            .padding(.vertical, T.space2)
            .background {
                Capsule(style: .continuous)
                    .fill(copied ? self.nativePositive.opacity(T.Opacity.tint) : self.nativeBadgeFill)
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(
                                copied
                                    ? self.nativePositive.opacity(0.18)
                                    : self.nativeControlBorder.opacity(0.42),
                                lineWidth: T.stroke)
                    }
            }
        }
        .buttonStyle(.plain)
        .help("\(helpTitle)\n\(helpDetail)")
    }

    private var configAndTerminalCard: some View {
        let localTargetDisplay = self.appViewModel.localProxyCommandTargetDisplay()
        let managedTargetDisplay = self.appViewModel.managedEndpointProxyCommandTargetDisplay()
        let showManagedTargetAction = localTargetDisplay != managedTargetDisplay

        return VStack(spacing: 0) {
            self.settingsCardHeader(self.tr("ui.section.config_and_terminal"), symbol: "doc.text")

            HStack(spacing: T.space8) {
                self.settingsRowLabel(symbol: "doc.text", title: self.tr("ui.quick.switch_config"), tint: self.nativePurple)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if self.appViewModel.isRemoteTarget {
                    Text(self.tr("ui.machine.remote_readonly"))
                        .font(.app(size: T.FontSize.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    AttachedPopoverMenu(
                        width: ConfigSwitcherMenu.width,
                        onWillPresent: { self.appViewModel.refreshRemoteConfigMenuStates() })
                    { _ in
                        HStack(spacing: T.space2) {
                            Text(self.appViewModel.selectedConfigName)
                                .foregroundStyle(nativeSecondaryLabel)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.right")
                                .font(.app(size: T.FontSize.caption, weight: .semibold))
                                .foregroundStyle(nativeTertiaryLabel)
                        }
                        .font(.app(size: T.FontSize.caption, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    } content: { dismiss in
                        ConfigSwitcherMenu(dismiss: dismiss).environmentObject(self.appViewModel)
                    }
                    .frame(width: self.settingsMenuControlWidth, alignment: .trailing)
                    .appBorderedButtonStyle()
                    .controlSize(.small)
                    .disabled(self.appViewModel.isQuickRuleSaving)
                }
            }
            .menuRowPadding(vertical: T.space6)
            .overlay(alignment: .bottom) { Divider().opacity(0.4).padding(.leading, 30) }

            HStack(spacing: T.space8) {
                self.settingsRowLabel(symbol: "terminal", title: self.tr("ui.quick.terminal"), tint: self.nativeWarning)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                HStack(spacing: T.space4) {
                    self.proxyCommandActionButton(
                        title: self.appViewModel.localProxyCommandHostDisplay(),
                        target: .local,
                        helpTitle: self.tr("ui.quick.copy_terminal"),
                        helpDetail: localTargetDisplay)
                    {
                        self.appViewModel.copyLocalProxyCommand()
                    }
                    if showManagedTargetAction {
                        self.proxyCommandActionButton(
                            title: self.appViewModel.managedEndpointProxyCommandHostDisplay(),
                            target: .currentEndpoint,
                            helpTitle: self.tr("ui.quick.copy_terminal_current_endpoint"),
                            helpDetail: managedTargetDisplay)
                        {
                            self.appViewModel.copyManagedEndpointProxyCommand()
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .menuRowPadding(vertical: T.space6)
        }
        .appSectionCard()
    }

    func settingsToggleRow(
        _ title: String,
        symbol: String,
        isOn: Binding<Bool>,
        isDisabled: Bool = false) -> some View
    {
        HStack(spacing: T.space8) {
            self.settingsRowLabel(symbol: symbol, title: title)
                .layoutPriority(1)
            Spacer(minLength: 0)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isDisabled)
        }
        .menuRowPadding(vertical: T.space6)
        .overlay(alignment: .bottom) { Divider().opacity(0.4).padding(.leading, 30) }
    }

    func settingsMenuRow(
        _ title: String,
        symbol: String,
        valueText: String,
        controlWidth: CGFloat? = nil,
        popoverWidth: CGFloat? = nil,
        @ViewBuilder options: @escaping (_ dismiss: @escaping () -> Void) -> some View) -> some View
    {
        let resolvedControlWidth = controlWidth ?? self.settingsMenuControlWidth

        return HStack(spacing: T.space8) {
            self.settingsRowLabel(symbol: symbol, title: title)
                .layoutPriority(1)
            Spacer(minLength: 0)
            AttachedPopoverMenu(width: popoverWidth ?? resolvedControlWidth) { _ in
                HStack(spacing: T.space2) {
                    Text(valueText)
                        .foregroundStyle(nativeSecondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.right")
                        .font(.app(size: T.FontSize.caption, weight: .semibold))
                        .foregroundStyle(nativeTertiaryLabel)
                }
                .font(.app(size: T.FontSize.caption, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .trailing)
            } content: { dismiss in
                options(dismiss)
            }
            .frame(width: resolvedControlWidth, alignment: .trailing)
            .appBorderedButtonStyle()
            .controlSize(.small)
        }
        .menuRowPadding(vertical: T.space6)
        .overlay(alignment: .bottom) { Divider().opacity(0.4).padding(.leading, 30) }
    }

    private func settingsSelectionRow(
        _ configuration: SettingsSelectionRowConfiguration<some Hashable>) -> some View
    {
        self.settingsMenuRow(
            configuration.title,
            symbol: configuration.symbol,
            valueText: configuration.valueText)
        { dismiss in
            ForEach(configuration.options, id: \.self) { option in
                AttachedPopoverMenuItem(
                    title: configuration.optionTitle(option),
                    selected: configuration.isSelected(option))
                {
                    configuration.onSelect(option)
                    dismiss()
                }
            }
        }
    }

    func settingsPortFieldRow(_ title: String, symbol: String, text: Binding<String>) -> some View {
        HStack(spacing: T.space8) {
            self.settingsRowLabel(symbol: symbol, title: title)
                .layoutPriority(1)

            Spacer(minLength: 0)

            TextField(self.tr("ui.placeholder.port"), text: text)
                .textFieldStyle(.roundedBorder)
                .font(.appMono(size: T.FontSize.callout))
                .foregroundStyle(nativePrimaryLabel)
                .multilineTextAlignment(.trailing)
                .frame(width: self.settingsPortFieldWidth, alignment: .trailing)
                .onChange(of: text.wrappedValue) { _ in
                    self.appViewModel.scheduleProxyPortsAutoSaveIfNeeded()
                }
                .onSubmit {
                    Task { await self.appViewModel.applyProxyPorts(autoSaved: true) }
                }
        }
        .padding(.vertical, T.space4)
    }

    func systemProxyExceptionBinding(id: EditableSystemProxyException.ID) -> Binding<String> {
        Binding(
            get: {
                self.appViewModel.systemProxyExceptions.first(where: { $0.id == id })?.value ?? ""
            },
            set: { value in
                guard let index = self.appViewModel.systemProxyExceptions.firstIndex(where: { $0.id == id }) else {
                    return
                }
                self.appViewModel.systemProxyExceptions[index].value = value
            })
    }

    func systemProxyExceptionRow(_ exception: EditableSystemProxyException) -> some View {
        HStack(spacing: T.space4) {
            TextField(
                self.tr("ui.placeholder.system_proxy_exception"),
                text: self.systemProxyExceptionBinding(id: exception.id))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.appMono(size: T.FontSize.callout))
                .foregroundStyle(nativePrimaryLabel)

            Button {
                self.appViewModel.removeSystemProxyExceptionDraft(id: exception.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(nativeCritical.opacity(T.Opacity.solid))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(self.tr("ui.action.remove_exception"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func maintenanceActionButton(_ title: String, symbol: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label {
                Text(title)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            } icon: {
                Image(systemName: symbol)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .appBorderedButtonStyle()
        .controlSize(.small)
        .disabled(!self.maintenanceActionEnabled)
        .opacity(self.maintenanceActionEnabled ? 1 : 0.62)
    }

    func settingsFeedbackBanner(text: String, color: Color, symbol: String) -> some View {
        SheetNote(text: text, tint: color, symbol: symbol).appSectionCard()
    }

    func statusBarModeLabel(_ mode: StatusBarDisplayMode) -> String {
        switch mode {
        case .iconAndSpeed:
            self.tr("ui.settings.display_mode.icon_and_speed")
        case .iconOnly:
            self.tr("ui.settings.display_mode.icon_only")
        case .speedOnly:
            self.tr("ui.settings.display_mode.speed_only")
        }
    }

    func appearanceModeLabel(_ mode: AppAppearanceMode) -> String {
        switch mode {
        case .system:
            self.tr("ui.settings.appearance.system")
        case .light:
            self.tr("ui.settings.appearance.light")
        case .dark:
            self.tr("ui.settings.appearance.dark")
        }
    }

    var settingsMenuControlWidth: CGFloat {
        let contentWidth = T.contentWidth - T.cardPadding * 2
        return min(152, max(118, contentWidth * 0.43))
    }

    var settingsPortFieldWidth: CGFloat {
        let contentWidth = T.contentWidth - T.cardPadding * 2
        return min(108, max(92, contentWidth * 0.30))
    }

    var maintenanceActionEnabled: Bool {
        SystemTabViewModel.maintenanceActionEnabled(session: self.appViewModel)
    }

    var geoUpdateActionEnabled: Bool {
        self.appViewModel.isRuntimeRunning && !self.appViewModel.isGeoUpdateInFlight
    }

    var geoUpdateFeedbackSymbol: String? {
        switch self.appViewModel.geoUpdateState {
        case .idle, .updating:
            nil
        case .succeeded:
            "checkmark.circle"
        case .failed:
            "exclamationmark.triangle"
        }
    }

    var geoUpdateFeedbackColor: Color {
        switch self.appViewModel.geoUpdateState {
        case .succeeded:
            nativePositive.opacity(T.Opacity.solid)
        case .failed:
            nativeCritical.opacity(T.Opacity.solid)
        default:
            nativeSecondaryLabel
        }
    }

    var isSystemProxyExceptionsSyncing: Bool {
        self.appViewModel.settingsSyncingKey == "system-proxy-exceptions"
    }

    var settingsFeedbackState: (message: String, color: Color, symbol: String)? {
        guard let feedback = SystemTabViewModel.feedbackState(session: appViewModel) else { return nil }
        let color: Color = switch feedback.kind {
        case .error:
            nativeCritical.opacity(T.Opacity.solid)
        case .warning:
            nativeWarning.opacity(T.Opacity.solid)
        case .success:
            nativePositive.opacity(T.Opacity.solid)
        }
        return (feedback.message, color, feedback.symbol)
    }

    func editableCoreSettingBinding(_ setting: AppViewModel.EditableCoreSetting) -> Binding<Bool> {
        Binding(
            get: { self.appViewModel.boolValue(for: setting) },
            set: { value in
                Task { await self.appViewModel.applyEditableCoreSetting(setting, to: value) }
            })
    }

    var body: some View {
        let isRemote = self.appViewModel.isRemoteTarget
        let proxyPortFields: [(titleKey: String, symbol: String, text: Binding<String>)] = [
            ("ui.settings.port.port", "network", $appViewModel.settingsPort),
            ("ui.settings.port.socks", "wave.3.right", self.$appViewModel.settingsSocksPort),
            ("ui.settings.port.mixed", "arrow.triangle.merge", self.$appViewModel.settingsMixedPort),
            ("ui.settings.port.redir", "arrowshape.turn.up.right", self.$appViewModel.settingsRedirPort),
            ("ui.settings.port.tproxy", "shield.lefthalf.filled", self.$appViewModel.settingsTProxyPort),
        ]
        let localOnlyItems: [(id: String, title: String, symbol: String, isOn: Binding<Bool>)] = [
            (
                "launch-at-login",
                tr("ui.settings.launch_at_login"),
                "person.crop.circle.badge.checkmark",
                Binding(
                    get: { self.appViewModel.launchAtLoginEnabled },
                    set: { self.appViewModel.applyLaunchAtLogin($0) })),
            (
                "auto-start-core",
                tr("ui.settings.auto_start_core"),
                "power.circle",
                Binding(
                    get: { self.appViewModel.autoStartCoreEnabled },
                    set: { self.appViewModel.autoStartCoreEnabled = $0 })),
        ]
        let coreToggleItems: [(id: String, title: String, symbol: String, isOn: Binding<Bool>)] = [
            (
                AppViewModel.EditableCoreSetting.allowLan.id,
                self.tr("ui.settings.allow_lan"),
                "network",
                self.editableCoreSettingBinding(.allowLan)),
            (
                AppViewModel.EditableCoreSetting.ipv6.id,
                self.tr("ui.settings.ipv6"),
                "globe",
                self.editableCoreSettingBinding(.ipv6)),
            (
                AppViewModel.EditableCoreSetting.tcpConcurrent.id,
                self.tr("ui.settings.tcp_concurrent"),
                "point.3.connected.trianglepath.dotted",
                self.editableCoreSettingBinding(.tcpConcurrent)),
        ]
        let maintenanceActions: [(titleKey: String, symbol: String, action: @MainActor () async -> Void)] = [
            (
                "ui.action.flush_fakeip_cache",
                "externaldrive.badge.minus",
                { await self.appViewModel.flushFakeIPCache() }),
            (
                "ui.action.flush_dns_cache",
                "network.badge.shield.half.filled",
                { await self.appViewModel.flushDNSCache() }),
        ]
        let selectedLogLevel = self.appViewModel.stringValue(for: .logLevel)
        let systemProxyExceptionsTitle = isRemote
            ? "\(tr("ui.section.system_proxy_exceptions")) (\(tr("ui.machine.local_label")))"
            : self.tr("ui.section.system_proxy_exceptions")

        return VStack(alignment: .leading, spacing: T.sectionSpacing) {
            if let feedback = settingsFeedbackState {
                self.settingsFeedbackBanner(text: feedback.message, color: feedback.color, symbol: feedback.symbol)
            }
            self.configAndTerminalCard
            VStack(spacing: 0) {
                self.settingsCardHeader(
                    isRemote ? self.tr("ui.section.local_app_settings") : self.tr("ui.section.basic_settings"),
                    symbol: "slider.horizontal.3")
                ForEach(localOnlyItems, id: \.id) { item in
                    self.settingsToggleRow(
                        isRemote ? "\(item.title) (\(self.tr("ui.machine.local_label")))" : item.title,
                        symbol: item.symbol,
                        isOn: item.isOn)
                }
                self.settingsToggleRow(
                    self.tr("ui.settings.show_traffic_chart"),
                    symbol: "chart.xyaxis.line",
                    isOn: self.$showTrafficChart)
                self.defaultTestURLSection
                self.settingsSelectionRow(.init(
                    title: self.tr("ui.settings.menu_bar_style"),
                    symbol: "menubar.rectangle",
                    valueText: self.statusBarModeLabel(self.appViewModel.statusBarDisplayMode),
                    options: StatusBarDisplayMode.allCases,
                    optionTitle: self.statusBarModeLabel,
                    isSelected: { self.appViewModel.statusBarDisplayMode == $0 },
                    onSelect: { self.appViewModel.statusBarDisplayMode = $0 }))
                self.settingsSelectionRow(.init(
                    title: self.tr("ui.settings.language"),
                    symbol: "character.book.closed",
                    valueText: self.appViewModel.uiLanguage == .zhHans ? self.tr("ui.language.zh_hans") : self
                        .tr("ui.language.en"),
                    options: AppLanguage.allCases,
                    optionTitle: { $0 == .zhHans ? self.tr("ui.language.zh_hans") : self.tr("ui.language.en") },
                    isSelected: { self.appViewModel.uiLanguage == $0 },
                    onSelect: self.appViewModel.setUILanguage))
                self.settingsSelectionRow(.init(
                    title: self.tr("ui.settings.appearance"),
                    symbol: "circle.lefthalf.filled",
                    valueText: self.appearanceModeLabel(self.appViewModel.appearanceMode),
                    options: AppAppearanceMode.allCases,
                    optionTitle: self.appearanceModeLabel,
                    isSelected: { self.appViewModel.appearanceMode == $0 },
                    onSelect: self.appViewModel.setAppearanceMode))
                self.settingsSelectionRow(.init(
                    title: self.tr("ui.settings.log_level"),
                    symbol: "text.alignleft",
                    valueText: selectedLogLevel,
                    options: ConfigLogLevel.allCases,
                    optionTitle: \.rawValue,
                    isSelected: { selectedLogLevel.caseInsensitiveCompare($0.rawValue) == .orderedSame },
                    onSelect: { level in
                        Task { await self.appViewModel.applyEditableCoreSetting(.logLevel, to: level.rawValue) }
                    }))
                Button {
                    self.isExceptionsExpanded.toggle()
                } label: {
                    HStack(spacing: T.space8) {
                        self.settingsRowLabel(
                            symbol: "arrowshape.turn.up.right.circle",
                            title: systemProxyExceptionsTitle)
                            .layoutPriority(1)
                        Spacer(minLength: 0)
                        HStack(spacing: T.space2) {
                            let count = self.appViewModel.systemProxyExceptions.count
                            if count > 0 {
                                Text("\(count)")
                                    .foregroundStyle(nativeSecondaryLabel)
                                    .lineLimit(1)
                            }
                            Image(systemName: "chevron.right")
                                .font(.app(size: T.FontSize.caption, weight: .semibold))
                                .foregroundStyle(nativeTertiaryLabel)
                                .rotationEffect(.degrees(self.isExceptionsExpanded ? 90 : 0))
                        }
                        .font(.app(size: T.FontSize.caption, weight: .medium))
                    }
                    .menuRowPadding(vertical: T.space4)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: T.space4) {
                    Text(self.tr("ui.settings.system_proxy_exceptions_hint"))
                        .font(.app(size: T.FontSize.caption, weight: .regular))
                        .foregroundStyle(nativeSecondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)

                    if self.appViewModel.systemProxyExceptions.isEmpty {
                        Text(self.tr("ui.settings.system_proxy_exceptions_empty"))
                            .font(.app(size: T.FontSize.body, weight: .regular))
                            .foregroundStyle(nativeSecondaryLabel)
                    } else {
                        VStack(alignment: .leading, spacing: T.space4) {
                            ForEach(self.appViewModel.systemProxyExceptions) { item in
                                self.systemProxyExceptionRow(item)
                            }
                        }
                    }

                    HStack(spacing: T.space4) {
                        TextField(
                            self.tr("ui.placeholder.system_proxy_exception"),
                            text: self.$appViewModel.systemProxyNewException)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .font(.app(size: T.FontSize.body, weight: .regular))
                            .foregroundStyle(nativePrimaryLabel)
                            .onSubmit {
                                self.appViewModel.addSystemProxyExceptionDraft()
                            }

                        Button(self.tr("ui.action.add_exception")) {
                            self.appViewModel.addSystemProxyExceptionDraft()
                        }
                        .appBorderedButtonStyle()
                        .controlSize(.small)
                        .disabled(!self.appViewModel.canAddSystemProxyException || self
                            .isSystemProxyExceptionsSyncing)
                    }

                    HStack(spacing: T.space4) {
                        Button {
                            self.appViewModel.restoreDefaultSystemProxyExceptionsDraft()
                        } label: {
                            Label(self.tr("ui.action.restore_defaults"), systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .appBorderedButtonStyle()
                        .controlSize(.small)
                        .disabled(self.isSystemProxyExceptionsSyncing)

                        Button {
                            Task { await self.appViewModel.saveSystemProxyExceptions() }
                        } label: {
                            Label(self.tr("ui.action.save_exceptions"), systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .appBorderedButtonStyle()
                        .controlSize(.small)
                        .disabled(self.isSystemProxyExceptionsSyncing)
                    }
                }
                .menuRowPadding(vertical: T.space4)
                .frame(maxHeight: self.isExceptionsExpanded ? .infinity : 0, alignment: .top)
                .clipped()
                .opacity(self.isExceptionsExpanded ? 1 : 0)
            }
            .appSectionCard()
            .animation(self.reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.80), value: self.isExceptionsExpanded)

            VStack(spacing: 0) {
                self.settingsCardHeader(
                    isRemote ? self.tr("ui.section.core_settings_remote") : self.tr("ui.section.core_settings"),
                    symbol: "gearshape.2")
                ForEach(coreToggleItems, id: \.id) { item in
                    self.settingsToggleRow(
                        item.title,
                        symbol: item.symbol,
                        isOn: item.isOn,
                        isDisabled: self.appViewModel.isCoreSettingSyncing)
                }
                if !isRemote {
                    self.nativeDNSIPv6Row
                }
            }
            .appSectionCard()

            VStack(spacing: 0) {
                self.settingsCardHeader(
                    self.tr("ui.section.proxy_ports"),
                    symbol: "point.3.connected.trianglepath.dotted")

                VStack(alignment: .leading, spacing: T.space4) {
                    ForEach(proxyPortFields, id: \.titleKey) { item in
                        self.settingsPortFieldRow(
                            self.tr(item.titleKey),
                            symbol: item.symbol,
                            text: item.text)
                    }
                }
                .menuRowPadding(vertical: T.space4)
            }
            .appSectionCard()

            VStack(spacing: 0) {
                self.settingsCardHeader(
                    self.tr("ui.section.maintenance"),
                    symbol: "wrench.and.screwdriver")

                VStack(alignment: .leading, spacing: T.space4) {
                    HStack(spacing: T.space6) {
                        ForEach(maintenanceActions, id: \.titleKey) { item in
                            self.maintenanceActionButton(self.tr(item.titleKey), symbol: item.symbol) {
                                await item.action()
                            }
                        }
                    }

                    HStack(spacing: T.space6) {
                        Button {
                            Task { await self.appViewModel.upgradeGeo() }
                        } label: {
                            HStack(spacing: T.space4) {
                                Group {
                                    if self.appViewModel.isGeoUpdateInFlight {
                                        ProgressView()
                                            .controlSize(.mini)
                                    } else if let symbol = self.geoUpdateFeedbackSymbol {
                                        Image(systemName: symbol)
                                            .foregroundStyle(self.geoUpdateFeedbackColor)
                                    } else {
                                        Image(systemName: "arrow.down.circle")
                                    }
                                }
                                .frame(width: 16, height: 16)
                                Text(self.tr("ui.action.update_geo_database"))
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .appBorderedButtonStyle()
                        .controlSize(.small)
                        .disabled(!self.geoUpdateActionEnabled)
                        .opacity(self.geoUpdateActionEnabled ? 1 : 0.62)

                        Button {
                            self.appViewModel.showCoreDirectoryInFinder()
                        } label: {
                            Label(self.tr("ui.action.open_core_directory"), systemImage: "folder")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .appBorderedButtonStyle()
                        .controlSize(.small)
                    }
                }
                .menuRowPadding(vertical: T.space4)
            }
            .appSectionCard()
        }
        .onAppear {
            self.testURLDraft = self.appViewModel.defaultHealthcheckURL
        }
        .onChange(of: self.appViewModel.customHealthcheckURL) { _ in
            self.testURLDraft = self.appViewModel.defaultHealthcheckURL
        }
        .onDisappear {
            self.proxyCommandCopyResetTask?.cancel()
            self.proxyCommandCopyResetTask = nil
        }
    }

    private var defaultTestURLSection: some View {
        let presets: [(label: String, url: String)] = [
            ("gstatic", AppViewModel.builtInHealthcheckURL),
            ("Cloudflare", AppViewModel.cloudflareHealthcheckURL),
        ]
        return VStack(alignment: .leading, spacing: T.space6) {
            self.settingsRowLabel(symbol: "speedometer", title: self.tr("ui.settings.test_url"))
            HStack(spacing: T.space4) {
                TextField(AppViewModel.builtInHealthcheckURL, text: self.$testURLDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.appMono(size: T.FontSize.caption))
                    .foregroundStyle(self.nativePrimaryLabel)
                    .onSubmit { self.appViewModel.updateCustomHealthcheckURL(self.testURLDraft) }
                Button(self.tr("ui.proxy_provider.save")) {
                    self.appViewModel.updateCustomHealthcheckURL(self.testURLDraft)
                }
                .appBorderedButtonStyle()
                .controlSize(.small)
                .disabled(self.testURLDraft.trimmed == self.appViewModel.defaultHealthcheckURL)
            }
            HStack(spacing: T.space6) {
                ForEach(presets, id: \.url) { preset in
                    let selected = self.appViewModel.defaultHealthcheckURL == preset.url
                    Button {
                        self.testURLDraft = preset.url
                        self.appViewModel.updateCustomHealthcheckURL(preset.url)
                    } label: {
                        HStack(spacing: 3) {
                            if selected {
                                Image(systemName: "checkmark").font(.app(size: 9, weight: .bold))
                            }
                            Text(preset.label).font(.app(size: T.FontSize.caption, weight: .medium))
                        }
                        .padding(.horizontal, T.space6)
                        .padding(.vertical, T.space2)
                        .foregroundStyle(selected ? self.nativeAccent : self.nativeSecondaryLabel)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selected ? self.nativeAccent.opacity(T.Opacity.tint) : self.nativeBadgeFill))
                    }
                    .buttonStyle(.plain)
                    .help(preset.url)
                }
                Spacer(minLength: 0)
            }
        }
        .menuRowPadding(vertical: T.space6)
        .overlay(alignment: .bottom) { Divider().opacity(0.4).padding(.leading, 30) }
    }

    private var nativeDNSIPv6Row: some View {
        let hasSnapshot = self.appViewModel.nativeDNSSnapshot != nil
        let isOn = Binding(
            get: { self.appViewModel.nativeDNSSnapshot?.dnsIPv6 ?? false },
            set: { value in Task { await self.appViewModel.applyNativeDNSIPv6(value) } })
        return VStack(alignment: .leading, spacing: T.space4) {
            HStack(spacing: T.space8) {
                self.settingsRowLabel(symbol: "network.badge.shield.half.filled", title: self.tr("ui.settings.dns_ipv6"))
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if self.appViewModel.isNativeDNSSaving {
                    ProgressView().controlSize(.mini)
                }
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!hasSnapshot || self.appViewModel.isNativeDNSSaving || self.appViewModel.isQuickRuleSaving || self.appViewModel.isCoreSettingSyncing)
            }
            Text(self.tr("ui.settings.dns_ipv6_hint"))
                .font(.app(size: T.FontSize.caption))
                .foregroundStyle(self.nativeSecondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 26)
        }
        .menuRowPadding(vertical: T.space6)
    }
}
