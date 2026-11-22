import XCTest
@testable import Quotio

final class MenuAccountStatusTests: XCTestCase {

    private func decodeAuthFile(_ json: String) throws -> AuthFile {
        try JSONDecoder().decode(AuthFile.self, from: Data(json.utf8))
    }

    func testActiveAuthFileMapsToActiveWithoutErrorDetail() throws {
        let active = try decodeAuthFile(#"""
        {"id":"1","name":"antigravity-a@example.com.json","provider":"antigravity","status":"active","status_message":"","disabled":false,"unavailable":false,"email":"a@example.com"}
        """#)
        let ready = try decodeAuthFile(#"""
        {"id":"2","name":"codex-a@example.com.json","provider":"codex","status":"ready","status_message":"","disabled":false,"unavailable":false,"email":"a@example.com"}
        """#)

        XCTAssertTrue(active.isReady)
        XCTAssertTrue(ready.isReady)
        XCTAssertEqual(MenuAccountHealthIndicator.from(authFile: active), MenuAccountHealthIndicator(state: .active, detailMessage: nil))
        XCTAssertEqual(MenuAccountHealthIndicator.from(authFile: ready), MenuAccountHealthIndicator(state: .active, detailMessage: nil))
    }

    func testErrorAuthFileExtractsNestedJSONErrorMessage() throws {
        let file = try decodeAuthFile(#"""
        {"id":"1","name":"claude-a@example.com.json","provider":"claude","status":"error","status_message":"{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"This request would exceed your account's rate limit. Please try again later.\"},\"request_id\":\"req_123\"}","disabled":false,"unavailable":true,"email":"a@example.com"}
        """#)

        XCTAssertFalse(file.isReady)
        let indicator = MenuAccountHealthIndicator.from(authFile: file)
        XCTAssertEqual(indicator?.state, .error)
        XCTAssertEqual(indicator?.detailMessage, "This request would exceed your account's rate limit. Please try again later.")
    }

    func testUnavailableAuthFileWithoutMessageUsesFallbackError() throws {
        let file = try decodeAuthFile(#"""
        {"id":"1","name":"claude-a@example.com.json","provider":"claude","status":"active","status_message":"","disabled":false,"unavailable":true,"email":"a@example.com"}
        """#)

        XCTAssertFalse(file.isReady)
        let indicator = MenuAccountHealthIndicator.from(authFile: file)
        XCTAssertEqual(indicator, MenuAccountHealthIndicator(state: .error, detailMessage: "Account error"))
    }

    func testHumanReadableStatusHandlesTopLevelErrorAndPlainText() throws {
        let topLevelError = try decodeAuthFile(#"""
        {"id":"1","name":"a.json","provider":"claude","status":"error","status_message":"{\"error\":\"token_revoked\"}","disabled":false,"unavailable":true}
        """#)
        let topLevelMessage = try decodeAuthFile(#"""
        {"id":"2","name":"b.json","provider":"claude","status":"error","status_message":"{\"message\":\"Quota exhausted\"}","disabled":false,"unavailable":true}
        """#)
        let plainText = try decodeAuthFile(#"""
        {"id":"3","name":"c.json","provider":"claude","status":"error","status_message":"Upstream returned 503","disabled":false,"unavailable":true}
        """#)

        XCTAssertEqual(topLevelError.humanReadableStatus, "token_revoked")
        XCTAssertEqual(topLevelMessage.humanReadableStatus, "Quota exhausted")
        XCTAssertEqual(plainText.humanReadableStatus, "Upstream returned 503")
    }

    func testCoolingAndDisabledStatesMapCorrectly() throws {
        let cooling = try decodeAuthFile(#"""
        {"id":"1","name":"a.json","provider":"claude","status":"cooling","status_message":"Rate limited for 5m","disabled":false,"unavailable":false}
        """#)
        let disabled = try decodeAuthFile(#"""
        {"id":"2","name":"b.json","provider":"claude","status":"error","status_message":"","disabled":true,"unavailable":true}
        """#)

        XCTAssertEqual(
            MenuAccountHealthIndicator.from(authFile: cooling),
            MenuAccountHealthIndicator(state: .cooling, detailMessage: "Rate limited for 5m")
        )
        XCTAssertEqual(
            MenuAccountHealthIndicator.from(authFile: disabled),
            MenuAccountHealthIndicator(state: .disabled, detailMessage: "Account disabled")
        )
    }

    func testForbiddenFlagEscalatesActiveOrMissingAuthFileToError() throws {
        let active = try decodeAuthFile(#"""
        {"id":"1","name":"a.json","provider":"claude","status":"active","disabled":false,"unavailable":false}
        """#)

        XCTAssertEqual(
            MenuAccountHealthIndicator.from(authFile: active, isForbidden: true),
            MenuAccountHealthIndicator(state: .error, detailMessage: "Authentication error")
        )
        XCTAssertNil(MenuAccountHealthIndicator.from(authFile: nil, isForbidden: false))
        XCTAssertEqual(
            MenuAccountHealthIndicator.from(authFile: nil, isForbidden: true),
            MenuAccountHealthIndicator(state: .error, detailMessage: "Authentication error")
        )
    }

    func testAuthFileEqualityTracksStatusMessageAndUnavailable() throws {
        let first = try decodeAuthFile(#"""
        {"id":"1","name":"a.json","provider":"claude","status":"error","status_message":"First error","disabled":false,"unavailable":true}
        """#)
        let second = try decodeAuthFile(#"""
        {"id":"1","name":"a.json","provider":"claude","status":"error","status_message":"Second error","disabled":false,"unavailable":true}
        """#)
        let third = try decodeAuthFile(#"""
        {"id":"1","name":"a.json","provider":"claude","status":"active","status_message":"","disabled":false,"unavailable":false}
        """#)
        let fourth = try decodeAuthFile(#"""
        {"id":"1","name":"a.json","provider":"claude","status":"active","status_message":"","disabled":false,"unavailable":true}
        """#)

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(third, fourth)
    }

    func testMatchingAuthFilePrefersEnabledOverDisabledForDuplicateEmail() throws {
        let disabledOld = try decodeAuthFile(#"""
        {"id":"old","name":"claude-old.json","provider":"claude","status":"error","disabled":true,"unavailable":true,"email":"a@example.com"}
        """#)
        let activeNew = try decodeAuthFile(#"""
        {"id":"new","name":"claude-new.json","provider":"claude","status":"active","disabled":false,"unavailable":false,"email":"a@example.com"}
        """#)

        let match = MenuAccountHealthIndicator.matchingAuthFile(
            in: [disabledOld, activeNew],
            provider: .claude,
            accountKey: "a@example.com"
        )
        XCTAssertEqual(match?.id, "new")
    }

    func testUnknownStatusDoesNotReportActiveAndRespectsForbidden() throws {
        let outdated = try decodeAuthFile(#"""
        {"id":"1","name":"a.json","provider":"claude","status":"outdated","disabled":false,"unavailable":false}
        """#)
        let expired = try decodeAuthFile(#"""
        {"id":"2","name":"b.json","provider":"claude","status":"expired","disabled":false,"unavailable":false}
        """#)

        XCTAssertEqual(
            MenuAccountHealthIndicator.from(authFile: outdated),
            MenuAccountHealthIndicator(state: .cooling, detailMessage: "Outdated")
        )
        XCTAssertEqual(
            MenuAccountHealthIndicator.from(authFile: expired),
            MenuAccountHealthIndicator(state: .disabled, detailMessage: "Expired")
        )
        XCTAssertEqual(
            MenuAccountHealthIndicator.from(authFile: expired, isForbidden: true),
            MenuAccountHealthIndicator(state: .error, detailMessage: "Authentication error")
        )
    }
}
