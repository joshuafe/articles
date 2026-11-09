//
//  HubWire.swift
//  FrictionlessMac
//
//  The hub's wire format (DESIGN-PM.md §9): the Postgres rows of
//  hub/supabase/migrations as snake_case JSON, with calendar dates as
//  'YYYY-MM-DD' and instants as ISO-8601 at millisecond precision. Every
//  PlanCore type maps to one row struct and back, and `HubChanges.diff` turns
//  two ledgers into the batch `apply_changes` expects.
//

import Foundation
import PlanCore

// MARK: - Dates on the wire

enum HubDates {
    static let calendar = Calendar.current

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func day(_ d: Date?) -> String? { d.map { dayFormatter.string(from: $0) } }
    static func day(_ s: String?) -> Date? {
        guard let s, s.count >= 10, let d = dayFormatter.date(from: String(s.prefix(10))) else { return nil }
        return calendar.startOfDay(for: d)
    }
    /// Millisecond precision both ways, so a round trip through the hub is a no-op.
    static func stamp(_ d: Date?) -> String? {
        guard let d else { return nil }
        let ms = (d.timeIntervalSince1970 * 1000).rounded() / 1000
        return isoFractional.string(from: Date(timeIntervalSince1970: ms))
    }
    static func stamp(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = isoFractional.date(from: s) { return d }
        if let d = isoPlain.date(from: s) { return d }
        // Postgres may print more than three fractional digits: trim to milliseconds.
        if let r = s.range(of: #"\.\d{4,}"#, options: .regularExpression) {
            let trimmed = s.replacingCharacters(in: r, with: String(s[r].prefix(4)))
            return isoFractional.date(from: trimmed)
        }
        return nil
    }
}

// MARK: - Rows

struct WireArea: Codable, Equatable {
    var id: UUID; var name: String; var colour_hex: UInt32; var intended_share: Double; var sort_order: Int
    var created_at: String?

    init(_ a: Area) { id = a.id; name = a.name; colour_hex = a.colourHex; intended_share = a.intendedShare; sort_order = a.order }
    var model: Area { Area(id: id, name: name, colourHex: colour_hex, intendedShare: intended_share, order: sort_order) }
}

struct WireProject: Codable, Equatable {
    var id: UUID; var name: String; var colour_hex: UInt32; var goal: String?; var archived: Bool; var created_at: String?
    var area_id: UUID?; var horizon: String; var status: String; var narrative: String?; var people: [String]

    init(_ p: Project) {
        id = p.id; name = p.name; colour_hex = p.colourHex; goal = p.goal; archived = p.archived
        created_at = HubDates.stamp(p.createdAt); area_id = p.areaID; horizon = p.horizon.rawValue; status = p.status.rawValue
        narrative = p.narrative; people = p.people
    }
    var model: Project {
        Project(id: id, name: name, colourHex: colour_hex, goal: goal, archived: archived,
                createdAt: HubDates.stamp(created_at) ?? .now, areaID: area_id,
                horizon: Horizon(rawValue: horizon) ?? .month, status: ProjectStatus(rawValue: status) ?? .active,
                narrative: narrative, people: people)
    }
}

struct WireTarget: Codable, Equatable {
    var id: UUID; var project_id: UUID?; var title: String; var due: String?; var kind: String
    var why_it_matters: String?; var consequence_if_missed: String?; var done: Bool; var done_at: String?
    var created_at: String?; var source_capture_id: UUID?

    init(_ t: Target) {
        id = t.id; project_id = t.projectID; title = t.title; due = HubDates.day(t.due); kind = t.kind.rawValue
        why_it_matters = t.whyItMatters; consequence_if_missed = t.consequenceIfMissed; done = t.done
        done_at = HubDates.stamp(t.doneAt); created_at = HubDates.stamp(t.createdAt); source_capture_id = t.sourceCaptureID
    }
    var model: Target {
        Target(id: id, projectID: project_id, title: title, due: HubDates.day(due), kind: DeadlineKind(rawValue: kind) ?? .none,
               whyItMatters: why_it_matters, consequenceIfMissed: consequence_if_missed, done: done, doneAt: HubDates.stamp(done_at),
               createdAt: HubDates.stamp(created_at) ?? .now, sourceCaptureID: source_capture_id)
    }
}

