import Foundation

struct ReadingItem: Identifiable, Codable, Hashable, Sendable {
    enum Source: String, Codable {
        case manual
        case task
        case companion
    }

    let id: UUID
    var title: String
    var url: URL
    var tags: [String]
    var capturedAt: Date
    var source: Source
    var relatedTaskID: UUID?

    init(
        id: UUID = UUID(),
        title: String,
        url: URL,
        tags: [String] = [],
        capturedAt: Date = .now,
        source: Source,
        relatedTaskID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.tags = tags
        self.capturedAt = capturedAt
        self.source = source
        self.relatedTaskID = relatedTaskID
    }
}
