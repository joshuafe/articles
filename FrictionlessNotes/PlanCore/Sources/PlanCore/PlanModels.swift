//
//  PlanModels.swift
//  PlanCore
//
//  DESIGN-PM.md §5 — the project-manager layer's value types, shared by the
//  iPhone app and the Mac app. Plain structs; the apps map them to storage.
//  No UI here: colours and tints are app-side extensions.
//

import Foundation

/// Where a filed thought belongs. Shared so a task's category is one type everywhere.
public enum NoteCategory: String, Codable, CaseIterable, Sendable {
    case todo, shopping, idea, note, journal, reference
}

/// Deadlines are typed (§2). `hard` is never moved by the planner, only flagged;
/// `goal` may be proposed to move; `none` is the backlog.
public enum DeadlineKind: String, Codable, CaseIterable, Sendable {
    case hard, goal, none

    public var label: String {
        switch self {
        case .hard: return "hard deadline"
        case .goal: return "goal"
        case .none: return "no date"
        }
    }
}

public enum TaskState: String, Codable, Sendable {
    case todo, doing, waiting, done
}

/// A life area (DESIGN-PM.md v4.1): research, clinical, learning, family, health …
/// Each carries the share of your working time you mean to give it, so the
/// portfolio can show where time actually goes against where it should.
public struct Area: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var colourHex: UInt32
    public var intendedShare: Double     // 0…1 of weekly capacity
    public var order: Int

    public init(id: UUID = UUID(), name: String, colourHex: UInt32, intendedShare: Double, order: Int) {
        self.id = id
        self.name = name
        self.colourHex = colourHex
        self.intendedShare = intendedShare
        self.order = order
    }

    /// A starting set; the owner renames and reweights.
    public static let defaults: [Area] = [
        Area(name: "Research", colourHex: 0x5BA8FF, intendedShare: 0.35, order: 0),
        Area(name: "Clinical", colourHex: 0xFF8FA3, intendedShare: 0.15, order: 1),
        Area(name: "Learning", colourHex: 0xC792F2, intendedShare: 0.15, order: 2),
        Area(name: "Teaching & service", colourHex: 0x4CD98A, intendedShare: 0.10, order: 3),
        Area(name: "Family", colourHex: 0xF2A65A, intendedShare: 0.15, order: 4),
        Area(name: "Health", colourHex: 0x6FD2E0, intendedShare: 0.10, order: 5),
    ]
}

/// How far out a project lives. Drives the roadmap and the review rhythm.
public enum Horizon: String, Codable, CaseIterable, Sendable {
    case week, month, quarter, year, someday

    public var label: String {
        switch self {
        case .week: return "this week"
        case .month: return "this month"
        case .quarter: return "this quarter"
        case .year: return "this year"
        case .someday: return "someday"
        }
    }
}

public enum ProjectStatus: String, Codable, CaseIterable, Sendable {
    case active, waiting, paused, done
}

public struct Project: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var colourHex: UInt32
    public var goal: String?
    public var archived: Bool
    public let createdAt: Date
    // v4.1 — life project manager fields; all have defaults so older stores decode.
    public var areaID: UUID?
    public var horizon: Horizon
    public var status: ProjectStatus
    public var narrative: String?        // one plain paragraph of where it stands
    public var people: [String]

    public init(id: UUID = UUID(), name: String, colourHex: UInt32 = 0x5BA8FF,
                goal: String? = nil, archived: Bool = false, createdAt: Date = .now,
                areaID: UUID? = nil, horizon: Horizon = .month, status: ProjectStatus = .active,
                narrative: String? = nil, people: [String] = []) {
        self.id = id
        self.name = name
        self.colourHex = colourHex
        self.goal = goal
        self.archived = archived
        self.createdAt = createdAt
        self.areaID = areaID
        self.horizon = horizon
        self.status = status
        self.narrative = narrative
        self.people = people
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, colourHex, goal, archived, createdAt, areaID, horizon, status, narrative, people
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colourHex = try c.decode(UInt32.self, forKey: .colourHex)
        goal = try c.decodeIfPresent(String.self, forKey: .goal)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        areaID = try c.decodeIfPresent(UUID.self, forKey: .areaID)
        horizon = try c.decodeIfPresent(Horizon.self, forKey: .horizon) ?? .month
        status = try c.decodeIfPresent(ProjectStatus.self, forKey: .status) ?? .active
        narrative = try c.decodeIfPresent(String.self, forKey: .narrative)
        people = try c.decodeIfPresent([String].self, forKey: .people) ?? []
    }

    /// A small, distinct palette for projects, assigned round-robin.
    public static let palette: [UInt32] = [0x5BA8FF, 0x6FD2E0, 0xC792F2, 0xF2A65A, 0x4CD98A, 0xFF8FA3, 0xFFD66B]
}

