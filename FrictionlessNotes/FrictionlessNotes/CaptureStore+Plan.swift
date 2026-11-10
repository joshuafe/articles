//
//  CaptureStore+Plan.swift
//  FrictionlessNotes
//
//  The project-manager layer on the store (DESIGN-PM.md): re-planning, targets,
//  decisions, ideas, capacity and the demo seed. The stored properties live in
//  CaptureStore.swift; everything here is derived from or mutates them, and
//  every mutation ends in schedulePersist(), which re-runs the engine.
//

import Foundation
import SwiftUI

extension CaptureStore {

    // MARK: Re-plan (Tier 0)

    /// Recompute the assessment from the live ledger. Cheap; called on every change.
    func replan() {
        let input = PlanEngine.Input(today: .now, calendar: .current, capacity: capacity,
                                     targets: targets, tasks: listItems)
        let result = PlanEngine.plan(input)
        assessment = result
        mergeEngineDecisions(result.raised)
    }

    /// Engine-raised "what gives?" cards: one open card per will-miss target,
    /// dropped again the moment the target is reachable.
    private func mergeEngineDecisions(_ raised: [Decision]) {
        let raisedTargets = Set(raised.compactMap(\.targetID))
        decisions.removeAll { d in
            d.raisedBy == "engine" && !d.isAnswered && !(d.targetID.map { raisedTargets.contains($0) } ?? false)
        }
        for d in raised {
            let exists = decisions.contains { $0.raisedBy == "engine" && $0.targetID == d.targetID && !$0.isAnswered }
            if !exists { decisions.insert(d, at: 0) }
        }
    }

    // MARK: Queries

    var openTargets: [Target] { targets.filter { !$0.done } }

    /// Hard targets by date — the Now strip's "Due" box.
    var hardTargetsByDue: [Target] {
        openTargets.filter { $0.kind == .hard && $0.due != nil }.sorted { $0.due! < $1.due! }
    }

    /// Anything at risk, slipping or will-miss, worst first.
    var atRiskTargets: [Target] {
        openTargets
            .filter { [.atRisk, .willMiss, .slipping].contains(status(of: $0.id)?.state) }
            .sorted { (status(of: $0.id)?.state.severity ?? 9) < (status(of: $1.id)?.state.severity ?? 9) }
    }

    func status(of targetID: UUID) -> TargetStatus? { assessment.status(of: targetID) }
    func step(of taskID: UUID) -> PlanStep? { assessment.step(of: taskID) }

    func tasks(for targetID: UUID) -> [ListItem] {
        listItems.filter { $0.targetID == targetID }
            .sorted { ($0.pathOrder, $0.createdAt) < ($1.pathOrder, $1.createdAt) }
    }

    func target(_ id: UUID?) -> Target? {
        guard let id else { return nil }
        return targets.first { $0.id == id }
    }

