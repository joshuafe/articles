//
//  PlanEngine.swift
//  FrictionlessNotes
//
//  Tier 0 — the urgency engine (DESIGN-PM.md §6.1). Deterministic, no model,
//  runs on every change in well under a millisecond. Port of
//  pm-prototype/engine.py; keep the two in step.
//
//  Two walks per target:
//    backwards from the deadline  → each step's WALL (latest finish for the end date to hold)
//    forwards from today, EDF     → each step's PLANNED window in real capacity, then its
//                                   TARGET DATE (planned end + buffer, never past the wall)
//

import Foundation

public enum PlanEngine {

    public struct Input {
        public var today: Date
        public var calendar: Calendar
        public var capacity: CapacityModel
        public var targets: [Target]
        public var tasks: [ListItem]
        public var horizonDays: Int

        public init(today: Date, calendar: Calendar = .current, capacity: CapacityModel,
                    targets: [Target], tasks: [ListItem], horizonDays: Int = 120) {
            self.today = today
            self.calendar = calendar
            self.capacity = capacity
            self.targets = targets
            self.tasks = tasks
            self.horizonDays = horizonDays
        }
    }

    /// Mutable per-step working state for the simulation.
    private final class Node {
        let task: ListItem
        let target: Target?
        let index: Int
        let siblings: Int
        var wall: Date?
        var latestStart: Date?
        var left: Int
        var readyFrom: Date
        var plannedStart: Date?
        var plannedEnd: Date?
        var lead: Int { task.leadDays }

        init(task: ListItem, target: Target?, index: Int, siblings: Int, today: Date) {
            self.task = task
            self.target = target
            self.index = index
            self.siblings = siblings
            self.left = task.plannedEffort
            self.readyFrom = today
        }

        var kind: DeadlineKind {
            if let target { return target.kind }
            return task.dueKind ?? .none
        }
    }

    public static func plan(_ input: Input) -> PlanAssessment {
        let cal = input.calendar
        let today = cal.startOfDay(for: input.today)
        let horizon = cal.date(byAdding: .day, value: input.horizonDays, to: today)!
        func cap(_ day: Date) -> Int { input.capacity.minutes(on: day, calendar: cal) }
        func shift(_ day: Date, _ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: day)! }

        // ── Group open tasks into paths ──────────────────────────────────────
        var paths: [[Node]] = []
        let openTargets = input.targets.filter { !$0.done }
        var targetByID: [UUID: Target] = [:]
        for t in openTargets { targetByID[t.id] = t }

        for t in openTargets {
            let steps = input.tasks
                .filter { $0.targetID == t.id && !$0.done }
                .sorted { ($0.pathOrder, $0.createdAt) < ($1.pathOrder, $1.createdAt) }
            if steps.isEmpty { continue }
            paths.append(steps.enumerated().map { Node(task: $1, target: t, index: $0, siblings: steps.count, today: today) })
        }
        // Standalone tasks (no live target) are one-step paths of their own.
        for task in input.tasks where !task.done && task.category == .todo
            && (task.targetID == nil || targetByID[task.targetID!] == nil) {
            paths.append([Node(task: task, target: nil, index: 0, siblings: 1, today: today)])
        }

        // ── Backward walk: walls and latest starts ───────────────────────────
        for path in paths {
            var lf: Date? = path.first?.target?.due.map { cal.startOfDay(for: $0) }
            for node in path.reversed() {
                let own = node.task.dueDate.map { cal.startOfDay(for: $0) }
                let wall = [lf, own].compactMap { $0 }.min()
                node.wall = wall
                guard let wall else { continue }
                var remaining = node.task.plannedEffort
                var day = wall
                let floor = shift(today, -365)
                while remaining > 0 && day > floor {
                    remaining -= cap(day)
                    if remaining > 0 { day = shift(day, -1) }
                }
                node.latestStart = day
                lf = shift(day, -node.lead)
            }
        }

        // ── Forward walk: earliest-deadline-first, by urgency class ──────────
        let all = paths.flatMap { $0 }
        func urgencyClass(_ n: Node, on day: Date) -> Int {
            switch n.kind {
            case .hard:
                if let ls = n.latestStart, ls <= day { return 0 }
                return 2
            case .goal:
                if let w = n.wall, w < day { return 1 }
                return 3
            case .none:
                return 4
            }
        }
        func rank(_ n: Node, on day: Date) -> (Int, Date, Date, Int) {
            (urgencyClass(n, on: day), n.wall ?? horizon, n.target?.due ?? horizon, n.index)
        }
        func lessThan(_ a: (Int, Date, Date, Int), _ b: (Int, Date, Date, Int)) -> Bool {
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1 != b.1 { return a.1 < b.1 }
            if a.2 != b.2 { return a.2 < b.2 }
            return a.3 < b.3
        }

