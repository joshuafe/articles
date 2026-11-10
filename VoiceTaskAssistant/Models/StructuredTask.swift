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
    let topics: [String]
    let readingList: [ReadingReference]

    init(summary: String, subtasks: [Subtask], reminders: [Reminder], topics: [String], readingList: [ReadingReference]) {
        self.summary = summary
        self.subtasks = subtasks
        self.reminders = reminders
        self.topics = topics
        self.readingList = readingList
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(String.self, forKey: .summary)
        subtasks = try container.decodeIfPresent([Subtask].self, forKey: .subtasks) ?? []
        reminders = try container.decodeIfPresent([Reminder].self, forKey: .reminders) ?? []
        topics = try container.decodeIfPresent([String].self, forKey: .topics) ?? []
        readingList = try container.decodeIfPresent([ReadingReference].self, forKey: .readingList) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(summary, forKey: .summary)
        try container.encode(subtasks, forKey: .subtasks)
        try container.encode(reminders, forKey: .reminders)
        try container.encode(topics, forKey: .topics)
        try container.encode(readingList, forKey: .readingList)
    }

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

extension StructuredTask {
    struct ReadingReference: Codable, Hashable, Identifiable {
        let id: UUID
        let title: String
        let url: URL
        let tags: [String]

        init(id: UUID = UUID(), title: String, url: URL, tags: [String]) {
            self.id = id
            self.title = title
            self.url = url
            self.tags = tags
        }
    }
}
