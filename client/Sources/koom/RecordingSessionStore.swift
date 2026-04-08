import CoreGraphics
import Foundation

final class RecordingSessionStore: @unchecked Sendable {
    nonisolated static let sessionManifestFilename = "session.json"

    struct SessionHandle {
        var session: RecordingSession
        let directoryURL: URL

        var manifestURL: URL {
            directoryURL.appendingPathComponent(
                RecordingSessionStore.sessionManifestFilename
            )
        }
    }

    struct RecordingSession: Codable {
        enum State: String, Codable {
            case recording
            case paused
            case finalizing
            case completed
            case discarded
        }

        struct DisplaySnapshot: Codable {
            let id: UInt32
            let name: String
            let width: Int
            let height: Int
        }

        struct Segment: Codable, Identifiable {
            let index: Int
            let filename: String
            let startedAt: Date
            var endedAt: Date?
            var cleanStop: Bool
            var durationSeconds: Double?
            var hasVideo: Bool?
            var hasAudio: Bool?

            var id: Int { index }
        }

        let manifestVersion: Int
        let sessionID: String
        let createdAt: Date
        var updatedAt: Date
        var state: State
        let finalFilename: String
        let display: DisplaySnapshot
        let cameraID: String?
        let microphoneID: String?
        let fragmentIntervalSeconds: Double
        var segments: [Segment]
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func createSession(
        finalFilename: String,
        display: RecordingSession.DisplaySnapshot,
        cameraID: String?,
        microphoneID: String?,
        fragmentIntervalSeconds: TimeInterval
    ) throws -> SessionHandle {
        try ensureBaseDirectoriesExist()

        let sessionID = UUID().uuidString.lowercased()
        let directoryURL = sessionsDirectoryURL()
            .appendingPathComponent(sessionID, isDirectory: true)
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let now = Date()
        let session = RecordingSession(
            manifestVersion: 1,
            sessionID: sessionID,
            createdAt: now,
            updatedAt: now,
            state: .recording,
            finalFilename: finalFilename,
            display: display,
            cameraID: normalizedOptionalID(cameraID),
            microphoneID: normalizedOptionalID(microphoneID),
            fragmentIntervalSeconds: fragmentIntervalSeconds,
            segments: []
        )

        let handle = SessionHandle(session: session, directoryURL: directoryURL)
        try writeManifest(for: handle)
        return handle
    }

    func loadRecoverableSessions() -> [SessionHandle] {
        let sessionsDirectory = sessionsDirectoryURL()
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: sessionsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var handles: [SessionHandle] = []

        for directoryURL in entries {
                let manifestURL = directoryURL.appendingPathComponent(
                    Self.sessionManifestFilename
                )
            let decoder = JSONDecoder()
            guard
                let data = try? Data(contentsOf: manifestURL),
                let session = try? decoder.decode(
                    RecordingSession.self,
                    from: data
                )
            else {
                continue
            }

            guard session.state != .completed, session.state != .discarded else {
                continue
            }

            let handle = SessionHandle(session: session, directoryURL: directoryURL)
            let existingSegments = existingSegmentURLs(for: handle)
            guard !existingSegments.isEmpty else {
                try? fileManager.removeItem(at: directoryURL)
                continue
            }

            handles.append(handle)
        }

        return handles.sorted {
            $0.session.updatedAt > $1.session.updatedAt
        }
    }

    func createNextSegment(in handle: inout SessionHandle) throws -> URL {
        let nextIndex = handle.session.segments.count + 1
        let filename = String(format: "segment-%04d.mp4", nextIndex)
        let now = Date()
        handle.session.segments.append(
            .init(
                index: nextIndex,
                filename: filename,
                startedAt: now,
                endedAt: nil,
                cleanStop: false,
                durationSeconds: nil,
                hasVideo: nil,
                hasAudio: nil
            )
        )
        handle.session.state = .recording
        handle.session.updatedAt = now
        try writeManifest(for: handle)
        return segmentURL(forFilename: filename, in: handle)
    }

