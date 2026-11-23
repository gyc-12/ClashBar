import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ApplicationRuleEditorView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    let context: ApplicationRuleEditorContext
    private let loadCatalog: Bool
    @State private var applications: [ApplicationRoutingCandidate]
    @State private var selected: ApplicationRoutingCandidate?
    @State private var source: Int
    @State private var search = ""
    @State private var loading = false
    @State private var choosingFile = false
    @State private var choosingPolicy = false
    @State private var type: QuickRuleType
    @State private var target: String
    @State private var policy: String
    @State private var enableProcessLookup: Bool
    @State private var error: String?
    @State private var result: NativeRuleSaveResult?

    init(context: ApplicationRuleEditorContext, applications: [ApplicationRoutingCandidate]? = nil) {
        self.context = context
        self.loadCatalog = applications == nil
        self._applications = State(initialValue: applications ?? [])
        self._selected = State(initialValue: context.selected)
        self._source = State(initialValue: context.selected == nil ? 0 : 1)
        let type = context.selected?.preferredType ?? .processPath
        self._type = State(initialValue: type)
        self._target = State(initialValue: context.selected?.target(for: type) ?? "")
        self._policy = State(initialValue: "DIRECT")
        self._enableProcessLookup = State(initialValue: context.processMode == "off" || context.fileProcessMode == "off")
    }

    private var rule: QuickRoutingRule? { try? QuickRoutingRule(type: self.type, target: self.target, policy: self.policy) }
    private var needsProcessLookup: Bool { self.context.processMode == "off" || self.context.fileProcessMode == "off" }
    private var canSave: Bool {
        self.rule != nil && (!self.needsProcessLookup || self.enableProcessLookup) && self.appViewModel.canEditQuickRules
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(self.tr("ui.app_rule.title"), systemImage: "app.badge").font(.headline)
            Text(self.context.document.configURL.lastPathComponent).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    self.applicationPicker
                    self.ruleFields
                    self.notes
                }.disabled(self.appViewModel.isQuickRuleSaving || self.result != nil)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            self.footer
        }.padding(20).frame(width: 460, height: 690)
        .interactiveDismissDisabled(self.appViewModel.isQuickRuleSaving)
        .task {
            guard self.loadCatalog else { return }
            self.loading = true
            let applications = await ApplicationCatalogService().applications()
            guard !Task.isCancelled else { return }
            self.applications = applications
            self.loading = false
        }
        .onChange(of: self.type) { type in
            self.target = self.selected?.target(for: type) ?? ""
        }
        .fileImporter(isPresented: self.$choosingFile, allowedContentTypes: [.applicationBundle]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let application = try ApplicationCatalogService.application(at: url)
                if !self.applications.contains(where: { $0.id == application.id }) { self.applications.insert(application, at: 0) }
                self.source = 0
                self.search = ""
                self.select(application)
            } catch { self.error = self.appViewModel.quickRuleErrorText(error) }
        }
    }

    private var applicationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(self.tr("ui.app_rule.source"), selection: self.$source) {
                    Text(self.tr("ui.app_rule.installed")).tag(0)
                    Text(self.tr("ui.app_rule.observed")).tag(1)
                }.pickerStyle(.segmented).labelsHidden()
                Button { self.choosingFile = true } label: { Image(systemName: "folder") }
                    .help(self.tr("ui.app_rule.choose_application"))
                    .accessibilityLabel(self.tr("ui.app_rule.choose_application"))
            }
            TextField(self.tr("ui.app_rule.search"), text: self.$search).textFieldStyle(.roundedBorder)
            let candidates = (self.source == 0 ? self.applications : self.context.observed).filter { $0.matches(self.search) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(candidates) { candidate in
                        Button { self.select(candidate) } label: {
                            HStack(spacing: 8) {
                                if let path = candidate.bundlePath {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 24, height: 24)
                                } else { Image(systemName: "terminal").frame(width: 24) }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.name).font(.system(size: 12)).lineLimit(1)
                                    Text(candidate.processPath ?? candidate.processName).font(.system(size: 10))
                                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                if self.selected?.id == candidate.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }.padding(6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .background(self.selected?.id == candidate.id ? Color.accentColor.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    if candidates.isEmpty {
                        if self.loading && self.source == 0 { ProgressView().controlSize(.small) }
                        else { self.note(self.tr(self.source == 0 ? "ui.app_rule.empty_installed" : "ui.app_rule.empty_observed")) }
                    }
                }
            }.frame(height: 150)
        }
    }

    private var ruleFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            self.field(self.tr("ui.app_rule.match")) {
                Picker(self.tr("ui.app_rule.match"), selection: self.$type) {
                    Text(self.tr("ui.app_rule.path")).tag(QuickRuleType.processPath)
                    Text(self.tr("ui.app_rule.name")).tag(QuickRuleType.processName)
                }.pickerStyle(.segmented).labelsHidden()
            }
            TextField(self.tr(self.type == .processPath ? "ui.app_rule.path_placeholder" : "ui.app_rule.name_placeholder"),
                text: Binding(get: { self.target }, set: { self.target = $0; self.selected = nil }))
                .textFieldStyle(.roundedBorder)
            self.note(self.tr(self.type == .processPath ? "ui.app_rule.path_hint" : "ui.app_rule.name_hint"))
            self.field(self.tr("ui.quick_rule.policy")) {
                Button { self.choosingPolicy = true } label: {
                    HStack { Text(self.policy); Spacer(); Image(systemName: "chevron.up.chevron.down") }
                }.popover(isPresented: self.$choosingPolicy) {
                    RuleTargetPickerView(targets: self.context.document.policies, selected: self.policy) { policy in
                        self.policy = policy
                        self.choosingPolicy = false
                    }.environmentObject(self.appViewModel)
                }
            }
            self.field(self.tr("ui.quick_rule.preview")) {
                Text(self.rule?.line ?? self.tr("ui.app_rule.error.process"))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            Toggle(self.tr("ui.app_rule.enable_lookup"), isOn: self.$enableProcessLookup)
            self.note(self.tr("ui.app_rule.lookup_state", self.context.fileProcessMode, self.context.processMode))
            if self.needsProcessLookup && !self.enableProcessLookup {
                Text(self.tr("ui.app_rule.error.disabled")).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            self.note(self.tr("ui.app_rule.capture_hint"))
            self.note(self.tr("ui.quick_rule.native_hint"))
            if self.appViewModel.currentMode != .rule { self.note(self.tr("ui.quick_rule.mode_hint")) }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if self.context.isSubscription && self.result == nil {
                Label(self.tr("ui.quick_rule.subscription_hint"), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let result {
                Label(self.tr(result.applied ? "ui.native_rule.saved" : "ui.native_rule.saved_file"), systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
                if let backup = result.backupURL {
                    Button(self.tr("ui.quick_rule.show_backup")) { NSWorkspace.shared.activateFileViewerSelecting([backup]) }.font(.caption)
                }
            }
            HStack {
                Spacer()
                if self.result != nil {
                    Button(self.tr("ui.action.close")) { self.dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(self.tr("ui.action.cancel")) { self.dismiss() }.keyboardShortcut(.cancelAction)
                        .disabled(self.appViewModel.isQuickRuleSaving)
                    Button(self.tr(self.appViewModel.nativeRulesMatchRuntime ? "ui.quick_rule.save" : "ui.native_rule.save_file")) { self.save() }
                        .keyboardShortcut(.defaultAction).disabled(!self.canSave)
                    if self.appViewModel.isQuickRuleSaving { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    private func select(_ candidate: ApplicationRoutingCandidate) {
        self.selected = candidate
        self.type = candidate.preferredType
        self.target = candidate.target(for: candidate.preferredType)
        self.error = nil
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); content() }
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func save() {
        guard let rule else { return }
        self.error = nil
        Task {
            do { self.result = try await self.appViewModel.saveApplicationRule(rule, context: self.context,
                                                                            enableProcessLookup: self.enableProcessLookup) }
            catch { self.error = self.appViewModel.quickRuleErrorText(error) }
        }
    }
}
