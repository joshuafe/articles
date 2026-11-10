//
//  SeedImporterTests.swift
//  PlanCoreTests
//
//  The prototype seed (pm-prototype/seed.json) round-trips into a Ledger and
//  the engine schedules it the way the Python prototype did.
//

import Testing
import Foundation
@testable import PlanCore

struct SeedImporterTests {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private var seedURL: URL {
        // PlanCore/Tests/PlanCoreTests/SeedImporterTests.swift → ../../../../pm-prototype/seed.json
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("pm-prototype/seed.json")
    }

    @Test func seedParsesIntoALedger() throws {
        let data = try Data(contentsOf: seedURL)
        let ledger = try SeedImporter.parse(data, calendar: cal, now: day(2026, 11, 8))

        #expect(ledger.projects.count == 5)
        #expect(ledger.targets.count == 8)
        #expect(ledger.tasks.count == 27)
        #expect(ledger.decisions.count == 4)
        #expect(ledger.capacity.minutesByWeekday == [120, 120, 120, 120, 120, 300, 300])

        let manuscript = try #require(ledger.targets.first { $0.title.hasPrefix("Submit the review manuscript") })
        #expect(manuscript.kind == .hard)
        #expect(manuscript.due == day(2026, 12, 15))
        let steps = ledger.tasks(for: manuscript.id)
        #expect(steps.map(\.text).first == "Complete the full draft")
        #expect(steps[1].leadDays == 10)
        #expect(steps[1].dueDate == day(2026, 12, 1))
        #expect(steps[1].dueKind == .hard)

        let overdue = try #require(ledger.targets.first { $0.title.hasPrefix("Overdue back assignments") })
        #expect(overdue.kind == .hard)      // D3: cutoff Friday Nov 13

        let d1 = try #require(ledger.decisions.first { $0.code == "D1" })
        #expect(d1.isAnswered)
        #expect(d1.targetID != nil)
    }

    @Test func engineSchedulesTheSeedLikeThePrototype() throws {
        let data = try Data(contentsOf: seedURL)
        let ledger = try SeedImporter.parse(data, calendar: cal, now: day(2026, 11, 8))
        let a = PlanEngine.plan(PlanEngine.Input(today: day(2026, 11, 8), calendar: cal,
                                                 capacity: ledger.capacity, targets: ledger.targets, tasks: ledger.tasks))

        // Today (Sun Nov 8, 300 min) opens with the presentation, as in schedule.md.
        let first = try #require(a.todaysCut.first)
        let firstTask = try #require(ledger.tasks.first { $0.id == first.taskID })
        #expect(firstTask.text == "Finalize the slides")
        #expect(a.committedMinutes(on: day(2026, 11, 8)) == 300)

        // The reader deadline pulls the draft's wall to Nov 21.
        let manuscript = try #require(ledger.targets.first { $0.title.hasPrefix("Submit the review manuscript") })
        let draft = ledger.tasks(for: manuscript.id)[0]
        #expect(a.steps[draft.id]?.wall == day(2026, 11, 21))

        // Nothing is unreachable at this capacity; three hard targets are tight.
        #expect(a.raised.isEmpty)
        let tight = ledger.targets.filter { a.targets[$0.id]?.state == .atRisk }
        #expect(tight.count == 3)
    }

    @Test func ledgerFileRoundTrips() throws {
        let data = try Data(contentsOf: seedURL)
        let ledger = try SeedImporter.parse(data, calendar: cal, now: day(2026, 11, 8))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plancore-test-\(UUID().uuidString).json")
        try LedgerFile.save(ledger, to: url)
        let back = try #require(LedgerFile.load(from: url))
        // ISO-8601 drops sub-second precision, so compare content, not timestamps.
        #expect(back.projects.map(\.id) == ledger.projects.map(\.id))
        #expect(back.targets.map { ($0.id, $0.title, $0.due, $0.kind) }.elementsEqual(
            ledger.targets.map { ($0.id, $0.title, $0.due, $0.kind) }, by: { $0 == $1 }))
        #expect(back.tasks.map(\.id) == ledger.tasks.map(\.id))
        #expect(back.tasks.map(\.effortMinutes) == ledger.tasks.map(\.effortMinutes))
        #expect(back.decisions.map(\.code) == ledger.decisions.map(\.code))
        #expect(back.capacity == ledger.capacity)
        try? FileManager.default.removeItem(at: url)
    }
}
