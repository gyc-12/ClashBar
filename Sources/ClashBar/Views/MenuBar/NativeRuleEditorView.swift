import AppKit
import SwiftUI

struct NativeRuleEditorView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    let context: NativeRuleEditorContext
    @State private var raw: String
    @State private var isCustom: Bool
    @State private var rawMode: Bool
    @State private var choosingPolicy = false
    @State private var error: String?
    @State private var result: NativeRuleSaveResult?

    init(context: NativeRuleEditorContext) {
        self.context = context
        self._raw = State(initialValue: context.entry.raw)
        self._isCustom = State(initialValue: context.entry.isCustom)
        let syntax = context.entry.syntax
        self._rawMode = State(initialValue: syntax == nil || !NativeRuleSyntax.types.contains(syntax?.type ?? ""))
    }

    private var syntax: NativeRuleSyntax? { NativeRuleSyntax(raw: self.raw) }
    private var targets: [String] {
        self.syntax?.targetsSubRule == true ? self.context.document.subRuleNames : self.context.document.policies
    }

    var body: some View {
        ModalSheetContainer(title: self.tr("ui.native_rule.edit"),
                            subtitle: "\(self.context.document.configURL.lastPathComponent) · #\(self.context.entry.index + 1)",
                            symbol: "pencil", height: MenuBarLayoutTokens.Sheet.tallHeight) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(self.tr("ui.native_rule.raw_mode"), isOn: self.$rawMode)
                    if self.rawMode || self.syntax == nil {
                        self.field(self.tr("ui.native_rule.raw")) {
                            TextEditor(text: self.$raw).scrollContentBackground(.hidden)
                                .frame(height: 96).appCodeBlock()
                        }
                        self.note(self.tr("ui.native_rule.raw_hint"))
                    } else if let syntax {
                        self.field(self.tr("ui.quick_rule.type")) {
                            Picker(self.tr("ui.quick_rule.type"),
                                   selection: Binding(get: { syntax.type }, set: { self.update(type: $0) })) {
                                ForEach(NativeRuleSyntax.types, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden()
                        }
                        if syntax.type != "MATCH" {
                            self.field(self.tr(syntax.type == "RULE-SET" ? "ui.native_rule.provider" : "ui.native_rule.condition")) {
                                if syntax.type == "RULE-SET" {
                                    Picker(self.tr("ui.native_rule.provider"),
                                           selection: Binding(get: { syntax.payload }, set: { self.update(payload: $0) })) {
                                        ForEach(Array(Set(self.context.document.providerNames + [syntax.payload])).sorted(), id: \.self) { Text($0).tag($0) }
                                    }.labelsHidden()
                                } else {
                                    TextField(self.tr("ui.native_rule.condition"),
                                              text: Binding(get: { syntax.payload }, set: { self.update(payload: $0) }))
                                        .textFieldStyle(.roundedBorder).font(.appMono(size: MenuBarLayoutTokens.FontSize.callout))
                                }
                            }
                        }
                        self.field(self.tr(syntax.targetsSubRule ? "ui.native_rule.subrule" : "ui.quick_rule.policy")) {
                            Button { self.choosingPolicy = true } label: {
                                HStack { Text(syntax.target); Spacer(); Image(systemName: "chevron.up.chevron.down") }
                            }
                            .appBorderedButtonStyle()
                            .popover(isPresented: self.$choosingPolicy) {
                                RuleTargetPickerView(targets: self.targets, selected: syntax.target) { target in
                                    self.raw = (try? syntax.replacingTarget(target)) ?? self.raw
                                    self.choosingPolicy = false
                                }.environmentObject(self.appViewModel)
                            }
                        }
                        if syntax.supportsNoResolve { Toggle("no-resolve", isOn: self.optionBinding("no-resolve")) }
                        if syntax.supportsSource { Toggle("src", isOn: self.optionBinding("src")) }
                        if syntax.type == "RULE-SET" { self.note(self.tr("ui.native_rule.ruleset_hint")) }
                        if syntax.targetsSubRule { self.note(self.tr("ui.native_rule.subrule_hint")) }
                    }
                }
                .appSectionCard(padding: 12)
                .disabled(self.appViewModel.isQuickRuleSaving || self.result != nil)
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(self.tr("ui.native_rule.custom"), isOn: self.$isCustom)
                        .disabled(self.appViewModel.isQuickRuleSaving || self.result != nil)
                    self.note(self.tr("ui.native_rule.custom_hint"))
                    self.field(self.tr("ui.quick_rule.preview")) { Text(self.raw).appCodeBlock() }
                    self.note(self.tr(self.appViewModel.nativeRulesMatchRuntime ? "ui.native_rule.apply_hint" : "ui.native_rule.file_hint"))
                    if self.context.isSubscription {
                        SheetNote(text: self.tr("ui.quick_rule.subscription_hint"), tint: self.nativeWarning, symbol: "exclamationmark.triangle")
                    }
                    if self.appViewModel.currentMode != .rule { self.note(self.tr("ui.quick_rule.mode_hint")) }
                }
                .appSectionCard(padding: 12)
                if let error { SheetNote(text: error, tint: self.nativeCritical, symbol: "exclamationmark.triangle") }
                if let result {
                    SheetNote(text: self.tr(result.applied ? "ui.native_rule.saved" : "ui.native_rule.saved_file"),
                              tint: self.nativePositive, symbol: "checkmark.circle.fill")
                    if let backup = result.backupURL {
                        Button(self.tr("ui.quick_rule.show_backup")) { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                            .font(.app(size: MenuBarLayoutTokens.FontSize.subheadline))
                    }
                }
            }
        } footer: {
            HStack(spacing: 8) {
                if self.appViewModel.isQuickRuleSaving { ProgressView().controlSize(.small) }
                Spacer()
                if self.result != nil {
                    Button(self.tr("ui.action.close")) { self.dismiss() }.keyboardShortcut(.defaultAction)
                        .appBorderedButtonStyle(prominent: true)
                } else {
                    Button(self.tr("ui.action.cancel")) { self.dismiss() }.keyboardShortcut(.cancelAction)
                        .appBorderedButtonStyle().disabled(self.appViewModel.isQuickRuleSaving)
                    Button(self.tr(self.appViewModel.nativeRulesMatchRuntime ? "ui.quick_rule.save" : "ui.native_rule.save_file")) { self.save() }
                        .keyboardShortcut(.defaultAction).appBorderedButtonStyle(prominent: true)
                        .disabled(self.raw.trimmed.isEmpty || !self.appViewModel.canEditQuickRules)
                }
            }
        }
        .interactiveDismissDisabled(self.appViewModel.isQuickRuleSaving)
    }

    private func update(type: String? = nil, payload: String? = nil, options: [String]? = nil) {
        guard let syntax else { return }
        let nextType = type ?? syntax.type
        let nextPayload = payload ?? (syntax.type == "MATCH" ? "example.com" : syntax.payload)
        var target = syntax.target
        if nextType == "SUB-RULE", !self.context.document.subRuleNames.contains(target) {
            target = self.context.document.subRuleNames.first ?? "sub-rule"
        }
        if nextType != "SUB-RULE", syntax.targetsSubRule { target = self.context.document.policies.first ?? "DIRECT" }
        var fields = nextType == "MATCH" ? [nextType, target] : [nextType, nextPayload, target]
        let available = NativeRuleSyntax(raw: fields.joined(separator: ","))
        fields += (options ?? syntax.options).filter {
            ($0 == "no-resolve" && available?.supportsNoResolve == true)
                || ($0 == "src" && available?.supportsSource == true)
        }
        self.raw = fields.joined(separator: ",")
    }

    private func optionBinding(_ option: String) -> Binding<Bool> {
        Binding(
            get: { self.syntax?.options.contains(option) == true },
            set: { enabled in
                var options = self.syntax?.options.filter { $0 != option } ?? []
                if enabled { options.append(option) }
                self.update(options: options)
            })
    }
    private func field<Content: View>(_ label: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        SheetField(title: label, content: content)
    }
    private func note(_ text: String) -> some View { SheetNote(text: text) }
    private func save() {
        self.error = nil
        Task {
            do {
                self.result = try await self.appViewModel.saveNativeRule(
                    document: self.context.document, entry: self.context.entry, raw: self.raw, isCustom: self.isCustom)
            } catch { self.error = self.appViewModel.quickRuleErrorText(error) }
        }
    }
}

