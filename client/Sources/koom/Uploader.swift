@preconcurrency import AppKit
@preconcurrency import AVFoundation
import Foundation

/// State machine for an in-flight or completed **single-file**
/// upload. The UI binds to this via `AppModel.uploadState` and
/// renders the appropriate progress, success, or error affordance.
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

/// State machine for the **batch catch-up** flow — uploading every
/// local recording that isn't already on the backend. Per-file
/// progress lives in `UploadState`; this enum tracks the overall
/// batch position and terminal outcome.
enum CatchUpState: Equatable, Sendable {
    case idle
    case scanning
    case diffing(localCount: Int)
    case noMissingFiles(localCount: Int)
    case uploading(
        currentIndex: Int,
        totalMissing: Int,
        currentFilename: String
    )
    case completed(uploaded: Int, total: Int)
    case failed(uploaded: Int, total: Int, message: String)
}

/// Plain error struct used internally by `performUpload`. The
/// message is surfaced to the user verbatim via `UploadState.failed`
/// or `CatchUpState.failed`, so it should already be human-readable
/// at construction time.
private struct UploadFailure: Error {
    let message: String
}

/// Orchestrates upload flows against the koom backend.
///
/// Two public entry points:
///
///   - `uploadRecording(at:)` — single-file upload triggered right
///     after a recording stops. Runs the full state machine
///     including terminal states, and on success copies the share
///     URL to the pasteboard and opens it in the default browser.
///
///   - `catchUpRecordings(onCatchUpStateChange:)` — batch upload
///     for the "Sync Unsent Recordings" menu command. Scans
///     `~/Movies/koom/`, asks the backend which files are missing,
///     and uploads each one sequentially. Does NOT open browser
///     tabs per file (that would spam N tabs for a batch of N).
///
/// Both entry points share a private `performUpload(at:)` method
/// that handles the init → streaming PUT → complete sequence and
/// emits `UploadState` progress updates along the way. The shared
/// method returns a typed `Result` so each entry point can decide
/// how to handle success/failure at the batch level.
///
/// Error handling contract: the local recording file is **never**
/// deleted or mutated by this class. Any failure path leaves the
/// MP4 untouched so the user can retry later via catch-up.
@MainActor
final class Uploader {
    /// Per-file upload state updates. The progress-reporting
    /// closure must be @Sendable because the upload flow hands it
    /// to a URLSession delegate on a background queue. Callers
    /// (AppModel) satisfy this by hopping to the main actor inside
    /// the closure via `Task { @MainActor in ... }`.
    var onStateChange: (@Sendable (UploadState) -> Void)?

    // MARK: Single-file upload (post-recording)

    func uploadRecording(at fileURL: URL) async {
        emit(.preparing)
        let result = await performUpload(at: fileURL)
        switch result {
        case .success(let shareURL):
            openAndPasteShareURL(shareURL)
            emit(.completed(shareURL: shareURL))
        case .failure(let failure):
            emit(.failed(message: failure.message))
        }
    }

    // MARK: Batch catch-up

    /// Scans the local recordings directory, asks the backend which
    /// files still need to be uploaded, and uploads each missing
    /// file sequentially. Per-file progress is emitted via the
    /// existing `onStateChange` callback (so the UI's per-file
    /// progress bar works unchanged). Batch-level progress is
    /// emitted via the provided `onCatchUpStateChange` callback.
    ///
    /// Continues past individual file failures — one bad upload
    /// doesn't abort the whole batch. Final state reports totals.
    func catchUpRecordings(
        onCatchUpStateChange: @Sendable @escaping (CatchUpState) -> Void
    ) async {
        onCatchUpStateChange(.scanning)
        let localFiles = Self.scanLocalRecordings()

        guard !localFiles.isEmpty else {
            onCatchUpStateChange(.completed(uploaded: 0, total: 0))
            return
        }

        onCatchUpStateChange(.diffing(localCount: localFiles.count))

        // We need the API client for the diff call — load config once
        // upfront so we fail fast if it's missing, instead of after
        // the directory scan.
        guard let api = makeAPIClient() else {
            onCatchUpStateChange(
                .failed(
                    uploaded: 0,
                    total: 0,
                    message: KoomAPI.APIError.missingBackendURL
                        .localizedDescription
                )
            )
            return
        }

        let filenames = localFiles.map { $0.lastPathComponent }
        let diffResponse: KoomAPI.DiffFilenamesResponse
        do {
            diffResponse = try await api.diffFilenames(filenames)
        } catch {
            onCatchUpStateChange(
                .failed(
                    uploaded: 0,
                    total: 0,
                    message: error.localizedDescription
                )
            )
            return
        }

        let missingSet = Set(diffResponse.missing)
        let missingURLs = localFiles.filter {
            missingSet.contains($0.lastPathComponent)
        }

        guard !missingURLs.isEmpty else {
            onCatchUpStateChange(.noMissingFiles(localCount: localFiles.count))
            return
        }

        AppLog.info(
            "Catch-up found \(missingURLs.count) missing file(s) out of \(localFiles.count) local recording(s)."
        )

        var successCount = 0
        var lastError: String?

        for (zeroIndex, fileURL) in missingURLs.enumerated() {
            let humanIndex = zeroIndex + 1
            onCatchUpStateChange(
                .uploading(
                    currentIndex: humanIndex,
                    totalMissing: missingURLs.count,
                    currentFilename: fileURL.lastPathComponent
                )
            )
            AppLog.info(
                "Catch-up \(humanIndex)/\(missingURLs.count): \(fileURL.lastPathComponent)"
            )

            emit(.preparing)
            let result = await performUpload(at: fileURL)

            switch result {
            case .success:
                successCount += 1
                // Drop the per-file progress UI between files so it
                // re-animates from 0% on the next one.
                emit(.idle)
            case .failure(let failure):
                lastError = failure.message
                AppLog.error(
                    "Catch-up failed on \(fileURL.lastPathComponent): \(failure.message)"
                )
                emit(.idle)
                // Intentionally continue to the next file.
            }
        }

        if successCount == missingURLs.count {
            onCatchUpStateChange(
                .completed(
                    uploaded: successCount,
                    total: missingURLs.count
                )
            )
        } else {
            let failedCount = missingURLs.count - successCount
            onCatchUpStateChange(
                .failed(
                    uploaded: successCount,
                    total: missingURLs.count,
                    message: lastError.map { "\(failedCount) upload(s) failed. Last error: \($0)" }
                        ?? "\(failedCount) upload(s) failed."
                )
            )
        }
    }

