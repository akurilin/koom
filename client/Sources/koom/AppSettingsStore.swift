import CoreGraphics
import Foundation

@MainActor
final class AppSettingsStore {
    private enum Key {
        static let selectedDisplayID = "selectedDisplayID"
        static let selectedCameraID = "selectedCameraID"
        static let selectedMicrophoneID = "selectedMicrophoneID"
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
            selectedMicrophoneID: defaults.string(forKey: Key.selectedMicrophoneID)
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

    struct Snapshot {
        let selectedDisplayID: CGDirectDisplayID?
        let selectedCameraID: String?
        let selectedMicrophoneID: String?
    }
}
