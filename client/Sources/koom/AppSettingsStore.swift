import CoreGraphics
import Foundation

@MainActor
final class AppSettingsStore {
    private enum Key {
        static let selectedDisplayID = "selectedDisplayID"
        static let selectedCameraID = "selectedCameraID"
        static let selectedMicrophoneID = "selectedMicrophoneID"
        static let cameraBubbleSize = "cameraBubbleSize"
        static let captureResolution = "captureResolution"
        static let captureFrameRate = "captureFrameRate"
        static let uploadRecordings = "uploadRecordings"
        // Preserve the existing preference while broadening it from
        // upload-only optimization to local recording optimization.
        static let optimizeRecordings = "optimizeUploads"
    }

    private let preferences: any KoomPreferences

    init(preferences: any KoomPreferences = KoomRuntimeProfile.preferences) {
        self.preferences = preferences
    }

    convenience init(defaults: UserDefaults) {
        self.init(preferences: UserDefaultsPreferences(defaults))
    }

    func load() -> Snapshot {
        let displayValue =
            preferences.object(forKey: Key.selectedDisplayID) as? NSNumber

        return Snapshot(
            selectedDisplayID: displayValue.map { CGDirectDisplayID($0.uint32Value) },
            selectedCameraID: preferences.string(forKey: Key.selectedCameraID),
            selectedMicrophoneID: preferences.string(forKey: Key.selectedMicrophoneID),
            cameraBubbleSize: preferences.string(forKey: Key.cameraBubbleSize)
                .flatMap(CameraBubbleSize.init(rawValue:))
                ?? CameraBubbleSize.defaultValue,
            compressionSettings: loadCompressionSettings()
        )
    }

    func loadCompressionSettings() -> CompressionSettings {
        let captureResolution =
            preferences.string(forKey: Key.captureResolution)
            .flatMap(CaptureResolutionOption.init(rawValue:))
            ?? CompressionSettings.default.captureResolution

        let captureFrameRate =
            (preferences.object(forKey: Key.captureFrameRate) as? NSNumber)
            .flatMap { CaptureFrameRateOption(rawValue: $0.intValue) }
            ?? CompressionSettings.default.captureFrameRate

        let optimizeRecordings =
            if preferences.object(forKey: Key.optimizeRecordings) == nil {
                CompressionSettings.default.optimizeRecordings
            } else {
                preferences.bool(forKey: Key.optimizeRecordings)
            }

        let uploadRecordings =
            if preferences.object(forKey: Key.uploadRecordings) == nil {
                CompressionSettings.default.uploadRecordings
            } else {
                preferences.bool(forKey: Key.uploadRecordings)
            }

        return CompressionSettings(
            captureResolution: captureResolution,
            captureFrameRate: captureFrameRate,
            uploadRecordings: uploadRecordings,
            optimizeRecordings: optimizeRecordings
        )
    }

    func saveSelectedDisplayID(_ displayID: CGDirectDisplayID) {
        preferences.set(
            NSNumber(value: displayID),
            forKey: Key.selectedDisplayID
        )
    }

    func saveSelectedCameraID(_ cameraID: String) {
        preferences.set(cameraID, forKey: Key.selectedCameraID)
    }

    func saveSelectedMicrophoneID(_ microphoneID: String) {
        preferences.set(microphoneID, forKey: Key.selectedMicrophoneID)
    }

    func saveCameraBubbleSize(_ cameraBubbleSize: CameraBubbleSize) {
        preferences.set(
            cameraBubbleSize.rawValue,
            forKey: Key.cameraBubbleSize
        )
    }

    func saveCaptureResolution(_ captureResolution: CaptureResolutionOption) {
        preferences.set(
            captureResolution.rawValue,
            forKey: Key.captureResolution
        )
    }

    func saveCaptureFrameRate(_ captureFrameRate: CaptureFrameRateOption) {
        preferences.set(
            captureFrameRate.rawValue,
            forKey: Key.captureFrameRate
        )
    }

    func saveOptimizeRecordings(_ optimizeRecordings: Bool) {
        preferences.set(optimizeRecordings, forKey: Key.optimizeRecordings)
    }

    func saveUploadRecordings(_ uploadRecordings: Bool) {
        preferences.set(uploadRecordings, forKey: Key.uploadRecordings)
    }

    struct Snapshot {
        let selectedDisplayID: CGDirectDisplayID?
        let selectedCameraID: String?
        let selectedMicrophoneID: String?
        let cameraBubbleSize: CameraBubbleSize
        let compressionSettings: CompressionSettings
    }
}
