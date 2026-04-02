@preconcurrency import AppKit
@preconcurrency import AVFoundation
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
        }
    }
    @Published var isBusy = false
    @Published var statusMessage = "Ready." {
        didSet {
            AppLog.info("Status: \(statusMessage)")
        }
    }
    @Published var lastRecordingURL: URL?

    private let cameraPreviewManager = CameraPreviewManager()
    private let overlayWindowController = CameraOverlayWindowController()
    private let settingsStore: AppSettingsStore
    private var recorder: ScreenRecorder?
    private var hasPlacedWindow = false

    init(settingsStore: AppSettingsStore = AppSettingsStore()) {
        self.settingsStore = settingsStore

        let restoredSettings = settingsStore.load()
        if let restoredDisplayID = restoredSettings.selectedDisplayID {
            selectedDisplayID = restoredDisplayID
        }
        selectedCameraID = restoredSettings.selectedCameraID ?? ""
        selectedMicrophoneID = restoredSettings.selectedMicrophoneID ?? ""

        AppLog.info(
            "Restored settings. Display: \(restoredSettings.selectedDisplayID.map(String.init) ?? "none"), camera: \(restoredSettings.selectedCameraID ?? "none"), microphone: \(restoredSettings.selectedMicrophoneID ?? "none")"
        )

        refreshHardware()
    }

    func refreshHardware() {
        refreshDisplays()
        refreshCaptureDevices()
        updateOverlay()
        AppLog.info("Hardware refreshed. Displays: \(displays.count), cameras: \(cameras.count), microphones: \(microphones.count)")
    }

    func configureControlWindow(_ window: NSWindow) {
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.sharingType = .none
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
            await stopRecordingTask(discardOutput: false, restartAfterStop: false)
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
            await stopRecordingTask(discardOutput: true, restartAfterStop: true)
        }
    }

    func togglePause() {
        guard let recorder else { return }

        switch recordingState {
        case .recording:
            AppLog.info("Pause recording requested.")
            recorder.pause()
            recordingState = .paused
            statusMessage = "Paused."
        case .paused:
            AppLog.info("Resume recording requested.")
            recorder.resume()
            recordingState = .recording
            statusMessage = "Recording resumed."
        case .idle:
            break
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
        AppLog.info("Active camera: \(selectedCameraID.isEmpty ? "none" : selectedCameraID), microphone: \(selectedMicrophoneID.isEmpty ? "none" : selectedMicrophoneID)")
    }

    private func updateOverlay() {
        overlayWindowController.update(
            session: cameraPreviewManager.session,
            displayID: selectedDisplayID,
            isVisible: !selectedCameraID.isEmpty
        )
    }

    private func startRecordingTask() async {
        guard displays.contains(where: { $0.id == selectedDisplayID }) else {
            statusMessage = "Choose a display before recording."
            return
        }

        isBusy = true
        statusMessage = "Checking permissions..."
        defer { isBusy = false }

        let permissionsOkay = await requestPermissions()
        guard permissionsOkay else { return }

        let outputURL = makeOutputURL()

        do {
            let recorder = ScreenRecorder(
                configuration: .init(
                    displayID: selectedDisplayID,
                    microphoneID: selectedMicrophoneID.isEmpty ? nil : selectedMicrophoneID,
                    outputURL: outputURL
                )
            )

            try await recorder.start()

            self.recorder = recorder
            lastRecordingURL = outputURL
            recordingState = .recording
            statusMessage = "Recording to \(outputURL.lastPathComponent)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func stopRecordingTask(discardOutput: Bool, restartAfterStop: Bool) async {
        guard let recorder else { return }

        isBusy = true
        statusMessage = discardOutput ? "Restarting..." : "Stopping recording..."
        defer { isBusy = false }

        do {
            let outputURL = try await recorder.stop(discardOutput: discardOutput)

            self.recorder = nil
            recordingState = .idle

            if discardOutput {
                lastRecordingURL = nil
                statusMessage = "Previous recording discarded."
            } else {
                lastRecordingURL = outputURL
                statusMessage = "Saved \(outputURL.lastPathComponent)"
            }

            if restartAfterStop {
                await startRecordingTask()
            }
        } catch {
            self.recorder = nil
            recordingState = .idle
            statusMessage = error.localizedDescription
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

    private func makeOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        let baseDirectory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let recordingsDirectory = baseDirectory.appendingPathComponent("koom", isDirectory: true)

        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)

        let url = recordingsDirectory
            .appendingPathComponent("koom_\(formatter.string(from: Date()))")
            .appendingPathExtension("mp4")
        AppLog.info("Next recording path: \(url.path)")
        return url
    }
}