struct WireTask: Codable, Equatable {
    var id: UUID; var text: String; var category: String; var group_label: String?; var due_hint: String?
    var done: Bool; var done_at: String?; var created_at: String?; var source_capture_id: UUID?; var source_action_id: UUID?
    var project_id: UUID?; var target_id: UUID?; var path_order: Int; var effort_minutes: Int?; var lead_days: Int
    var milestone: Bool; var needs_you: Bool; var waiting_on: String?; var due_date: String?; var due_kind: String?
    var state: String; var planned_by: String?; var actual_minutes: Int?

    init(_ t: ListItem) {
        id = t.id; text = t.text; category = t.category.rawValue; group_label = t.group; due_hint = t.due
        done = t.done; done_at = HubDates.stamp(t.doneAt); created_at = HubDates.stamp(t.createdAt)
        source_capture_id = t.sourceCaptureID; source_action_id = t.sourceActionID
        project_id = t.projectID; target_id = t.targetID; path_order = t.pathOrder; effort_minutes = t.effortMinutes
        lead_days = t.leadDays; milestone = t.milestone; needs_you = t.needsYou; waiting_on = t.waitingOn
        due_date = HubDates.day(t.dueDate); due_kind = t.dueKind?.rawValue; state = t.state.rawValue
        planned_by = t.plannedBy; actual_minutes = t.actualMinutes
    }
    var model: ListItem {
        ListItem(id: id, text: text, category: NoteCategory(rawValue: category) ?? .todo, group: group_label, due: due_hint,
                 done: done, doneAt: HubDates.stamp(done_at), createdAt: HubDates.stamp(created_at) ?? .now,
                 sourceCaptureID: source_capture_id, sourceActionID: source_action_id, projectID: project_id, targetID: target_id,
                 pathOrder: path_order, effortMinutes: effort_minutes, leadDays: lead_days, milestone: milestone, needsYou: needs_you,
                 waitingOn: waiting_on, dueDate: HubDates.day(due_date), dueKind: due_kind.flatMap { DeadlineKind(rawValue: $0) },
                 state: TaskState(rawValue: state) ?? .todo, plannedBy: planned_by, actualMinutes: actual_minutes)
    }
}

struct WireOption: Codable, Equatable { var label: String; var does: String }

struct WireDecision: Codable, Equatable {
    var id: UUID; var code: String; var project_id: UUID?; var target_id: UUID?; var question: String
    var why_now: String; var background: String; var touches: String; var options: [WireOption]; var if_unanswered: String
    var raised_by: String; var asked_at: String?; var answered_at: String?; var answer: String?; var deferred_until: String?

    init(_ d: Decision) {
        id = d.id; code = d.code; project_id = d.projectID; target_id = d.targetID; question = d.question
        why_now = d.whyNow; background = d.background; touches = d.touches
        options = d.options.map { WireOption(label: $0.label, does: $0.does) }; if_unanswered = d.ifUnanswered
        raised_by = d.raisedBy; asked_at = HubDates.stamp(d.askedAt); answered_at = HubDates.stamp(d.answeredAt)
        answer = d.answer; deferred_until = HubDates.stamp(d.deferredUntil)
    }
    var model: Decision {
        Decision(id: id, code: code, projectID: project_id, targetID: target_id, question: question, whyNow: why_now,
                 background: background, touches: touches, options: options.map { DecisionOption(label: $0.label, does: $0.does) },
                 ifUnanswered: if_unanswered, raisedBy: raised_by, askedAt: HubDates.stamp(asked_at) ?? .now,
                 answeredAt: HubDates.stamp(answered_at), answer: answer, deferredUntil: HubDates.stamp(deferred_until))
    }
}

struct WireIdea: Codable, Equatable {
    var id: UUID; var project_id: UUID?; var text: String; var created_at: String?; var source_capture_id: UUID?
    init(_ i: Idea) { id = i.id; project_id = i.projectID; text = i.text; created_at = HubDates.stamp(i.createdAt); source_capture_id = i.sourceCaptureID }
    var model: Idea { Idea(id: id, projectID: project_id, text: text, createdAt: HubDates.stamp(created_at) ?? .now, sourceCaptureID: source_capture_id) }
}

struct WireFixed: Codable, Equatable { var day: String; var minutes: Int; var why: String }

