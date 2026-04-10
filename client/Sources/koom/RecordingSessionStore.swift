import CoreGraphics
import Foundation

final class RecordingSessionStore: @unchecked Sendable {
    nonisolated static let sessionManifestFilename = "session.json"

    struct SessionHandle {
        var session: RecordingSession
        let directoryURL: URL
        let environment: KoomEnvironment

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
        var environment: KoomEnvironment?
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
        environment: KoomEnvironment,
        display: RecordingSession.DisplaySnapshot,
        cameraID: String?,
        microphoneID: String?,
        fragmentIntervalSeconds: TimeInterval
    ) throws -> SessionHandle {
        try ensureBaseDirectoriesExist(for: environment)

        let sessionID = UUID().uuidString.lowercased()
        let directoryURL = Self.sessionsDirectoryURL(
            for: environment,
            fileManager: fileManager
        )
        .appendingPathComponent(sessionID, isDirectory: true)
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let now = Date()
        let session = RecordingSession(
            manifestVersion: 2,
            sessionID: sessionID,
            createdAt: now,
            updatedAt: now,
            state: .recording,
            environment: environment,
            finalFilename: finalFilename,
            display: display,
            cameraID: normalizedOptionalID(cameraID),
            microphoneID: normalizedOptionalID(microphoneID),
            fragmentIntervalSeconds: fragmentIntervalSeconds,
            segments: []
        )

        let handle = SessionHandle(
            session: session,
            directoryURL: directoryURL,
            environment: environment
        )
        try writeManifest(for: handle)
        return handle
    }

    func loadRecoverableSessions() -> [SessionHandle] {
        var handles: [SessionHandle] = []

        for environment in KoomEnvironment.allCases {
            handles += contentsOfRecoverableSessions(
                at: Self.sessionsDirectoryURL(
                    for: environment,
                    fileManager: fileManager
                ),
                fallbackEnvironment: environment
            )
        }

        handles += contentsOfRecoverableSessions(
            at: Self.legacySessionsDirectoryURL(fileManager: fileManager),
            fallbackEnvironment: KoomConfig.legacyEnvironment
        )

        return handles.sorted {
            $0.session.updatedAt > $1.session.updatedAt
        }
    }

    private func contentsOfRecoverableSessions(
        at sessionsDirectory: URL,
        fallbackEnvironment: KoomEnvironment
    ) -> [SessionHandle] {
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
                let decodedSession = try? decoder.decode(
                    RecordingSession.self,
                    from: data
                )
            else {
                continue
            }

            guard
                decodedSession.state != .completed,
                decodedSession.state != .discarded
            else {
                continue
            }

            var session = decodedSession
            if session.environment == nil {
                session.environment = fallbackEnvironment
            }

            let handle = SessionHandle(
                session: session,
                directoryURL: directoryURL,
                environment: session.environment ?? fallbackEnvironment
            )
            let existingSegments = existingSegmentURLs(for: handle)
            guard !existingSegments.isEmpty else {
                try? fileManager.removeItem(at: directoryURL)
                continue
            }

            handles.append(handle)
        }

        return handles
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

    func finalOutputURL(
        for filename: String,
        environment: KoomEnvironment
    ) -> URL {
        Self.recordingsDirectoryURL(
            for: environment,
            fileManager: fileManager
        ).appendingPathComponent(filename)
    }

    func finalOutputURL(for handle: SessionHandle) -> URL {
        finalOutputURL(
            for: handle.session.finalFilename,
            environment: handle.environment
        )
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
        let destinationURL = finalOutputURL(for: handle)
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

    static func recordingsDirectoryURL(
        for environment: KoomEnvironment,
        fileManager: FileManager = .default
    ) -> URL {
        baseDirectory(fileManager: fileManager)
            .appendingPathComponent("koom", isDirectory: true)
            .appendingPathComponent(
                environment.recordingsSubdirectoryName,
                isDirectory: true
            )
    }

    static func legacyRecordingsDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL {
        baseDirectory(fileManager: fileManager)
            .appendingPathComponent("koom", isDirectory: true)
    }

    private func ensureBaseDirectoriesExist(
        for environment: KoomEnvironment
    ) throws {
        try fileManager.createDirectory(
            at: Self.recordingsDirectoryURL(
                for: environment,
                fileManager: fileManager
            ),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: Self.sessionsDirectoryURL(
                for: environment,
                fileManager: fileManager
            ),
            withIntermediateDirectories: true
        )
    }

    private static func sessionsDirectoryURL(
        for environment: KoomEnvironment,
        fileManager: FileManager
    ) -> URL {
        recordingsDirectoryURL(
            for: environment,
            fileManager: fileManager
        )
        .appendingPathComponent(".sessions", isDirectory: true)
    }

    private static func legacySessionsDirectoryURL(
        fileManager: FileManager
    ) -> URL {
        legacyRecordingsDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(".sessions", isDirectory: true)
    }

    private static func baseDirectory(fileManager: FileManager) -> URL {
        fileManager.urls(
            for: .moviesDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
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
