//
//  MacStore.swift
//  FrictionlessMac
//
//  The Mac's ledger: a JSON file in Application Support (until the hub lands),
//  re-planned by the shared engine on every change, re-read when something
//  else writes the file. The same verbs the phone has, so the two surfaces
//  stay interchangeable.
//

import Foundation
import Observation
import PlanCore

@MainActor
@Observable
final class MacStore {
    var ledger: Ledger
    var assessment: PlanAssessment = .empty
    var lastSaved: Date?
    var loadError: String?

    let url: URL
    private var watcher: DispatchSourceFileSystemObject?

    init(url: URL = LedgerFile.defaultURL()) {
        self.url = url
        if let loaded = LedgerFile.load(from: url) {
            ledger = loaded
        } else {
            ledger = .empty
        }
        ensureAreas()
        replan()
        watch()
    }

    /// Older ledgers have no areas: give them the defaults and file the known
    /// seed projects by name. Everything else stays unfiled until the owner moves it.
    private func ensureAreas() {
        guard ledger.areas.isEmpty else { return }
        ledger.areas = Area.defaults
        func area(_ name: String) -> UUID? { ledger.areas.first { $0.name == name }?.id }
        let byName: [String: String] = ["Modeling class": "Learning", "D&I course": "Learning",
                                        "Review manuscript": "Research", "ASH 2026": "Research",
                                        "HOSTing": "Teaching & service"]
        for i in ledger.projects.indices where ledger.projects[i].areaID == nil {
            if let a = byName[ledger.projects[i].name] { ledger.projects[i].areaID = area(a) }
        }
        try? LedgerFile.save(ledger, to: url)
    }

    // MARK: Plan

    func replan() {
        let input = PlanEngine.Input(today: .now, capacity: ledger.capacity,
                                     targets: ledger.targets, tasks: ledger.tasks)
        let result = PlanEngine.plan(input)
        assessment = result
        mergeEngineDecisions(result.raised)
    }

    private func mergeEngineDecisions(_ raised: [Decision]) {
        let raisedTargets = Set(raised.compactMap(\.targetID))
        ledger.decisions.removeAll { d in
            d.raisedBy == "engine" && !d.isAnswered && !(d.targetID.map { raisedTargets.contains($0) } ?? false)
        }
        for d in raised where !ledger.decisions.contains(where: { $0.raisedBy == "engine" && $0.targetID == d.targetID && !$0.isAnswered }) {
            ledger.decisions.insert(d, at: 0)
        }
    }

    /// Every mutation ends here: re-plan, then write the file whole.
    func commit() {
        replan()
        do {
            try LedgerFile.save(ledger, to: url)
            lastSaved = .now
        } catch {
            loadError = "couldn't save: \(error.localizedDescription)"
        }
    }

    // MARK: Queries

    var openTargets: [Target] { ledger.targets.filter { !$0.done } }
    var hardTargetsByDue: [Target] {
        openTargets.filter { $0.kind == .hard && $0.due != nil }.sorted { $0.due! < $1.due! }
    }
    var atRiskTargets: [Target] {
        openTargets.filter { [.atRisk, .willMiss, .slipping].contains(status(of: $0.id)?.state) }
            .sorted { (status(of: $0.id)?.state.severity ?? 9) < (status(of: $1.id)?.state.severity ?? 9) }
    }
    var openDecisions: [Decision] {
        ledger.decisions.filter { $0.isOpen() }.sorted { a, b in
            if (a.raisedBy == "engine") != (b.raisedBy == "engine") { return a.raisedBy == "engine" }
            return a.askedAt > b.askedAt
        }
    }
    var deferredDecisions: [Decision] { ledger.decisions.filter { $0.isDeferred() } }
    var hasWillMiss: Bool { openTargets.contains { status(of: $0.id)?.state == .willMiss } }

