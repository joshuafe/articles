//
//  NowView.swift
//  FrictionlessMac
//
//  The Now strip as a page (Due · At risk · Today) and its compact menu-bar form.
//

import SwiftUI
import PlanCore

struct NowView: View {
    @Environment(MacStore.self) private var store
    @State private var selected: UUID?

    var body: some View {
        HSplitView {
            List {
                SwiftUI.Section("Due — hard deadlines by date") {
                    if store.hardTargetsByDue.isEmpty { Text("No hard deadlines.").foregroundStyle(.secondary) }
                    ForEach(store.hardTargetsByDue) { t in
                        let st = store.status(of: t.id)
                        HStack {
                            Text(MacFormat.day(t.due)).monospacedDigit().frame(width: 92, alignment: .leading).foregroundStyle(.secondary)
                            Text(t.title).lineLimit(1)
                            Spacer()
                            StateDot(state: st?.state)
                            Text(MacFormat.slack(st?.slackDays)).foregroundStyle(.secondary).font(.caption)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selected = t.id }
                    }
                }
                SwiftUI.Section("At risk") {
                    if store.atRiskTargets.isEmpty { Text("Nothing at risk.").foregroundStyle(.secondary) }
                    ForEach(store.atRiskTargets) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { StateDot(state: store.status(of: t.id)?.state); Text(t.title).lineLimit(1) }
                            Text(reason(t)).font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selected = t.id }
                    }
                }
                SwiftUI.Section("Today — \(MacFormat.minutes(store.committed(on: .now))) planned of \(MacFormat.minutes(store.capacity(on: .now)))") {
                    if store.todaysWork.isEmpty { Text("Nothing scheduled today.").foregroundStyle(.secondary) }
                    ForEach(store.todaysWork, id: \.task.id) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            Toggle("", isOn: Binding(get: { entry.task.done }, set: { _ in store.toggleDone(taskID: entry.task.id) }))
                                .toggleStyle(.checkbox).labelsHidden()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.task.text).strikethrough(entry.task.done)
                                Text("\(MacFormat.minutes(entry.minutes)) · \(store.target(entry.task.targetID)?.title ?? "backlog")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selected = entry.task.targetID }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

            if let id = selected, store.target(id) != nil {
                TargetDetailMac(targetID: id)
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Pick a target", systemImage: "scope", description: Text("Details and its path appear here."))
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func reason(_ t: Target) -> String {
        guard let st = store.status(of: t.id) else { return "" }
        if let lateID = st.lateTaskIDs.first, let task = store.task(lateID), let step = store.step(of: lateID) {
            return "\(task.text) lands \(MacFormat.day(step.plannedEnd)), no later than \(MacFormat.day(step.wall))"
        }
        return "\(st.state.label) · \(MacFormat.slack(st.slackDays))"
    }
}

/// The menu-bar popover: the same three boxes, compact, plus an Open button.
struct MenuBarNow: View {
    @Environment(MacStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Program").font(.headline)
                Spacer()
                let n = store.openDecisions.count
                if n > 0 { Text("\(n) for you").font(.caption).foregroundStyle(.blue) }
            }
            if store.openTargets.isEmpty {
                Text("Nothing with a date yet.").foregroundStyle(.secondary)
                Button("Load November seed") { store.importDemoSeed() }
            }
            group("Due") {
                ForEach(store.hardTargetsByDue.prefix(4)) { t in
                    row(MacFormat.day(t.due), t.title, store.status(of: t.id)?.state)
                }
            }
            if !store.atRiskTargets.isEmpty {
                group("At risk") {
                    ForEach(store.atRiskTargets.prefix(3)) { t in
                        row(MacFormat.slack(store.status(of: t.id)?.slackDays), t.title, store.status(of: t.id)?.state)
                    }
                }
            }
            group("Today · \(MacFormat.minutes(store.committed(on: .now)))") {
                ForEach(store.todaysWork.prefix(5), id: \.task.id) { e in
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(get: { e.task.done }, set: { _ in store.toggleDone(taskID: e.task.id) }))
                            .toggleStyle(.checkbox).labelsHidden()
                        Text(e.task.text).lineLimit(1).strikethrough(e.task.done)
                        Spacer()
                        Text(MacFormat.minutes(e.minutes)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                Button("Open Program") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "Program") }
                Spacer()
                Button("Re-plan") { store.replan() }
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ lead: String, _ title: String, _ state: TargetState?) -> some View {
        HStack(spacing: 6) {
            StateDot(state: state)
            Text(lead).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(title).lineLimit(1)
            Spacer()
        }
    }
}
