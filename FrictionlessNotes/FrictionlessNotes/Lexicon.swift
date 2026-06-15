//
//  Lexicon.swift
//  FrictionlessNotes
//
//  Personal lexicon (DESIGN.md §"Personal lexicon"). Terms the user actually
//  says — names, medical/scientific vocabulary, product names. v1 source is
//  manual tap-to-correct: each correction stores a (heard → meant) pair. The
//  brain's polish pass injects the relevant terms into its prompt, so the ear
//  (Parakeet) can keep mishearing a word and the LLM still fixes it every time.
//
//  Round 1: in-memory, mirroring the rest of the model layer. Round 2 backs
//  this with the synced SwiftData `LexiconEntry` table.
//

import Foundation
import Observation

/// One thing the user taught the app: they said `meant`, the ear heard `heard`.
struct LexiconEntry: Identifiable, Equatable, Codable {
    let id: UUID
    let meant: String               // the correct term — "metformin", "Beauchamp"
    var misheardForms: [String]     // what the ear produced — "met forman", "bo champ"
    let source: Source
    let addedAt: Date

    enum Source: String, Codable { case correction, contacts, extracted }

    init(id: UUID = UUID(), meant: String, misheardForms: [String] = [],
         source: Source = .correction, addedAt: Date = .now) {
        self.id = id
        self.meant = meant
        self.misheardForms = misheardForms
        self.source = source
        self.addedAt = addedAt
    }
}

/// The live lexicon. Owned by CaptureStore, read by the brain at file time.
@MainActor
@Observable
final class Lexicon {

    private(set) var entries: [LexiconEntry] = []

    /// Record a correction. If the user has taught this term before, the new
    /// misheard form is folded into the existing entry rather than duplicated.
    func learn(meant: String, heard: String?, source: LexiconEntry.Source = .correction) {
        let term = meant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        let misheard = heard?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let i = entries.firstIndex(where: { $0.meant.caseInsensitiveCompare(term) == .orderedSame }) {
            if let misheard, !misheard.isEmpty,
               !entries[i].misheardForms.contains(misheard) {
                entries[i].misheardForms.append(misheard)
            }
        } else {
            entries.insert(
                LexiconEntry(meant: term,
                             misheardForms: misheard.map { [$0] } ?? [],
                             source: source),
                at: 0
            )
        }
    }

    /// The brain's prompt budget is small, so we keep the injected list short
    /// and most-recent-first. Round 2 ranks by relevance to the current draft.
    func promptTerms(limit: Int = 24) -> [String] {
        Array(entries.prefix(limit).map(\.meant))
    }

    /// A compact line the polish prompt can paste in verbatim. Empty when the
    /// user hasn't taught anything yet, so the brain sees no noise.
    func promptInjection(limit: Int = 24) -> String {
        let terms = promptTerms(limit: limit)
        guard !terms.isEmpty else { return "" }
        return "The user often says these terms; prefer them when the transcript "
            + "is a near-match: " + terms.joined(separator: ", ") + "."
    }
}
