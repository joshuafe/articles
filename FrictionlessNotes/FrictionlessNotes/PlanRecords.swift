//
//  PlanRecords.swift
//  FrictionlessNotes
//
//  SwiftData records for the project-manager layer (DESIGN-PM.md §5). Same
//  boundary pattern as CaptureRecord: every property optional or defaulted, no
//  unique constraints, value-type mapping at load/save.
//

import Foundation
import SwiftData

@Model
final class ProjectRecord {
    var id: UUID = UUID()
    var name: String = ""
    var colourHex: Int = 0x5BA8FF
    var goal: String?
    var archived: Bool = false
    var createdAt: Date = Date.now

    init(id: UUID, name: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

extension ProjectRecord {
    convenience init(_ p: Project) {
        self.init(id: p.id, name: p.name, createdAt: p.createdAt)
        update(from: p)
    }
    func update(from p: Project) {
        name = p.name
        colourHex = Int(p.colourHex)
        goal = p.goal
        archived = p.archived
    }
}

extension Project {
    init(record r: ProjectRecord) {
        self.init(id: r.id, name: r.name, colourHex: UInt32(clamping: r.colourHex),
                  goal: r.goal, archived: r.archived, createdAt: r.createdAt)
    }
}

@Model
final class TargetRecord {
    var id: UUID = UUID()
    var projectID: UUID?
    var title: String = ""
    var due: Date?
    var kindRaw: String = DeadlineKind.none.rawValue
    var whyItMatters: String?
    var consequenceIfMissed: String?
    var done: Bool = false
    var doneAt: Date?
    var createdAt: Date = Date.now
    var sourceCaptureID: UUID?

    init(id: UUID, title: String, createdAt: Date) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
    }
}

extension TargetRecord {
    convenience init(_ t: Target) {
        self.init(id: t.id, title: t.title, createdAt: t.createdAt)
        update(from: t)
    }
    func update(from t: Target) {
        projectID = t.projectID
        title = t.title
        due = t.due
        kindRaw = t.kind.rawValue
        whyItMatters = t.whyItMatters
        consequenceIfMissed = t.consequenceIfMissed
        done = t.done
        doneAt = t.doneAt
        sourceCaptureID = t.sourceCaptureID
    }
}

extension Target {
    init(record r: TargetRecord) {
        self.init(id: r.id, projectID: r.projectID, title: r.title, due: r.due,
                  kind: DeadlineKind(rawValue: r.kindRaw) ?? .none,
                  whyItMatters: r.whyItMatters, consequenceIfMissed: r.consequenceIfMissed,
                  done: r.done, doneAt: r.doneAt, createdAt: r.createdAt,
                  sourceCaptureID: r.sourceCaptureID)
    }
}

@Model
final class DecisionRecord {
    var id: UUID = UUID()
    var code: String = ""
    var projectID: UUID?
    var targetID: UUID?
    var question: String = ""
    var whyNow: String = ""
    var background: String = ""
    var touches: String = ""
    var optionsData: Data?            // [DecisionOption] as JSON
    var ifUnanswered: String = ""
    var raisedBy: String = "user"
    var askedAt: Date = Date.now
    var answeredAt: Date?
    var answer: String?
    var deferredUntil: Date?

    init(id: UUID, code: String, askedAt: Date) {
        self.id = id
        self.code = code
        self.askedAt = askedAt
    }
}

extension DecisionRecord {
    convenience init(_ d: Decision) {
        self.init(id: d.id, code: d.code, askedAt: d.askedAt)
        update(from: d)
    }
    func update(from d: Decision) {
        code = d.code
        projectID = d.projectID
        targetID = d.targetID
        question = d.question
        whyNow = d.whyNow
        background = d.background
        touches = d.touches
        optionsData = try? JSONEncoder().encode(d.options)
        ifUnanswered = d.ifUnanswered
        raisedBy = d.raisedBy
        answeredAt = d.answeredAt
        answer = d.answer
        deferredUntil = d.deferredUntil
    }
}

extension Decision {
    init(record r: DecisionRecord) {
        let options = r.optionsData.flatMap { try? JSONDecoder().decode([DecisionOption].self, from: $0) } ?? []
        self.init(id: r.id, code: r.code, projectID: r.projectID, targetID: r.targetID,
                  question: r.question, whyNow: r.whyNow, background: r.background,
                  touches: r.touches, options: options, ifUnanswered: r.ifUnanswered,
                  raisedBy: r.raisedBy, askedAt: r.askedAt, answeredAt: r.answeredAt,
                  answer: r.answer, deferredUntil: r.deferredUntil)
    }
}

@Model
final class IdeaRecord {
    var id: UUID = UUID()
    var projectID: UUID?
    var text: String = ""
    var createdAt: Date = Date.now
    var sourceCaptureID: UUID?

    init(id: UUID, text: String, createdAt: Date) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

extension IdeaRecord {
    convenience init(_ i: Idea) {
        self.init(id: i.id, text: i.text, createdAt: i.createdAt)
        update(from: i)
    }
    func update(from i: Idea) {
        projectID = i.projectID
        text = i.text
        sourceCaptureID = i.sourceCaptureID
    }
}

extension Idea {
    init(record r: IdeaRecord) {
        self.init(id: r.id, projectID: r.projectID, text: r.text,
                  createdAt: r.createdAt, sourceCaptureID: r.sourceCaptureID)
    }
}
