import Foundation

struct StructuredTask: Codable, Hashable {
    struct Subtask: Codable, Hashable, Identifiable {
        let id: UUID
        let title: String
        let dueDate: Date?
        let notes: String?

        init(id: UUID = UUID(), title: String, dueDate: Date? = nil, notes: String? = nil) {
            self.id = id
            self.title = title
            self.dueDate = dueDate
            self.notes = notes
        }
    }

    let summary: String
    let subtasks: [Subtask]
    let reminders: [Reminder]

    struct Reminder: Codable, Hashable, Identifiable {
        let id: UUID
        let title: String
        let fireDate: Date

        init(id: UUID = UUID(), title: String, fireDate: Date) {
            self.id = id
            self.title = title
            self.fireDate = fireDate
        }
    }
}
