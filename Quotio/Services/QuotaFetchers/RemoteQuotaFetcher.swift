//
//  RemoteQuotaFetcher.swift
//  Quotio
//
//  Fetches provider quotas for credentials that live on a remote CLIProxyAPI.
//  Tokens never leave the server: each upstream usage request goes through
//  POST /v0/management/api-call, which substitutes `$TOKEN$` for the
//  credential selected by `auth_index` (refreshing it server-side when needed).
//

import Foundation

nonisolated enum RemoteQuotaFetcher {
    static let claudeUsageURL = "https://api.anthropic.com/api/oauth/usage"
    static let codexUsageURL = "https://chatgpt.com/backend-api/wham/usage"

    static let supportedProviders: Set<AIProvider> = [.claude, .codex, .antigravity]

    /// Upstream usage requests for one credential, tried in order until one parses.
    static func requests(for file: AuthFile) -> [APICallRequest] {
        guard let authIndex = file.authIndex, !authIndex.isEmpty,
              let provider = file.providerType else { return [] }

        switch provider {
        case .claude:
            return [APICallRequest(
                authIndex: authIndex,
                method: "GET",
                url: claudeUsageURL,
                header: [
                    "Authorization": "Bearer $TOKEN$",
                    "Accept": "application/json",
                    "anthropic-beta": "oauth-2025-04-20",
                    "User-Agent": "claude-code/2.1.69",
                ],
                data: nil
            )]
        case .codex:
            var header = [
                "Authorization": "Bearer $TOKEN$",
                "Accept": "application/json",
            ]
            if let accountId = file.idToken?.chatgptAccountId, !accountId.isEmpty {
                header["ChatGPT-Account-Id"] = accountId
            }
            return [APICallRequest(authIndex: authIndex, method: "GET", url: codexUsageURL, header: header, data: nil)]
        case .antigravity:
            let header = [
                "Authorization": "Bearer $TOKEN$",
                "Content-Type": "application/json",
                "User-Agent": AntigravityQuotaFetcher.userAgent,
            ]
            let body = antigravityBody(projectId: file.projectId)
            return [
                APICallRequest(authIndex: authIndex, method: "POST", url: AntigravityQuotaFetcher.quotaSummaryAPIURL, header: header, data: body),
                APICallRequest(authIndex: authIndex, method: "POST", url: AntigravityQuotaFetcher.quotaAPIURL, header: header, data: body),
            ]
        default:
            return []
        }
    }

    /// Maps an `/api-call` response to quota data. Returns `isForbidden` data for
    /// 401/403 so the account shows as needing attention instead of disappearing.
    static func quota(for file: AuthFile, request: APICallRequest, response: APICallResponse) -> ProviderQuotaData? {
        if response.statusCode == 401 || response.statusCode == 403 {
            return ProviderQuotaData(isForbidden: true)
        }
        guard 200...299 ~= response.statusCode,
              let data = response.body?.data(using: .utf8) else { return nil }

        switch file.providerType {
        case .claude:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String != "error" else { return nil }
            let info = ClaudeCodeQuotaInfo(
                accessToken: nil,
                email: file.email,
                fiveHour: ClaudeCodeQuotaFetcher.parseQuotaUsage(from: json["five_hour"] as? [String: Any]),
                sevenDay: ClaudeCodeQuotaFetcher.parseQuotaUsage(from: json["seven_day"] as? [String: Any]),
                sevenDaySonnet: ClaudeCodeQuotaFetcher.parseQuotaUsage(from: json["seven_day_sonnet"] as? [String: Any]),
                sevenDayOpus: ClaudeCodeQuotaFetcher.parseQuotaUsage(from: json["seven_day_opus"] as? [String: Any]),
                extraUsage: ClaudeCodeQuotaFetcher.parseExtraUsage(from: json["extra_usage"] as? [String: Any])
            )
            return ClaudeCodeQuotaFetcher.quotaData(from: info)
        case .codex:
            return try? CodexUsageMapper.map(
                data: data,
                identity: CodexQuotaIdentity(planType: file.idToken?.planType)
            )
        case .antigravity:
            if request.url == AntigravityQuotaFetcher.quotaSummaryAPIURL {
                guard let models = AntigravityQuotaFetcher.parseQuotaSummaryModels(from: data),
                      !models.isEmpty else { return nil }
                return ProviderQuotaData(models: models)
            }
            guard let models = try? AntigravityQuotaFetcher.parseAvailableModels(from: data) else { return nil }
            return ProviderQuotaData(models: models)
        default:
            return nil
        }
    }

    /// Fetches quotas for every supported, enabled credential, keyed by provider
    /// and `AuthFile.quotaLookupKey` (the same key the Quota screen and menu bar use).
    static func fetchAll(files: [AuthFile], client: ManagementAPIClient) async -> [AIProvider: [String: ProviderQuotaData]] {
        let targets = files.filter { file in
            guard let provider = file.providerType else { return false }
            return supportedProviders.contains(provider) && !file.disabled
        }

        return await withTaskGroup(of: (AIProvider, String, ProviderQuotaData?).self) { group in
            for file in targets {
                group.addTask {
                    (file.providerType!, file.quotaLookupKey, await fetch(file: file, client: client))
                }
            }
            var results: [AIProvider: [String: ProviderQuotaData]] = [:]
            for await (provider, key, quota) in group {
                if let quota {
                    results[provider, default: [:]][key] = quota
                }
            }
            return results
        }
    }

    /// Claude limits from the `Anthropic-Ratelimit-Unified-*` headers the proxy recorded on the
    /// account's own inference traffic. Anthropic rate-limits `/api/oauth/usage` aggressively,
    /// so this is preferred over an extra upstream call.
    static func observedClaudeQuota(for file: AuthFile, maxAge: TimeInterval, now: Date = Date()) -> ProviderQuotaData? {
        guard file.providerType == .claude,
              let observation = file.quota,
              let signals = observation.signals,
              let observedAt = observation.observedAt.flatMap(parseDate),
              now.timeIntervalSince(observedAt) <= maxAge else { return nil }

        func window(_ name: String, _ prefix: String) -> ModelQuota? {
            guard let used = signals["Anthropic-Ratelimit-Unified-\(prefix)-Utilization"].flatMap(Double.init) else { return nil }
            let reset = signals["Anthropic-Ratelimit-Unified-\(prefix)-Reset"]
                .flatMap(TimeInterval.init)
                .map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) } ?? ""
            return ModelQuota(name: name, percentage: max(0, min(100, 100 - used * 100)), resetTime: reset)
        }

        let models = [window("five-hour-session", "5h"), window("seven-day-weekly", "7d")].compactMap { $0 }
        guard !models.isEmpty else { return nil }
        let rejected = signals["Anthropic-Ratelimit-Unified-Status"] == "rejected"
        return ProviderQuotaData(models: models, lastUpdated: observedAt, isForbidden: rejected)
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// Observations older than this fall back to an active usage request.
    static let observationMaxAge: TimeInterval = 6 * 60 * 60

    /// Minimum gap between active Claude usage requests for one credential, and the backoff
    /// after a 429 when the upstream sends no Retry-After.
    static let claudeUsageMinInterval: TimeInterval = 15 * 60

    /// Next time an active Claude usage request is allowed, per auth_index.
    private static let claudeBackoff = ClaudeUsageBackoff()

    static func fetch(file: AuthFile, client: ManagementAPIClient, force: Bool = false) async -> ProviderQuotaData? {
        if var observed = observedClaudeQuota(for: file, maxAge: observationMaxAge) {
            observed.accountDisplayName = file.email
            return observed
        }
        let isClaude = file.providerType == .claude
        let backoffKey = file.authIndex ?? file.name
        if isClaude, !force, !claudeBackoff.allows(backoffKey) {
            return nil
        }
        for request in requests(for: file) {
            do {
                let response = try await client.apiCall(request)
                if isClaude {
                    claudeBackoff.record(backoffKey, response: response, minInterval: claudeUsageMinInterval)
                    if response.statusCode == 429 {
                        Log.quota("Claude usage endpoint rate-limited; keeping previous quota")
                        return nil
                    }
                }
                if var quota = quota(for: file, request: request, response: response) {
                    quota.accountDisplayName = quota.accountDisplayName ?? file.email
                    return quota
                }
            } catch {
                Log.quota("Remote quota request failed for \(file.providerType?.rawValue ?? file.provider): \(error.localizedDescription)")
            }
        }
        return nil
    }

    private static func antigravityBody(projectId: String?) -> String {
        guard let projectId, !projectId.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["project": projectId]),
              let body = String(data: data, encoding: .utf8) else { return "{}" }
        return body
    }
}

/// Tracks when the next active Claude usage request is allowed per credential.
nonisolated final class ClaudeUsageBackoff: @unchecked Sendable {
    private let lock = NSLock()
    private var nextAllowed: [String: Date] = [:]

    func allows(_ key: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (nextAllowed[key] ?? .distantPast) <= now
    }

    func record(_ key: String, response: APICallResponse, minInterval: TimeInterval, now: Date = Date()) {
        var wait = minInterval
        if response.statusCode == 429,
           let retryAfter = response.header?.first(where: { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame })?
               .value.first.flatMap(TimeInterval.init) {
            wait = max(wait, retryAfter)
        }
        lock.lock(); defer { lock.unlock() }
        nextAllowed[key] = now.addingTimeInterval(wait)
    }
}
