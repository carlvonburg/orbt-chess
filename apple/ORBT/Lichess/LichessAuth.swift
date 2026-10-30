import AuthenticationServices
import Foundation
import Observation
import OpeningCoreRust
import SwiftUI

/// Lichess OAuth2 with PKCE. No client registration and no scopes are needed; the
/// explorer only requires a valid token. Tokens last about a year and have no refresh.
/// The requests, the PKCE challenge, the callback check and the answers are in the core;
/// this runs the browser sheet, sends the requests and keeps the token in the Keychain.
@Observable
final class LichessAuth {
    private(set) var token: String?
    private(set) var username: String?
    private(set) var expiresAt: Date?
    var lastError: String?

    var isSignedIn: Bool { token != nil }

    init() {
        if let stored = Keychain.read(Self.tokenKey),
           let data = stored.data(using: .utf8),
           let saved = try? JSONDecoder().decode(StoredToken.self, from: data),
           saved.expiresAt > .now {
            token = saved.token
            username = saved.username
            expiresAt = saved.expiresAt
        }
    }

    /// Runs the browser sign-in. Returns false when the user cancelled.
    @discardableResult
    func signIn(using session: WebAuthenticationSession) async -> Bool {
        lastError = nil
        let verifier = oauthRandomString(random: Self.randomBytes(64))
        let state = oauthRandomString(random: Self.randomBytes(32))
        let redirectUri = lichessRedirectUri()
        do {
            let callback = try await session.authenticate(
                using: URL(string: lichessAuthorizeUrl(verifier: verifier, state: state, redirectUri: redirectUri))!,
                callback: .customScheme(lichessCallbackScheme()),
                preferredBrowserSession: .shared,
                additionalHeaderFields: [:]
            )
            guard let code = try oauthParseRedirect(url: callback.absoluteString, expectedState: state) else {
                return false  // the user declined
            }
            try await exchange(code: code, verifier: verifier, redirectUri: redirectUri)
            return true
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func signOut() async {
        if let token {
            _ = await HTTP.send(lichessRevokeRequest(token: token))
        }
        clear()
    }

    /// Called when Lichess answered 401: the token was revoked or expired.
    func tokenRejected() {
        clear()
        lastError = "Your Lichess session expired. Please sign in again."
    }

    private func clear() {
        token = nil
        username = nil
        expiresAt = nil
        Keychain.delete(Self.tokenKey)
    }

    private func exchange(code: String, verifier: String, redirectUri: String) async throws {
        let request = lichessTokenRequest(code: code, verifier: verifier, redirectUri: redirectUri)
        guard let response = await HTTP.send(request) else {
            throw AuthError.message("Could not reach Lichess")
        }
        let parsed = try lichessParseToken(response: response, nowSecs: Int64(Date.now.timeIntervalSince1970))
        token = parsed.token
        expiresAt = Date(timeIntervalSince1970: TimeInterval(parsed.expiresAt))
        username = await HTTP.send(lichessAccountRequest(token: parsed.token)).flatMap(lichessParseAccount)
        persist()
    }

    private func persist() {
        guard let token, let expiresAt else { return }
        let saved = StoredToken(token: token, username: username, expiresAt: expiresAt)
        if let data = try? JSONEncoder().encode(saved), let text = String(data: data, encoding: .utf8) {
            Keychain.write(text, for: Self.tokenKey)
        }
    }

    private struct StoredToken: Codable {
        let token: String
        let username: String?
        let expiresAt: Date
    }

    private enum AuthError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let m): m }
        }
    }

    private static let tokenKey = "lichess-token"

    private static func randomBytes(_ count: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }
}

enum Keychain {
    private static let service = "org.orbtchess.orbt"

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, for key: String) {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
