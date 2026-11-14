import Foundation
import Security
import SystemConfiguration

/// Desktop sign-in: the app opens the backend's `/connect` page in an
/// `ASWebAuthenticationSession` (see `SettingsView`). The admin signs
/// in with Google there if needed and confirms; the server then
/// redirects to `koom://auth-callback?state=…&token=…&email=…`, which
/// completes the session and hands the app a per-device bearer token.
///
/// This type holds the parts that don't need a UI: building the
/// connect URL and validating the callback.
enum DeviceSignIn {
    static let callbackScheme = "koom"

    enum Outcome: Equatable {
        case signedIn(KoomConfig.DeviceCredential)
        case cancelled
    }

    enum SignInError: LocalizedError, Equatable {
        case stateMismatch
        case malformedCallback

        var errorDescription: String? {
            switch self {
            case .stateMismatch:
                return "Sign-in response didn't match this request. Please try again."
            case .malformedCallback:
                return "The server's sign-in response was incomplete. Please try again."
            }
        }
    }

    /// Fresh per-attempt correlation value (32 random bytes, base64url),
    /// echoed back by the server so a stray callback can't be accepted.
    static func makeState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func connectURL(
        backendURL: URL,
        state: String,
        deviceName: String
    ) -> URL {
        var components = URLComponents(
            url: backendURL.appendingPathComponent("connect"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "device", value: deviceName),
        ]
        return components.url!
    }

    static func parseCallback(
        _ url: URL,
        expectedState: String
    ) throws -> Outcome {
        guard url.scheme == callbackScheme,
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems
        else {
            throw SignInError.malformedCallback
        }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }

        guard value("state") == expectedState else {
            throw SignInError.stateMismatch
        }
        if value("error") == "cancelled" {
            return .cancelled
        }
        guard let token = value("token"), let email = value("email") else {
            throw SignInError.malformedCallback
        }
        return .signedIn(KoomConfig.DeviceCredential(token: token, email: email))
    }

    /// The Mac's user-visible name ("Alex's MacBook Pro"), shown on the
    /// confirmation page and stored as the device label.
    static var deviceName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?)
            ?? ProcessInfo.processInfo.hostName
    }
}