/// The "there": a dated outcome with a typed deadline. Its path is the ordered
/// list of tasks whose `targetID` points here (ordered by `pathOrder`).
public struct Target: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var projectID: UUID?
    public var title: String
    public var due: Date?
    public var kind: DeadlineKind
    public var whyItMatters: String?
    public var consequenceIfMissed: String?
    public var done: Bool
    public var doneAt: Date?
    public let createdAt: Date
    public let sourceCaptureID: UUID?

    public init(id: UUID = UUID(), projectID: UUID? = nil, title: String, due: Date? = nil,
                kind: DeadlineKind = .none, whyItMatters: String? = nil,
                consequenceIfMissed: String? = nil, done: Bool = false, doneAt: Date? = nil,
                createdAt: Date = .now, sourceCaptureID: UUID? = nil) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.due = due
        self.kind = kind
        self.whyItMatters = whyItMatters
        self.consequenceIfMissed = consequenceIfMissed
        self.done = done
        self.doneAt = doneAt
        self.createdAt = createdAt
        self.sourceCaptureID = sourceCaptureID
    }
}

/// A real, checkable list item — and, in v4, the project manager's task. It may
/// belong to a project, sit on a target's path (ordered), carry an effort
/// estimate and a lead time, and have a typed date of its own. All of that is
/// optional, so a plain shopping item is exactly what it was.
public struct ListItem: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var text: String
    public var category: NoteCategory          // .todo or .shopping
    public var group: String?                  // cluster label ("permit", "groceries")
    public var due: String?                    // short spoken hint ("fri") — display only
    public var done: Bool
    public var doneAt: Date?
    public let createdAt: Date
    public let sourceCaptureID: UUID?          // provenance — tap back to the capture
    public let sourceActionID: UUID?           // links to the FilingAction (undo / move)

    // Project-manager fields (all optional)
    public var projectID: UUID?
    public var targetID: UUID?                 // the path this task is a step of
    public var pathOrder: Int                  // position on that path
    public var effortMinutes: Int?             // own work; nil = unestimated (engine assumes 30)
    public var leadDays: Int                   // elapsed waiting after this step (a reviewer, a shipment)
    public var milestone: Bool                 // worth a calendar date of its own
    public var needsYou: Bool                  // only the owner can do it
    public var waitingOn: String?              // a person or event
    public var dueDate: Date?                  // the task's own typed date (start of day)
    public var dueKind: DeadlineKind?
    public var state: TaskState
    public var plannedBy: String?              // nil = user/Gemma; "planner" when the planner added it
    public var actualMinutes: Int?             // what it really took (learning loop)

    public init(id: UUID = UUID(), text: String, category: NoteCategory,
                group: String? = nil, due: String? = nil, done: Bool = false,
                doneAt: Date? = nil, createdAt: Date = .now,
                sourceCaptureID: UUID? = nil, sourceActionID: UUID? = nil,
                projectID: UUID? = nil, targetID: UUID? = nil, pathOrder: Int = 0,
                effortMinutes: Int? = nil, leadDays: Int = 0, milestone: Bool = false,
                needsYou: Bool = false, waitingOn: String? = nil, dueDate: Date? = nil,
                dueKind: DeadlineKind? = nil, state: TaskState = .todo,
                plannedBy: String? = nil, actualMinutes: Int? = nil) {
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
        self.projectID = projectID
        self.targetID = targetID
        self.pathOrder = pathOrder
        self.effortMinutes = effortMinutes
        self.leadDays = leadDays
        self.milestone = milestone
        self.needsYou = needsYou
        self.waitingOn = waitingOn
        self.dueDate = dueDate
        self.dueKind = dueKind
        self.state = done ? .done : state
        self.plannedBy = plannedBy
        self.actualMinutes = actualMinutes
    }

    /// Effort the engine plans with. Unestimated work counts as half an hour.
    public var plannedEffort: Int { effortMinutes ?? 30 }
}

