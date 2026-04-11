@preconcurrency import AVFoundation
@preconcurrency import AppKit
import CoreGraphics

@MainActor
final class AppModel: ObservableObject {
    struct DisplayOption: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let name: String
        let size: CGSize
    }

    struct DeviceOption: Identifiable, Hashable {
        let id: String
        let name: String
    }

    enum RecordingState {
        case idle
        case recording
        case paused
    }

    @Published var displays: [DisplayOption] = []
    @Published var cameras: [DeviceOption] = []
    @Published var microphones: [DeviceOption] = []
    @Published var selectedDisplayID: CGDirectDisplayID = 0 {
        didSet {
            settingsStore.saveSelectedDisplayID(selectedDisplayID)
        }
    }
    @Published var selectedCameraID = "" {
        didSet {
            settingsStore.saveSelectedCameraID(selectedCameraID)
        }
    }
    @Published var selectedMicrophoneID = "" {
        didSet {
            settingsStore.saveSelectedMicrophoneID(selectedMicrophoneID)
        }
    }
    @Published var recordingState: RecordingState = .idle {
        didSet {
            AppLog.info("Recording state: \(String(describing: recordingState))")
            if let controlWindow {
                applyControlWindowCapturePolicy(controlWindow)
            }
        }
    }
    @Published var isBusy = false
    @Published var statusMessage = "Ready." {
        didSet {
            AppLog.info("Status: \(statusMessage)")
        }
    }
    @Published var lastRecordingURL: URL?
    @Published var uploadState: UploadState = .idle
    @Published var catchUpState: CatchUpState = .idle
    @Published var isCatchingUp: Bool = false

    var isRecordingInProgress: Bool {
        recorder != nil
    }

    private enum RecoveryDecision {
        case resume
        case finishPartial
        case notNow
        case discard
    }

    private let cameraPreviewManager = CameraPreviewManager()
    private let overlayWindowController = CameraOverlayWindowController()
    private let settingsStore: AppSettingsStore
    private let uploader = Uploader()
    private let sessionStore = RecordingSessionStore()
    private let assembler = RecordingAssembler()
    private let fragmentIntervalSeconds: TimeInterval = 2

    private var recorder: ScreenRecorder?
    private weak var controlWindow: NSWindow?
    private var isControlWindowCaptureSuppressed = false
    private var hasPlacedWindow = false
    private var currentSession: RecordingSessionStore.SessionHandle?
    private var currentSessionWasRecovered = false
    private var isHandlingRecorderRuntimeIssue = false

    init(settingsStore: AppSettingsStore = AppSettingsStore()) {
        self.settingsStore = settingsStore

        uploader.onStateChange = { @Sendable [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.uploadState = state
                if let uploadStatusMessage = self.uploadStatusMessage(for: state) {
                    self.statusMessage = uploadStatusMessage
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .koomCatchUpRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.catchUpRecordings()
            }
        }

        let restoredSettings = settingsStore.load()
        if let restoredDisplayID = restoredSettings.selectedDisplayID {
            selectedDisplayID = restoredDisplayID
        }
        selectedCameraID = restoredSettings.selectedCameraID ?? ""
        selectedMicrophoneID = restoredSettings.selectedMicrophoneID ?? ""

        AppLog.info(
            "Restored settings. Display: \(restoredSettings.selectedDisplayID.map(String.init) ?? "none"), camera: \(restoredSettings.selectedCameraID ?? "none"), microphone: \(restoredSettings.selectedMicrophoneID ?? "none"), compression: \(restoredSettings.compressionSettings.logDescription)"
        )
    }

    func warmBackgroundServices() {
        Task { [uploader] in
            let issue = await uploader.prepareForLaunch()
            guard let issue else { return }

            await MainActor.run {
                if self.statusMessage == "Ready." {
                    self.statusMessage =
                        "Auto-title is unavailable right now. See Troubleshooting > Reveal Logs in Finder."
                }
            }
            AppLog.error("Background services: \(issue)")
        }
    }

    // MARK: - Catch-up

    func catchUpRecordings() {
        guard !isCatchingUp else {
            AppLog.info("Catch-up already in progress; ignoring duplicate request.")
            return
        }
        isCatchingUp = true

        let onCatchUpStateChange: @Sendable (CatchUpState) -> Void = { [weak self] state in
            Task { @MainActor in
                self?.catchUpState = state
            }
        }

        Task { [uploader] in
            await uploader.catchUpRecordings(
                onCatchUpStateChange: onCatchUpStateChange
            )
            await MainActor.run {
                self.isCatchingUp = false
            }
        }
    }

    // MARK: - Recovery

    func recoverInterruptedSessionsIfNeeded(attachedTo window: NSWindow) async {
        guard recorder == nil, !isBusy else { return }

        let recoverableSessions = sessionStore.loadRecoverableSessions()
        guard !recoverableSessions.isEmpty else { return }

        for recoverableSession in recoverableSessions {
            let decision = await presentRecoveryPrompt(
                for: recoverableSession,
                attachedTo: window
            )

            switch decision {
            case .resume:
                guard applySelections(from: recoverableSession) else {
                    return
                }
                await startRecordingTask(
                    resuming: recoverableSession,
                    recovered: true
                )
                return

            case .finishPartial:
                await finalizeRecoveredSession(recoverableSession)

            case .discard:
                try? sessionStore.discardSession(recoverableSession)
                statusMessage = "Discarded interrupted recording \(recoverableSession.session.finalFilename)."

            case .notNow:
                statusMessage = "Interrupted recording kept for later recovery."
                return
            }
        }
    }

    func refreshHardware() {
        refreshDisplays()
        refreshCaptureDevices()
        updateOverlay()
        AppLog.info("Hardware refreshed. Displays: \(displays.count), cameras: \(cameras.count), microphones: \(microphones.count)")
    }

    func configureControlWindow(_ window: NSWindow) {
        controlWindow = window
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        applyControlWindowCapturePolicy(window)
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true

        if !hasPlacedWindow, let screen = NSScreen.main ?? NSScreen.screens.first {
            let origin = NSPoint(
                x: screen.visibleFrame.midX - (window.frame.width / 2),
                y: screen.visibleFrame.midY - (window.frame.height / 2)
            )
            window.setFrameOrigin(origin)
            hasPlacedWindow = true
            AppLog.info("Placed control panel at (\(Int(origin.x)), \(Int(origin.y))) on \(screen.localizedName).")
        }
    }

    func displaySelectionDidChange() {
        AppLog.info("Selected display: \(selectedDisplayID)")
        updateOverlay()
    }

    func cameraSelectionDidChange() {
        AppLog.info("Selected camera: \(selectedCameraID.isEmpty ? "none" : selectedCameraID)")
        cameraPreviewManager.setCamera(uniqueID: selectedCameraID.isEmpty ? nil : selectedCameraID)
        updateOverlay()
    }

    func microphoneSelectionDidChange() {
        AppLog.info("Selected microphone: \(selectedMicrophoneID.isEmpty ? "none" : selectedMicrophoneID)")
    }

    func revealLastRecording() {
        guard let url = lastRecordingURL, FileManager.default.fileExists(atPath: url.path) else { return }
        AppLog.info("Revealing recording at \(url.path)")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func startRecording() {
        guard recordingState == .idle, !isBusy else { return }
        AppLog.info("Start recording requested.")
        Task {
            await startRecordingTask()
        }
    }

    func stopRecording() {
        guard recordingState != .idle, !isBusy else { return }
        AppLog.info("Stop recording requested.")
        Task {
            _ = await stopRecordingTask(
                discardOutput: false,
                restartAfterStop: false,
                uploadAfterStop: true,
                awaitUploadAfterStop: false
            )
        }
    }

    func restartRecording() {
        guard recordingState != .idle, !isBusy else {
            if recordingState == .idle {
                startRecording()
            }
            return
        }

        AppLog.info("Restart recording requested.")
        Task {
            _ = await stopRecordingTask(
                discardOutput: true,
                restartAfterStop: true,
                uploadAfterStop: true,
                awaitUploadAfterStop: false
            )
        }
    }

    func resolveRecordingForTermination(discardOutput: Bool) async -> Bool {
        guard recorder != nil else { return true }
        return await stopRecordingTask(
            discardOutput: discardOutput,
            restartAfterStop: false,
            uploadAfterStop: !discardOutput,
            awaitUploadAfterStop: !discardOutput
        )
    }

    func togglePause() {
        guard let recorder else { return }
        guard var currentSession else { return }

        switch recordingState {
        case .recording:
            AppLog.info("Pause recording requested.")
            recorder.pause()
            try? sessionStore.updateState(.paused, in: &currentSession)
            self.currentSession = currentSession
            recordingState = .paused
            setControlWindowCaptureSuppressed(false)
            statusMessage = "Paused."

        case .paused:
            AppLog.info("Resume recording requested.")
            setControlWindowCaptureSuppressed(true)
            recorder.resume()
            try? sessionStore.updateState(.recording, in: &currentSession)
            self.currentSession = currentSession
            recordingState = .recording
            setControlWindowCaptureSuppressed(false)
            statusMessage = "Recording resumed."

        case .idle:
            break
        }
    }

    private func uploadStatusMessage(for state: UploadState) -> String? {
        switch state {
        case .idle:
            return nil
        case .preparing:
            return "Preparing upload…"
        case .optimizing:
            return "Optimizing upload copy with ffmpeg…"
        case .initializing:
            return "Starting upload…"
        case .uploading(let progress):
            return "Uploading recording (\(Int(progress * 100))%)…"
        case .finalizing:
            return "Finalizing upload…"
        case .postProcessing(let stage):
            switch stage {
            case .preparingOllama(let modelName):
                return
                    "Upload finished. Preparing Ollama (\(modelName)) for local title generation…"
            case .extractingAudio:
                return
                    "Upload finished. Extracting microphone audio for transcription…"
            case .transcribing(let modelName):
                return
                    "Upload finished. Transcribing narration with Whisper (\(modelName))…"
            case .generatingTitle(let modelName):
                return
                    "Upload finished. Generating a short title summary with Ollama (\(modelName))…"
            case .savingGeneratedTitle:
                return
                    "Upload finished. Saving the generated title to the backend…"
            case .uploadingTranscript:
                return
                    "Upload finished. Uploading word-level transcript…"
            case .generatingThumbnail:
                return
                    "Upload finished. Generating a JPEG thumbnail from the recording…"
            case .uploadingThumbnail:
                return
                    "Upload finished. Uploading the generated thumbnail…"
            }
        case .completed:
            return "Upload complete. Share URL copied and opened."
        case .failed(let message):
            return "Upload failed: \(message)"
        }
    }

    private func refreshDisplays() {
        let screens = NSScreen.screens.compactMap { screen -> DisplayOption? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            return DisplayOption(
                id: CGDirectDisplayID(number.uint32Value),
                name: screen.localizedName,
                size: screen.frame.size
            )
        }

        displays = screens

        if !screens.contains(where: { $0.id == selectedDisplayID }), let firstDisplay = screens.first {
            selectedDisplayID = firstDisplay.id
        }

        if let selectedDisplay = displays.first(where: { $0.id == selectedDisplayID }) {
            AppLog.info("Active display is \(selectedDisplay.name) (\(Int(selectedDisplay.size.width))x\(Int(selectedDisplay.size.height))).")
        }
    }

    private func refreshCaptureDevices() {
        let discoveredCameras = CaptureDeviceCatalog.cameras()
            .map { DeviceOption(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let discoveredMicrophones = CaptureDeviceCatalog.microphones()
            .map { DeviceOption(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        cameras = discoveredCameras
        microphones = discoveredMicrophones

        if !selectedCameraID.isEmpty, !discoveredCameras.contains(where: { $0.id == selectedCameraID }) {
            selectedCameraID = ""
        }

        if !selectedMicrophoneID.isEmpty, !discoveredMicrophones.contains(where: { $0.id == selectedMicrophoneID }) {
            selectedMicrophoneID = ""
        }

        cameraPreviewManager.setCamera(uniqueID: selectedCameraID.isEmpty ? nil : selectedCameraID)
        AppLog.info(
            "Active camera: \(selectedCameraID.isEmpty ? "none" : selectedCameraID), microphone: \(selectedMicrophoneID.isEmpty ? "none" : selectedMicrophoneID)"
        )
    }

    private func updateOverlay() {
        overlayWindowController.update(
            session: cameraPreviewManager.session,
            displayID: selectedDisplayID,
            isVisible: !selectedCameraID.isEmpty
        )
    }

    private func startRecordingTask(
        resuming recoverableSession: RecordingSessionStore.SessionHandle? = nil,
        recovered: Bool = false
    ) async {
        guard displays.contains(where: { $0.id == selectedDisplayID }) else {
            statusMessage = "Choose a display before recording."
            return
        }

        isBusy = true
        statusMessage = "Checking permissions..."
        defer { isBusy = false }

        let permissionsOkay = await requestPermissions()
        guard permissionsOkay else { return }

        let previousRecoverableState = recoverableSession?.session.state ?? .recording
        var workingSession = recoverableSession

        do {
            if workingSession == nil {
                guard let displaySnapshot = currentDisplaySnapshot() else {
                    statusMessage = "Choose a display before recording."
                    return
                }

                workingSession = try sessionStore.createSession(
                    finalFilename: makeOutputFilename(),
                    environment: KoomConfig.activeEnvironment,
                    display: displaySnapshot,
                    cameraID: selectedCameraID.isEmpty ? nil : selectedCameraID,
                    microphoneID: selectedMicrophoneID.isEmpty ? nil : selectedMicrophoneID,
                    fragmentIntervalSeconds: fragmentIntervalSeconds
                )
            }

            guard var workingSession else {
                statusMessage = "koom could not create a recording session."
                return
            }

            let segmentURL = try sessionStore.createNextSegment(in: &workingSession)
            let compressionSettings = settingsStore.loadCompressionSettings()
            AppLog.info("Using compression settings: \(compressionSettings.logDescription)")
            let recorder = ScreenRecorder(
                configuration: .init(
                    displayID: selectedDisplayID,
                    microphoneID: selectedMicrophoneID.isEmpty ? nil : selectedMicrophoneID,
                    outputURL: segmentURL,
                    movieFragmentInterval: CMTime(
                        seconds: fragmentIntervalSeconds,
                        preferredTimescale: 600
                    ),
                    expectedFrameRate: compressionSettings.captureFrameRate
                        .framesPerSecond
                ),
                onRuntimeIssue: { [weak self] message in
                    Task { [weak self] in
                        await self?.handleRecorderRuntimeIssue(message)
                    }
                }
            )

            setControlWindowCaptureSuppressed(true)
            try await recorder.start()

            self.currentSession = workingSession
            self.currentSessionWasRecovered = recovered
            self.recorder = recorder
            lastRecordingURL = nil
            recordingState = .recording
            setControlWindowCaptureSuppressed(false)
            statusMessage =
                recovered
                ? "Interrupted recording resumed."
                : "Recording to \(workingSession.session.finalFilename)"
        } catch {
            if var workingSession {
                try? sessionStore.removeLatestSegment(in: &workingSession)
                if workingSession.session.segments.isEmpty {
                    try? sessionStore.discardSession(workingSession)
                } else {
                    try? sessionStore.updateState(
                        previousRecoverableState,
                        in: &workingSession
                    )
                }
            }

            setControlWindowCaptureSuppressed(false)
            statusMessage = error.localizedDescription
        }
    }

    private func stopRecordingTask(
        discardOutput: Bool,
        restartAfterStop: Bool,
        uploadAfterStop: Bool,
        awaitUploadAfterStop: Bool
    ) async -> Bool {
        guard let recorder else { return false }
        guard var currentSession else { return false }

        isBusy = true
        statusMessage = discardOutput ? "Restarting..." : "Stopping recording..."
        defer { isBusy = false }

        do {
            let segmentURL = try await recorder.stop(discardOutput: discardOutput)
            self.recorder = nil
            recordingState = .idle
            setControlWindowCaptureSuppressed(false)

            if discardOutput {
                try? sessionStore.discardSession(currentSession)
                self.currentSession = nil
                currentSessionWasRecovered = false
                lastRecordingURL = nil
                statusMessage = "Previous recording discarded."
            } else {
                let inspection = try await assembler.inspectSegment(at: segmentURL)
                try sessionStore.markLatestSegmentStopped(
                    in: &currentSession,
                    cleanStop: true,
                    durationSeconds: inspection.durationSeconds,
                    hasVideo: inspection.hasVideo,
                    hasAudio: inspection.hasAudio
                )
                try sessionStore.updateState(.finalizing, in: &currentSession)

                let finalURL: URL
                let uploadEnvironment = currentSession.environment
                if !currentSessionWasRecovered && currentSession.session.segments.count == 1 {
                    finalURL = try sessionStore.promoteSingleSegmentToFinalLocation(
                        from: currentSession
                    )
                } else {
                    finalURL = try await assembler.assembleSession(
                        currentSession,
                        store: sessionStore
                    )
                }

                try? sessionStore.cleanupSessionDirectory(for: currentSession)
                self.currentSession = nil
                currentSessionWasRecovered = false
                lastRecordingURL = finalURL
                statusMessage =
                    uploadAfterStop
                    ? "Saved \(finalURL.lastPathComponent). Uploading..."
                    : "Saved \(finalURL.lastPathComponent)"

                if uploadAfterStop, awaitUploadAfterStop {
                    let uploadSucceeded = await uploader.uploadRecording(
                        at: finalURL,
                        environment: uploadEnvironment
                    )
                    if !uploadSucceeded {
                        statusMessage =
                            "Saved \(finalURL.lastPathComponent), but upload failed."
                        return false
                    }
                } else if uploadAfterStop {
                    Task { [uploader, uploadEnvironment] in
                        await uploader.uploadRecording(
                            at: finalURL,
                            environment: uploadEnvironment
                        )
                    }
                }
            }

            if restartAfterStop {
                await startRecordingTask()
            }
            return true
        } catch {
            if !discardOutput,
                let salvagedURL = await salvageInterruptedRecording(
                    from: &currentSession
                )
            {
                self.recorder = nil
                self.currentSession = nil
                currentSessionWasRecovered = false
                recordingState = .idle
                setControlWindowCaptureSuppressed(false)
                lastRecordingURL = salvagedURL
                statusMessage =
                    "Recording interrupted. Saved partial recording as \(salvagedURL.lastPathComponent)."
                return true
            }

            self.recorder = nil
            self.currentSession = nil
            currentSessionWasRecovered = false
            recordingState = .idle
            setControlWindowCaptureSuppressed(false)
            statusMessage = error.localizedDescription
            return false
        }
    }

    private func salvageInterruptedRecording(
        from currentSession: inout RecordingSessionStore.SessionHandle
    ) async -> URL? {
        guard let latestSegment = currentSession.session.segments.last else {
            return nil
        }

        let segmentURL = sessionStore.segmentURL(
            for: latestSegment,
            in: currentSession
        )
        guard FileManager.default.fileExists(atPath: segmentURL.path) else {
            return nil
        }

        do {
            let inspection = try await assembler.inspectSegment(at: segmentURL)
            try sessionStore.markLatestSegmentStopped(
                in: &currentSession,
                cleanStop: false,
                durationSeconds: inspection.durationSeconds,
                hasVideo: inspection.hasVideo,
                hasAudio: inspection.hasAudio
            )
            try sessionStore.updateState(.finalizing, in: &currentSession)

            let finalURL: URL
            if !currentSessionWasRecovered
                && currentSession.session.segments.count == 1
            {
                finalURL = try sessionStore.promoteSingleSegmentToFinalLocation(
                    from: currentSession
                )
            } else {
                finalURL = try await assembler.assembleSession(
                    currentSession,
                    store: sessionStore
                )
            }

            try? sessionStore.cleanupSessionDirectory(for: currentSession)
            AppLog.info(
                "Recovered partial recording without relaunch: \(finalURL.path)"
            )
            return finalURL
        } catch {
            AppLog.error(
                "Could not salvage interrupted recording in-process: \(error.localizedDescription)"
            )
            return nil
        }
    }

    private func handleRecorderRuntimeIssue(_ message: String) async {
        guard !isHandlingRecorderRuntimeIssue else { return }
        guard !isBusy else { return }
        guard recorder != nil else { return }

        isHandlingRecorderRuntimeIssue = true
        defer { isHandlingRecorderRuntimeIssue = false }

        AppLog.error("Recorder runtime issue detected: \(message)")
        statusMessage = "Recording interrupted internally. Saving the partial recording..."

        let stopSucceeded = await stopRecordingTask(
            discardOutput: false,
            restartAfterStop: false,
            uploadAfterStop: false,
            awaitUploadAfterStop: false
        )

        if stopSucceeded, let lastRecordingURL {
            statusMessage = "Recording interrupted. Saved partial recording as \(lastRecordingURL.lastPathComponent)."
        } else if !stopSucceeded {
            statusMessage = "Recording interrupted. Relaunch koom if you need to recover the partial session."
        }
    }

    private func finalizeRecoveredSession(
        _ recoverableSession: RecordingSessionStore.SessionHandle
    ) async {
        isBusy = true
        statusMessage = "Recovering interrupted recording..."
        defer { isBusy = false }

        var recoverableSession = recoverableSession

        do {
            KoomConfig.activeEnvironment = recoverableSession.environment
            try sessionStore.updateState(.finalizing, in: &recoverableSession)
            let finalURL = try await assembler.assembleSession(
                recoverableSession,
                store: sessionStore
            )
            try? sessionStore.cleanupSessionDirectory(for: recoverableSession)
            lastRecordingURL = finalURL
            statusMessage = "Recovered \(finalURL.lastPathComponent)"

            let uploadEnvironment = recoverableSession.environment
            Task { [uploader, uploadEnvironment] in
                await uploader.uploadRecording(
                    at: finalURL,
                    environment: uploadEnvironment
                )
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func presentRecoveryPrompt(
        for recoverableSession: RecordingSessionStore.SessionHandle,
        attachedTo window: NSWindow
    ) async -> RecoveryDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Interrupted recording found"
        alert.informativeText =
            """
            koom found an unfinished \(recoverableSession.environment.displayName) recording (\(recoverableSession.session.finalFilename)).

            You can resume it, finish the partial recording now, keep it for later, or discard it.
            """
        alert.addButton(withTitle: "Resume Recording")
        alert.addButton(withTitle: "Finish Partial")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Discard")

        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                switch response {
                case .alertFirstButtonReturn:
                    continuation.resume(returning: .resume)
                case .alertSecondButtonReturn:
                    continuation.resume(returning: .finishPartial)
                case .alertThirdButtonReturn:
                    continuation.resume(returning: .notNow)
                default:
                    continuation.resume(returning: .discard)
                }
            }
        }
    }

    private func applySelections(
        from recoverableSession: RecordingSessionStore.SessionHandle
    ) -> Bool {
        KoomConfig.activeEnvironment = recoverableSession.environment
        refreshHardware()

        guard
            let restoredDisplayID = resolveDisplayID(
                for: recoverableSession.session.display
            )
        else {
            statusMessage = "Reconnect the original display to resume this interrupted recording, or choose Finish Partial instead."
            return false
        }

        selectedDisplayID = restoredDisplayID
        displaySelectionDidChange()

        if let savedCameraID = recoverableSession.session.cameraID,
            cameras.contains(where: { $0.id == savedCameraID })
        {
            selectedCameraID = savedCameraID
        } else {
            selectedCameraID = ""
        }
        cameraSelectionDidChange()

        if let savedMicrophoneID = recoverableSession.session.microphoneID,
            microphones.contains(where: { $0.id == savedMicrophoneID })
        {
            selectedMicrophoneID = savedMicrophoneID
        } else {
            selectedMicrophoneID = ""
        }
        microphoneSelectionDidChange()

        return true
    }

    private func resolveDisplayID(
        for snapshot: RecordingSessionStore.RecordingSession.DisplaySnapshot
    ) -> CGDirectDisplayID? {
        if let exactMatch = displays.first(where: { $0.id == snapshot.id }) {
            return exactMatch.id
        }

        return displays.first(where: {
            $0.name == snapshot.name && Int($0.size.width) == snapshot.width && Int($0.size.height) == snapshot.height
        })?.id
    }

    private func currentDisplaySnapshot() -> RecordingSessionStore.RecordingSession.DisplaySnapshot? {
        guard let selectedDisplay = displays.first(where: { $0.id == selectedDisplayID }) else {
            return nil
        }

        return .init(
            id: selectedDisplay.id,
            name: selectedDisplay.name,
            width: Int(selectedDisplay.size.width),
            height: Int(selectedDisplay.size.height)
        )
    }

    private func applyControlWindowCapturePolicy(_ window: NSWindow) {
        window.sharingType =
            (recordingState == .recording || isControlWindowCaptureSuppressed)
            ? .none
            : .readOnly
    }

    private func setControlWindowCaptureSuppressed(_ suppressed: Bool) {
        isControlWindowCaptureSuppressed = suppressed
        if let controlWindow {
            applyControlWindowCapturePolicy(controlWindow)
        }
    }

    private func requestPermissions() async -> Bool {
        if !CGPreflightScreenCaptureAccess() {
            AppLog.info("Requesting screen recording permission.")
            let granted = CGRequestScreenCaptureAccess()
            guard granted else {
                AppLog.error("Screen recording permission denied.")
                statusMessage = "Screen recording permission is required. Approve koom in System Settings, then relaunch it."
                return false
            }
        }

        if !selectedCameraID.isEmpty {
            AppLog.info("Checking camera permission.")
            let cameraPermission = await permission(for: .video)
            guard cameraPermission else {
                AppLog.error("Camera permission denied.")
                statusMessage = "Camera permission is required for the face overlay."
                return false
            }
        }

        if !selectedMicrophoneID.isEmpty {
            AppLog.info("Checking microphone permission.")
            let microphonePermission = await permission(for: .audio)
            guard microphonePermission else {
                AppLog.error("Microphone permission denied.")
                statusMessage = "Microphone permission is required for narration."
                return false
            }
        }

        AppLog.info("All required permissions are available.")
        return true
    }

    private func permission(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func makeOutputFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "koom_\(formatter.string(from: Date())).mp4"
    }
}
