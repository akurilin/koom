import CoreMedia
import Foundation

enum RecorderTrack: String {
    case video
    case audio
}

enum RecorderSampleDropReason: Equatable {
    case paused
    case nonMonotonic
    case waitingForSessionAnchor
}

struct RecorderTimelineDecision {
    let dropReason: RecorderSampleDropReason?
    let shouldStartSession: Bool
    let didAnchorTrack: Bool
    let shouldLogFirstSampleFormat: Bool
    let sessionOffset: CMTime?
    let retimeOffset: CMTime?

    var shouldAppend: Bool {
        dropReason == nil && retimeOffset != nil
    }
}

struct RecorderTimelineController {
    private struct TrackState {
        var firstPTS: CMTime?
        var lastRetimedPTS: CMTime?
        var hasSeenFirstSample = false
    }

    private struct PauseState {
        var accumulatedOffset: CMTime = .zero
        var pausePTS: CMTime?
        var needsResumeOffset = false
    }

    private var sessionStartPTS: CMTime?
    private var pauseState = PauseState()
    private var isPaused = false
    private var videoState = TrackState()
    private var audioState = TrackState()

    mutating func pause() {
        isPaused = true
    }

    mutating func resume() {
        isPaused = false
        pauseState.needsResumeOffset = true
    }

    mutating func processSample(
        sourcePTS: CMTime,
        track: RecorderTrack
    ) -> RecorderTimelineDecision {
        if isPaused {
            if pauseState.pausePTS == nil, CMTIME_IS_VALID(sourcePTS) {
                pauseState.pausePTS = sourcePTS
            }
            return .init(
                dropReason: .paused,
                shouldStartSession: false,
                didAnchorTrack: false,
                shouldLogFirstSampleFormat: false,
                sessionOffset: nil,
                retimeOffset: nil
            )
        }

        if pauseState.needsResumeOffset {
            if let pausePTS = pauseState.pausePTS, CMTIME_IS_VALID(sourcePTS) {
                let pauseDelta = CMTimeSubtract(sourcePTS, pausePTS)
                if pauseDelta > .zero {
                    pauseState.accumulatedOffset = CMTimeAdd(
                        pauseState.accumulatedOffset,
                        pauseDelta
                    )
                }
            }

            pauseState.pausePTS = nil
            pauseState.needsResumeOffset = false
        }

        var trackState = state(for: track)
        var shouldStartSession = false
        var didAnchorTrack = false
        var sessionOffset: CMTime?
        var shouldLogFirstSampleFormat = false

        if trackState.firstPTS == nil, CMTIME_IS_VALID(sourcePTS) {
            trackState.firstPTS = sourcePTS
            didAnchorTrack = true

            if sessionStartPTS == nil {
                sessionStartPTS = sourcePTS
                shouldStartSession = true
            }

            sessionOffset =
                sessionStartPTS.map {
                    CMTimeSubtract(sourcePTS, $0)
                } ?? .zero
        }

        if !trackState.hasSeenFirstSample {
            trackState.hasSeenFirstSample = true
            shouldLogFirstSampleFormat = true
        }

        guard let sessionStartPTS else {
            setState(trackState, for: track)
            return .init(
                dropReason: .waitingForSessionAnchor,
                shouldStartSession: false,
                didAnchorTrack: didAnchorTrack,
                shouldLogFirstSampleFormat: shouldLogFirstSampleFormat,
                sessionOffset: sessionOffset,
                retimeOffset: nil
            )
        }

        let retimeOffset = CMTimeAdd(
            sessionStartPTS,
            pauseState.accumulatedOffset
        )
        let retimedPTS = CMTimeSubtract(sourcePTS, retimeOffset)

        if let lastRetimedPTS = trackState.lastRetimedPTS,
            CMTIME_IS_VALID(retimedPTS),
            CMTIME_IS_VALID(lastRetimedPTS),
            retimedPTS <= lastRetimedPTS
        {
            setState(trackState, for: track)
            return .init(
                dropReason: .nonMonotonic,
                shouldStartSession: shouldStartSession,
                didAnchorTrack: didAnchorTrack,
                shouldLogFirstSampleFormat: shouldLogFirstSampleFormat,
                sessionOffset: sessionOffset,
                retimeOffset: retimeOffset
            )
        }

        trackState.lastRetimedPTS = retimedPTS
        setState(trackState, for: track)

        return .init(
            dropReason: nil,
            shouldStartSession: shouldStartSession,
            didAnchorTrack: didAnchorTrack,
            shouldLogFirstSampleFormat: shouldLogFirstSampleFormat,
            sessionOffset: sessionOffset,
            retimeOffset: retimeOffset
        )
    }

    private func state(for track: RecorderTrack) -> TrackState {
        switch track {
        case .video:
            return videoState
        case .audio:
            return audioState
        }
    }

    private mutating func setState(
        _ state: TrackState,
        for track: RecorderTrack
    ) {
        switch track {
        case .video:
            videoState = state
        case .audio:
            audioState = state
        }
    }
}

struct RecorderBackpressureDecision {
    let shouldLog: Bool
    let shouldReportRuntimeIssue: Bool
    let droppedVideoSamples: Int
    let consecutiveAudioBackpressureSamples: Int
}

struct RecorderBackpressureMonitor {
    let maxConsecutiveAudioBackpressureSamples: Int

    private(set) var droppedVideoSamples = 0
    private(set) var consecutiveAudioBackpressureSamples = 0

    init(maxConsecutiveAudioBackpressureSamples: Int = 5) {
        self.maxConsecutiveAudioBackpressureSamples =
            maxConsecutiveAudioBackpressureSamples
    }

    mutating func noteSuccessfulAppend(for track: RecorderTrack) {
        guard track == .audio else { return }
        consecutiveAudioBackpressureSamples = 0
    }

    mutating func noteBackpressure(
        for track: RecorderTrack
    ) -> RecorderBackpressureDecision {
        switch track {
        case .audio:
            consecutiveAudioBackpressureSamples += 1
            return .init(
                shouldLog: consecutiveAudioBackpressureSamples == 1
                    || consecutiveAudioBackpressureSamples
                        == maxConsecutiveAudioBackpressureSamples,
                shouldReportRuntimeIssue: consecutiveAudioBackpressureSamples
                    >= maxConsecutiveAudioBackpressureSamples,
                droppedVideoSamples: droppedVideoSamples,
                consecutiveAudioBackpressureSamples:
                    consecutiveAudioBackpressureSamples
            )

        case .video:
            droppedVideoSamples += 1
            return .init(
                shouldLog: droppedVideoSamples == 1
                    || droppedVideoSamples.isMultiple(of: 60),
                shouldReportRuntimeIssue: false,
                droppedVideoSamples: droppedVideoSamples,
                consecutiveAudioBackpressureSamples:
                    consecutiveAudioBackpressureSamples
            )
        }
    }
}
