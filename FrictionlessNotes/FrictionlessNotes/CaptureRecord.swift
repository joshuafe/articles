//
//  CaptureRecord.swift
//  FrictionlessNotes
//
//  SwiftData persistence record for a Capture. Storage is kept as a boundary
//  concern: the app keeps its value-type `Capture` (value semantics, Equatable
//  animations, pipeline events carrying captures), and this @Model is its
//  durable form. The store maps between the two at load/save.
//
//  CloudKit-ready by construction (so the design's iCloud sync is a later flip,
//  not a rewrite): every property is optional or defaulted and there are no
//  unique constraints — SwiftData+CloudKit's requirements.
//

import Foundation
import SwiftData

@Model
final class CaptureRecord {
    var id: UUID = UUID()
    var createdAt: Date = Date.now
    var kindRaw: String = CaptureKind.text.rawValue
    var deviceTranscript: String = ""
    var finalTranscript: String?
    var previousTranscript: String?
    var userEditedAt: Date?
    var summary: String?
    var categoryRaw: String?
    var provisionalCategoryRaw: String?
    var statusRaw: String = CaptureStatus.saved.rawValue
    var reviewGuessRaw: String?
    var reviewReason: String?
    var polishArrivedAt: Date?
    /// `[FilingAction]` encoded as JSON — small, and avoids a child-entity
    /// relationship for v1 (the design's ActionLog can split it out later).
    var actionsData: Data?
    var isQuestion: Bool = false
    var answer: String?
    var answerArrivedAt: Date?
    var citationsData: Data?            // [UUID] of cited captures, JSON

    init(id: UUID, createdAt: Date, kindRaw: String, deviceTranscript: String) {
        self.id = id
        self.createdAt = createdAt
        self.kindRaw = kindRaw
        self.deviceTranscript = deviceTranscript
    }
}

extension CaptureRecord {
    convenience init(_ capture: Capture) {
        self.init(id: capture.id, createdAt: capture.createdAt,
                  kindRaw: capture.kind.rawValue, deviceTranscript: capture.deviceTranscript)
        update(from: capture)
    }

    /// Copy the mutable fields across — used for both insert and update.
    func update(from c: Capture) {
        deviceTranscript = c.deviceTranscript
        finalTranscript = c.finalTranscript
        previousTranscript = c.previousTranscript
        userEditedAt = c.userEditedAt
        summary = c.summary
        categoryRaw = c.category?.rawValue
        provisionalCategoryRaw = c.provisionalCategory?.rawValue
        statusRaw = c.status.rawValue
        reviewGuessRaw = c.reviewGuess?.rawValue
        reviewReason = c.reviewReason
        polishArrivedAt = c.polishArrivedAt
        actionsData = try? JSONEncoder().encode(c.actions)
        isQuestion = c.isQuestion
        answer = c.answer
        answerArrivedAt = c.answerArrivedAt
        citationsData = try? JSONEncoder().encode(c.citedCaptureIDs)
    }
}

extension Capture {
    init(record r: CaptureRecord) {
        self.init(id: r.id, createdAt: r.createdAt,
                  kind: CaptureKind(rawValue: r.kindRaw) ?? .text,
                  deviceTranscript: r.deviceTranscript,
                  status: CaptureStatus(rawValue: r.statusRaw) ?? .saved)
        finalTranscript = r.finalTranscript
        previousTranscript = r.previousTranscript
        userEditedAt = r.userEditedAt
        summary = r.summary
        category = r.categoryRaw.flatMap(NoteCategory.init(rawValue:))
        provisionalCategory = r.provisionalCategoryRaw.flatMap(NoteCategory.init(rawValue:))
        reviewGuess = r.reviewGuessRaw.flatMap(NoteCategory.init(rawValue:))
        reviewReason = r.reviewReason
        polishArrivedAt = r.polishArrivedAt
        actions = r.actionsData.flatMap { try? JSONDecoder().decode([FilingAction].self, from: $0) } ?? []
        isQuestion = r.isQuestion
        answer = r.answer
        answerArrivedAt = r.answerArrivedAt
        citedCaptureIDs = r.citationsData.flatMap { try? JSONDecoder().decode([UUID].self, from: $0) } ?? []
    }
}
