import AppKit
import Foundation

@MainActor
extension AppViewModel {
    var canEditQuickRules: Bool {
        !self.isRemoteTarget && !self.isCoreActionProcessing && !self.isReadingBrowser
            && self.configService.selectedConfig != nil
    }

    var quickRuleService: QuickRuleService {
        QuickRuleService(homeDirectory: self.workingDirectoryManager.rootDirectoryURL)
    }

    func rememberBrowserSource() {
        let application = NSWorkspace.shared.frontmostApplication
        if application?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            self.browserSourceBundleID = application?.bundleIdentifier
        }
    }

    func openBrowserQuickRule() async {
        guard self.canEditQuickRules else { return }
        let selected = self.configService.selectedConfig
        self.rememberBrowserSource()
        self.isReadingBrowser = true
        var target: QuickRuleTarget?
        var notice: String?
        do {
            target = try await BrowserTabService().capture(bundleID: self.browserSourceBundleID)
        } catch {
            if case BrowserTabService.CaptureError.denied = error {
                notice = self.tr("ui.quick_rule.browser.denied")
            } else if case BrowserTabService.CaptureError.unsupported = error {
                notice = self.tr("ui.quick_rule.browser.unsupported")
            } else {
                notice = self.tr("ui.quick_rule.browser.unavailable")
            }
        }
        self.isReadingBrowser = false
        guard selected == self.configService.selectedConfig else { return }
        self.openQuickRuleEditor(target: target, notice: notice)
    }

    func openQuickRuleEditor(target: QuickRuleTarget? = nil, notice: String? = nil) {
        guard self.canEditQuickRules, let config = self.configService.selectedConfig else { return }
        do {
            let data = try Data(contentsOf: config)
            self.quickRuleEditorContext = QuickRuleEditorContext(
                configURL: config,
                target: target,
                policies: try self.quickRuleService.policies(in: data),
                originalConfig: data,
                providers: try self.quickRuleService.localProviders(in: data, configURL: config),
                isSubscription: self.remoteConfigSubscriptions[config.lastPathComponent] != nil,
                notice: notice
            )
        } catch {
            self.runModalAlert(
                style: .warning,
                message: self.tr("ui.quick_rule.title"),
                informative: self.quickRuleErrorText(error),
                buttons: [self.tr("ui.action.ok")]
            )
        }
    }

    func saveQuickRule(_ rule: QuickRoutingRule, context: QuickRuleEditorContext, providerName: String?) async throws
        -> URL?
    {
        guard self.canEditQuickRules, self.isSelectedRoutingConfig(context.configURL),
            !self.isCoreSettingSyncing, !self.isTunSyncing
        else { throw QuickRuleError.contextChanged }
        self.isQuickRuleSaving = true
        defer { self.isQuickRuleSaving = false }
        let service = self.quickRuleService
        let edit = try service.prepare(rule: rule, context: context, providerName: providerName)
        let document = try self.nativeRuleService.read(configURL: context.configURL, data: context.originalConfig)
        let result = try await self.commitRoutingRuleEdit(edit, document: document)
        self.refreshNativeRuleDocument()
        self.appendLog(
            level: "info",
            message: self.tr("ui.quick_rule.saved_log", rule.target, edit.targetURL.lastPathComponent)
        )
        return result.backupURL
    }

    func quickRuleErrorText(_ error: Error) -> String {
        if let applicationError = error as? ApplicationRoutingError {
            switch applicationError {
            case .invalidApplication: return self.tr("ui.app_rule.error.application")
            case .invalidProcess: return self.tr("ui.app_rule.error.process")
            case .processLookupDisabled: return self.tr("ui.app_rule.error.disabled")
            }
        }
        guard let ruleError = error as? QuickRuleError else { return error.localizedDescription }
        switch ruleError {
        case .invalidTarget: return self.tr("ui.quick_rule.error.target")
        case .invalidRuleText: return self.tr("ui.native_rule.error.raw")
        case .invalidPolicy: return self.tr("ui.quick_rule.error.policy")
        case .invalidConfig: return self.tr("ui.quick_rule.error.config")
        case .contextChanged: return self.tr("ui.quick_rule.error.changed")
        case .recoveryFailed(let path): return self.tr("ui.quick_rule.error.recovery", path)
        }
    }
}
