//
//  CategoryFirstPass.swift
//  FrictionlessNotes
//
//  Stage 1 — the instant first pass. A small Create ML text classifier
//  (CoreML, Neural-Engine eligible) that guesses a capture's category in
//  milliseconds at near-zero power, so the ledger can paint a tinted tick the
//  moment the words land — long before Gemma (Stage 2) does the authoritative
//  organizing/answering on the GPU.
//
//  Deliberately decoupled from any brain: it's a plain first pass owned by the
//  store, so it works the same whichever pipeline (Gemma / Apple / mock) fills
//  in the real result. Gemma's `.filed` category always wins; this only colors
//  the wait.
//
//  Self-contained and fail-quiet: the model loads off the main thread and every
//  call returns nil until a trained `NoteCategoryClassifier.mlmodelc` is bundled
//  — so the app behaves exactly as before until the model lands, then lights up
//  with no further wiring. The training signal is free: Gemma's own category
//  decisions plus the user's corrections (refileLog / Lexicon) are the labels.
//

import Foundation
import NaturalLanguage

/// Off-main owner of the CoreML category model. Only Sendable values cross the
/// boundary (a String in, a NoteCategory out); the model never leaves the actor.
actor CategoryFirstPass {

    private var model: NLModel?
    private var triedLoad = false

    /// Compiled model resource name (Xcode compiles `NoteCategoryClassifier.mlmodel`
    /// → `NoteCategoryClassifier.mlmodelc` and bundles it).
    private static let resource = "NoteCategoryClassifier"

    /// Lazy, one-shot load — happens on this actor's executor, never on main.
    private func loadIfNeeded() {
        guard !triedLoad else { return }
        triedLoad = true
        guard let url = Bundle.main.url(forResource: Self.resource, withExtension: "mlmodelc") else {
            return  // No model bundled yet — stay quiet, no guess.
        }
        model = try? NLModel(contentsOf: url)
    }

    /// Best-effort category guess. Returns nil when no model is available, the
    /// text is too short to mean anything, or the label isn't one we recognize.
    func classify(_ text: String) -> NoteCategory? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }
        loadIfNeeded()
        guard let model, let label = model.predictedLabel(for: trimmed) else { return nil }
        return NoteCategory(rawValue: label)
    }
}
