import SwiftUI

private typealias T = MenuBarLayoutTokens

extension MenuBarRootView {
    var modeAndTabSection: some View {
        VStack(spacing: T.space8) {
            self.modeSwitcher
            self.topTabs
        }
        .padding(.bottom, T.space2)
        .frame(maxWidth: .infinity)
    }

    var modeSwitcher: some View {
        HStack(spacing: T.space2) {
            self.modeSegmentButton(title: tr("ui.mode.rule"), mode: .rule, symbol: "shield.lefthalf.filled")
            self.modeSegmentButton(title: tr("ui.mode.global"), mode: .global, symbol: "globe")
            self.modeSegmentButton(title: tr("ui.mode.direct"), mode: .direct, symbol: "bolt.fill")
        }
        .padding(3)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04),
                    in: RoundedRectangle(cornerRadius: T.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("ui.navigation.mode"))
    }

    func modeSegmentButton(title: String, mode: CoreMode, symbol: String) -> some View {
        let selected = appViewModel.currentMode == mode
        let hovered = hoveredMode == mode

        return Button {
            guard appViewModel.isModeSwitchEnabled, switchingMode == nil, !selected else { return }
            switchingMode = mode
            Task { @MainActor in
                await appViewModel.switchMode(to: mode)
                switchingMode = nil
            }
        } label: {
            HStack(spacing: T.space6) {
                if switchingMode == mode {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                } else {
                    Image(systemName: symbol)
                        .foregroundStyle(selected ? nativeAccent : nativeSecondaryLabel)
                        .accessibilityHidden(true)
                }
                Text(title).lineLimit(1)
            }
            .font(.app(size: T.FontSize.callout, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? nativePrimaryLabel : nativeSecondaryLabel)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background {
                let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                if selected {
                    shape.fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.white)
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.08 : 0.10), radius: 2, y: 1)
                        .matchedGeometryEffect(id: "mode-selection", in: segmentedSelectionNamespace)
                } else if hovered {
                    shape.fill(Color.primary.opacity(0.04))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!appViewModel.isModeSwitchEnabled || switchingMode != nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hoveredMode = self.nextHovered(current: hoveredMode, target: mode, isHovering: $0) }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: appViewModel.currentMode)
    }

    var topTabs: some View {
        HStack(spacing: T.space2) {
            ForEach(RootTab.allCases, id: \.self) { tab in
                self.tabSegmentButton(tab)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("ui.navigation.pages"))
    }

    func tabSegmentButton(_ tab: RootTab) -> some View {
        let selected = rootViewModel.currentTab == tab
        let hovered = hoveredTab == tab

        return Button {
            guard !selected else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                rootViewModel.syncCurrentTab(tab)
            }
        } label: {
            HStack(spacing: T.space4) {
                Image(systemName: tab.symbolName)
                    .font(.app(size: T.FontSize.caption, weight: .medium))
                    .accessibilityHidden(true)
                Text(tr(tab.titleKey))
                    .font(.app(size: T.FontSize.subheadline, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? nativeAccent : nativeSecondaryLabel)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, T.space6)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background {
                let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                if selected {
                    shape.fill(nativeAccent.opacity(colorScheme == .dark ? 0.18 : 0.10))
                        .matchedGeometryEffect(id: "tab-selection", in: segmentedSelectionNamespace)
                } else if hovered {
                    shape.fill(Color.primary.opacity(0.04))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr(tab.titleKey))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hoveredTab = self.nextHovered(current: hoveredTab, target: tab, isHovering: $0) }
    }
}
