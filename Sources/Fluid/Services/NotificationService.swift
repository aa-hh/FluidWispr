import Foundation
import UserNotifications

enum NotificationService {
    enum UserInfoKey {
        static let kind = "kind"
    }

    enum Kind {
        static let aiProcessingFallback = "aiProcessingFallback"
        static let commandModeFailure = "commandModeFailure"
    }

    static func showAIProcessingFallback(error: String, providerName: String, budgetMilliseconds: Int?) {
        guard SettingsStore.shared.notifyAIProcessingFailures else { return }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.deliverAIProcessingFallback(
                    body: self.fallbackBody(for: error, providerName: providerName, budgetMilliseconds: budgetMilliseconds),
                    using: center
                )
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, requestError in
                    if let requestError {
                        DebugLogger.shared.warning(
                            "Notification permission request failed: \(requestError.localizedDescription)",
                            source: "NotificationService"
                        )
                    }
                    guard granted else { return }
                    self.deliverAIProcessingFallback(
                    body: self.fallbackBody(for: error, providerName: providerName, budgetMilliseconds: budgetMilliseconds),
                    using: center
                )
                }
            case .denied:
                DebugLogger.shared.debug(
                    "Skipping AI fallback notification because notification permission is denied",
                    source: "NotificationService"
                )
            @unknown default:
                break
            }
        }
    }

    static func showCommandModeFailure(error: String) {
        guard SettingsStore.shared.notifyAIProcessingFailures else { return }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.deliverCommandModeFailure(error: error, using: center)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, requestError in
                    if let requestError {
                        DebugLogger.shared.warning(
                            "Notification permission request failed: \(requestError.localizedDescription)",
                            source: "NotificationService"
                        )
                    }
                    guard granted else { return }
                    self.deliverCommandModeFailure(error: error, using: center)
                }
            case .denied:
                DebugLogger.shared.debug(
                    "Skipping Command Mode notification because notification permission is denied",
                    source: "NotificationService"
                )
            @unknown default:
                break
            }
        }
    }

    /// The cleanup fallback notification body: the cause in plain words, picked from the error text.
    /// `budgetMilliseconds` is nil when cleanup ran without a time limit.
    static func fallbackBody(for error: String, providerName: String, budgetMilliseconds: Int?) -> String {
        if error.localizedCaseInsensitiveContains("timed out") || error.contains("AI cleanup took longer than") {
            let limit = budgetMilliseconds.map { "in \($0) ms" } ?? "in time"
            return "\(providerName) didn’t answer \(limit), so your words went in as spoken."
        }
        if error.contains("API key not set") {
            return "No \(providerName) key is set, so your words went in as spoken."
        }
        return "\(providerName) cleanup failed, so your words went in as spoken."
    }

    private static func deliverAIProcessingFallback(body: String, using center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "Pasted without cleanup"
        content.body = body
        content.sound = nil
        content.userInfo = [UserInfoKey.kind: Kind.aiProcessingFallback]

        let request = UNNotificationRequest(
            identifier: "ai-cleanup-fallback-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request) { addError in
            if let addError {
                DebugLogger.shared.warning(
                    "Failed to show AI fallback notification: \(addError.localizedDescription)",
                    source: "NotificationService"
                )
            }
        }
    }

    private static func deliverCommandModeFailure(error: String, using center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "Command Mode needs setup"
        content.body = error
        content.sound = nil
        content.userInfo = [UserInfoKey.kind: Kind.commandModeFailure]

        let request = UNNotificationRequest(
            identifier: "command-mode-failure-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request) { addError in
            if let addError {
                DebugLogger.shared.warning(
                    "Failed to show Command Mode notification: \(addError.localizedDescription)",
                    source: "NotificationService"
                )
            }
        }
    }
}
