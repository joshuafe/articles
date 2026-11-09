//
//  PortfolioView.swift
//  FrictionlessMac
//
//  The life view (DESIGN-PM.md v4.1): areas with their projects as cards,
//  where time is going against where it was meant to go, and the roadmap of
//  milestones across the coming weeks. The Now strip is demoted to the menu
//  bar and its own page; this is the front door.
//

import SwiftUI
import PlanCore

struct PortfolioView: View {
    @Environment(MacStore.self) private var store
    @State private var selectedProject: UUID?

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(store.areasInOrder) { area in
                        AreaBlock(area: area, selected: $selectedProject)
                    }
                    let unfiled = store.projects(in: nil)
                    if !unfiled.isEmpty {
                        AreaBlock(area: nil, selected: $selectedProject)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let id = selectedProject, let p = store.ledger.project(id) {
                        ProjectDetailMac(project: p)
                        Divider()
                    }
                    BalanceView()
                    RoadmapView()
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Areas and project cards

struct AreaBlock: View {
    @Environment(MacStore.self) private var store
    let area: Area?
    @Binding var selected: UUID?

    var body: some View {
        let projects = store.projects(in: area?.id)
        let color = area.map { Color(hex: $0.colourHex) } ?? Color.secondary
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(area?.name ?? "Unfiled").font(.headline)
                if let area {
                    Text("\(Int((area.intendedShare * 100).rounded()))% intended").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(weekLine(for: area)).font(.caption).foregroundStyle(.secondary)
            }
            if projects.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "circle.dashed").foregroundStyle(.orange)
                    Text(area == nil ? "Nothing unfiled." : "Nothing here yet — no project carries this part of your life.")
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(projects) { p in
                        ProjectCard(project: p, color: color, isSelected: selected == p.id)
                            .onTapGesture { selected = p.id }
                    }
                }
            }
        }
    }

    private func weekLine(for area: Area?) -> String {
        let cal = Calendar.current
        let start = cal.startOfDay(for: .now)
        let end = cal.date(byAdding: .day, value: 7, to: start)!
        let planned = store.plannedMinutes(area: area?.id, from: start, to: end)
        return planned == 0 ? "nothing planned this week" : "\(MacFormat.minutes(planned)) planned this week"
    }
}

struct ProjectCard: View {
    @Environment(MacStore.self) private var store
    let project: Project
    let color: Color
    let isSelected: Bool

