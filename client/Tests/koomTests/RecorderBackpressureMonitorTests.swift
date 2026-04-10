import XCTest

@testable import koom

final class RecorderBackpressureMonitorTests: XCTestCase {
    func testAudioBackpressureEscalatesAtThresholdAndResetsOnSuccess() {
        var monitor = RecorderBackpressureMonitor(
            maxConsecutiveAudioBackpressureSamples: 3
        )

        let first = monitor.noteBackpressure(for: .audio)
        XCTAssertTrue(first.shouldLog)
        XCTAssertFalse(first.shouldReportRuntimeIssue)
        XCTAssertEqual(first.consecutiveAudioBackpressureSamples, 1)

        let second = monitor.noteBackpressure(for: .audio)
        XCTAssertFalse(second.shouldLog)
        XCTAssertFalse(second.shouldReportRuntimeIssue)
        XCTAssertEqual(second.consecutiveAudioBackpressureSamples, 2)

        let third = monitor.noteBackpressure(for: .audio)
        XCTAssertTrue(third.shouldLog)
        XCTAssertTrue(third.shouldReportRuntimeIssue)
        XCTAssertEqual(third.consecutiveAudioBackpressureSamples, 3)

        monitor.noteSuccessfulAppend(for: .audio)

        let afterReset = monitor.noteBackpressure(for: .audio)
        XCTAssertTrue(afterReset.shouldLog)
        XCTAssertFalse(afterReset.shouldReportRuntimeIssue)
        XCTAssertEqual(afterReset.consecutiveAudioBackpressureSamples, 1)
    }

    func testVideoBackpressureLogsFirstAndEverySixtiethDrop() {
        var monitor = RecorderBackpressureMonitor(
            maxConsecutiveAudioBackpressureSamples: 3
        )

        let first = monitor.noteBackpressure(for: .video)
        XCTAssertTrue(first.shouldLog)
        XCTAssertFalse(first.shouldReportRuntimeIssue)
        XCTAssertEqual(first.droppedVideoSamples, 1)

        for dropIndex in 2...59 {
            let decision = monitor.noteBackpressure(for: .video)
            XCTAssertFalse(decision.shouldLog, "unexpected log at drop \(dropIndex)")
            XCTAssertFalse(decision.shouldReportRuntimeIssue)
            XCTAssertEqual(decision.droppedVideoSamples, dropIndex)
        }

        let sixtieth = monitor.noteBackpressure(for: .video)
        XCTAssertTrue(sixtieth.shouldLog)
        XCTAssertFalse(sixtieth.shouldReportRuntimeIssue)
        XCTAssertEqual(sixtieth.droppedVideoSamples, 60)
    }
}
