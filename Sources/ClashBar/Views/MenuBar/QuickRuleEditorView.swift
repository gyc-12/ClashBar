import AppKit
import SwiftUI

struct QuickRuleEditorView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    let context: QuickRuleEditorContext

    @State private var target: String
    @State private var type: QuickRuleType
    @State private var policy: String
    @State private var providerName = ""
    @State private var errorMessage: String?
    @State private var saved = false
    @State private var savedWhileRunning = false
    @State private var backupURL: URL?

    init(context: QuickRuleEditorContext) {
        self.context = context
        self._target = State(initialValue: context.target?.value ?? "")
        self._type = State(initialValue: context.target?.type ?? .domain)
        self._policy = State(initialValue: context.policies.first ?? "DIRECT")
    }

    private var provider: LocalRuleProvider? {
        self.context.providers.first { $0.name == self.providerName }
    }

    private var rule: QuickRoutingRule? {
        try? QuickRoutingRule(
            type: self.type,
            target: self.target,
            policy: self.provider?.policies.first ?? self.policy
        )
    }

    private var preview: String? {
        guard let rule else { return nil }
        if let provider { return try? provider.entry(for: rule) }
        return rule.line
    }

    var body: some View {
        ModalSheetContainer(title: self.tr("ui.quick_rule.title"), subtitle: self.context.configURL.lastPathComponent,
                            symbol: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: MenuBarLayoutTokens.space12) {
                if let notice = self.context.notice { self.note(notice) }
                VStack(alignment: .leading, spacing: 12) {
                    self.field(self.tr("ui.quick_rule.destination")) {
                        Picker(self.tr("ui.quick_rule.destination"), selection: self.$providerName) {
                            Text(self.tr("ui.quick_rule.native_rules")).tag("")
                            ForEach(self.context.providers) { provider in Text(provider.name).tag(provider.name) }
                        }.labelsHidden()
                    }
                    self.field(self.tr("ui.quick_rule.target")) {
                        TextField(self.tr("ui.quick_rule.target_placeholder"), text: self.$target)
                            .textFieldStyle(.roundedBorder).font(.appMono(size: MenuBarLayoutTokens.FontSize.callout))
                    }
                    self.field(self.tr("ui.quick_rule.type")) {
                        Picker(self.tr("ui.quick_rule.type"), selection: self.$type) {
                            ForEach(QuickRuleType.destinationTypes) { type in
                                Text(type.rawValue).tag(type).disabled(self.provider?.supports(type) == false)
                            }
                        }.labelsHidden()
                    }
                    self.field(self.tr("ui.quick_rule.policy")) {
                        if let provider {
                            Text(provider.policies.joined(separator: " / "))
                            self.note(self.tr("ui.quick_rule.provider_policy"))
                        } else {
                            Picker(self.tr("ui.quick_rule.policy"), selection: self.$policy) {
                                ForEach(self.context.policies, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden()
                        }
                    }
                    if self.type == .domainSuffix { self.note(self.tr("ui.quick_rule.suffix_hint")) }
                }
                .appSectionCard(padding: 12)
                .disabled(self.appViewModel.isQuickRuleSaving || self.saved)
                VStack(alignment: .leading, spacing: 10) {
                    self.field(self.tr("ui.quick_rule.preview")) {
                        Text(self.preview ?? self.tr("ui.quick_rule.error.target")).appCodeBlock()
                    }
                    self.note(self.tr(self.provider == nil ? "ui.quick_rule.native_hint" : "ui.quick_rule.provider_hint"))
                    if self.context.isSubscription {
                        SheetNote(text: self.tr("ui.quick_rule.subscription_hint"), tint: self.nativeWarning, symbol: "exclamationmark.triangle")
                    }
                    if self.appViewModel.currentMode != .rule { self.note(self.tr("ui.quick_rule.mode_hint")) }
                }
                .appSectionCard(padding: 12)
                if let errorMessage {
                    SheetNote(text: errorMessage, tint: self.nativeCritical, symbol: "exclamationmark.triangle")
                }
                if self.saved {
                    SheetNote(text: self.tr(self.savedWhileRunning ? "ui.quick_rule.saved" : "ui.native_rule.saved_file"),
                              tint: self.nativePositive, symbol: "checkmark.circle.fill")
                    if let backupURL {
                        Button(self.tr("ui.quick_rule.show_backup")) { NSWorkspace.shared.activateFileViewerSelecting([backupURL]) }
                            .font(.app(size: MenuBarLayoutTokens.FontSize.subheadline))
                    }
                }
            }
        } footer: {
            HStack(spacing: 8) {
                if self.appViewModel.isQuickRuleSaving { ProgressView().controlSize(.small) }
                Spacer()
                if self.saved {
                    Button(self.tr("ui.action.close")) { self.dismiss() }.keyboardShortcut(.defaultAction)
                        .appBorderedButtonStyle(prominent: true)
                } else {
                    Button(self.tr("ui.action.cancel")) { self.dismiss() }
                        .keyboardShortcut(.cancelAction).disabled(self.appViewModel.isQuickRuleSaving)
                        .appBorderedButtonStyle()
                    Button(self.tr(self.appViewModel.nativeRulesMatchRuntime ? "ui.quick_rule.save" : "ui.native_rule.save_file")) { self.save() }
                        .keyboardShortcut(.defaultAction)
                        .appBorderedButtonStyle(prominent: true)
                        .disabled(self.preview == nil || !self.appViewModel.canEditQuickRules)
                }
            }
        }
        .interactiveDismissDisabled(self.appViewModel.isQuickRuleSaving)
        .onChange(of: self.target) { text in
            guard let target = QuickRuleTarget.parse(text) else { return }
            if target.type.isIP || self.type.isIP { self.type = target.type }
        }
        .onChange(of: self.providerName) { _ in
            if let provider, !provider.supports(self.type) {
                self.type = provider.behavior == "ipcidr" ? .ipv4 : .domain
            }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        SheetField(title: label, content: content)
    }

    private func note(_ text: String) -> some View { SheetNote(text: text) }

    private func save() {
        guard let rule else { return }
        self.errorMessage = nil
        Task {
            do {
                self.savedWhileRunning = self.appViewModel.processManager.isRunning
                self.backupURL = try await self.appViewModel.saveQuickRule(
                    rule,
                    context: self.context,
                    providerName: self.providerName.isEmpty ? nil : self.providerName
                )
                self.savedWhileRunning = self.appViewModel.lastRuleSaveApplied
                self.saved = true
            } catch {
                self.errorMessage = self.appViewModel.quickRuleErrorText(error)
            }
        }
    }
}

struct QuickRuleContextMenu: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    let targets: [QuickRuleTarget]

    var body: some View {
        if !self.targets.isEmpty {
            Divider()
            Menu(self.tr("ui.quick_rule.add")) {
                if self.appViewModel.isRemoteTarget {
                    Text(self.tr("ui.quick_rule.local_only"))
                } else {
                    ForEach(self.targets) { target in
                        Button("\(target.value) · \(target.type.rawValue)") {
                            self.appViewModel.openQuickRuleEditor(target: target)
                        }
                        .disabled(!self.appViewModel.canEditQuickRules)
                    }
                }
            }
        }
    }
}
