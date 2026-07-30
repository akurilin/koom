import Foundation
import XCTest

@testable import koom

@MainActor
final class AppSettingsStoreTests: XCTestCase {
    func testCaptureResolutionRoundTrips() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        settings.saveCaptureResolution(.ultraHD4K)

        XCTAssertEqual(
            settings.loadCompressionSettings().captureResolution,
            .ultraHD4K
        )
    }

    func testUploadRecordingsCanBeDisabled() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        settings.saveUploadRecordings(false)

        XCTAssertFalse(settings.loadCompressionSettings().uploadRecordings)
    }

    func testRecordingOptimizationCanBeDisabled() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        settings.saveOptimizeRecordings(false)

        XCTAssertFalse(settings.loadCompressionSettings().optimizeRecordings)
    }

    func testCameraBubbleSizeRoundTrips() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AppSettingsStore(defaults: defaults).saveCameraBubbleSize(.large)

        XCTAssertEqual(
            AppSettingsStore(defaults: defaults).load().cameraBubbleSize,
            .large
        )
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "AppSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