    func status(of targetID: UUID) -> TargetStatus? { assessment.status(of: targetID) }
    func step(of taskID: UUID) -> PlanStep? { assessment.step(of: taskID) }
    func target(_ id: UUID?) -> Target? { id.flatMap { tid in ledger.targets.first { $0.id == tid } } }
    func project(_ id: UUID?) -> Project? { ledger.project(id) }
    func task(_ id: UUID) -> ListItem? { ledger.tasks.first { $0.id == id } }
    func tasks(for targetID: UUID) -> [ListItem] { ledger.tasks(for: targetID) }
    func targets(in projectID: UUID?) -> [Target] {
        openTargets.filter { $0.projectID == projectID }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    /// Allocations on a day as (task, minutes).
    func work(on day: Date) -> [(task: ListItem, minutes: Int)] {
        let start = Calendar.current.startOfDay(for: day)
        return (assessment.allocations[start] ?? []).compactMap { a in
            guard let t = task(a.taskID) else { return nil }
            return (t, a.minutes)
        }
    }
    var todaysWork: [(task: ListItem, minutes: Int)] { work(on: .now) }

    func capacity(on day: Date) -> Int { ledger.capacity.minutes(on: day, calendar: .current) }
    func committed(on day: Date) -> Int { assessment.committedMinutes(on: Calendar.current.startOfDay(for: day)) }

    /// Minutes the plan placed on a day for hard-deadline work — the part that
    /// isn't negotiable. Goal and backlog work is "flexible" and can yield.
    func committedHard(on day: Date) -> Int {
        let start = Calendar.current.startOfDay(for: day)
        return (assessment.allocations[start] ?? []).reduce(0) { sum, a in
            let kind = task(a.taskID).flatMap { t in target(t.targetID)?.kind ?? t.dueKind } ?? .none
            return sum + (kind == .hard ? a.minutes : 0)
        }
    }
    func committedFlexible(on day: Date) -> Int { committed(on: day) - committedHard(on: day) }

    /// "Realistic free time": capacity minus what hard deadlines already claim.
    func free(on day: Date) -> Int { max(0, capacity(on: day) - committedHard(on: day)) }

    /// Open steps, most pressing first, that fit a number of free minutes —
    /// the "what do I really have time for" chooser (§8.4).
    func whatFits(minutes: Int) -> [ListItem] {
        let open = ledger.tasks.filter { !$0.done && $0.category == .todo }
        return open
            .filter { $0.plannedEffort <= max(minutes, 15) }
            .sorted { a, b in
                let sa = step(of: a.id), sb = step(of: b.id)
                let ka = target(a.targetID)?.kind ?? (a.dueKind ?? .none)
                let kb = target(b.targetID)?.kind ?? (b.dueKind ?? .none)
                if ka != kb { return rank(ka) < rank(kb) }
                return (sa?.wall ?? .distantFuture) < (sb?.wall ?? .distantFuture)
            }
    }
    private func rank(_ k: DeadlineKind) -> Int { k == .hard ? 0 : (k == .goal ? 1 : 2) }

    // MARK: Mutations

    func toggleDone(taskID: UUID) {
        guard let i = ledger.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        ledger.tasks[i].done.toggle()
        ledger.tasks[i].doneAt = ledger.tasks[i].done ? .now : nil
        ledger.tasks[i].state = ledger.tasks[i].done ? .done : .todo
        if let tid = ledger.tasks[i].targetID, let t = ledger.targets.firstIndex(where: { $0.id == tid }) {
            let open = ledger.tasks.filter { $0.targetID == tid && !$0.done }
            ledger.targets[t].done = open.isEmpty
            ledger.targets[t].doneAt = open.isEmpty ? .now : nil
        }
        commit()
    }

    func answer(decisionID: UUID, option: DecisionOption) {
        guard let i = ledger.decisions.firstIndex(where: { $0.id == decisionID }) else { return }
        ledger.decisions[i].answeredAt = .now
        ledger.decisions[i].answer = option.label
        ledger.decisions[i].deferredUntil = nil
        commit()
    }

    func deferDecision(decisionID: UUID, days: Int = 3) {
        guard let i = ledger.decisions.firstIndex(where: { $0.id == decisionID }) else { return }
        ledger.decisions[i].deferredUntil = Calendar.current.date(byAdding: .day, value: days, to: .now)
        commit()
    }

    func projectID(named name: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = ledger.projects.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) { return p.id }
        let p = Project(name: trimmed, colourHex: Project.palette[ledger.projects.count % Project.palette.count])
        ledger.projects.append(p)
        return p.id
    }