        var allocations: [Date: [Allocation]] = [:]
        var day = today
        while day <= horizon {
            var free = cap(day)
            while free > 0 {
                let ready = all.filter { n in
                    guard n.left > 0, n.readyFrom <= day else { return false }
                    if n.index == 0 { return true }
                    let prev = paths.first { $0.contains { $0 === n } }![n.index - 1]
                    return prev.left == 0
                }
                guard let pick = ready.min(by: { lessThan(rank($0, on: day), rank($1, on: day)) }) else { break }
                let take = min(free, pick.left)
                pick.left -= take
                free -= take
                if pick.plannedStart == nil { pick.plannedStart = day }
                allocations[day, default: []].append(Allocation(taskID: pick.task.id, minutes: take))
                if pick.left == 0 {
                    pick.plannedEnd = day
                    let next = pick.index + 1
                    if let path = paths.first(where: { $0.contains { $0 === pick } }), next < path.count {
                        path[next].readyFrom = pick.lead > 0 ? shift(day, pick.lead + 1) : day
                    }
                }
            }
            day = shift(day, 1)
        }

        // ── Target dates, lateness, states ───────────────────────────────────
        var steps: [UUID: PlanStep] = [:]
        var statuses: [UUID: TargetStatus] = [:]
        var raised: [Decision] = []

        for path in paths {
            var lateIDs: [UUID] = []
            var remaining = 0
            for node in path {
                remaining += node.task.plannedEffort
                let buffer = max(1, Int((Double(node.task.plannedEffort) / 240.0).rounded(.up)))
                var targetDate: Date?
                var late = false
                if let pe = node.plannedEnd {
                    if let wall = node.wall {
                        targetDate = min(wall, shift(pe, buffer))
                        late = pe > wall
                    } else {
                        targetDate = pe
                    }
                } else {
                    late = node.wall != nil      // never fit inside the horizon
                }
                if late { lateIDs.append(node.task.id) }
                steps[node.task.id] = PlanStep(
                    taskID: node.task.id, targetID: node.target?.id, index: node.index,
                    wall: node.wall, latestStart: node.latestStart,
                    plannedStart: node.plannedStart, plannedEnd: node.plannedEnd,
                    targetDate: targetDate, late: late, minutesLeft: node.left)
            }
            guard let target = path.first?.target, let last = path.last else { continue }
            var slack: Int?
            if let pe = last.plannedEnd, let wall = last.wall {
                slack = cal.dateComponents([.day], from: pe, to: wall).day
            }
            let state: TargetState
            switch target.kind {
            case .hard:
                state = !lateIDs.isEmpty ? .willMiss : ((slack ?? 99) < 2 ? .atRisk : .onTrack)
            case .goal:
                state = !lateIDs.isEmpty ? .slipping : .onTrack
            case .none:
                state = .backlog
            }
            statuses[target.id] = TargetStatus(targetID: target.id, state: state, slackDays: slack,
                                               lateTaskIDs: lateIDs, remainingMinutes: remaining)
            if state == .willMiss, let firstLate = path.first(where: { lateIDs.contains($0.task.id) }) {
                let f = DateFormatter(); f.calendar = cal; f.dateFormat = "EEE MMM d"
                let dueText = target.due.map { f.string(from: $0) } ?? "its date"
                raised.append(Decision(
                    code: "E-\(target.id.uuidString.prefix(4))", projectID: target.projectID, targetID: target.id,
                    question: "\u{201C}\(target.title)\u{201D} can\u{2019}t be finished by \(dueText) at current capacity. What gives?",
                    whyNow: "\(firstLate.task.text) lands on \(firstLate.plannedEnd.map { f.string(from: $0) } ?? "never") but had to finish by \(firstLate.wall.map { f.string(from: $0) } ?? "?").",
                    background: "Hard deadline; the engine never moves it. Everything due earlier was placed first (earliest deadline first).",
                    touches: "This target and whatever you choose to move.",
                    options: [
                        DecisionOption(label: "Add hours", does: "Raise capacity on named days; the plan re-runs."),
                        DecisionOption(label: "Move a goal out", does: "Pushes a goal target\u{2019}s steps after this one."),
                        DecisionOption(label: "Shrink the scope", does: "Cut or shorten steps."),
                    ],
                    ifUnanswered: "It stays red; the step named above runs late.",
                    raisedBy: "engine"))
            }
        }
        for t in input.targets where t.done {
            statuses[t.id] = TargetStatus(targetID: t.id, state: .done, slackDays: nil, lateTaskIDs: [], remainingMinutes: 0)
        }
        for t in openTargets where statuses[t.id] == nil {
            // a target with no open steps yet: on track if its date is ahead, else at risk of being forgotten
            let due = t.due.map { cal.startOfDay(for: $0) }
            let slack = due.map { cal.dateComponents([.day], from: today, to: $0).day ?? 0 }
            let state: TargetState = t.kind == .none ? .backlog : ((slack ?? 99) < 2 ? .atRisk : .onTrack)
            statuses[t.id] = TargetStatus(targetID: t.id, state: state, slackDays: slack, lateTaskIDs: [], remainingMinutes: 0)
        }

        return PlanAssessment(computedAt: .now, today: today, steps: steps, targets: statuses,
                              allocations: allocations, raised: raised)
    }
}