    var body: some View {
        let health = store.health(project)
        let next = store.nextMilestone(project)
        let touched = store.lastTouched(project)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(project.name).font(.headline).lineLimit(1)
                Spacer()
                StateDot(state: health)
            }
            if let goal = project.goal, !goal.isEmpty {
                Text(goal).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else if let n = project.narrative {
                Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let next {
                HStack(spacing: 4) {
                    Image(systemName: "flag").font(.caption2).foregroundStyle(.secondary)
                    Text(next.task.text).font(.caption).lineLimit(1)
                    Spacer()
                    Text(MacFormat.day(next.date)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            } else {
                Text("No next step").font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Text(health.label).font(.caption2).foregroundStyle(healthColor(health))
                Text("·").foregroundStyle(.secondary)
                Text(project.horizon.label).font(.caption2).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Text(MacFormat.minutes(store.remainingMinutes(project)) + " left").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(touched.map { "touched \($0.formatted(.relative(presentation: .named)))" } ?? "untouched")
                    .font(.caption2).foregroundStyle(touched == nil ? .orange : .secondary)
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? color : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 8) }
        .contentShape(Rectangle())
    }

    private func healthColor(_ s: TargetState) -> Color {
        switch s {
        case .onTrack, .done: .green
        case .atRisk, .slipping: .orange
        case .willMiss: .red
        case .backlog: .secondary
        }
    }
}

// MARK: - Project detail (narrative, area, horizon, its targets)

struct ProjectDetailMac: View {
    @Environment(MacStore.self) private var store
    let project: Project
    @State private var narrative = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(project.name).font(.title2.weight(.semibold))
                Spacer()
                StateDot(state: store.health(project))
                Text(store.health(project).label).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Picker("Area", selection: Binding(get: { project.areaID }, set: { store.setProjectArea(project.id, areaID: $0) })) {
                    Text("Unfiled").tag(UUID?.none)
                    ForEach(store.areasInOrder) { a in Text(a.name).tag(UUID?.some(a.id)) }
                }
                .frame(maxWidth: 220)
                Picker("Horizon", selection: Binding(get: { project.horizon }, set: { store.setProjectHorizon(project.id, horizon: $0) })) {
                    ForEach(Horizon.allCases, id: \.self) { h in Text(h.label).tag(h) }
                }
                .frame(maxWidth: 200)
            }
            TextField("Where it stands, in a sentence or two", text: $narrative, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .onAppear { narrative = project.narrative ?? "" }
                .onSubmit { store.setProjectNarrative(project.id, narrative) }
            if !project.people.isEmpty {
                Text("People: " + project.people.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            let targets = store.targets(in: project.id)
            if targets.isEmpty {
                Text("No dated outcome yet. Add one with ⌘N.").font(.caption).foregroundStyle(.orange)
            }
            ForEach(targets) { t in
                TargetRowMac(target: t, color: store.area(project.areaID).map { Color(hex: $0.colourHex) } ?? .secondary)
            }
        }
    }
}

// MARK: - Balance: where the week goes vs where it was meant to go

struct BalanceView: View {
    @Environment(MacStore.self) private var store

    var body: some View {
        let cal = Calendar.current
        let start = cal.startOfDay(for: .now)
        let end = cal.date(byAdding: .day, value: 7, to: start)!
        let cap = max(1, store.capacityMinutes(from: start, to: end))
        VStack(alignment: .leading, spacing: 8) {
            Text("Balance — next 7 days").font(.headline)
            Text("Planned by area (solid) against the share you intend (tick). \(MacFormat.minutes(cap)) of capacity in the week.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(store.areasInOrder) { area in
                let planned = store.plannedMinutes(area: area.id, from: start, to: end)
                let frac = min(1, Double(planned) / Double(cap))
                HStack(spacing: 8) {
                    Text(area.name).font(.caption).frame(width: 120, alignment: .leading).lineLimit(1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.12))
                            Capsule().fill(Color(hex: area.colourHex)).frame(width: geo.size.width * frac)
                            Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 2, height: 14)
                                .offset(x: geo.size.width * min(1, area.intendedShare) - 1)
                        }
                    }
                    .frame(height: 10)
                    Text(planned == 0 ? "—" : "\(Int((frac * 100).rounded()))%")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(planned == 0 && area.intendedShare > 0 ? .orange : .secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            let unfiled = store.plannedMinutes(area: nil, from: start, to: end)
            if unfiled > 0 {
                Text("\(MacFormat.minutes(unfiled)) planned on unfiled projects.").font(.caption).foregroundStyle(.secondary)
            }
            let neglected = store.areasInOrder.filter { store.plannedMinutes(area: $0.id, from: start, to: end) == 0 && $0.intendedShare > 0 }
            if !neglected.isEmpty {
                Text("Nothing planned in " + neglected.map(\.name).joined(separator: ", ") + " this week.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Roadmap: milestones across the coming weeks

struct RoadmapView: View {
    @Environment(MacStore.self) private var store
    private let weeks = 8

    var body: some View {
        let cal = Calendar.current
        let start = cal.startOfDay(for: .now)
        let items = store.roadmapItems().filter { $0.date < cal.date(byAdding: .day, value: 7 * weeks, to: start)! }
        let projects = Array(Set(items.map(\.project.id))).compactMap { store.ledger.project($0) }
            .sorted { ($0.areaID?.uuidString ?? "~", $0.name) < ($1.areaID?.uuidString ?? "~", $1.name) }
        VStack(alignment: .leading, spacing: 8) {
            Text("Roadmap — next \(weeks) weeks").font(.headline)
            Text("Milestones on the dates the plan chose; red when a step runs past its wall.").font(.caption).foregroundStyle(.secondary)
            if items.isEmpty {
                Text("No milestones ahead.").foregroundStyle(.secondary)
            }
            // header row of week starts
            HStack(spacing: 0) {
                Text("").frame(width: 130)
                ForEach(0..<weeks, id: \.self) { w in
                    let d = cal.date(byAdding: .day, value: 7 * w, to: start)!
                    Text(d.formatted(.dateTime.month(.abbreviated).day())).font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(projects) { p in
                let color = store.area(p.areaID).map { Color(hex: $0.colourHex) } ?? .secondary
                let mine = items.filter { $0.project.id == p.id }
                let lanes = laneLayout(mine, start: start)
                HStack(alignment: .top, spacing: 0) {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text(p.name).font(.caption).lineLimit(1)
                    }
                    .frame(width: 130, alignment: .leading)
                    .padding(.top, 2)
                    GeometryReader { geo in
                        let span = Double(7 * weeks)
                        let chipW: CGFloat = 118
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(Color.secondary.opacity(0.08)).frame(height: 1).offset(y: 10)
                            ForEach(Array(lanes.enumerated()), id: \.offset) { idx, placed in
                                let x = min(geo.size.width - chipW, geo.size.width * Double(placed.day) / span)
                                Text(placed.item.task.text)
                                    .font(.caption2).lineLimit(1).truncationMode(.tail)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .frame(width: chipW, alignment: .leading)
                                    .background((placed.item.late ? Color.red : color).opacity(0.16), in: Capsule())
                                    .overlay(Capsule().strokeBorder(placed.item.late ? Color.red : color, lineWidth: 1))
                                    .offset(x: max(0, x), y: CGFloat(placed.lane) * 20)
                                    .help("\(placed.item.task.text) · \(MacFormat.day(placed.item.date))")
                            }
                        }
                    }
                    .frame(height: CGFloat(max(1, (lanes.map(\.lane).max() ?? 0) + 1)) * 20)
                }
            }
        }
    }
}

/// Chips that would overlap on one row drop to the next lane.
private struct PlacedChip { let item: (project: Project, task: ListItem, date: Date, late: Bool); let day: Int; let lane: Int }

private func laneLayout(_ items: [(project: Project, task: ListItem, date: Date, late: Bool)], start: Date) -> [PlacedChip] {
    let cal = Calendar.current
    let chipDays = 12                      // ≈ chip width in days at 8 weeks across the pane
    var laneEnds: [Int] = []
    var out: [PlacedChip] = []
    for item in items.sorted(by: { $0.date < $1.date }) {
        let day = max(0, cal.dateComponents([.day], from: start, to: item.date).day ?? 0)
        var lane = laneEnds.firstIndex { $0 <= day } ?? laneEnds.count
        if lane == laneEnds.count { laneEnds.append(0) }
        laneEnds[lane] = day + chipDays
        _ = lane
        out.append(PlacedChip(item: item, day: day, lane: lane))
        lane = 0
    }
    return out
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
