@preconcurrency import AVFoundation
import CoreMedia
import Foundation

final class RecordingAssembler: @unchecked Sendable {
    struct SegmentInspection {
        let duration: CMTime
        let hasVideo: Bool
        let hasAudio: Bool

        var durationSeconds: Double? {
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        }
    }

    func inspectSegment(at url: URL) async throws -> SegmentInspection {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)
        let hasVideo = tracks.contains { $0.mediaType == .video }
        let hasAudio = tracks.contains { $0.mediaType == .audio }

        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0, hasVideo else {
            throw RecordingAssemblerError.unusableSegment(
                url.lastPathComponent
            )
        }

        return SegmentInspection(
            duration: duration,
            hasVideo: hasVideo,
            hasAudio: hasAudio
        )
    }

    func assembleSession(
        _ handle: RecordingSessionStore.SessionHandle,
        store: RecordingSessionStore
    ) async throws -> URL {
        let preparedSegments = try await loadPreparedSegments(from: handle, store: store)
        guard !preparedSegments.isEmpty else {
            throw RecordingAssemblerError.noRecoverableSegments
        }

        let composition = AVMutableComposition()
        guard
            let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            throw RecordingAssemblerError.couldNotCreateCompositionTrack("video")
        }

        var compositionAudioTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero

        for preparedSegment in preparedSegments {
            let timeRange = CMTimeRange(
                start: .zero,
                duration: preparedSegment.duration
            )
            try compositionVideoTrack.insertTimeRange(
                timeRange,
                of: preparedSegment.videoTrack,
                at: cursor
            )

            if let audioTrack = preparedSegment.audioTrack {
                if compositionAudioTrack == nil {
                    compositionAudioTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                }

                try compositionAudioTrack?.insertTimeRange(
                    timeRange,
                    of: audioTrack,
                    at: cursor
                )
            }

            cursor = CMTimeAdd(cursor, preparedSegment.duration)
        }

        let outputURL = store.finalOutputURL(for: handle)
        try await export(
            asset: composition,
            to: outputURL,
            presetName: AVAssetExportPresetPassthrough
        )
        return outputURL
    }

    private struct PreparedSegment {
        let asset: AVURLAsset
        let duration: CMTime
        let videoTrack: AVAssetTrack
        let audioTrack: AVAssetTrack?
    }

    private func loadPreparedSegments(
        from handle: RecordingSessionStore.SessionHandle,
        store: RecordingSessionStore
    ) async throws -> [PreparedSegment] {
        var preparedSegments: [PreparedSegment] = []

        for segment in handle.session.segments.sorted(by: { $0.index < $1.index }) {
            let segmentURL = store.segmentURL(for: segment, in: handle)
            guard FileManager.default.fileExists(atPath: segmentURL.path) else {
                continue
            }

            let asset = AVURLAsset(url: segmentURL)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks)

            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else {
                continue
            }

            guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
                continue
            }

            let audioTrack = tracks.first(where: { $0.mediaType == .audio })

            preparedSegments.append(
                PreparedSegment(
                    asset: asset,
                    duration: duration,
                    videoTrack: videoTrack,
                    audioTrack: audioTrack
                )
            )
        }

        return preparedSegments
    }

    private func export(
        asset: AVAsset,
        to outputURL: URL,
        presetName: String
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)

        do {
            try await exportOnce(asset: asset, to: outputURL, presetName: presetName)
        } catch {
            guard presetName == AVAssetExportPresetPassthrough else {
                throw error
            }

            try? FileManager.default.removeItem(at: outputURL)
            try await exportOnce(
                asset: asset,
                to: outputURL,
                presetName: AVAssetExportPresetHighestQuality
            )
        }
    }

    private func exportOnce(
        asset: AVAsset,
        to outputURL: URL,
        presetName: String
    ) async throws {
        guard
            let exportSession = AVAssetExportSession(
                asset: asset,
                presetName: presetName
            )
        else {
            throw RecordingAssemblerError.exportSessionUnavailable(presetName)
        }

        if #available(macOS 15.0, *) {
            do {
                try await exportSession.export(to: outputURL, as: .mp4)
                return
            } catch {
                throw RecordingAssemblerError.exportFailed(
                    error.localizedDescription
                )
            }
        } else {
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mp4
            exportSession.shouldOptimizeForNetworkUse = false

            await withCheckedContinuation { continuation in
                exportSession.exportAsynchronously {
                    continuation.resume()
                }
            }

            switch exportSession.status {
            case .completed:
                return
            case .failed, .cancelled:
                throw RecordingAssemblerError.exportFailed(
                    exportSession.error?.localizedDescription
                        ?? "The export did not complete."
                )
            default:
                throw RecordingAssemblerError.exportFailed(
                    "The export ended in an unexpected state."
                )
            }
        }
    }
}

private enum RecordingAssemblerError: LocalizedError {
    case noRecoverableSegments
    case unusableSegment(String)
    case couldNotCreateCompositionTrack(String)
    case exportSessionUnavailable(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRecoverableSegments:
            return "koom could not find any usable media in the interrupted recording."
        case .unusableSegment(let filename):
            return "koom could not read a playable recording segment: \(filename)"
        case .couldNotCreateCompositionTrack(let kind):
            return "koom could not create a \(kind) track for recovery."
        case .exportSessionUnavailable(let presetName):
            return "koom could not create an export session (\(presetName))."
        case .exportFailed(let message):
            return "koom could not finalize the recovered recording. \(message)"
        }
    }
}
