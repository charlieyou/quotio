//
//  RemoteOAuthCallbackTarget.swift
//  Quotio
//

import Foundation

/// Parsed loopback callback target extracted from an OAuth authorization URL's `redirect_uri`.
///
/// In Remote Proxy mode, CLIProxyAPI generates OAuth URLs whose `redirect_uri` points to
/// `localhost:<port>/<path>` on the proxy host. Quotio uses this target to bind a temporary
/// local loopback listener on the user's Mac and forward the callback to the remote server's
/// `/v0/management/oauth-callback` endpoint.
nonisolated struct RemoteOAuthCallbackTarget: Equatable, Sendable {
    let port: UInt16
    let path: String

    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    /// Extracts a loopback callback target from an OAuth authorization URL if its `redirect_uri`
    /// points to `http://localhost:<port>/...` (or `127.0.0.1` / `[::1]`).
    static func parse(fromAuthURL authURL: String) -> RemoteOAuthCallbackTarget? {
        guard let components = URLComponents(string: authURL),
              let rawRedirect = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
              !rawRedirect.isEmpty,
              let redirectComponents = URLComponents(string: rawRedirect),
              let scheme = redirectComponents.scheme?.lowercased(),
              scheme == "http",
              let host = redirectComponents.host?.lowercased(),
              loopbackHosts.contains(host),
              let rawPort = redirectComponents.port,
              let port = UInt16(exactly: rawPort),
              port > 0 else {
            return nil
        }

        let rawPath = redirectComponents.path
        let normalizedPath: String
        if rawPath.isEmpty {
            normalizedPath = "/"
        } else if rawPath.hasPrefix("/") {
            normalizedPath = rawPath
        } else {
            normalizedPath = "/" + rawPath
        }

        return RemoteOAuthCallbackTarget(
            port: port,
            path: normalizedPath
        )
    }

    /// Normalizes a manually pasted callback URL from a browser address bar.
    /// Prepends `http://` when browsers omit the scheme for `localhost:` or `127.0.0.1:`.
    static func normalizedCallbackURL(from rawInput: String) -> String? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        let candidate: String
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            candidate = trimmed
        } else if lower.hasPrefix("localhost:") || lower.hasPrefix("127.0.0.1:") || lower.hasPrefix("[::1]:") {
            candidate = "http://" + trimmed
        } else {
            return nil
        }

        guard let components = URLComponents(string: candidate),
              components.scheme != nil,
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        return candidate
    }
}
