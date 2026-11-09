//
//  Ledger.swift
//  PlanCore
//
//  The whole project-manager state as one value, plus a JSON file store (the
//  Mac app's storage until the hub lands) and the seed importer that reads
//  pm-prototype/seed.json. The iPhone app keeps SwiftData and uses only the
//  importer; both ends agree on these types.
//

import Foundation

public struct Ledger: Equatable, Codable, Sendable {
    public var areas: [Area]
    public var projects: [Project]
    public var targets: [Target]
    public var tasks: [ListItem]
    public var decisions: [Decision]
    public var ideas: [Idea]
    public var capacity: CapacityModel

    public init(areas: [Area] = [], projects: [Project] = [], targets: [Target] = [], tasks: [ListItem] = [],
                decisions: [Decision] = [], ideas: [Idea] = [], capacity: CapacityModel = .interim) {
        self.areas = areas
        self.projects = projects
        self.targets = targets
        self.tasks = tasks
        self.decisions = decisions
        self.ideas = ideas
        self.capacity = capacity
    }

    private enum CodingKeys: String, CodingKey { case areas, projects, targets, tasks, decisions, ideas, capacity }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        areas = try c.decodeIfPresent([Area].self, forKey: .areas) ?? []
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        targets = try c.decodeIfPresent([Target].self, forKey: .targets) ?? []
        tasks = try c.decodeIfPresent([ListItem].self, forKey: .tasks) ?? []
        decisions = try c.decodeIfPresent([Decision].self, forKey: .decisions) ?? []
        ideas = try c.decodeIfPresent([Idea].self, forKey: .ideas) ?? []
        capacity = try c.decodeIfPresent(CapacityModel.self, forKey: .capacity) ?? .interim
    }

    public func area(_ id: UUID?) -> Area? {
        guard let id else { return nil }
        return areas.first { $0.id == id }
    }

    public static let empty = Ledger()

    public func tasks(for targetID: UUID) -> [ListItem] {
        tasks.filter { $0.targetID == targetID }
            .sorted { ($0.pathOrder, $0.createdAt) < ($1.pathOrder, $1.createdAt) }
    }

    public func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    /// Append another ledger's content (used to merge a seed into live data).
    public mutating func merge(_ other: Ledger, replaceCapacity: Bool) {
        for a in other.areas where !areas.contains(where: { $0.name.caseInsensitiveCompare(a.name) == .orderedSame }) {
            areas.append(a)
        }
        projects.append(contentsOf: other.projects)
        targets.append(contentsOf: other.targets)
        tasks.append(contentsOf: other.tasks)
        decisions.append(contentsOf: other.decisions)
        ideas.append(contentsOf: other.ideas)
        if replaceCapacity { capacity = other.capacity }
    }
}

// MARK: - JSON file store

public enum LedgerFile {
    public static func defaultURL(appName: String = "FrictionlessNotes") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ledger.json")
    }

    public static func load(from url: URL) -> Ledger? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Ledger.self, from: data)
    }

    public static func save(_ ledger: Ledger, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ledger)
        // Write whole, then rename, so a reader never sees half a file.
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}

// MARK: - Seed importer (pm-prototype/seed.json)

public enum SeedImporter {
    public enum SeedError: Error { case malformed(String) }

    private static let colours: [String: UInt32] = [
        "blue": 0x5BA8FF, "teal": 0x6FD2E0, "purple": 0xC792F2, "orange": 0xF2A65A,
        "green": 0x4CD98A, "pink": 0xFF8FA3, "yellow": 0xFFD66B,
    ]

    /// Parse the prototype seed into a ledger. Dates become start-of-day in `calendar`.
    public static func parse(_ data: Data, calendar: Calendar = .current, now: Date = .now) throws -> Ledger {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SeedError.malformed("root is not an object")
        }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        func date(_ any: Any?) -> Date? {
            guard let s = any as? String, let d = f.date(from: String(s.prefix(10))) else { return nil }
            return calendar.startOfDay(for: d)
        }
        func kind(_ any: Any?) -> DeadlineKind { DeadlineKind(rawValue: (any as? String) ?? "") ?? .none }

        var ledger = Ledger()

        // Areas (optional in the seed; defaults otherwise)
        var areaIDs: [String: UUID] = [:]
        if let seedAreas = root["areas"] as? [[String: Any]], !seedAreas.isEmpty {
            for (i, a) in seedAreas.enumerated() {
                guard let code = a["id"] as? String, let name = a["name"] as? String else { continue }
                let hex = colours[(a["colour"] as? String ?? "").lowercased()] ?? Project.palette[i % Project.palette.count]
                let area = Area(name: name, colourHex: hex, intendedShare: (a["share"] as? Double) ?? 0.1, order: i)
                areaIDs[code] = area.id
                ledger.areas.append(area)
            }
        } else {
            ledger.areas = Area.defaults
        }

