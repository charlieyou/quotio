import XCTest
@testable import Quotio

/// Remote Proxy mode reads quotas for credentials stored on a remote CLIProxyAPI
/// through POST /v0/management/api-call. These tests pin the request each
/// provider sends and how the proxied upstream response becomes quota data.
final class RemoteQuotaFetcherTests: XCTestCase {
    private func authFile(_ json: String) throws -> AuthFile {
        try JSONDecoder().decode(AuthFilesResponse.self, from: Data(#"{"files":[\#(json)]}"#.utf8)).files[0]
    }

    func testDecodesRemoteAuthFileFieldsFromManagementAPI() throws {
        let file = try authFile(#"""
        {"id":"codex-a@example.com-pro.json","auth_index":"7f3a","name":"codex-a@example.com-pro.json",
         "type":"codex","provider":"codex","status":"active","disabled":false,"unavailable":false,
         "email":"a@example.com","project_id":"proj-1",
         "id_token":{"chatgpt_account_id":"acct-123","plan_type":"pro"},
         "quota":{"signals":{}},"success":3,"failed":0}
        """#)
        XCTAssertEqual(file.authIndex, "7f3a")
        XCTAssertEqual(file.projectId, "proj-1")
        XCTAssertEqual(file.idToken?.chatgptAccountId, "acct-123")
        XCTAssertEqual(file.idToken?.planType, "pro")
    }

    func testUnexpectedIDTokenShapeDoesNotFailAuthFileList() throws {
        let file = try authFile(#"{"id":"x","name":"x.json","provider":"codex","status":"active","disabled":false,"unavailable":false,"id_token":"eyJ.raw.jwt"}"#)
        XCTAssertNil(file.idToken?.chatgptAccountId)
    }

    func testClaudeRequestUsesTokenPlaceholderAndOAuthBeta() throws {
        let file = try authFile(#"{"id":"c","auth_index":"11","name":"claude-a@example.com.json","provider":"claude","status":"active","disabled":false,"unavailable":false,"email":"a@example.com"}"#)
        let requests = RemoteQuotaFetcher.requests(for: file)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].authIndex, "11")
        XCTAssertEqual(requests[0].method, "GET")
        XCTAssertEqual(requests[0].url, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(requests[0].header?["Authorization"], "Bearer $TOKEN$")
        XCTAssertEqual(requests[0].header?["anthropic-beta"], "oauth-2025-04-20")
    }

    func testCodexRequestSendsAccountIDFromProxyClaims() throws {
        let file = try authFile(#"{"id":"x","auth_index":"22","name":"codex-a@example.com-pro.json","provider":"codex","status":"active","disabled":false,"unavailable":false,"id_token":{"chatgpt_account_id":"acct-9"}}"#)
        let request = try XCTUnwrap(RemoteQuotaFetcher.requests(for: file).first)
        XCTAssertEqual(request.url, "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(request.header?["ChatGPT-Account-Id"], "acct-9")
        XCTAssertEqual(request.header?["Authorization"], "Bearer $TOKEN$")
    }

    func testAntigravityRequestsPassProjectAndFallBackToAvailableModels() throws {
        let file = try authFile(#"{"id":"x","auth_index":"33","name":"antigravity-a@example.com.json","provider":"antigravity","status":"active","disabled":false,"unavailable":false,"project_id":"proj-7"}"#)
        let requests = RemoteQuotaFetcher.requests(for: file)
        XCTAssertEqual(requests.map(\.url), [
            AntigravityQuotaFetcher.quotaSummaryAPIURL,
            AntigravityQuotaFetcher.quotaAPIURL,
        ])
        let body = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(requests[0].data).utf8)) as? [String: String]
        XCTAssertEqual(body, ["project": "proj-7"])
    }

    func testCredentialWithoutAuthIndexIsSkipped() throws {
        let file = try authFile(#"{"id":"x","name":"claude-a.json","provider":"claude","status":"active","disabled":false,"unavailable":false}"#)
        XCTAssertTrue(RemoteQuotaFetcher.requests(for: file).isEmpty)
    }

    func testClaudeUsageBodyMapsToRemainingPercentages() throws {
        let file = try authFile(#"{"id":"c","auth_index":"11","name":"claude-a.json","provider":"claude","status":"active","disabled":false,"unavailable":false}"#)
        let request = try XCTUnwrap(RemoteQuotaFetcher.requests(for: file).first)
        let body = #"""
        {"five_hour":{"utilization":37,"resets_at":"2026-11-21T15:00:00Z"},"seven_day":{"utilization":81.5,"resets_at":"2026-11-25T00:00:00Z"},"seven_day_opus":null,
         "limits":[{"kind":"weekly_scoped","scope":{"model":{"display_name":"Claude Fable"}},"percent":30,"resets_at":"2026-11-26T00:00:00Z"},
                   {"kind":"session","scope":{"model":{"display_name":"Other"}},"percent":90}]}
        """#
        let quota = try XCTUnwrap(RemoteQuotaFetcher.quota(
            for: file, request: request,
            response: APICallResponse(statusCode: 200, header: nil, body: body)
        ))
        let byName = Dictionary(uniqueKeysWithValues: quota.models.map { ($0.name, $0.percentage) })
        XCTAssertEqual(byName["five-hour-session"], 63)
        XCTAssertEqual(byName["seven-day-weekly"], 18.5)
        XCTAssertNil(byName["seven-day-opus"])
        XCTAssertEqual(byName["seven-day-fable"], 70)
        XCTAssertNil(byName["seven-day-other"], "only weekly_scoped limits are model windows")
    }

    func testCodexUsageBodyMapsWindowsAndKeepsPlanFromClaims() throws {
        let file = try authFile(#"{"id":"x","auth_index":"22","name":"codex-a-pro.json","provider":"codex","status":"active","disabled":false,"unavailable":false,"id_token":{"plan_type":"pro"}}"#)
        let request = try XCTUnwrap(RemoteQuotaFetcher.requests(for: file).first)
        let body = #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000},"secondary_window":{"used_percent":75,"limit_window_seconds":604800}}}"#
        let quota = try XCTUnwrap(RemoteQuotaFetcher.quota(
            for: file, request: request,
            response: APICallResponse(statusCode: 200, header: nil, body: body)
        ))
        XCTAssertEqual(quota.planType, "pro")
        XCTAssertEqual(quota.models.map(\.percentage).sorted(), [25, 90])
    }

    func testAntigravityAvailableModelsBodyFiltersAndClamps() throws {
        let file = try authFile(#"{"id":"x","auth_index":"33","name":"antigravity-a.json","provider":"antigravity","status":"active","disabled":false,"unavailable":false}"#)
        let request = RemoteQuotaFetcher.requests(for: file)[1]
        let body = #"{"models":{"gemini-3-pro":{"quotaInfo":{"remainingFraction":1.4,"resetTime":"r"}},"chat_20706":{"quotaInfo":{"remainingFraction":0.1}}}}"#
        let quota = try XCTUnwrap(RemoteQuotaFetcher.quota(
            for: file, request: request,
            response: APICallResponse(statusCode: 200, header: nil, body: body)
        ))
        XCTAssertEqual(quota.models.map(\.name), ["gemini-3-pro"])
        XCTAssertEqual(quota.models.first?.percentage, 100)
    }

    func testUpstreamAuthFailureMarksAccountForbiddenAndServerErrorYieldsNothing() throws {
        let file = try authFile(#"{"id":"c","auth_index":"11","name":"claude-a.json","provider":"claude","status":"active","disabled":false,"unavailable":false}"#)
        let request = try XCTUnwrap(RemoteQuotaFetcher.requests(for: file).first)
        let forbidden = RemoteQuotaFetcher.quota(for: file, request: request, response: APICallResponse(statusCode: 401, header: nil, body: "{}"))
        XCTAssertEqual(forbidden?.isForbidden, true)
        XCTAssertNil(RemoteQuotaFetcher.quota(for: file, request: request, response: APICallResponse(statusCode: 500, header: nil, body: "{}")))
    }

    func testClaudeUsesProxyObservedRateLimitHeadersWithoutUpstreamCall() throws {
        let file = try authFile(#"""
        {"id":"c","auth_index":"11","name":"claude-a.json","provider":"claude","status":"active","disabled":false,"unavailable":false,
         "quota":{"observed_at":"2026-11-21T23:46:12.408051392+08:00","signals":{
           "Anthropic-Ratelimit-Unified-5h-Utilization":"0.28","Anthropic-Ratelimit-Unified-5h-Reset":"1795276800",
           "Anthropic-Ratelimit-Unified-7d-Utilization":"0.77","Anthropic-Ratelimit-Unified-7d-Reset":"1795300000",
           "Anthropic-Ratelimit-Unified-Status":"allowed_warning"}}}
        """#)
        let observedAt = ISO8601DateFormatter().date(from: "2026-11-21T15:46:12Z")!
        let quota = try XCTUnwrap(RemoteQuotaFetcher.observedClaudeQuota(for: file, maxAge: 3600, now: observedAt.addingTimeInterval(60)))
        let byName = Dictionary(uniqueKeysWithValues: quota.models.map { ($0.name, $0) })
        XCTAssertEqual(try XCTUnwrap(byName["five-hour-session"]).percentage, 72, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(byName["seven-day-weekly"]).percentage, 23, accuracy: 0.001)
        XCTAssertEqual(byName["seven-day-weekly"]?.resetTime, "2026-11-21T22:26:40Z")
        XCTAssertFalse(quota.isForbidden)

        XCTAssertNil(RemoteQuotaFetcher.observedClaudeQuota(for: file, maxAge: 3600, now: observedAt.addingTimeInterval(3601)))
    }

    func testClaudeFableWindowComesFromNewestFableModelObservation() throws {
        let file = try authFile(#"""
        {"id":"c","auth_index":"11","name":"claude-a.json","provider":"claude","status":"active","disabled":false,"unavailable":false,
         "quota":{"observed_at":"2026-11-21T15:46:12Z","signals":{"Anthropic-Ratelimit-Unified-7d-Utilization":"0.5","Anthropic-Ratelimit-Unified-Status":"rejected"}},
         "model_quotas":{
           "claude-fable-5-1":{"observed_at":"2026-11-20T10:00:00Z","signals":{"Anthropic-Ratelimit-Unified-7d_oi-Utilization":"0.10"}},
           "claude-fable-5-2":{"observed_at":"2026-11-21T15:00:00Z","signals":{"Anthropic-Ratelimit-Unified-7d_oi-Utilization":"1.01","Anthropic-Ratelimit-Unified-7d_oi-Reset":"1795300000"}},
           "claude-sonnet-5":{"observed_at":"2026-11-21T15:40:00Z","signals":{"Anthropic-Ratelimit-Unified-7d_oi-Utilization":"0.40"}}}}
        """#)
        let now = ISO8601DateFormatter().date(from: "2026-11-21T15:47:00Z")!
        let quota = try XCTUnwrap(RemoteQuotaFetcher.observedClaudeQuota(for: file, maxAge: 3600, now: now))
        let fable = try XCTUnwrap(quota.models.first { $0.name == "seven-day-fable" })
        XCTAssertEqual(fable.percentage, 0, "over-limit utilization clamps to 0% left")
        XCTAssertEqual(fable.resetTime, "2026-11-21T22:26:40Z")
        XCTAssertFalse(quota.isForbidden, "a rejected window is a limit, not an auth failure")
    }

    func testClaudeWindowsPastTheirResetAreFreshAndWeeklyResetRollsForward() throws {
        // Every window reset at 16:00Z; the last observation was at 15:59Z (before the reset).
        let file = try authFile(#"""
        {"id":"c","auth_index":"11","name":"claude-a.json","provider":"claude","status":"active","disabled":false,"unavailable":false,
         "quota":{"observed_at":"2026-11-21T15:59:00Z","signals":{
           "Anthropic-Ratelimit-Unified-5h-Utilization":"0.32","Anthropic-Ratelimit-Unified-5h-Reset":"1795276800",
           "Anthropic-Ratelimit-Unified-7d-Utilization":"0.78","Anthropic-Ratelimit-Unified-7d-Reset":"1795276800",
           "Anthropic-Ratelimit-Unified-7d_oi-Utilization":"1.0","Anthropic-Ratelimit-Unified-7d_oi-Reset":"1795276800"}}}
        """#)
        let now = ISO8601DateFormatter().date(from: "2026-11-21T16:21:00Z")!
        let quota = try XCTUnwrap(RemoteQuotaFetcher.observedClaudeQuota(for: file, maxAge: 3600, now: now))
        let byName = Dictionary(uniqueKeysWithValues: quota.models.map { ($0.name, $0) })
        XCTAssertEqual(byName["five-hour-session"]?.percentage, 100)
        XCTAssertEqual(byName["five-hour-session"]?.resetTime, "", "a new 5h window starts on the next request")
        XCTAssertEqual(byName["seven-day-weekly"]?.percentage, 100)
        XCTAssertEqual(byName["seven-day-weekly"]?.resetTime, "2026-11-28T16:00:00Z")
        XCTAssertEqual(byName["seven-day-fable"]?.percentage, 100)
        XCTAssertEqual(byName["seven-day-fable"]?.resetTime, "2026-11-28T16:00:00Z")
    }

    func testClaudeWithoutObservationsFallsBackToUsageRequest() throws {
        let file = try authFile(#"{"id":"c","auth_index":"11","name":"claude-a.json","provider":"claude","status":"active","disabled":false,"unavailable":false,"quota":{"signals":{}}}"#)
        XCTAssertNil(RemoteQuotaFetcher.observedClaudeQuota(for: file, maxAge: .infinity))
        XCTAssertEqual(RemoteQuotaFetcher.requests(for: file).count, 1)
    }
}

final class ClaudeUsageBackoffTests: XCTestCase {
    func testWaitsMinimumIntervalAndHonorsLongerRetryAfterOn429() {
        let backoff = ClaudeUsageBackoff()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(backoff.allows("a", now: t0))

        backoff.record("a", response: APICallResponse(statusCode: 200, header: nil, body: nil), minInterval: 900, now: t0)
        XCTAssertFalse(backoff.allows("a", now: t0.addingTimeInterval(899)))
        XCTAssertTrue(backoff.allows("a", now: t0.addingTimeInterval(900)))
        XCTAssertTrue(backoff.allows("b", now: t0), "backoff is per credential")

        backoff.record("a", response: APICallResponse(statusCode: 429, header: ["retry-after": ["3600"]], body: nil), minInterval: 900, now: t0)
        XCTAssertFalse(backoff.allows("a", now: t0.addingTimeInterval(3599)))
        XCTAssertTrue(backoff.allows("a", now: t0.addingTimeInterval(3600)))
    }
}
