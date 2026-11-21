import XCTest
@testable import Quotio

final class AccountSortingTests: XCTestCase {
    private struct Account: Equatable {
        let email: String
    }

    func testActiveAccountFloatsToTop() {
        let accounts = [
            Account(email: "alpha@example.com"),
            Account(email: "bravo@example.com"),
            Account(email: "charlie@example.com")
        ]

        let result = AccountSorting.prioritizingActive(accounts) {
            $0.email == "charlie@example.com"
        }

        XCTAssertEqual(result.map(\.email), [
            "charlie@example.com",
            "alpha@example.com",
            "bravo@example.com"
        ])
    }

    func testMultipleActiveAccountsKeepStableRelativeOrder() {
        let accounts = [
            Account(email: "alpha@example.com"),
            Account(email: "bravo@example.com"),
            Account(email: "charlie@example.com"),
            Account(email: "delta@example.com")
        ]

        let active: Set<String> = ["bravo@example.com", "delta@example.com"]
        let result = AccountSorting.prioritizingActive(accounts) {
            active.contains($0.email)
        }

        XCTAssertEqual(result.map(\.email), [
            "bravo@example.com",
            "delta@example.com",
            "alpha@example.com",
            "charlie@example.com"
        ])
    }

    func testNoActiveAccountLeavesOrderUnchanged() {
        let accounts = [
            Account(email: "charlie@example.com"),
            Account(email: "alpha@example.com"),
            Account(email: "bravo@example.com")
        ]

        let result = AccountSorting.prioritizingActive(accounts) { _ in false }

        XCTAssertEqual(result, accounts)
    }

    func testAllActiveAccountsLeaveOrderUnchanged() {
        let accounts = [
            Account(email: "charlie@example.com"),
            Account(email: "alpha@example.com")
        ]

        let result = AccountSorting.prioritizingActive(accounts) { _ in true }

        XCTAssertEqual(result, accounts)
    }

    func testEmptyListStaysEmpty() {
        let result = AccountSorting.prioritizingActive([Account]()) { _ in true }
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Menu bar account list

    private func quota(displayName: String?) -> ProviderQuotaData {
        ProviderQuotaData(accountDisplayName: displayName)
    }

    func testMenuBarFloatsActiveAntigravityAccountToTop() {
        let quotas: [String: ProviderQuotaData] = [
            "alpha@example.com": quota(displayName: "alpha@example.com"),
            "bravo@example.com": quota(displayName: "bravo@example.com"),
            "charlie@example.com": quota(displayName: "charlie@example.com")
        ]

        let ordered = StatusBarMenuBuilder.orderedAccounts(quotas, provider: .antigravity) {
            $0 == "charlie@example.com"
        }

        XCTAssertEqual(ordered.map(\.email), [
            "charlie@example.com",
            "alpha@example.com",
            "bravo@example.com"
        ])
    }

    func testMenuBarKeepsAlphabeticalOrderWhenNoAntigravityAccountIsActive() {
        let quotas: [String: ProviderQuotaData] = [
            "charlie@example.com": quota(displayName: "charlie@example.com"),
            "alpha@example.com": quota(displayName: "alpha@example.com"),
            "bravo@example.com": quota(displayName: "bravo@example.com")
        ]

        let ordered = StatusBarMenuBuilder.orderedAccounts(quotas, provider: .antigravity) { _ in false }

        XCTAssertEqual(ordered.map(\.email), [
            "alpha@example.com",
            "bravo@example.com",
            "charlie@example.com"
        ])
    }

    func testMenuBarLeavesNonAntigravityProvidersAlphabetical() {
        let quotas: [String: ProviderQuotaData] = [
            "alpha@example.com": quota(displayName: "alpha@example.com"),
            "charlie@example.com": quota(displayName: "charlie@example.com")
        ]

        // The same email may exist on another provider; the Antigravity "in use in the
        // IDE" signal must not reorder that provider's list.
        let ordered = StatusBarMenuBuilder.orderedAccounts(quotas, provider: .claude) {
            $0 == "charlie@example.com"
        }

        XCTAssertEqual(ordered.map(\.email), [
            "alpha@example.com",
            "charlie@example.com"
        ])
    }

    func testMenuBarOrdersAccountsBySoonestSharedResetThenEmail() {
        let now = Date()
        func iso(_ hours: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(hours * 3600)) }
        func account(_ models: [(String, String)]) -> ProviderQuotaData {
            ProviderQuotaData(models: models.map { ModelQuota(name: $0.0, percentage: 50, resetTime: $0.1) })
        }
        let quotas: [String: ProviderQuotaData] = [
            // The 5h session resets soonest, but weekly and Fable share the later reset.
            "alpha@example.com": account([("five-hour-session", iso(1)), ("seven-day-weekly", iso(48)), ("seven-day-fable", iso(48))]),
            "bravo@example.com": account([("seven-day-weekly", iso(24))]),
            "charlie@example.com": account([("seven-day-weekly", "")]),
            "delta@example.com": account([("seven-day-weekly", iso(-1))]),
            "echo@example.com": account([("seven-day-weekly", iso(24))]),
            // No shared reset: the later (weekly) reset is the key, not the 5h session.
            "foxtrot@example.com": account([("five-hour-session", iso(0.5)), ("seven-day-weekly", iso(72))]),
        ]

        let ordered = StatusBarMenuBuilder.orderedAccounts(quotas, provider: .claude) { _ in false }

        XCTAssertEqual(ordered.map(\.email), [
            "bravo@example.com",
            "echo@example.com",
            "alpha@example.com",
            "foxtrot@example.com",
            "charlie@example.com",
            "delta@example.com"
        ])
    }

    func testMenuBarUsesAccountKeyFallbackForActiveCheck() {
        let quotas: [String: ProviderQuotaData] = [
            "alpha@example.com": quota(displayName: nil),
            "zulu@example.com": quota(displayName: nil)
        ]

        let ordered = StatusBarMenuBuilder.orderedAccounts(quotas, provider: .antigravity) {
            $0 == "zulu@example.com"
        }

        XCTAssertEqual(ordered.map(\.email), ["zulu@example.com", "alpha@example.com"])
        XCTAssertEqual(ordered.map(\.accountKey), ["zulu@example.com", "alpha@example.com"])
    }

    func testMenuBarEmptyQuotasProduceNoRows() {
        let ordered = StatusBarMenuBuilder.orderedAccounts([:], provider: .antigravity) { _ in true }
        XCTAssertTrue(ordered.isEmpty)
    }
}
