import CoreMedia
import XCTest

@testable import koom

final class RecorderTimelineControllerTests: XCTestCase {
    func testVideoAnchorsSessionBeforeAudio() {
        var controller = RecorderTimelineController()

        let video = controller.processSample(
            sourcePTS: pts(10.0),
            track: .video
        )
        XCTAssertTrue(video.shouldAppend)
        XCTAssertTrue(video.shouldStartSession)
        XCTAssertTrue(video.didAnchorTrack)
        XCTAssertTrue(video.shouldLogFirstSampleFormat)
        XCTAssertEqual(seconds(video.sessionOffset), 0.0, accuracy: 0.0001)
        XCTAssertEqual(seconds(video.retimeOffset), 10.0, accuracy: 0.0001)
        XCTAssertEqual(
            seconds(retimedPTS(for: pts(10.0), using: video)),
            0.0,
            accuracy: 0.0001
        )

        let audio = controller.processSample(
            sourcePTS: pts(10.25),
            track: .audio
        )
        XCTAssertTrue(audio.shouldAppend)
        XCTAssertFalse(audio.shouldStartSession)
        XCTAssertTrue(audio.didAnchorTrack)
        XCTAssertTrue(audio.shouldLogFirstSampleFormat)
        XCTAssertEqual(seconds(audio.sessionOffset), 0.25, accuracy: 0.0001)
        XCTAssertEqual(seconds(audio.retimeOffset), 10.0, accuracy: 0.0001)
        XCTAssertEqual(
            seconds(retimedPTS(for: pts(10.25), using: audio)),
            0.25,
            accuracy: 0.0001
        )
    }

    func testAudioCanAnchorSessionBeforeVideo() {
        var controller = RecorderTimelineController()

        let audio = controller.processSample(
            sourcePTS: pts(42.0),
            track: .audio
        )
        XCTAssertTrue(audio.shouldAppend)
        XCTAssertTrue(audio.shouldStartSession)
        XCTAssertTrue(audio.didAnchorTrack)
        XCTAssertEqual(seconds(audio.retimeOffset), 42.0, accuracy: 0.0001)

        let video = controller.processSample(
            sourcePTS: pts(42.2),
            track: .video
        )
        XCTAssertTrue(video.shouldAppend)
        XCTAssertFalse(video.shouldStartSession)
        XCTAssertTrue(video.didAnchorTrack)
        XCTAssertEqual(seconds(video.sessionOffset), 0.2, accuracy: 0.0001)
        XCTAssertEqual(
            seconds(retimedPTS(for: pts(42.2), using: video)),
            0.2,
            accuracy: 0.0001
        )
    }

    func testPauseResumeRemovesGapFromTimeline() {
        var controller = RecorderTimelineController()

        _ = controller.processSample(sourcePTS: pts(5.0), track: .video)
        let beforePause = controller.processSample(
            sourcePTS: pts(6.0),
            track: .video
        )
        XCTAssertEqual(
            seconds(retimedPTS(for: pts(6.0), using: beforePause)),
            1.0,
            accuracy: 0.0001
        )

        controller.pause()
        let droppedWhilePaused = controller.processSample(
            sourcePTS: pts(7.0),
            track: .video
        )
        XCTAssertEqual(droppedWhilePaused.dropReason, .paused)
        XCTAssertFalse(droppedWhilePaused.shouldAppend)

        controller.resume()
        let afterResume = controller.processSample(
            sourcePTS: pts(9.0),
            track: .video
        )
        XCTAssertTrue(afterResume.shouldAppend)
        XCTAssertEqual(seconds(afterResume.retimeOffset), 7.0, accuracy: 0.0001)
        XCTAssertEqual(
            seconds(retimedPTS(for: pts(9.0), using: afterResume)),
            2.0,
            accuracy: 0.0001
        )
    }

    func testNonMonotonicSampleIsDropped() {
        var controller = RecorderTimelineController()

        _ = controller.processSample(sourcePTS: pts(10.0), track: .video)
        _ = controller.processSample(sourcePTS: pts(10.5), track: .video)

        let dropped = controller.processSample(
            sourcePTS: pts(10.4),
            track: .video
        )
        XCTAssertEqual(dropped.dropReason, .nonMonotonic)
        XCTAssertFalse(dropped.shouldAppend)
    }

    private func pts(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func seconds(_ time: CMTime?) -> Double {
        guard let time else { return -1 }
        return time.seconds
    }

    private func retimedPTS(
        for sourcePTS: CMTime,
        using decision: RecorderTimelineDecision
    ) -> CMTime {
        CMTimeSubtract(sourcePTS, decision.retimeOffset ?? .zero)
    }
}