    @discardableResult
    func addTarget(title: String, due: Date?, kind: DeadlineKind, projectName: String?, why: String?, effortMinutes: Int?) -> Target {
        var pid: UUID? = nil
        if let projectName, !projectName.trimmingCharacters(in: .whitespaces).isEmpty { pid = projectID(named: projectName) }
        let target = Target(projectID: pid, title: title, due: due.map { Calendar.current.startOfDay(for: $0) },
                            kind: due == nil ? .none : kind, whyItMatters: why)
        ledger.targets.insert(target, at: 0)
        ledger.tasks.insert(ListItem(text: title, category: .todo, projectID: pid, targetID: target.id,
                                     pathOrder: 0, effortMinutes: effortMinutes), at: 0)
        commit()
        return target
    }

    func addStep(to targetID: UUID, text: String, effortMinutes: Int?, milestone: Bool) {
        guard let t = target(targetID) else { return }
        let order = (tasks(for: targetID).map(\.pathOrder).max() ?? -1) + 1
        ledger.tasks.append(ListItem(text: text, category: .todo, projectID: t.projectID, targetID: targetID,
                                     pathOrder: order, effortMinutes: effortMinutes, milestone: milestone))
        commit()
    }

    func setEffort(taskID: UUID, minutes: Int?) {
        guard let i = ledger.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        ledger.tasks[i].effortMinutes = minutes
        commit()
    }

    func setDue(targetID: UUID, to due: Date?, kind: DeadlineKind) {
        guard let i = ledger.targets.firstIndex(where: { $0.id == targetID }) else { return }
        ledger.targets[i].due = due.map { Calendar.current.startOfDay(for: $0) }
        ledger.targets[i].kind = due == nil ? .none : kind
        commit()
    }

    func markTargetDone(_ targetID: UUID) {
        guard let i = ledger.targets.firstIndex(where: { $0.id == targetID }) else { return }
        ledger.targets[i].done = true
        ledger.targets[i].doneAt = .now
        for j in ledger.tasks.indices where ledger.tasks[j].targetID == targetID && !ledger.tasks[j].done {
            ledger.tasks[j].done = true; ledger.tasks[j].doneAt = .now; ledger.tasks[j].state = .done
        }
        commit()
    }

    func setCapacity(_ c: CapacityModel) {
        ledger.capacity = c
        commit()
    }

    func addIdea(_ text: String, projectID: UUID?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        ledger.ideas.insert(Idea(projectID: projectID, text: t), at: 0)
        commit()
    }

    // MARK: Portfolio (v4.1)

    var areasInOrder: [Area] { ledger.areas.sorted { $0.order < $1.order } }
    func projects(in areaID: UUID?) -> [Project] {
        ledger.projects.filter { $0.areaID == areaID && !$0.archived && $0.status != .done }
            .sorted { (health($0).severity, $0.name) < (health($1).severity, $1.name) }
    }
    func area(_ id: UUID?) -> Area? { ledger.area(id) }

    /// A project's health is its worst open target; a project with nothing dated is "backlog".
    func health(_ project: Project) -> TargetState {
        let states = targets(in: project.id).compactMap { status(of: $0.id)?.state }
        return states.min { $0.severity < $1.severity } ?? .backlog
    }

    /// The next milestone (or next step) across the project's targets, with the date the engine chose.
    func nextMilestone(_ project: Project) -> (task: ListItem, date: Date?)? {
        let candidates = ledger.tasks.filter { $0.projectID == project.id && !$0.done }
            .compactMap { t -> (ListItem, Date?)? in
                let d = step(of: t.id)?.targetDate
                return (t, d)
            }
        let milestones = candidates.filter { $0.0.milestone }
        let pool = milestones.isEmpty ? candidates : milestones
        return pool.min { ($0.1 ?? .distantFuture) < ($1.1 ?? .distantFuture) }
    }

    func lastTouched(_ project: Project) -> Date? {
        ledger.tasks.filter { $0.projectID == project.id }.compactMap(\.doneAt).max()
    }

    func remainingMinutes(_ project: Project) -> Int {
        ledger.tasks.filter { $0.projectID == project.id && !$0.done }.reduce(0) { $0 + $1.plannedEffort }
    }