public struct DecisionOption: Equatable, Codable, Sendable {
    public var label: String
    public var does: String

    public init(label: String, does: String) {
        self.label = label
        self.does = does
    }
}

/// A self-contained decision card (§7): readable without the conversation it
/// came from. Raised by the engine (a hard target can't be met), the planner
/// (ambiguity) or the user.
public struct Decision: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var code: String                 // "D3", "E-T1" — short, stable, shown on the card
    public var projectID: UUID?
    public var targetID: UUID?
    public var question: String
    public var whyNow: String
    public var background: String
    public var touches: String
    public var options: [DecisionOption]
    public var ifUnanswered: String
    public var raisedBy: String             // engine | planner | user
    public let askedAt: Date
    public var answeredAt: Date?
    public var answer: String?
    public var deferredUntil: Date?

    public init(id: UUID = UUID(), code: String, projectID: UUID? = nil, targetID: UUID? = nil,
                question: String, whyNow: String, background: String, touches: String,
                options: [DecisionOption], ifUnanswered: String, raisedBy: String = "user",
                askedAt: Date = .now, answeredAt: Date? = nil, answer: String? = nil,
                deferredUntil: Date? = nil) {
        self.id = id
        self.code = code
        self.projectID = projectID
        self.targetID = targetID
        self.question = question
        self.whyNow = whyNow
        self.background = background
        self.touches = touches
        self.options = options
        self.ifUnanswered = ifUnanswered
        self.raisedBy = raisedBy
        self.askedAt = askedAt
        self.answeredAt = answeredAt
        self.answer = answer
        self.deferredUntil = deferredUntil
    }

    public var isAnswered: Bool { answeredAt != nil }
    public func isOpen(at now: Date = .now) -> Bool {
        guard answeredAt == nil else { return false }
        if let until = deferredUntil, until > now { return false }
        return true
    }
    public func isDeferred(at now: Date = .now) -> Bool {
        answeredAt == nil && (deferredUntil.map { $0 > now } ?? false)
    }
}

public struct Idea: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var projectID: UUID?
    public var text: String
    public let createdAt: Date
    public let sourceCaptureID: UUID?

    public init(id: UUID = UUID(), projectID: UUID? = nil, text: String,
                createdAt: Date = .now, sourceCaptureID: UUID? = nil) {
        self.id = id
        self.projectID = projectID
        self.text = text
        self.createdAt = createdAt
        self.sourceCaptureID = sourceCaptureID
    }
}

// MARK: - Capacity (§6.1)

public struct FixedBlock: Equatable, Codable, Sendable {
    public var day: Date          // start of day
    public var minutes: Int
    public var why: String

    public init(day: Date, minutes: Int, why: String) {
        self.day = day
        self.minutes = minutes
        self.why = why
    }
}

/// Minutes of focused work the engine may schedule per day. Monday-first.
/// The work calendar is never read (§9.1), so this is the only load the
/// engine knows about on weekdays.
public struct CapacityModel: Equatable, Codable, Sendable {
    public var minutesByWeekday: [Int]     // index 0 = Monday … 6 = Sunday
    public var fixed: [FixedBlock]

    public init(minutesByWeekday: [Int] = [120, 120, 120, 120, 120, 300, 300], fixed: [FixedBlock] = []) {
        self.minutesByWeekday = minutesByWeekday
        self.fixed = fixed
    }

    public static let interim = CapacityModel()

