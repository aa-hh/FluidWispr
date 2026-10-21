import Foundation

extension SettingsStore {
    /// "Pill shows": the approved default is only while dictating.
    var recordingPillVisibility: RecordingPillVisibility {
        get {
            RecordingPillVisibility(rawValue: self.defaults.string(forKey: Keys.recordingPillVisibility) ?? "") ?? .whileDictating
        }
        set {
            guard newValue != self.recordingPillVisibility else { return }
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.recordingPillVisibility)
            NotificationCenter.default.post(name: RecordingPillController.settingsChanged, object: nil)
        }
    }

    /// "Pill size": Medium (120 × 28 pt) unless changed.
    var recordingPillSize: RecordingPillSize {
        get {
            RecordingPillSize(rawValue: self.defaults.string(forKey: Keys.recordingPillSize) ?? "") ?? .medium
        }
        set {
            guard newValue != self.recordingPillSize else { return }
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.recordingPillSize)
            NotificationCenter.default.post(name: RecordingPillController.settingsChanged, object: nil)
        }
    }
}
