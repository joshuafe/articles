import AppIntents
import Foundation

struct CaptureReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture reminder"
    static var description = IntentDescription("Start recording a reminder for the wall display.")

    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        ReminderIntentBridge.shared.triggerCapture()
        return .result(dialog: "Ready to record your reminder.")
    }
}

struct ReminderAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CaptureReminderIntent(), phrases: [
            "Capture reminder in \(.applicationName)",
            "Remember this with \(.applicationName)",
            "Add a reminder to the board using \(.applicationName)"
        ])
    }
}

@MainActor
final class ReminderIntentBridge {
    static let shared = ReminderIntentBridge()

    func triggerCapture() {
        NotificationCenter.default.post(name: ReminderCaptureNotifications.beginCapture, object: nil)
    }
}
