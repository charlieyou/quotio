import XCTest
@testable import Quotio

@MainActor
final class OperatingModeTests: XCTestCase {
    func testRemoteModeRawValueRoundTrips() {
        XCTAssertEqual(OperatingMode(rawValue: "remote"), .remoteProxy)
    }

    func testLegacyRemoteModeMigratesToRemoteProxy() {
        XCTAssertEqual(
            OperatingMode.fromLegacy(appModeRaw: "full", connectionMode: .remote),
            .remoteProxy
        )
    }

    func testLegacyLocalModeMigratesToLocalProxy() {
        XCTAssertEqual(
            OperatingMode.fromLegacy(appModeRaw: "full", connectionMode: .local),
            .localProxy
        )
    }

    func testRemoteManagementURLAcceptsBareServerURL() {
        let cases = [
            "https://cyou-cliproxyapi.fly.dev",
            "https://cyou-cliproxyapi.fly.dev/",
            " https://cyou-cliproxyapi.fly.dev/v0 ",
            "https://cyou-cliproxyapi.fly.dev/v0/management/",
        ]
        for input in cases {
            XCTAssertEqual(
                RemoteConnectionConfig(endpointURL: input).managementBaseURL,
                "https://cyou-cliproxyapi.fly.dev/v0/management",
                input
            )
        }
    }
}
