//
//  Models.swift
//  FrictionlessNotes
//
//  Round 1 model layer — plain structs (DESIGN.md data model arrives as SwiftData in round 2).
//

import SwiftUI

enum CaptureKind: String, Codable {
    case audio, text, photo
}

/// DESIGN.md status lifecycle. Every transition is user-visible.
enum CaptureStatus: String, Codable {
    case saved          // committed on device
    case uploaded       // acked by iCloud (mocked in round 1)
    case processing     // Mac agent working
    case done           // enriched, filed
    case needsReview    // model declined to guess
    case error

    var tint: Color {
        switch self {
        case .saved: Theme.statusSaved
        case .uploaded: Theme.statusUploaded
        case .processing: Theme.statusProcessing
        case .done: Theme.statusDone
        case .needsReview: Theme.statusReview
        case .error: Theme.statusError
        }
    }

    var label: String {
        switch self {
        case .saved: "saved"
        case .uploaded: "uploaded"
        case .processing: "polishing"
        case .done: "done"
        case .needsReview: "needs review"
        case .error: "error"
        }
    }
}

enum NoteCategory: String, Codable, CaseIterable {
    case todo, shopping, idea, note, journal, reference

    var tint: Color {
        switch self {
        case .todo: Color(hex: 0x5BA8FF)
        case .shopping: Color(hex: 0x4CD98A)
        case .idea: Color(hex: 0xC792F2)
        case .note: Color(hex: 0x9C9CA8)
        case .journal: Color(hex: 0xF2A65A)
        case .reference: Color(hex: 0x6FD2E0)
        }
    }
}

/// One applied action from the Mac's enrich step — rendered as a filing receipt (M3).
struct FilingAction: Identifiable, Equatable, Codable {
    enum Tool: String, Codable {
        case fileCapture = "filed"
        case addListItem = "list"
        case createTodo = "todo"
        case learned = "learned"
    }

    let id: UUID
    let tool: Tool
    let text: String            // "Shopping: milk, eggs" / "ask Dr. Patel — metformin dosage"
    var listName: String?       // rendered in lamplight
    var due: String?            // always surfaced, never silent
    var category: NoteCategory?
    var undone: Bool = false

    init(id: UUID = UUID(), tool: Tool, text: String, listName: String? = nil,
         due: String? = nil, category: NoteCategory? = nil) {
        self.id = id
        self.tool = tool
        self.text = text
        self.listName = listName
        self.due = due
        self.category = category
    }
}

struct Capture: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let kind: CaptureKind

    var deviceTranscript: String        // on-phone Parakeet draft (round 1: mock)
    var finalTranscript: String?        // Mac polish; nil until it arrives
    var previousTranscript: String?     // what polish replaced — drives the M2 diff
    var userEditedAt: Date?             // once set, polish never applies (edit wins)

    var summary: String?
    var category: NoteCategory?
    /// Stage-1 ANE guess shown while we wait — colors the ledger tick the moment
    /// words land. Superseded by `category` once Gemma (Stage 2) files for real.
    var provisionalCategory: NoteCategory?
    var status: CaptureStatus
    var actions: [FilingAction] = []
    var reviewGuess: NoteCategory?
    var reviewReason: String?
    var polishArrivedAt: Date?          // recent → sweep plays
    // Ask: a capture the brain read as a question — answered from existing notes
    // instead of filed.
    var isQuestion: Bool = false
    var answer: String?
    var citedCaptureIDs: [UUID] = []
    var answerArrivedAt: Date?

    var bestTranscript: String { finalTranscript ?? deviceTranscript }
    var ledgerLine: String { summary ?? bestTranscript }

    init(id: UUID = UUID(), createdAt: Date = .now, kind: CaptureKind,
         deviceTranscript: String, status: CaptureStatus = .saved) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.deviceTranscript = deviceTranscript
        self.status = status
    }
}

/// Live transcription stream payload.
struct TranscriptUpdate: Sendable {
    var fullText: String
    var rms: Float              // 0…1, drives the Listening Field
}

/// Events the pipeline (Mac agent; round 1: MockPipeline) sends back.
enum PipelineEvent: Sendable {
    case statusChanged(UUID, CaptureStatus)
    case polish(UUID, newText: String, summary: String)
    case filed(UUID, category: NoteCategory, actions: [FilingAction])
    case needsReview(UUID, guess: NoteCategory, reason: String)
    /// One recording contained multiple thoughts — replace it with children.
    case split(UUID, into: [Capture])
    /// The brain read this capture as a question — answer it from existing notes.
    case isQuestion(UUID, query: String)
}

/// Lightweight question detection for pipelines without an LLM intent signal
/// (mock, Apple Foundation Models). Gemma uses its own decision field.
enum QuestionHeuristic {
    static func looksLikeQuestion(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.hasSuffix("?") { return true }
        let starters = ["what", "whats", "what's", "when", "where", "who", "why",
                        "how", "which", "did i", "do i", "is there", "are there",
                        "remind me what", "remind me when", "what did i", "where did i"]
        return starters.contains { t == $0 || t.hasPrefix($0 + " ") }
    }
}

/// Endpointing — stop is a physical signal, not a silence guess.
enum EndpointSignal: Sendable {
    case voiceStarted
    case thinkingSilence        // dim, wait
    case voiceResumed
    case disposalDetected       // sustained attitude change while silent
    case pocketed               // proximity sensor
    case silenceCapped          // ~3 min cap
}

enum MacStatus: Equatable, Sendable {
    case online(lastActiveMinutes: Int)
    case offline(waiting: Int)

    var isNoteworthy: Bool {
        switch self {
        case .online(let m): m > 10
        case .offline: true
        }
    }

    var line: String {
        switch self {
        case .online(let m): m < 1 ? "mac active now" : "mac last active \(m)m ago"
        case .offline(let n): n > 0 ? "mac offline — \(n) waiting" : "mac offline"
        }
    }
}