    func removeLatestSegment(in handle: inout SessionHandle) throws {
        guard let latestSegment = handle.session.segments.popLast() else {
            return
        }

        let latestSegmentURL = segmentURL(for: latestSegment, in: handle)
        if fileManager.fileExists(atPath: latestSegmentURL.path) {
            try? fileManager.removeItem(at: latestSegmentURL)
        }

        handle.session.updatedAt = Date()
        try writeManifest(for: handle)
    }

    func updateState(
        _ state: RecordingSession.State,
        in handle: inout SessionHandle
    ) throws {
        handle.session.state = state
        handle.session.updatedAt = Date()
        try writeManifest(for: handle)
    }

    func markLatestSegmentStopped(
        in handle: inout SessionHandle,
        cleanStop: Bool,
        durationSeconds: Double?,
        hasVideo: Bool,
        hasAudio: Bool
    ) throws {
        guard !handle.session.segments.isEmpty else { return }

        handle.session.segments[handle.session.segments.count - 1].endedAt = Date()
        handle.session.segments[handle.session.segments.count - 1].cleanStop = cleanStop
        handle.session.segments[handle.session.segments.count - 1].durationSeconds = durationSeconds
        handle.session.segments[handle.session.segments.count - 1].hasVideo = hasVideo
        handle.session.segments[handle.session.segments.count - 1].hasAudio = hasAudio
        handle.session.updatedAt = Date()
        try writeManifest(for: handle)
    }

    func finalOutputURL(for filename: String) -> URL {
        recordingsDirectoryURL().appendingPathComponent(filename)
    }

    func segmentURL(
        for segment: RecordingSession.Segment,
        in handle: SessionHandle
    ) -> URL {
        segmentURL(forFilename: segment.filename, in: handle)
    }

    func promoteSingleSegmentToFinalLocation(
        from handle: SessionHandle
    ) throws -> URL {
        guard let onlySegment = handle.session.segments.first else {
            throw SessionStoreError.missingSegment
        }

        let sourceURL = segmentURL(for: onlySegment, in: handle)
        let destinationURL = finalOutputURL(for: handle.session.finalFilename)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    func cleanupSessionDirectory(for handle: SessionHandle) throws {
        if fileManager.fileExists(atPath: handle.directoryURL.path) {
            try fileManager.removeItem(at: handle.directoryURL)
        }
    }

    func discardSession(_ handle: SessionHandle) throws {
        try cleanupSessionDirectory(for: handle)
    }

    func existingSegmentURLs(for handle: SessionHandle) -> [URL] {
        handle.session.segments
            .sorted { $0.index < $1.index }
            .map { segmentURL(for: $0, in: handle) }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    private func ensureBaseDirectoriesExist() throws {
        try fileManager.createDirectory(
            at: recordingsDirectoryURL(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: sessionsDirectoryURL(),
            withIntermediateDirectories: true
        )
    }

    private func recordingsDirectoryURL() -> URL {
        let baseDirectory = fileManager.urls(
            for: .moviesDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
        return baseDirectory.appendingPathComponent("koom", isDirectory: true)
    }

    private func sessionsDirectoryURL() -> URL {
        recordingsDirectoryURL()
            .appendingPathComponent(".sessions", isDirectory: true)
    }

    private func segmentURL(
        forFilename filename: String,
        in handle: SessionHandle
    ) -> URL {
        handle.directoryURL.appendingPathComponent(filename)
    }

    private func writeManifest(for handle: SessionHandle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(handle.session)
        try data.write(to: handle.manifestURL, options: .atomic)
    }

    private func normalizedOptionalID(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private enum SessionStoreError: LocalizedError {
    case missingSegment

    var errorDescription: String? {
        switch self {
        case .missingSegment:
            return "The interrupted recording is missing its media segment."
        }
    }
}
