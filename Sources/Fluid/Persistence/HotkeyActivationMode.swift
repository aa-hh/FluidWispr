import Foundation

enum HotkeyActivationMode: String, Codable, CaseIterable, Identifiable {
    case toggle, hold

    var id: String { self.rawValue }
}
