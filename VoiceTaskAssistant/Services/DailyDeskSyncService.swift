import Foundation

final class DailyDeskSyncService {
    private let calendar: Calendar
    private let fileManager: FileManager
    private let appGroupIdentifier = "group.com.example.voicetaskassistant"
    private var scheduledWork: DispatchWorkItem?

    init(calendar: Calendar = .current, fileManager: FileManager = .default) {
        self.calendar = calendar
        self.fileManager = fileManager
    }

    func record(task: CapturedTask) async {}

    func publishDailySummary(tasks: [CapturedTask]) async {
        guard let url = sharedFileURL() else { return }
        let summary = DailySummary(date: Date(), tasks: tasks.compactMap { task in
            guard let structured = task.structured else { return nil }
            return DailySummary.TaskEntry(from: structured, capturedAt: task.timestamp)
        })

        do {
            let data = try JSONEncoder().encode(summary)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("Failed to write daily summary: \(error)")
        }
    }

    func scheduleMorningSync(action: @escaping () -> Void) {
        scheduledWork?.cancel()
        let nextMorning = calendar.nextDate(after: Date(), matching: DateComponents(hour: 7, minute: 0), matchingPolicy: .nextTimePreservingSmallerComponents) ?? Date().addingTimeInterval(3600 * 24)
        let delay = max(1, nextMorning.timeIntervalSinceNow)
        let workItem = DispatchWorkItem(block: action)
        scheduledWork = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func sharedFileURL() -> URL? {
        #if os(iOS)
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?.appendingPathComponent("dailySummary.json")
        #else
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dailySummary.json")
        #endif
    }
}

struct DailySummary: Codable {
    let date: Date
    let tasks: [TaskEntry]

    struct TaskEntry: Codable, Identifiable {
        let id: UUID
        let summary: String
        let subtasks: [StructuredTask.Subtask]
        let reminders: [StructuredTask.Reminder]
        let capturedAt: Date

        init(from task: StructuredTask, capturedAt: Date) {
            self.id = UUID()
            self.summary = task.summary
            self.subtasks = task.subtasks
            self.reminders = task.reminders
            self.capturedAt = capturedAt
        }
    }
}
