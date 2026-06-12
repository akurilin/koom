import Foundation
import XCTest

@testable import koom

@MainActor
final class AppSettingsStoreTests: XCTestCase {
    func testUploadRecordingsDefaultsToEnabled() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)

        XCTAssertTrue(settings.loadCompressionSettings().uploadRecordings)
    }

    func testUploadRecordingsCanBeDisabled() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        settings.saveUploadRecordings(false)

        XCTAssertFalse(settings.loadCompressionSettings().uploadRecordings)
    }

    func testRecordingOptimizationDefaultsToEnabled() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)

        XCTAssertTrue(settings.loadCompressionSettings().optimizeRecordings)
    }

    func testRecordingOptimizationCanBeDisabled() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults)
        settings.saveOptimizeRecordings(false)

        XCTAssertFalse(settings.loadCompressionSettings().optimizeRecordings)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "AppSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
