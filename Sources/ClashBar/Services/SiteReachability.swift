import Foundation

enum ReachabilitySite: String, CaseIterable, Identifiable, Sendable {
    case gemini = "Gemini"
    case chatGPTRegion = "ChatGPTRegion"
    case chatGPT = "ChatGPT"
    case youtube = "YouTube"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .gemini: "Gemini"
        case .chatGPTRegion, .chatGPT: "ChatGPT"
        case .youtube: "YouTube"
        }
    }

    var url: String {
        switch self {
        case .gemini: GeminiRegionProbe.url
        case .chatGPTRegion, .chatGPT: GeminiRegionProbe.chatGPTURL
        case .youtube: "https://www.youtube.com/"
        }
    }

    func check(group: String?, client: any MihomoAPITransporting, proxyHost: String?) async -> SiteCheckResult {
        switch self {
        case .gemini:
            return await GeminiRegionProbe.check(client: client, host: proxyHost)
        case .chatGPTRegion:
            return await GeminiRegionProbe.checkChatGPT(client: client, host: proxyHost)
        case .chatGPT, .youtube:
            guard let group else { return .controllerError }
            do {
                let response: DelayMeasurement = try await client.request(
                    .proxyDelay(name: group, url: url, timeout: 8000, expected: "200-399"))
                guard let delay = response.value, delay > 0 else { return .unreachable }
                return .reachable(delay)
            } catch APIError.statusCode(504, _) { return .timeout }
            catch APIError.statusCode(503, _) { return .unreachable }
            catch { return .controllerError }
        }
    }
}

enum SiteCheckResult: Equatable, Sendable {
    case reachable(Int), timeout, unreachable, controllerError
    case regionSupported(String), regionRestricted(String?), indeterminate, proxyUnavailable, proxyAuthRequired
}
