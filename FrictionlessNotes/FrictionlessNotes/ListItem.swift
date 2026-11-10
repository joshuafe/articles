//
//  ListItem.swift
//  FrictionlessNotes
//
//  SwiftData record for `ListItem` (the value type lives in PlanCore so the Mac
//  app shares it). Same boundary pattern as Capture/CaptureRecord; CloudKit-ready:
//  every v4 column optional or defaulted, so existing stores migrate lightly.
//

import Foundation
import SwiftData

@Model
final class ListItemRecord {
    var id: UUID = UUID()
    var text: String = ""
    var categoryRaw: String = NoteCategory.todo.rawValue
    var group: String?
    var due: String?
    var done: Bool = false
    var doneAt: Date?
    var createdAt: Date = Date.now
    var sourceCaptureID: UUID?
    var sourceActionID: UUID?
    // v4
    var projectID: UUID?
    var targetID: UUID?
    var pathOrder: Int = 0
    var effortMinutes: Int?
    var leadDays: Int = 0
    var milestone: Bool = false
    var needsYou: Bool = false
    var waitingOn: String?
    var dueDate: Date?
    var dueKindRaw: String?
    var stateRaw: String = TaskState.todo.rawValue
    var plannedBy: String?
    var actualMinutes: Int?

    init(id: UUID, text: String, categoryRaw: String, createdAt: Date) {
        self.id = id
        self.text = text
        self.categoryRaw = categoryRaw
        self.createdAt = createdAt
    }
}

extension ListItemRecord {
    convenience init(_ i: ListItem) {
        self.init(id: i.id, text: i.text, categoryRaw: i.category.rawValue, createdAt: i.createdAt)
        update(from: i)
    }

    func update(from i: ListItem) {
        text = i.text
        categoryRaw = i.category.rawValue
        group = i.group
        due = i.due
        done = i.done
        doneAt = i.doneAt
        sourceCaptureID = i.sourceCaptureID
        sourceActionID = i.sourceActionID
        projectID = i.projectID
        targetID = i.targetID
        pathOrder = i.pathOrder
        effortMinutes = i.effortMinutes
        leadDays = i.leadDays
        milestone = i.milestone
        needsYou = i.needsYou
        waitingOn = i.waitingOn
        dueDate = i.dueDate
        dueKindRaw = i.dueKind?.rawValue
        stateRaw = i.state.rawValue
        plannedBy = i.plannedBy
        actualMinutes = i.actualMinutes
    }
}

extension ListItem {
    init(record r: ListItemRecord) {
        self.init(id: r.id, text: r.text,
                  category: NoteCategory(rawValue: r.categoryRaw) ?? .todo,
                  group: r.group, due: r.due, done: r.done, doneAt: r.doneAt,
                  createdAt: r.createdAt,
                  sourceCaptureID: r.sourceCaptureID, sourceActionID: r.sourceActionID,
                  projectID: r.projectID, targetID: r.targetID, pathOrder: r.pathOrder,
                  effortMinutes: r.effortMinutes, leadDays: r.leadDays,
                  milestone: r.milestone, needsYou: r.needsYou, waitingOn: r.waitingOn,
                  dueDate: r.dueDate, dueKind: r.dueKindRaw.flatMap(DeadlineKind.init(rawValue:)),
                  state: TaskState(rawValue: r.stateRaw) ?? .todo,
                  plannedBy: r.plannedBy, actualMinutes: r.actualMinutes)
    }
}
