//
//  PlanEngineTests.swift
//  PlanCoreTests
//
//  The urgency engine on dates — DESIGN-PM.md §6.1. Mirrors pm-prototype/engine.py.
//

import Testing
import Foundation
@testable import PlanCore

struct PlanEngineTests {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// Sunday Nov 8 2026 — the seed's "today".
    private var today: Date { day(2026, 11, 8) }

    private func input(targets: [Target], tasks: [ListItem],
                       capacity: CapacityModel = CapacityModel(minutesByWeekday: [120, 120, 120, 120, 120, 300, 300])) -> PlanEngine.Input {
        PlanEngine.Input(today: today, calendar: cal, capacity: capacity, targets: targets, tasks: tasks)
    }

    private func step(_ text: String, _ effort: Int, target: UUID, order: Int,
                      lead: Int = 0, milestone: Bool = false, due: Date? = nil, dueKind: DeadlineKind? = nil) -> ListItem {
        ListItem(text: text, category: .todo, targetID: target, pathOrder: order,
                 effortMinutes: effort, leadDays: lead, milestone: milestone, dueDate: due, dueKind: dueKind)
    }

    @Test func wallsWalkBackFromTheDeadline() {
        // 600 minutes of draft at 120/weekday, must finish by Nov 21 (Sat, 300): wall for the draft is Nov 21,
        // its latest start walks back over Nov 21(300), 20(120), 19(120), 18(120) → Nov 18.
        let t = Target(title: "Manuscript", due: day(2026, 12, 15), kind: .hard)
        let draft = step("Complete the draft", 600, target: t.id, order: 0, milestone: true)
        let send = step("Send to readers", 30, target: t.id, order: 1, lead: 10, due: day(2026, 12, 1), dueKind: .hard)
        let incorporate = step("Incorporate comments", 240, target: t.id, order: 2)
        let a = PlanEngine.plan(input(targets: [t], tasks: [draft, send, incorporate]))

        #expect(a.steps[send.id]?.wall == day(2026, 12, 1))          // its own hard date caps the wall
        #expect(a.steps[draft.id]?.wall == day(2026, 11, 21))        // 10 days of lead before Dec 1, then the send's 30 min on Dec 1
        #expect(a.steps[draft.id]?.latestStart == day(2026, 11, 18))
        #expect(a.steps[incorporate.id]?.wall == day(2026, 12, 15))
    }

    @Test func hardDeadlinesOutrankGoalsToday() {
        let talk = Target(title: "Presentation", due: day(2026, 11, 9), kind: .hard)
        let slides = step("Finalize slides", 120, target: talk.id, order: 0)
        let overdue = Target(title: "Back assignments", due: day(2026, 11, 8), kind: .goal)
        let a1 = step("Assignment A", 90, target: overdue.id, order: 0)
        let cap = CapacityModel(minutesByWeekday: [150, 150, 150, 150, 150, 300, 300],
                                fixed: [FixedBlock(day: day(2026, 11, 9), minutes: 120, why: "the talk")])
        let a = PlanEngine.plan(input(targets: [talk, overdue], tasks: [slides, a1], capacity: cap))

        let todayIDs = a.todaysCut.map(\.taskID)
        #expect(todayIDs.first == slides.id)                          // the hard step that must start now goes first
        #expect(todayIDs.contains(a1.id))                             // the overdue goal fills what's left today
        #expect(a.targets[talk.id]?.state == .atRisk)                 // one day of slack
        #expect(a.steps[slides.id]?.plannedEnd == today)
    }

    @Test func aHardTargetThatCannotFitRaisesWhatGives() {
        let t = Target(title: "Impossible", due: day(2026, 11, 9), kind: .hard)
        let big = step("Twelve hours of work", 720, target: t.id, order: 0)
        let a = PlanEngine.plan(input(targets: [t], tasks: [big]))

        #expect(a.targets[t.id]?.state == .willMiss)
        #expect(a.steps[big.id]?.late == true)
        #expect(a.raised.count == 1)
        #expect(a.raised.first?.targetID == t.id)
        #expect(a.raised.first?.raisedBy == "engine")
    }

    @Test func goalsSlipInsteadOfMissing() {
        let g = Target(title: "Exam prep", due: day(2026, 11, 9), kind: .goal)
        let big = step("Review everything", 720, target: g.id, order: 0)
        let a = PlanEngine.plan(input(targets: [g], tasks: [big]))

        #expect(a.targets[g.id]?.state == .slipping)
        #expect(a.raised.isEmpty)                                     // goals never raise the red card
    }

    @Test func leadDaysDelayTheNextStep() {
        let t = Target(title: "Review", due: day(2026, 12, 15), kind: .hard)
        let send = step("Send", 30, target: t.id, order: 0, lead: 10)
        let after = step("After", 60, target: t.id, order: 1)
        let a = PlanEngine.plan(input(targets: [t], tasks: [send, after]))

        let sendEnd = a.steps[send.id]!.plannedEnd!
        let afterStart = a.steps[after.id]!.plannedStart!
        #expect(cal.dateComponents([.day], from: sendEnd, to: afterStart).day == 11)
    }

    @Test func targetDateNeverPassesTheWall() {
        let t = Target(title: "Midterm", due: day(2026, 11, 13), kind: .hard)
        let s1 = step("Model", 180, target: t.id, order: 0)
        let s2 = step("Write-up", 120, target: t.id, order: 1, milestone: true)
        let a = PlanEngine.plan(input(targets: [t], tasks: [s1, s2]))

        for s in [s1, s2] {
            let p = a.steps[s.id]!
            #expect(p.targetDate! <= p.wall!)
            #expect(p.targetDate! >= p.plannedEnd!)
        }
    }

    @Test func checkingOffRecomputesEverything() {
        let t = Target(title: "Midterm", due: day(2026, 11, 13), kind: .hard)
        var s1 = step("Model", 180, target: t.id, order: 0)
        let s2 = step("Write-up", 120, target: t.id, order: 1)
        let tight = CapacityModel(minutesByWeekday: [120, 120, 120, 120, 120, 100, 100])
        let before = PlanEngine.plan(input(targets: [t], tasks: [s1, s2], capacity: tight))
        s1.done = true
        let after = PlanEngine.plan(input(targets: [t], tasks: [s1, s2], capacity: tight))

        #expect(before.steps[s2.id]!.plannedStart! > after.steps[s2.id]!.plannedStart!)
        #expect(after.steps[s1.id] == nil)                            // done steps leave the plan
        #expect((after.targets[t.id]?.slackDays ?? 0) >= (before.targets[t.id]?.slackDays ?? 0))
    }

    @Test func capacityPatternIsMondayFirst() {
        let cap = CapacityModel(minutesByWeekday: [10, 20, 30, 40, 50, 60, 70])
        #expect(cap.minutes(on: day(2026, 11, 9), calendar: cal) == 10)   // Monday
        #expect(cap.minutes(on: day(2026, 11, 8), calendar: cal) == 70)   // Sunday
        #expect(cap.minutes(on: day(2026, 11, 14), calendar: cal) == 60)  // Saturday
    }
}
