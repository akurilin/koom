import XCTest

@testable import koom

final class BackendURLSettingTests: XCTestCase {
    func testNormalizationTrimsWhitespaceAndTrailingSlash() throws {
        let url = try BackendURLSetting.normalizedURL(
            "  https://koom.example.com/  ",
            for: .prod
        )

        XCTAssertEqual(url?.absoluteString, "https://koom.example.com")
    }

    func testBlankInputClearsTheOverride() throws {
        XCTAssertNil(
            try BackendURLSetting.normalizedURL(
                " \n ",
                for: .dev
            )
        )
    }

    func testInvalidURLsAreRejected() {
        for rawValue in [
            "koom.example.com",
            "ftp://koom.example.com",
            "https://",
        ] {
            XCTAssertThrowsError(
                try BackendURLSetting.normalizedURL(
                    rawValue,
                    for: .prod
                ),
                "Expected \(rawValue) to be rejected"
            )
        }
    }
}