    // MARK: - Internals

    /// Reads config, resolves metadata, and runs init → PUT →
    /// complete against the backend. Emits progress via
    /// `onStateChange` for preparing / initializing / uploading /
    /// finalizing. Does NOT emit the terminal `.completed` or
    /// `.failed` states — that's the caller's job — and does NOT
    /// perform the clipboard/browser side effects.
    private func performUpload(at fileURL: URL) async -> Result<URL, UploadFailure> {
        guard let api = makeAPIClient() else {
            return .failure(
                UploadFailure(
                    message: KoomAPI.APIError.missingBackendURL.localizedDescription
                )
            )
        }

        // Metadata about the finalized local file.
        let sizeBytes: Int64
        do {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: fileURL.path
            )
            sizeBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard sizeBytes > 0 else {
                return .failure(
                    UploadFailure(
                        message: "Local recording file is empty: \(fileURL.lastPathComponent)"
                    )
                )
            }
        } catch {
            return .failure(
                UploadFailure(
                    message: "Could not stat \(fileURL.lastPathComponent): \(error.localizedDescription)"
                )
            )
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
            return .failure(UploadFailure(message: error.localizedDescription))
        }

        AppLog.info(
            "Upload init: recordingId=\(initResponse.recordingId), shareUrl=\(initResponse.shareUrl)"
        )

        // Step 2: PUT bytes directly to R2 with progress.
        //
        // The progress closure must be @Sendable because it's
        // consumed by URLSession's delegate off the main actor.
        // Capturing `self` would drag main-actor isolation into the
        // closure, so we capture a local copy of `onStateChange`
        // (which is already @Sendable by type).
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
            return .failure(UploadFailure(message: error.localizedDescription))
        }

        // Step 3: complete
        emit(.finalizing)
        let completeResponse: KoomAPI.CompleteUploadResponse
        do {
            completeResponse = try await api.completeUpload(
                recordingId: initResponse.recordingId
            )
        } catch {
            return .failure(UploadFailure(message: error.localizedDescription))
        }

        guard let shareURL = URL(string: completeResponse.shareUrl) else {
            return .failure(
                UploadFailure(
                    message: "Server returned an invalid share URL: \(completeResponse.shareUrl)"
                )
            )
        }

        AppLog.info("Upload complete: \(shareURL.absoluteString)")
        return .success(shareURL)
    }

    /// Copies the share URL to the system pasteboard and opens it
    /// in the user's default browser. Called only for single-file
    /// uploads — the batch catch-up path intentionally skips this
    /// to avoid spamming browser tabs.
    private func openAndPasteShareURL(_ shareURL: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(shareURL.absoluteString, forType: .string)
        NSWorkspace.shared.open(shareURL)
    }

    private func makeAPIClient() -> KoomAPI? {
        guard let backendURL = KoomConfig.backendURL else {
            return nil
        }
        let secret: String
        do {
            guard let loaded = try KoomConfig.loadAdminSecret(),
                  !loaded.isEmpty else {
                return nil
            }
            secret = loaded
        } catch {
            AppLog.error(
                "Could not read admin secret from Keychain: \(error.localizedDescription)"
            )
            return nil
        }
        return KoomAPI(backendURL: backendURL, adminSecret: secret)
    }

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
            AppLog.info(
                "Could not read duration for \(fileURL.lastPathComponent): \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Enumerates `.mp4` files inside `~/Movies/koom/`, sorted by
    /// filename (which, because the recorder uses
    /// `koom_YYYY-MM-DD_HH-mm-ss.mp4`, also gives chronological
    /// order). Returns an empty array if the directory doesn't
    /// exist yet.
    private static func scanLocalRecordings() -> [URL] {
        let baseDirectory =
            FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        let recordingsDirectory = baseDirectory.appendingPathComponent(
            "koom",
            isDirectory: true
        )

        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: recordingsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        return entries
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
