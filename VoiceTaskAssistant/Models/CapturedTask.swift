import Foundation

struct CapturedTask: Identifiable, Codable, Hashable {
    enum Status: String, Codable {
        case pending
        case syncing
        case processed
        case failed
    }

    struct Segment: Codable, Hashable {
        let text: String
        let timestamp: TimeInterval
    }

    let id: UUID
    let rawText: String
    let timestamp: Date
    var status: Status
    var structured: StructuredTask?
    var segments: [Segment]

    init(id: UUID = UUID(), rawText: String, timestamp: Date = .now, status: Status = .pending, structured: StructuredTask? = nil, segments: [Segment] = []) {
        self.id = id
        self.rawText = rawText
        self.timestamp = timestamp
        self.status = status
        self.structured = structured
        self.segments = segments
    }
}
