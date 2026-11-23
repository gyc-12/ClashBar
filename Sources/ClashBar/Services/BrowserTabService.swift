import AppKit

@MainActor
struct BrowserTabService {
    enum CaptureError: Error {
        case unsupported, unavailable, denied
    }

    /// Only fixed, allowlisted application IDs are interpolated; page content never becomes script.
    nonisolated static func script(for bundleID: String) -> String? {
        let expression: String
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            expression = "URL of current tab of front window"
        case "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium",
            "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera":
            expression = "URL of active tab of front window"
        default: return nil
        }
        return """
            with timeout of 5 seconds
                tell application id "\(bundleID)"
                    if (count of windows) = 0 then return ""
                    return \(expression)
                end tell
            end timeout
            """
    }

    func capture(bundleID: String?) async throws -> QuickRuleTarget {
        guard let bundleID, let source = Self.script(for: bundleID) else { throw CaptureError.unsupported }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            throw CaptureError.unavailable
        }
        // NSAppleScript must execute on the main thread. Yield first to paint the busy state.
        await Task.yield()
        guard let script = NSAppleScript(source: source) else { throw CaptureError.unavailable }
        var details: NSDictionary?
        let output = script.executeAndReturnError(&details)
        if let details {
            if details[NSAppleScript.errorNumber] as? Int == -1743 { throw CaptureError.denied }
            throw CaptureError.unavailable
        }
        guard let url = output.stringValue, let scheme = URLComponents(string: url)?.scheme?.lowercased(),
            ["http", "https"].contains(scheme), let target = QuickRuleTarget.parse(url)
        else { throw CaptureError.unavailable }
        return target
    }
}
