@preconcurrency import AppKit
@preconcurrency import AVFoundation
import Foundation

/// State machine for an in-flight or completed upload. The UI binds
/// to this via `AppModel.uploadState` and renders the appropriate
/// progress, success, or error affordance.
///
/// Marked `Sendable` so it can be carried across actor boundaries
/// by the progress callback closure that hops from the URLSession
/// delegate's thread back onto the main actor.
enum UploadState: Equatable, Sendable {
    case idle
    case preparing
    case initializing
    case uploading(progress: Double)
    case finalizing
    case completed(shareURL: URL)
    case failed(message: String)
}

/// Orchestrates the full three-step upload flow for a single
/// recording: init → streaming PUT to R2 → complete.
///
/// The `onStateChange` callback lets the caller (AppModel) observe
/// state transitions without creating a retain cycle. All state
/// transitions happen on the main actor because the callback
/// ultimately drives SwiftUI updates.
///
/// Error handling contract: the local recording file is **never**
/// deleted or mutated by this class. Any failure path leaves the
/// MP4 untouched so the user can retry later (via the catch-up
/// feature that Round C will add, or a manual re-trigger).
@MainActor
final class Uploader {
    /// The progress-reporting closure must be @Sendable because the
    /// upload flow hands it to a URLSession delegate on a background
    /// queue. Callers (AppModel) satisfy this by hopping to the main
    /// actor inside the closure via `Task { @MainActor in ... }`.
    var onStateChange: (@Sendable (UploadState) -> Void)?

    func uploadRecording(at fileURL: URL) async {
        emit(.preparing)

        guard let backendURL = KoomConfig.backendURL else {
            emit(.failed(message: KoomAPI.APIError.missingBackendURL.localizedDescription))
            return
        }

        let adminSecret: String
        do {
            guard let loaded = try KoomConfig.loadAdminSecret(),
                  !loaded.isEmpty else {
                emit(.failed(message: KoomAPI.APIError.missingAdminSecret.localizedDescription))
                return
            }
            adminSecret = loaded
        } catch {
            emit(.failed(message: "Could not read admin secret from Keychain: \(error.localizedDescription)"))
            return
        }

        let api = KoomAPI(backendURL: backendURL, adminSecret: adminSecret)

        // Metadata about the finalized local file.
        let sizeBytes: Int64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            sizeBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard sizeBytes > 0 else {
                emit(.failed(message: "Local recording file is empty: \(fileURL.lastPathComponent)"))
                return
            }
        } catch {
            emit(.failed(message: "Could not stat \(fileURL.lastPathComponent): \(error.localizedDescription)"))
            return
        }

        // Duration is best-effort. If AVFoundation can't read it we
        // send null rather than failing the upload — the backend
        // contract allows nullable duration.
        let durationSeconds = await Self.readDurationSeconds(of: fileURL)

        // Step 1: init
        emit(.initializing)
        let initResponse: KoomAPI.InitUploadResponse
        do {
            initResponse = try await api.initUpload(
                originalFilename: fileURL.lastPathComponent,
                contentType: "video/mp4",
                sizeBytes: sizeBytes,
                durationSeconds: durationSeconds,
                title: nil
            )
        } catch {
            emit(.failed(message: error.localizedDescription))
            return
        }

        AppLog.info("Upload init: recordingId=\(initResponse.recordingId), shareUrl=\(initResponse.shareUrl)")

        // Step 2: PUT bytes directly to R2 with progress.
        //
        // The progress closure must be @Sendable because it's
        // consumed by URLSession's delegate off the main actor.
        // Capturing `self` would drag main-actor isolation into the
        // closure, so we capture a local copy of `onStateChange`
        // (which is already @Sendable by type) and call it
        // directly. `onStateChange` is set by AppModel with a
        // closure that hops back to the main actor via
        // `Task { @MainActor in ... }`.
        emit(.uploading(progress: 0.0))
        let onStateChange = self.onStateChange
        do {
            try await api.uploadFile(
                fileURL: fileURL,
                to: initResponse.upload.url,
                method: initResponse.upload.method,
                headers: initResponse.upload.headers ?? [:],
                progressHandler: { fraction in
                    onStateChange?(.uploading(progress: fraction))
                }
            )
        } catch {
            emit(.failed(message: error.localizedDescription))
            return
        }

        // Step 3: complete
        emit(.finalizing)
        let completeResponse: KoomAPI.CompleteUploadResponse
        do {
            completeResponse = try await api.completeUpload(
                recordingId: initResponse.recordingId
            )
        } catch {
            emit(.failed(message: error.localizedDescription))
            return
        }

        guard let shareURL = URL(string: completeResponse.shareUrl) else {
            emit(.failed(message: "Server returned an invalid share URL: \(completeResponse.shareUrl)"))
            return
        }

        AppLog.info("Upload complete: \(shareURL.absoluteString)")

        // Copy the share URL to the clipboard so the user can paste
        // it immediately, then open it in the default browser.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(shareURL.absoluteString, forType: .string)
        NSWorkspace.shared.open(shareURL)

        emit(.completed(shareURL: shareURL))
    }

    // MARK: - Internals

    private func emit(_ state: UploadState) {
        onStateChange?(state)
    }

    /// Best-effort read of an MP4's duration via AVFoundation.
    /// Returns nil if the asset can't be loaded or has no duration.
    private static func readDurationSeconds(of fileURL: URL) async -> Double? {
        let asset = AVURLAsset(url: fileURL)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 {
                return seconds
            }
            return nil
        } catch {
            AppLog.info("Could not read duration for \(fileURL.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }
}