        // Projects
        var projectIDs: [String: UUID] = [:]
        for (i, p) in ((root["projects"] as? [[String: Any]]) ?? []).enumerated() {
            guard let code = p["id"] as? String, let name = p["name"] as? String else { continue }
            let hex = colours[(p["colour"] as? String ?? "").lowercased()] ?? Project.palette[i % Project.palette.count]
            let horizon = Horizon(rawValue: (p["horizon"] as? String) ?? "") ?? .month
            let project = Project(name: name, colourHex: hex, goal: p["goal"] as? String,
                                  areaID: areaIDs[p["area"] as? String ?? ""], horizon: horizon,
                                  narrative: p["narrative"] as? String,
                                  people: (p["people"] as? [String]) ?? [])
            projectIDs[code] = project.id
            ledger.projects.append(project)
        }

        // Targets and their steps
        var targetIDs: [String: UUID] = [:]
        for t in (root["targets"] as? [[String: Any]]) ?? [] {
            guard let code = t["id"] as? String, let title = t["title"] as? String else { continue }
            let target = Target(projectID: projectIDs[t["project"] as? String ?? ""], title: title,
                                due: date(t["due"]), kind: kind(t["kind"]), whyItMatters: t["why"] as? String)
            targetIDs[code] = target.id
            ledger.targets.append(target)
            for (order, s) in ((t["steps"] as? [[String: Any]]) ?? []).enumerated() {
                guard let text = s["text"] as? String else { continue }
                let item = ListItem(text: text, category: .todo, done: (s["done"] as? Bool) ?? false,
                                    projectID: target.projectID, targetID: target.id, pathOrder: order,
                                    effortMinutes: s["effort"] as? Int, leadDays: (s["lead_days"] as? Int) ?? 0,
                                    milestone: (s["milestone"] as? Bool) ?? false,
                                    needsYou: (s["needs_you"] as? Bool) ?? false,
                                    dueDate: date(s["due"]),
                                    dueKind: s["due_kind"] != nil ? kind(s["due_kind"]) : nil)
                ledger.tasks.append(item)
            }
        }

        // Decisions
        for d in (root["decisions"] as? [[String: Any]]) ?? [] {
            guard let code = d["id"] as? String, let question = d["question"] as? String else { continue }
            let options = ((d["options"] as? [[String: Any]]) ?? []).compactMap { o -> DecisionOption? in
                guard let label = o["label"] as? String else { return nil }
                return DecisionOption(label: label, does: (o["does"] as? String) ?? "")
            }
            let targetID = targetIDs[d["target"] as? String ?? ""]
            let projectID = targetID.flatMap { tid in ledger.targets.first { $0.id == tid }?.projectID }
            var decision = Decision(code: code, projectID: projectID, targetID: targetID, question: question,
                                    whyNow: (d["why_now"] as? String) ?? "", background: (d["background"] as? String) ?? "",
                                    touches: (d["touches"] as? String) ?? "", options: options,
                                    ifUnanswered: (d["if_unanswered"] as? String) ?? "", raisedBy: "user", askedAt: now)
            if let answered = d["answered"] as? String, !answered.isEmpty {
                decision.answeredAt = date(answered) ?? now
                decision.answer = d["answer"] as? String
            }
            ledger.decisions.append(decision)
        }

        // Capacity
        if let cap = root["capacity"] as? [String: Any] {
            var minutes = [120, 120, 120, 120, 120, 300, 300]
            if let wk = cap["weekday_minutes"] as? Int { for i in 0..<5 { minutes[i] = wk } }
            if let we = cap["weekend_minutes"] as? Int { minutes[5] = we; minutes[6] = we }
            if let pattern = cap["pattern"] as? [String: Any] {
                for (i, key) in ["mon", "tue", "wed", "thu", "fri", "sat", "sun"].enumerated() {
                    if let v = pattern[key] as? Int { minutes[i] = v }
                }
            }
            let fixed = ((cap["fixed"] as? [[String: Any]]) ?? []).compactMap { fb -> FixedBlock? in
                guard let day = date(fb["date"]), let m = fb["minutes"] as? Int else { return nil }
                return FixedBlock(day: day, minutes: m, why: (fb["why"] as? String) ?? "")
            }
            ledger.capacity = CapacityModel(minutesByWeekday: minutes, fixed: fixed)
        }
        return ledger
    }
}
