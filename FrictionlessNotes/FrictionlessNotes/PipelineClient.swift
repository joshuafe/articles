//
//  PipelineClient.swift
//  FrictionlessNotes
//
//  Stub seam per UI-SPEC.md §6. Round 2 swaps MockPipeline for the
//  CloudKit-backed client without touching a view.
//

import Foundation

@MainActor
protocol PipelineClient: AnyObject {
    var events: AsyncStream<PipelineEvent> { get }
    func submit(_ capture: Capture)
    /// Receipt Undo / Move-to — logged as a refile learning signal.
    func refile(captureID: UUID, actionID: UUID, to: NoteCategory?)
    var offline: Bool { get set }
    /// Captures waiting because the brain is unreachable (mock offline / mac asleep).
    var heldCount: Int { get }
    /// Read just before filing each capture so a just-taught correction applies
    /// to the very next thought. Returns a prompt fragment (empty when nothing
    /// has been learned). The store wires this to the live Lexicon.
    var lexiconProvider: (() -> String)? { get set }
}

/// Timed, canned Mac-agent behavior:
/// uploaded +1 s · processing +2 s · polish +4 s · filed +4.5 s.
/// Every 5th capture lands in needsReview. The two-thought script gets split.
@MainActor
final class MockPipeline: PipelineClient {

    let events: AsyncStream<PipelineEvent>
    private let cont: AsyncStream<PipelineEvent>.Continuation

    var offline: Bool = false {
        didSet { if !offline { drainHeldQueue() } }
    }
    var lexiconProvider: (() -> String)?

    private var held: [Capture] = []
    private var submissionCount = 0
    private(set) var refileLog: [(capture: UUID, action: UUID, to: NoteCategory?)] = []

    init() {
        (events, cont) = AsyncStream.makeStream(of: PipelineEvent.self)
    }

    var heldCount: Int { held.count }

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

    private func drainHeldQueue() {
        let queue = held
        held.removeAll()
        for c in queue { process(c) }
    }

    private func process(_ capture: Capture) {
        submissionCount += 1
        let isReviewCase = submissionCount % 5 == 0
        let isSplitCase = capture.deviceTranscript.contains("never had to turn on")
            && capture.deviceTranscript.contains("permit")

        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1))
            self.cont.yield(.statusChanged(capture.id, .uploaded))
            try? await Task.sleep(for: .seconds(1))
            self.cont.yield(.statusChanged(capture.id, .processing))

            if isSplitCase {
                try? await Task.sleep(for: .seconds(2))
                self.emitSplit(of: capture)
                return
            }

            try? await Task.sleep(for: .seconds(2))
            if isReviewCase {
                self.cont.yield(.needsReview(capture.id, guess: .note,
                    reason: "couldn't tell if this is a note or a todo"))
                return
            }

            let (polished, summary, category, actions) = Self.enrich(capture)
            self.cont.yield(.polish(capture.id, newText: polished, summary: summary))
            try? await Task.sleep(for: .milliseconds(500))
            self.cont.yield(.filed(capture.id, category: category, actions: actions))
        }
    }

    private func emitSplit(of capture: Capture) {
        let first = Capture(kind: .audio,
            deviceTranscript: "call dana about the permit before friday", status: .processing)
        let second = Capture(kind: .audio,
            deviceTranscript: "an idea the app should feel like a screen that never had to turn on",
            status: .processing)
        cont.yield(.split(capture.id, into: [first, second]))

        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1))
            self.cont.yield(.polish(first.id,
                newText: "Call Dana about the permit before Friday.",
                summary: "call Dana about the permit — Friday"))
            self.cont.yield(.filed(first.id, category: .todo, actions: [
                FilingAction(tool: .createTodo, text: "call Dana — permit",
                             listName: "todo", due: "fri", category: .todo)
            ]))
            try? await Task.sleep(for: .seconds(1))
            self.cont.yield(.polish(second.id,
                newText: "Idea: the app should feel like a screen that never had to turn on.",
                summary: "an app like a screen that never had to turn on"))
            self.cont.yield(.filed(second.id, category: .idea, actions: [
                FilingAction(tool: .fileCapture, text: "filed", listName: "ideas", category: .idea)
            ]))
        }
    }

    /// Canned enrichment incl. the homophone/term fix the polish sweep demos.
    private static func enrich(_ c: Capture) -> (String, String, NoteCategory, [FilingAction]) {
        let t = c.deviceTranscript.lowercased()
        if t.contains("met forman") || t.contains("metformin") {
            return (
                "Remember to ask Dr. Patel about the new metformin dosage before Friday.",
                "ask Dr. Patel about metformin dosage — Friday",
                .todo,
                [
                    FilingAction(tool: .createTodo, text: "ask Dr. Patel — metformin dosage",
                                 listName: "todo", due: "fri", category: .todo),
                    FilingAction(tool: .learned, text: "learned \u{201C}metformin\u{201D}",
                                 category: .reference)
                ]
            )
        }
        if t.contains("milk") || t.contains("coffee") {
            return (
                "We need milk, eggs, and the good coffee from the place on Fifth.",
                "milk, eggs, the good coffee",
                .shopping,
                [FilingAction(tool: .addListItem, text: "milk, eggs, good coffee",
                              listName: "shopping", category: .shopping)]
            )
        }
        let polished = c.deviceTranscript.prefix(1).uppercased() + String(c.deviceTranscript.dropFirst()) + "."
        return (
            polished,
            String(c.deviceTranscript.prefix(48)),
            .note,
            [FilingAction(tool: .fileCapture, text: "filed", listName: "notes", category: .note)]
        )
    }
}
