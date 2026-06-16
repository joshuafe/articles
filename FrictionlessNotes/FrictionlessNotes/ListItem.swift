//
//  ListItem.swift
//  FrictionlessNotes
//
//  A real, checkable list item — the actionable output of filing. When the brain
//  files a todo/shopping capture, each FilingAction becomes one of these,
//  carrying provenance back to the source capture. Same value-type + SwiftData
//  boundary pattern as Capture/CaptureRecord; CloudKit-ready.
//

import Foundation
import SwiftData

struct ListItem: Identifiable, Equatable, Codable {
    let id: UUID
    var text: String
    var category: NoteCategory          // .todo or .shopping
    var group: String?                  // cluster label ("permit", "groceries")
    var due: String?
    var done: Bool
    var doneAt: Date?
    let createdAt: Date
    let sourceCaptureID: UUID?           // provenance — tap back to the capture
    let sourceActionID: UUID?            // links to the FilingAction (undo / move)

    init(id: UUID = UUID(), text: String, category: NoteCategory,
         group: String? = nil, due: String? = nil, done: Bool = false,
         doneAt: Date? = nil, createdAt: Date = .now,
         sourceCaptureID: UUID? = nil, sourceActionID: UUID? = nil) {
        self.id = id
        self.text = text
        self.category = category
        self.group = group
        self.due = due
        self.done = done
        self.doneAt = doneAt
        self.createdAt = createdAt
        self.sourceCaptureID = sourceCaptureID
        self.sourceActionID = sourceActionID
    }
}

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
    }
}

extension ListItem {
    init(record r: ListItemRecord) {
        self.init(id: r.id, text: r.text,
                  category: NoteCategory(rawValue: r.categoryRaw) ?? .todo,
                  group: r.group, due: r.due, done: r.done, doneAt: r.doneAt,
                  createdAt: r.createdAt,
                  sourceCaptureID: r.sourceCaptureID, sourceActionID: r.sourceActionID)
    }
}
