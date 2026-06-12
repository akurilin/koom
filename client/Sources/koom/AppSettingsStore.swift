import CoreGraphics
import Foundation

@MainActor
final class AppSettingsStore {
    private enum Key {
        static let selectedDisplayID = "selectedDisplayID"
        static let selectedCameraID = "selectedCameraID"
        static let selectedMicrophoneID = "selectedMicrophoneID"
        static let captureFrameRate = "captureFrameRate"
        static let uploadRecordings = "uploadRecordings"
        // Preserve the existing preference while broadening it from
        // upload-only optimization to local recording optimization.
        static let optimizeRecordings = "optimizeUploads"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Snapshot {
        let displayValue = defaults.object(forKey: Key.selectedDisplayID) as? NSNumber

        return Snapshot(
            selectedDisplayID: displayValue.map { CGDirectDisplayID($0.uint32Value) },
            selectedCameraID: defaults.string(forKey: Key.selectedCameraID),
            selectedMicrophoneID: defaults.string(forKey: Key.selectedMicrophoneID),
            compressionSettings: loadCompressionSettings()
        )
    }

    func loadCompressionSettings() -> CompressionSettings {
        let captureFrameRate =
            (defaults.object(forKey: Key.captureFrameRate) as? NSNumber)
            .flatMap { CaptureFrameRateOption(rawValue: $0.intValue) }
            ?? CompressionSettings.default.captureFrameRate

        let optimizeRecordings =
            if defaults.object(forKey: Key.optimizeRecordings) == nil {
                CompressionSettings.default.optimizeRecordings
            } else {
                defaults.bool(forKey: Key.optimizeRecordings)
            }

        let uploadRecordings =
            if defaults.object(forKey: Key.uploadRecordings) == nil {
                CompressionSettings.default.uploadRecordings
            } else {
                defaults.bool(forKey: Key.uploadRecordings)
            }

        return CompressionSettings(
            captureFrameRate: captureFrameRate,
            uploadRecordings: uploadRecordings,
            optimizeRecordings: optimizeRecordings
        )
    }

    func saveSelectedDisplayID(_ displayID: CGDirectDisplayID) {
        defaults.set(NSNumber(value: displayID), forKey: Key.selectedDisplayID)
    }

    func saveSelectedCameraID(_ cameraID: String) {
        defaults.set(cameraID, forKey: Key.selectedCameraID)
    }

    func saveSelectedMicrophoneID(_ microphoneID: String) {
        defaults.set(microphoneID, forKey: Key.selectedMicrophoneID)
    }

    func saveCaptureFrameRate(_ captureFrameRate: CaptureFrameRateOption) {
        defaults.set(captureFrameRate.rawValue, forKey: Key.captureFrameRate)
    }

    func saveOptimizeRecordings(_ optimizeRecordings: Bool) {
        defaults.set(optimizeRecordings, forKey: Key.optimizeRecordings)
    }

    func saveUploadRecordings(_ uploadRecordings: Bool) {
        defaults.set(uploadRecordings, forKey: Key.uploadRecordings)
    }

    struct Snapshot {
        let selectedDisplayID: CGDirectDisplayID?
        let selectedCameraID: String?
        let selectedMicrophoneID: String?
        let compressionSettings: CompressionSettings
    }
}