    public func minutes(on day: Date, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: day)   // 1 = Sunday … 7 = Saturday
        let mondayFirst = (weekday + 5) % 7
        let base = minutesByWeekday.indices.contains(mondayFirst) ? minutesByWeekday[mondayFirst] : 0
        let start = calendar.startOfDay(for: day)
        let reserved = fixed.filter { calendar.isDate($0.day, inSameDayAs: start) }.reduce(0) { $0 + $1.minutes }
        return max(0, base - reserved)
    }
}

// MARK: - Assessment (§6.1 output)

public enum TargetState: String, Codable, Sendable {
    case onTrack, atRisk, willMiss, slipping, done, backlog

    public var label: String {
        switch self {
        case .onTrack: return "on track"
        case .atRisk: return "at risk"
        case .willMiss: return "will miss"
        case .slipping: return "slipping"
        case .done: return "done"
        case .backlog: return "backlog"
        }
    }

    /// Sort key: the most pressing first.
    public var severity: Int {
        switch self {
        case .willMiss: return 0
        case .atRisk: return 1
        case .slipping: return 2
        case .onTrack: return 3
        case .backlog: return 4
        case .done: return 5
        }
    }
}

/// One task as the engine sees it: its wall, its planned window and the date
/// the engine chose for it. Every field is derived — never typed in.
public struct PlanStep: Equatable, Sendable {
    public let taskID: UUID
    public let targetID: UUID?
    public let index: Int
    public var wall: Date?
    public var latestStart: Date?
    public var plannedStart: Date?
    public var plannedEnd: Date?
    public var targetDate: Date?
    public var late: Bool
    public var minutesLeft: Int

    public init(taskID: UUID, targetID: UUID?, index: Int, wall: Date?, latestStart: Date?,
                plannedStart: Date?, plannedEnd: Date?, targetDate: Date?, late: Bool, minutesLeft: Int) {
        self.taskID = taskID
        self.targetID = targetID
        self.index = index
        self.wall = wall
        self.latestStart = latestStart
        self.plannedStart = plannedStart
        self.plannedEnd = plannedEnd
        self.targetDate = targetDate
        self.late = late
        self.minutesLeft = minutesLeft
    }
}

public struct TargetStatus: Equatable, Sendable {
    public let targetID: UUID
    public var state: TargetState
    public var slackDays: Int?
    public var lateTaskIDs: [UUID]
    public var remainingMinutes: Int

    public init(targetID: UUID, state: TargetState, slackDays: Int?, lateTaskIDs: [UUID], remainingMinutes: Int) {
        self.targetID = targetID
        self.state = state
        self.slackDays = slackDays
        self.lateTaskIDs = lateTaskIDs
        self.remainingMinutes = remainingMinutes
    }
}

public struct Allocation: Equatable, Sendable {
    public let taskID: UUID
    public let minutes: Int

    public init(taskID: UUID, minutes: Int) {
        self.taskID = taskID
        self.minutes = minutes
    }
}

public struct PlanAssessment: Equatable, Sendable {
    public let computedAt: Date
    public let today: Date
    public var steps: [UUID: PlanStep]              // by task id
    public var targets: [UUID: TargetStatus]        // by target id
    public var allocations: [Date: [Allocation]]    // by start of day
    public var raised: [Decision]                   // engine-raised "what gives?" cards

    public init(computedAt: Date, today: Date, steps: [UUID: PlanStep], targets: [UUID: TargetStatus],
                allocations: [Date: [Allocation]], raised: [Decision]) {
        self.computedAt = computedAt
        self.today = today
        self.steps = steps
        self.targets = targets
        self.allocations = allocations
        self.raised = raised
    }

    public var todaysCut: [Allocation] { allocations[today] ?? [] }

    public func status(of targetID: UUID) -> TargetStatus? { targets[targetID] }
    public func step(of taskID: UUID) -> PlanStep? { steps[taskID] }

    /// Minutes the plan has placed on a given day.
    public func committedMinutes(on day: Date) -> Int {
        (allocations[day] ?? []).reduce(0) { $0 + $1.minutes }
    }

    public static let empty = PlanAssessment(computedAt: .distantPast, today: .distantPast,
                                             steps: [:], targets: [:], allocations: [:], raised: [])
}
