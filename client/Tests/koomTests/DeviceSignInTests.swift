import XCTest

@testable import koom

final class DeviceSignInTests: XCTestCase {
    private let state = "abcdefghijklmnopqrstuvwxyz012345"

    func testConnectURLCarriesStateAndEncodedDeviceName() throws {
        let url = DeviceSignIn.connectURL(
            backendURL: URL(string: "https://koom.example.com")!,
            state: state,
            deviceName: "Alex's MacBook Pro"
        )
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(components.host, "koom.example.com")
        XCTAssertEqual(components.path, "/connect")
        XCTAssertEqual(
            components.queryItems?.first { $0.name == "device" }?.value,
            "Alex's MacBook Pro"
        )
        XCTAssertEqual(
            components.queryItems?.first { $0.name == "state" }?.value,
            state
        )
    }

    func testSuccessfulCallbackYieldsCredential() throws {
        let url = URL(
            string: "koom://auth-callback?state=\(state)&token=koom_dt_abc&email=admin%40example.com"
        )!
        XCTAssertEqual(
            try DeviceSignIn.parseCallback(url, expectedState: state),
            .signedIn(.init(token: "koom_dt_abc", email: "admin@example.com"))
        )
    }

    func testCancelledCallback() throws {
        let url = URL(string: "koom://auth-callback?state=\(state)&error=cancelled")!
        XCTAssertEqual(
            try DeviceSignIn.parseCallback(url, expectedState: state),
            .cancelled
        )
    }

    func testMismatchedStateIsRejected() {
        let url = URL(
            string: "koom://auth-callback?state=someone-elses-state&token=koom_dt_abc&email=a%40b.c"
        )!
        XCTAssertThrowsError(try DeviceSignIn.parseCallback(url, expectedState: state)) {
            XCTAssertEqual($0 as? DeviceSignIn.SignInError, .stateMismatch)
        }
    }

    func testMissingTokenIsRejected() {
        let url = URL(string: "koom://auth-callback?state=\(state)&email=a%40b.c")!
        XCTAssertThrowsError(try DeviceSignIn.parseCallback(url, expectedState: state)) {
            XCTAssertEqual($0 as? DeviceSignIn.SignInError, .malformedCallback)
        }
    }

    func testStatesAreURLSafeAndUnique() {
        let first = DeviceSignIn.makeState()
        XCTAssertNotEqual(first, DeviceSignIn.makeState())
        XCTAssertNotNil(first.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression))
    }
}
