import Foundation
import Network
import XCTest
@testable import Quotio

final class RemoteOAuthCallbackTests: XCTestCase {
    func testParseExtractsLoopbackTargetsForProviders() {
        let antigravityURL = "https://accounts.google.com/o/oauth2/v2/auth?client_id=abc&redirect_uri=http%3A%2F%2Flocalhost%3A51121%2Foauth-callback&state=agy-1"
        XCTAssertEqual(
            RemoteOAuthCallbackTarget.parse(fromAuthURL: antigravityURL),
            RemoteOAuthCallbackTarget(port: 51121, path: "/oauth-callback")
        )

        let claudeURL = "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&state=anth-1"
        XCTAssertEqual(
            RemoteOAuthCallbackTarget.parse(fromAuthURL: claudeURL),
            RemoteOAuthCallbackTarget(port: 54545, path: "/callback")
        )

        let codexURL = "https://auth.openai.com/oauth/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback&state=codex-1"
        XCTAssertEqual(
            RemoteOAuthCallbackTarget.parse(fromAuthURL: codexURL),
            RemoteOAuthCallbackTarget(port: 1455, path: "/auth/callback")
        )

        let ipv6URL = "https://example.com/auth?redirect_uri=http%3A%2F%2F%5B%3A%3A1%5D%3A8085%2Foauth2callback"
        XCTAssertEqual(
            RemoteOAuthCallbackTarget.parse(fromAuthURL: ipv6URL),
            RemoteOAuthCallbackTarget(port: 8085, path: "/oauth2callback")
        )
    }

    func testParseReturnsNilForNonLoopbackOrMissingPortOrRedirect() {
        XCTAssertNil(
            RemoteOAuthCallbackTarget.parse(
                fromAuthURL: "https://accounts.google.com/o/oauth2/v2/auth?redirect_uri=https%3A%2F%2Fproxy.example.com%2Fcallback"
            )
        )
        XCTAssertNil(
            RemoteOAuthCallbackTarget.parse(
                fromAuthURL: "https://accounts.google.com/o/oauth2/v2/auth?redirect_uri=http%3A%2F%2Flocalhost%2Fcallback"
            )
        )
        XCTAssertNil(
            RemoteOAuthCallbackTarget.parse(
                fromAuthURL: "https://chat.qwen.ai/authorize?user_code=ABCD-EFGH"
            )
        )
    }

    func testNormalizedCallbackURLHandlesSchemeAndWhitespace() {
        XCTAssertEqual(
            RemoteOAuthCallbackTarget.normalizedCallbackURL(
                from: "  http://localhost:51121/oauth-callback?code=abc&state=xyz\n"
            ),
            "http://localhost:51121/oauth-callback?code=abc&state=xyz"
        )
        XCTAssertEqual(
            RemoteOAuthCallbackTarget.normalizedCallbackURL(
                from: "localhost:51121/oauth-callback?code=abc&state=xyz"
            ),
            "http://localhost:51121/oauth-callback?code=abc&state=xyz"
        )
        XCTAssertEqual(
            RemoteOAuthCallbackTarget.normalizedCallbackURL(
                from: "127.0.0.1:1455/auth/callback?code=abc&state=xyz"
            ),
            "http://127.0.0.1:1455/auth/callback?code=abc&state=xyz"
        )
        XCTAssertNil(RemoteOAuthCallbackTarget.normalizedCallbackURL(from: "   "))
        XCTAssertNil(RemoteOAuthCallbackTarget.normalizedCallbackURL(from: "not-a-url"))
        XCTAssertNil(RemoteOAuthCallbackTarget.normalizedCallbackURL(from: "http://"))
    }

    func testCallbackServerIgnoresNonMatchingPathsAndIncludesPort() async throws {
        let server = MonitorOAuthCallbackServer()
        let port = try await server.start(expectedPath: "/oauth-callback")
        defer { server.stop() }

        async let callback = server.waitForCallback(timeout: .seconds(3))

        let faviconURL = URL(string: "http://127.0.0.1:\(port)/favicon.ico")!
        let (_, faviconResponse) = try await URLSession.shared.data(from: faviconURL)
        XCTAssertEqual((faviconResponse as? HTTPURLResponse)?.statusCode, 404)

        let callbackRequestURL = URL(string: "http://127.0.0.1:\(port)/oauth-callback?code=agy-code&state=agy-state")!
        let (_, callbackResponse) = try await URLSession.shared.data(from: callbackRequestURL)
        XCTAssertEqual((callbackResponse as? HTTPURLResponse)?.statusCode, 200)

        let captured = try await callback
        XCTAssertEqual(captured.port, Int(port))
        XCTAssertEqual(captured.path, "/oauth-callback")
        let items = URLComponents(url: captured, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first(where: { $0.name == "code" })?.value, "agy-code")
        XCTAssertEqual(items?.first(where: { $0.name == "state" })?.value, "agy-state")
    }

