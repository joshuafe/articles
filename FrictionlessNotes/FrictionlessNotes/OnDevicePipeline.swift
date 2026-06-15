//
//  OnDevicePipeline.swift
//  FrictionlessNotes
//
//  Tier-0 brain: Apple Foundation Models (on-device ~3B, iOS 26+).
//  Same PipelineClient seam as the mock and the future Mac client — filing
//  happens on the phone in ~1-2 s, fully offline, zero download, zero fees.
//  Guided generation decodes straight into FilingDecision: a tool call that
//  cannot be malformed. Low confidence or guardrail refusals → needsReview.
//

import Foundation
import FoundationModels

@available(iOS 26.0, *)
@Generable
struct FilingDecision {
    @Guide(description: "The transcript with punctuation, casing, and obvious mishearings fixed. Keep the speaker's words; do not add content.")
    var polishedTranscript: String

    @Guide(description: "A summary of at most 8 words, lowercase, no period.")
    var summary: String

    @Guide(description: "Where this thought belongs.")
    var category: FilingCategory

    @Guide(description: "For shopping captures: the individual items mentioned. Otherwise empty.")
    var shoppingItems: [String]

    @Guide(description: "Short due hint if the speaker mentioned a deadline, like 'fri' or 'jun 20'. Otherwise nil.")
    var due: String?

    @Guide(description: "True only if the category is clear. False when genuinely ambiguous.")
    var confident: Bool

    @Guide(description: "Almost always empty. ONLY populate this if the recording contains two or more clearly UNRELATED subjects (e.g. a grocery item AND an unrelated work task). A single train of thought across several sentences is ONE thought — leave this empty. When in doubt, leave empty.")
    var distinctThoughts: [String]
}

@available(iOS 26.0, *)
@Generable
enum FilingCategory: String, CaseIterable {
    case todo, shopping, idea, note, journal, reference

    var noteCategory: NoteCategory {
        NoteCategory(rawValue: rawValue) ?? .note
    }
}

@available(iOS 26.0, *)
@MainActor
final class OnDevicePipeline: PipelineClient {

    static var isSupported: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    let events: AsyncStream<PipelineEvent>
    private let cont: AsyncStream<PipelineEvent>.Continuation

    var offline: Bool = false {
        didSet { if !offline { drainHeld() } }
    }
    var lexiconProvider: (() -> String)?
    private var held: [Capture] = []
    var heldCount: Int { held.count }

    private(set) var refileLog: [(capture: UUID, action: UUID, to: NoteCategory?)] = []

    private let session: LanguageModelSession

    init() {
        (events, cont) = AsyncStream.makeStream(of: PipelineEvent.self)
        session = LanguageModelSession(instructions: """
            You file a person's spoken thoughts. Treat each recording as ONE \
            connected thought by default — people ramble, circle back, and add \
            detail across several sentences; keep all of that together as a single \
            note. Only ever separate a recording when it clearly contains two \
            entirely UNRELATED subjects. \
            Fix transcription errors gently, summarize the whole thought briefly, \
            and decide where it belongs: todo (actions with intent), shopping \
            (things to buy), idea, note (facts to keep), journal \
            (feelings/reflections), reference (names, numbers, addresses). \
            Be decisive for clear cases; mark confident=false only when truly ambiguous.
            """)
        session.prewarm()
    }

    func submit(_ capture: Capture) {
        guard !offline else {
            held.append(capture)
            return
        }
        process(capture)
    }

    func refile(captureID: UUID, actionID: UUID, to category: NoteCategory?) {
        refileLog.append((captureID, actionID, category))
    }

    private func drainHeld() {
        let queue = held
        held.removeAll()
        for c in queue { process(c) }
    }

    private func process(_ capture: Capture) {
        cont.yield(.statusChanged(capture.id, .processing))
        Task { [weak self] in
            guard let self else { return }
            do {
                let lexicon = self.lexiconProvider?() ?? ""
                let prompt = lexicon.isEmpty
                    ? "Thought: \u{201C}\(capture.deviceTranscript)\u{201D}"
                    : "\(lexicon)\nThought: \u{201C}\(capture.deviceTranscript)\u{201D}"
                let response = try await self.session.respond(
                    to: prompt,
                    generating: FilingDecision.self
                )
                self.apply(response.content, to: capture)
            } catch {
                // Guardrail refusal or generation failure — never guess, never lose.
                self.cont.yield(.needsReview(capture.id, guess: .note,
                    reason: "on-device model declined"))
            }
        }
    }

    private func apply(_ decision: FilingDecision, to capture: Capture) {
        // Multi-thought recording → split into children, file each.
        if decision.distinctThoughts.count > 1 {
            let children = decision.distinctThoughts.map {
                Capture(kind: capture.kind, deviceTranscript: $0, status: .processing)
            }
            cont.yield(.split(capture.id, into: children))
            for child in children { process(child) }
            return
        }

        cont.yield(.polish(capture.id,
                           newText: decision.polishedTranscript,
                           summary: decision.summary))

        guard decision.confident else {
            cont.yield(.needsReview(capture.id,
                                    guess: decision.category.noteCategory,
                                    reason: "low confidence"))
            return
        }

        let category = decision.category.noteCategory
        var actions: [FilingAction] = []
        switch category {
        case .shopping where !decision.shoppingItems.isEmpty:
            actions.append(FilingAction(tool: .addListItem,
                text: decision.shoppingItems.joined(separator: ", "),
                listName: "shopping", category: .shopping))
        case .todo:
            actions.append(FilingAction(tool: .createTodo,
                text: decision.summary,
                listName: "todo", due: decision.due, category: .todo))
        default:
            actions.append(FilingAction(tool: .fileCapture, text: "filed",
                listName: category.rawValue, category: category))
        }
        cont.yield(.filed(capture.id, category: category, actions: actions))
    }
}