    /// Minutes the plan places for an area in [from, to).
    func plannedMinutes(area areaID: UUID?, from: Date, to: Date) -> Int {
        let cal = Calendar.current
        var day = cal.startOfDay(for: from), total = 0
        while day < to {
            for a in assessment.allocations[day] ?? [] {
                if let t = task(a.taskID), ledger.project(t.projectID)?.areaID == areaID { total += a.minutes }
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return total
    }

    func capacityMinutes(from: Date, to: Date) -> Int {
        let cal = Calendar.current
        var day = cal.startOfDay(for: from), total = 0
        while day < to { total += capacity(on: day); day = cal.date(byAdding: .day, value: 1, to: day)! }
        return total
    }

    /// Milestones for the roadmap: every open milestone (or last step) with its target date.
    func roadmapItems() -> [(project: Project, task: ListItem, date: Date, late: Bool)] {
        ledger.tasks.filter { !$0.done }.compactMap { t in
            guard let p = ledger.project(t.projectID), let s = step(of: t.id), let d = s.targetDate else { return nil }
            let isLast = tasks(for: t.targetID ?? UUID()).last?.id == t.id
            guard t.milestone || isLast else { return nil }
            return (p, t, d, s.late)
        }
        .sorted { $0.date < $1.date }
    }

    struct Impact: Identifiable {
        let id = UUID()
        let title: String
        let before: TargetState
        let after: TargetState
        let slackBefore: Int?
        let slackAfter: Int?
        var worse: Bool { after.severity < before.severity || (slackAfter ?? 99) < (slackBefore ?? 99) }
    }

    /// Intake: what taking this on would do to everything already committed.
    func previewImpact(title: String, due: Date?, kind: DeadlineKind, effortMinutes: Int?) -> (impacts: [Impact], fits: Bool, newState: TargetState?) {
        let t = Target(title: title.isEmpty ? "New commitment" : title, due: due.map { Calendar.current.startOfDay(for: $0) }, kind: due == nil ? .none : kind)
        let step = ListItem(text: t.title, category: .todo, targetID: t.id, pathOrder: 0, effortMinutes: effortMinutes)
        let after = PlanEngine.plan(PlanEngine.Input(today: .now, capacity: ledger.capacity,
                                                     targets: ledger.targets + [t], tasks: ledger.tasks + [step]))
        var impacts: [Impact] = []
        for existing in openTargets {
            let b = assessment.targets[existing.id], a = after.targets[existing.id]
            guard let b, let a else { continue }
            let imp = Impact(title: existing.title, before: b.state, after: a.state, slackBefore: b.slackDays, slackAfter: a.slackDays)
            if imp.worse { impacts.append(imp) }
        }
        let mine = after.targets[t.id]
        return (impacts, mine.map { $0.state != .willMiss } ?? true, mine?.state)
    }

    func setProjectArea(_ projectID: UUID, areaID: UUID?) {
        guard let i = ledger.projects.firstIndex(where: { $0.id == projectID }) else { return }
        ledger.projects[i].areaID = areaID
        commit()
    }

    func setProjectHorizon(_ projectID: UUID, horizon: Horizon) {
        guard let i = ledger.projects.firstIndex(where: { $0.id == projectID }) else { return }
        ledger.projects[i].horizon = horizon
        commit()
    }

    func setProjectNarrative(_ projectID: UUID, _ text: String) {
        guard let i = ledger.projects.firstIndex(where: { $0.id == projectID }) else { return }
        ledger.projects[i].narrative = text.isEmpty ? nil : text
        commit()
    }

    // MARK: Seed

    var demoSeedLoaded: Bool { ledger.targets.contains { $0.title.hasPrefix("HOSTing presentation") } }

    func importDemoSeed() {
        guard !demoSeedLoaded,
              let url = Bundle.module.url(forResource: "DemoSeed", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let seed = try? SeedImporter.parse(data) else { return }
        ledger.merge(seed, replaceCapacity: ledger.targets.isEmpty)
        commit()
    }

    // MARK: File watching (another writer — the phone via the hub, later)

    private func watch() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if let loaded = LedgerFile.load(from: self.url), loaded != self.ledger {
                self.ledger = loaded
                self.replan()
            }
            // A rename/replace invalidates the descriptor; re-arm.
            source.cancel()
            self.watch()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }
}

enum MacFormat {
    static func day(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
    static func minutes(_ m: Int) -> String {
        let h = m / 60, r = m % 60
        if h == 0 { return "\(r) min" }
        return r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }
    static func slack(_ d: Int?) -> String {
        guard let d else { return "" }
        return d < 0 ? "\(-d) d late" : "\(d) d slack"
    }
}