struct WireCapacity: Codable, Equatable {
    var minutes_by_weekday: [Int]; var fixed: [WireFixed]
    init(_ c: CapacityModel) {
        minutes_by_weekday = c.minutesByWeekday
        fixed = c.fixed.compactMap { f in HubDates.day(f.day).map { WireFixed(day: $0, minutes: f.minutes, why: f.why) } }
    }
    var model: CapacityModel {
        CapacityModel(minutesByWeekday: minutes_by_weekday,
                      fixed: fixed.compactMap { f in HubDates.day(f.day).map { FixedBlock(day: $0, minutes: f.minutes, why: f.why) } })
    }
}

/// What `GET /sync` returns (ledger_snapshot). Unknown keys are ignored.
struct WireSnapshot: Decodable {
    var version: Int
    var areas: [WireArea]
    var projects: [WireProject]
    var targets: [WireTarget]
    var tasks: [WireTask]
    var decisions: [WireDecision]
    var ideas: [WireIdea]
    var capacity: WireCapacity?

    var ledger: Ledger {
        Ledger(areas: areas.map(\.model), projects: projects.map(\.model), targets: targets.map(\.model), tasks: tasks.map(\.model),
               decisions: decisions.map(\.model), ideas: ideas.map(\.model), capacity: capacity?.model ?? .interim)
    }
    var isEmpty: Bool { projects.isEmpty && targets.isEmpty && tasks.isEmpty && ideas.isEmpty }
}

// MARK: - Changes

/// The batch `apply_changes` takes: whole rows that are new or different, plus ids to delete.
struct HubChanges: Encodable {
    struct Deleted: Encodable {
        var areas: [UUID] = [], projects: [UUID] = [], targets: [UUID] = [], tasks: [UUID] = [], decisions: [UUID] = [], ideas: [UUID] = []
        var isEmpty: Bool { areas.isEmpty && projects.isEmpty && targets.isEmpty && tasks.isEmpty && decisions.isEmpty && ideas.isEmpty }
    }
    var areas: [WireArea] = []
    var projects: [WireProject] = []
    var targets: [WireTarget] = []
    var tasks: [WireTask] = []
    var decisions: [WireDecision] = []
    var ideas: [WireIdea] = []
    var capacity: WireCapacity?
    var deleted = Deleted()

    var isEmpty: Bool {
        areas.isEmpty && projects.isEmpty && targets.isEmpty && tasks.isEmpty && decisions.isEmpty && ideas.isEmpty && capacity == nil && deleted.isEmpty
    }
    var count: Int {
        areas.count + projects.count + targets.count + tasks.count + decisions.count + ideas.count + (capacity == nil ? 0 : 1)
            + deleted.areas.count + deleted.projects.count + deleted.targets.count + deleted.tasks.count + deleted.decisions.count + deleted.ideas.count
    }

    /// Rows in `new` that are missing from or different in `base`, and ids in `base` that `new` no longer has.
    static func diff(from base: Ledger, to new: Ledger) -> HubChanges {
        var c = HubChanges()
        func changed<M: Identifiable, W: Equatable>(_ old: [M], _ now: [M], _ wire: (M) -> W) -> (rows: [W], gone: [M.ID]) where M.ID == UUID {
            let oldByID = Dictionary(old.map { ($0.id, wire($0)) }, uniquingKeysWith: { a, _ in a })
            let newIDs = Set(now.map(\.id))
            var rows: [W] = []
            for m in now {
                let w = wire(m)
                if oldByID[m.id] != w { rows.append(w) }
            }
            return (rows, old.map(\.id).filter { !newIDs.contains($0) })
        }
        let a = changed(base.areas, new.areas, WireArea.init); c.areas = a.rows; c.deleted.areas = a.gone
        let p = changed(base.projects, new.projects, WireProject.init); c.projects = p.rows; c.deleted.projects = p.gone
        let t = changed(base.targets, new.targets, WireTarget.init); c.targets = t.rows; c.deleted.targets = t.gone
        let k = changed(base.tasks, new.tasks, WireTask.init); c.tasks = k.rows; c.deleted.tasks = k.gone
        let d = changed(base.decisions, new.decisions, WireDecision.init); c.decisions = d.rows; c.deleted.decisions = d.gone
        let i = changed(base.ideas, new.ideas, WireIdea.init); c.ideas = i.rows; c.deleted.ideas = i.gone
        if WireCapacity(base.capacity) != WireCapacity(new.capacity) { c.capacity = WireCapacity(new.capacity) }
        return c
    }
}
