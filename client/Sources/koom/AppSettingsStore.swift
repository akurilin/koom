import CoreGraphics
import Foundation

@MainActor
final class AppSettingsStore {
    private enum Key {
        static let selectedDisplayID = "selectedDisplayID"
        static let selectedCameraID = "selectedCameraID"
        static let selectedMicrophoneID = "selectedMicrophoneID"
        static let captureFrameRate = "captureFrameRate"
        static let optimizeUploads = "optimizeUploads"
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

        let optimizeUploads =
            if defaults.object(forKey: Key.optimizeUploads) == nil {
                CompressionSettings.default.optimizeUploads
            } else {
                defaults.bool(forKey: Key.optimizeUploads)
            }

        return CompressionSettings(
            captureFrameRate: captureFrameRate,
            optimizeUploads: optimizeUploads
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

    func saveOptimizeUploads(_ optimizeUploads: Bool) {
        defaults.set(optimizeUploads, forKey: Key.optimizeUploads)
    }

    struct Snapshot {
        let selectedDisplayID: CGDirectDisplayID?
        let selectedCameraID: String?
        let selectedMicrophoneID: String?
        let compressionSettings: CompressionSettings
    }
}