    func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func targets(in projectID: UUID?) -> [Target] {
        openTargets.filter { $0.projectID == projectID }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    /// Today's cut: the engine's allocations for today, as (task, minutes).
    var todaysWork: [(task: ListItem, minutes: Int)] {
        assessment.todaysCut.compactMap { a in
            guard let task = listItems.first(where: { $0.id == a.taskID }) else { return nil }
            return (task, a.minutes)
        }
    }

    /// Decision cards still waiting: engine first, then newest.
    var openDecisions: [Decision] {
        decisions.filter { $0.isOpen() }
            .sorted { a, b in
                if (a.raisedBy == "engine") != (b.raisedBy == "engine") { return a.raisedBy == "engine" }
                return a.askedAt > b.askedAt
            }
    }

    var deferredDecisions: [Decision] { decisions.filter { $0.isDeferred() } }

    /// The Now whisper on Home: "2 hard this week · 1 at risk · 4 today".
    var nowWhisper: String? {
        guard !openTargets.isEmpty else { return nil }
        let cal = Calendar.current
        let weekEnd = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: .now))!
        let hardThisWeek = hardTargetsByDue.filter { $0.due! < weekEnd }.count
        var parts: [String] = []
        if hardThisWeek > 0 { parts.append("\(hardThisWeek) hard this week") }
        let risk = atRiskTargets.count
        if risk > 0 { parts.append("\(risk) at risk") }
        let today = todaysWork.filter { !$0.task.done }.count
        if today > 0 { parts.append("\(today) today") }
        let forYou = openDecisions.count
        if forYou > 0 { parts.append("\(forYou) for you") }
        return parts.isEmpty ? "program" : parts.joined(separator: " \u{00B7} ")
    }

    var hasWillMiss: Bool { openTargets.contains { status(of: $0.id)?.state == .willMiss } }

    // MARK: Mutations

    /// Find a project by name (case-insensitive) or create it with the next palette colour.
    func projectID(named name: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = projects.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return p.id
        }
        let project = Project(name: trimmed, colourHex: Project.palette[projects.count % Project.palette.count])
        projects.append(project)
        return project.id
    }

    @discardableResult
    func addTarget(title: String, due: Date?, kind: DeadlineKind, projectName: String? = nil,
                   why: String? = nil, effortMinutes: Int? = nil, sourceCaptureID: UUID? = nil) -> Target {
        var projectID: UUID? = nil
        if let projectName { projectID = self.projectID(named: projectName) }
        let target = Target(projectID: projectID, title: title, due: due.map { Calendar.current.startOfDay(for: $0) },
                            kind: kind, whyItMatters: why, sourceCaptureID: sourceCaptureID)
        targets.insert(target, at: 0)
        // One-step path until the planner (or Joshua) decomposes it.
        listItems.insert(ListItem(text: title, category: .todo, sourceCaptureID: sourceCaptureID,
                                  projectID: projectID, targetID: target.id, pathOrder: 0,
                                  effortMinutes: effortMinutes), at: 0)
        schedulePersist()
        return target
    }

    func addStep(to targetID: UUID, text: String, effortMinutes: Int?, milestone: Bool = false, needsYou: Bool = false) {
        guard let target = target(targetID) else { return }
        let order = (tasks(for: targetID).map(\.pathOrder).max() ?? -1) + 1
        listItems.append(ListItem(text: text, category: .todo, projectID: target.projectID,
                                  targetID: targetID, pathOrder: order, effortMinutes: effortMinutes,
                                  milestone: milestone, needsYou: needsYou))
        schedulePersist()
    }

    func setDue(targetID: UUID, to due: Date?, kind: DeadlineKind) {
        guard let i = targets.firstIndex(where: { $0.id == targetID }) else { return }
        targets[i].due = due.map { Calendar.current.startOfDay(for: $0) }
        targets[i].kind = due == nil ? .none : kind
        schedulePersist()
    }

    func setEffort(taskID: UUID, minutes: Int?) {
        guard let i = listItems.firstIndex(where: { $0.id == taskID }) else { return }
        listItems[i].effortMinutes = minutes
        schedulePersist()
    }

    func markTargetDone(_ targetID: UUID) {
        guard let i = targets.firstIndex(where: { $0.id == targetID }) else { return }
        targets[i].done = true
        targets[i].doneAt = .now
        for j in listItems.indices where listItems[j].targetID == targetID && !listItems[j].done {
            listItems[j].done = true
            listItems[j].doneAt = .now
            listItems[j].state = .done
        }
        Haptics.checkOff()
        schedulePersist()
    }

    func answer(decisionID: UUID, option: DecisionOption) {
        guard let i = decisions.firstIndex(where: { $0.id == decisionID }) else { return }
        decisions[i].answeredAt = .now
        decisions[i].answer = option.label
        decisions[i].deferredUntil = nil
        Haptics.checkOff()
        schedulePersist()
    }

    func deferDecision(decisionID: UUID, days: Int = 3) {
        guard let i = decisions.firstIndex(where: { $0.id == decisionID }) else { return }
        decisions[i].deferredUntil = Calendar.current.date(byAdding: .day, value: days, to: .now)
        schedulePersist()
    }

    func addIdea(_ text: String, projectID: UUID? = nil, sourceCaptureID: UUID? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ideas.insert(Idea(projectID: projectID, text: trimmed, sourceCaptureID: sourceCaptureID), at: 0)
        schedulePersist()
    }

    func setCapacity(_ model: CapacityModel) {
        capacity = model
        schedulePersist()
    }

    // MARK: Capacity persistence (UserDefaults — small, local, not synced yet)

    private static let capacityKey = "pm.capacity.v1"

    func loadCapacity() {
        guard let data = UserDefaults.standard.data(forKey: Self.capacityKey),
              let model = try? JSONDecoder().decode(CapacityModel.self, from: data) else { return }
        capacity = model
    }

    func saveCapacity() {
        if let data = try? JSONEncoder().encode(capacity) {
            UserDefaults.standard.set(data, forKey: Self.capacityKey)
        }
    }

    // MARK: Demo seed (pm-prototype/seed.json, bundled as DemoSeed.json)

    var demoSeedLoaded: Bool { targets.contains { $0.title.hasPrefix("HOSTing presentation") } }

    /// Load Joshua's November objectives so the Program surface has something
    /// real to show. Idempotent: a second tap does nothing.
    func importDemoSeed() {
        guard !demoSeedLoaded,
              let url = Bundle.main.url(forResource: "DemoSeed", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let seed = try? SeedImporter.parse(data) else { return }
        projects.append(contentsOf: seed.projects)
        targets.insert(contentsOf: seed.targets, at: 0)
        listItems.insert(contentsOf: seed.tasks, at: 0)
        decisions.insert(contentsOf: seed.decisions, at: 0)
        capacity = seed.capacity
        Haptics.filed()
        schedulePersist()
    }
}