    func testCallbackServerFailsPromptlyWhenPreferredPortIsBusy() async throws {
        let blocker = MonitorOAuthCallbackServer()
        let port = try await blocker.start()
        defer { blocker.stop() }

        let contender = MonitorOAuthCallbackServer()
        defer { contender.stop() }

        do {
            _ = try await contender.start(preferredPort: port)
            XCTFail("Expected binding busy port \(port) to fail")
        } catch {
            // Expected: binding a port already held by another listener fails promptly.
        }
    }

    func testSubmitOAuthCallbackSendsExpectedPayloadAndSurfacesServerError() async throws {
        let stub = StubOAuthCallbackServer()
        let port = try await stub.start()
        defer { stub.stop() }

        let client = ManagementAPIClient(
            baseURL: "http://127.0.0.1:\(port)/v0/management",
            authKey: "test-key",
            timeoutConfig: .custom(requestTimeout: 5, resourceTimeout: 5, maxRetries: 0),
            verifySSL: true
        )

        let redirectURL = "http://localhost:51121/oauth-callback?code=abc&state=st-1"
        try await client.submitOAuthCallback(provider: .antigravity, redirectURL: redirectURL)

        let recorded = try XCTUnwrap(stub.lastRequest)
        XCTAssertEqual(recorded.method, "POST")
        XCTAssertEqual(recorded.path, "/v0/management/oauth-callback")
        let decoded = try JSONDecoder().decode(OAuthCallbackRequest.self, from: recorded.body)
        XCTAssertEqual(decoded.provider, "antigravity")
        XCTAssertEqual(decoded.redirectURL, redirectURL)

        try await client.submitOAuthCallback(provider: .claude, redirectURL: "http://localhost:54545/callback?code=c&state=s")
        let claudeRecorded = try XCTUnwrap(stub.lastRequest)
        let claudeDecoded = try JSONDecoder().decode(OAuthCallbackRequest.self, from: claudeRecorded.body)
        XCTAssertEqual(claudeDecoded.provider, "anthropic")

        stub.nextResponse = (404, #"{"status":"error","error":"unknown or expired state"}"#)
        do {
            try await client.submitOAuthCallback(provider: .antigravity, redirectURL: redirectURL)
            XCTFail("Expected server error")
        } catch let error as APIError {
            XCTAssertEqual(error.errorDescription, "unknown or expired state")
        }
    }
}

private final class StubOAuthCallbackServer: @unchecked Sendable {
    struct RecordedRequest {
        let method: String
        let path: String
        let body: Data
    }

    private let lock = NSLock()
    private var listener: NWListener?
    private var _lastRequest: RecordedRequest?
    private var _nextResponse: (Int, String) = (200, #"{"status":"ok"}"#)

    var lastRequest: RecordedRequest? {
        lock.lock()
        defer { lock.unlock() }
        return _lastRequest
    }

    var nextResponse: (Int, String) {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _nextResponse
        }
        set {
            lock.lock()
            _nextResponse = newValue
            lock.unlock()
        }
    }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "test.stub.oauth.callback"))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "test.stub.oauth.callback.conn"))
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, _ in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }
            guard let raw = String(data: accumulated, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let separator = "\r\n\r\n"
            guard let range = raw.range(of: separator) else {
                if isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: accumulated)
                }
                return
            }

            let headerBlock = String(raw[..<range.lowerBound])
            let bodyString = String(raw[range.upperBound...])
            let lines = headerBlock.components(separatedBy: "\r\n")
            let contentLength = lines
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0

            if bodyString.utf8.count < contentLength && !isComplete {
                self.receive(on: connection, buffer: accumulated)
                return
            }

            let requestLine = lines.first ?? ""
            let parts = requestLine.split(separator: " ")
            let method = parts.count > 0 ? String(parts[0]) : ""
            let path = parts.count > 1 ? String(parts[1]) : ""

            self.lock.lock()
            self._lastRequest = RecordedRequest(method: method, path: path, body: Data(bodyString.utf8))
            let (status, responseBody) = self._nextResponse
            self.lock.unlock()

            let response = "HTTP/1.1 \(status) OK\r\nContent-Type: application/json\r\nContent-Length: \(responseBody.utf8.count)\r\nConnection: close\r\n\r\n\(responseBody)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