/// Standard SwiftUI popovers support keyboard focus for the search field.
struct RuleTargetPickerView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    let targets: [String]
    let selected: String
    let onSelect: (String) -> Void
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.filterTextField(self.tr("ui.native_rule.search_policy"), text: self.$search)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(
                        self.targets.filter { self.search.isEmpty || $0.localizedStandardContains(self.search) },
                        id: \.self
                    ) { target in
                        Button {
                            self.onSelect(target)
                        } label: {
                            HStack {
                                Text(target).lineLimit(1)
                                Spacer()
                                if target == self.selected { Image(systemName: "checkmark") }
                            }.padding(6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(height: 220)
        }.font(.app(size: MenuBarLayoutTokens.FontSize.callout)).padding(12).frame(width: 260)
    }
}

struct NativeRulePolicyButton: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    let entry: NativeRuleEntry
    @State private var context: NativeRuleDocument?
    @State private var showing = false
    @State private var error: String?
    var body: some View {
        Button {
            self.context = self.appViewModel.nativeRuleDocument
            self.error = nil
            self.showing = true
        } label: {
            HStack(spacing: 3) {
                Text(self.entry.syntax?.target ?? "—").lineLimit(1).truncationMode(.tail)
                if self.appViewModel.nativeRuleSavingIndex == self.entry.index {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
            }.font(.app(size: MenuBarLayoutTokens.FontSize.subheadline)).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!self.appViewModel.canEditQuickRules)
            .help(self.tr("ui.native_rule.change_policy"))
            .popover(isPresented: self.$showing) {
                if let context, let syntax = self.entry.syntax {
                    VStack(alignment: .leading, spacing: 6) {
                        RuleTargetPickerView(
                            targets: syntax.targetsSubRule ? context.subRuleNames : context.policies,
                            selected: syntax.target
                        ) { target in
                            guard target != syntax.target else {
                                self.showing = false
                                return
                            }
                            Task {
                                do {
                                    let raw = try syntax.replacingTarget(target)
                                    _ = try await self.appViewModel.saveNativeRule(
                                        document: context, entry: self.entry, raw: raw, isCustom: self.entry.isCustom)
                                    self.showing = false
                                } catch { self.error = self.appViewModel.quickRuleErrorText(error) }
                            }
                        }.environmentObject(self.appViewModel).disabled(self.appViewModel.isQuickRuleSaving)
                        if let error { Text(error).font(.caption).foregroundStyle(.red).padding(12).frame(width: 260) }
                    }
                }
            }
    }
}
