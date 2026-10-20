import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import SwiftUI

/// Lichess OAuth2 with PKCE. No client registration and no scopes are needed; the
/// explorer only requires a valid token. Tokens last about a year and have no refresh.
@Observable
final class LichessAuth {
    static let clientID = "ch.cvb.openingTrainer"
    static let callbackScheme = "ch.cvb.openingtrainer"
    static let redirectURI = "\(callbackScheme)://oauth-callback"
    private static let host = URL(string: "https://lichess.org")!

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
        let verifier = Self.randomString(64)
        let state = Self.randomString(32)
        var components = URLComponents(url: Self.host.appending(path: "oauth"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "state", value: state),
        ]
        do {
            let callback = try await session.authenticate(
                using: components.url!,
                callback: .customScheme(Self.callbackScheme),
                preferredBrowserSession: .shared,
                additionalHeaderFields: [:]
            )
            let params = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func param(_ name: String) -> String? { params.first { $0.name == name }?.value }
            guard param("state") == state else { throw AuthError.message("State mismatch in Lichess callback") }
            if let error = param("error") {
                if error == "access_denied" { return false }
                throw AuthError.message("Lichess refused sign-in: \(error)")
            }
            guard let code = param("code") else { throw AuthError.message("No code in Lichess callback") }
            try await exchange(code: code, verifier: verifier)
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
            var request = URLRequest(url: Self.host.appending(path: "api/token"))
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
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

    private func exchange(code: String, verifier: String) async throws {
        var request = URLRequest(url: Self.host.appending(path: "api/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", Self.redirectURI),
            ("client_id", Self.clientID),
        ]
        request.httpBody = body.map { "\($0.0)=\(Self.formEncode($0.1))" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.message("Token exchange failed (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Double?
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        token = decoded.access_token
        expiresAt = Date.now.addingTimeInterval(decoded.expires_in ?? 365 * 86400)
        username = try? await fetchUsername()
        persist()
    }

    private func fetchUsername() async throws -> String? {
        guard let token else { return nil }
        var request = URLRequest(url: Self.host.appending(path: "api/account"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        struct Account: Decodable { let username: String }
        return try JSONDecoder().decode(Account.self, from: data).username
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

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars[Int(rng.next() % UInt64(chars.count))] })
    }

    private static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

enum Keychain {
    private static let service = "ch.cvb.openingTrainer"

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
