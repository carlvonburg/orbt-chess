import AuthenticationServices
import Foundation
import OpeningCoreRust
import SwiftUI

/// Where the repertoire folder syncs to (`FUTURE.md`, Connectors). None: iCloud Drive only.
enum SyncProvider: String, CaseIterable, Identifiable {
    case dropbox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dropbox: "Dropbox"
        }
    }

    /// The providers this build can sign in to: those whose keys are set (`Config/ORBT.xcconfig`).
    static var available: [SyncProvider] {
        allCases.filter { !SyncAuth.clientID(for: $0).isEmpty }
    }
}

/// What a sign-in gives the core (`RepertoireSync.setCredentials`): the refresh token, with
/// which the core gets access tokens itself, and the account to show in Settings.
struct SyncCredentials: Codable, Equatable {
    var accessToken: String?
    /// Unix ms; nil when unknown.
    var expiresAt: Int64?
    var refreshToken: String?
    /// The account's email or name.
    var account: String?
}

struct SyncSignInError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The sign-ins for the sync: OAuth with PKCE in the system's web sheet. The requests, the
/// challenge and the answers are the core's (`dropbox_authorize_url`, `oauth_parse_redirect`);
/// this runs the sheet and sends them.
enum SyncAuth {
    /// The provider's OAuth client id from the build (`Info.plist`, set from the xcconfig);
    /// empty when this build has none.
    static func clientID(for provider: SyncProvider) -> String {
        let key = switch provider {
        case .dropbox: "ORBTDropboxAppKey"
        }
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        // An unset build setting leaves the plist's `$(…)` reference empty, or as it is.
        return value.hasPrefix("$(") ? "" : value.trimmingCharacters(in: .whitespaces)
    }

    /// Asks the user to sign in. Nil when they cancelled; throws `SyncSignInError`.
    static func signIn(_ provider: SyncProvider, using session: WebAuthenticationSession) async throws -> SyncCredentials? {
        switch provider {
        case .dropbox: try await dropboxSignIn(using: session)
        }
    }

    private static func dropboxSignIn(using session: WebAuthenticationSession) async throws -> SyncCredentials? {
        let appKey = clientID(for: .dropbox)
        guard !appKey.isEmpty else { throw SyncSignInError(message: "This build has no Dropbox app key.") }
        let verifier = oauthRandomString(random: randomBytes(64))
        let state = oauthRandomString(random: randomBytes(32))
        let redirectUri = dropboxRedirectUri()
        guard let scheme = URL(string: redirectUri)?.scheme,
              let authorize = URL(string: dropboxAuthorizeUrl(appKey: appKey, verifier: verifier, state: state,
                                                             redirectUri: redirectUri)) else { return nil }
        let callback: URL
        do {
            callback = try await session.authenticate(using: authorize, callback: .customScheme(scheme),
                                                      preferredBrowserSession: .shared, additionalHeaderFields: [:])
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return nil
        }
        do {
            guard let code = try oauthParseRedirect(url: callback.absoluteString, expectedState: state) else {
                return nil  // the user declined
            }
            let request = dropboxTokenRequest(appKey: appKey, code: code, verifier: verifier, redirectUri: redirectUri)
            guard let response = await HTTP.send(request) else {
                throw SyncSignInError(message: "Could not reach Dropbox.")
            }
            let signIn = try dropboxParseToken(response: response, nowMs: SyncService.millis(.now))
            let account = await HTTP.send(dropboxAccountRequest(accessToken: signIn.accessToken)).flatMap(dropboxParseAccount)
            return SyncCredentials(accessToken: signIn.accessToken, expiresAt: signIn.expiresAt,
                                   refreshToken: signIn.refreshToken, account: account)
        } catch let error as SignInError {
            switch error {
            case .Failed(let reason): throw SyncSignInError(message: reason)
            }
        }
    }

    private static func randomBytes(_ count: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }
}
