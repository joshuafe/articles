//
//  ProjectsView.swift
//  FrictionlessMac
//
//  Projects → targets with path trackers; a target's detail with its steps,
//  walls and target dates; the add-deadline sheet.
//

import SwiftUI
import PlanCore

struct ProjectsView: View {
    @Environment(MacStore.self) private var store
    @State private var selected: UUID?

    var body: some View {
        HSplitView {
            List(selection: $selected) {
                ForEach(projectKeys, id: \.self) { pid in
                    let p = store.project(pid)
                    SwiftUI.Section {
                        ForEach(store.targets(in: pid)) { t in
                            TargetRowMac(target: t, color: p?.color ?? .secondary)
                                .tag(t.id)
                        }
                    } header: {
                        HStack {
                            Circle().fill(p?.color ?? .secondary).frame(width: 8, height: 8)
                            Text(p?.name ?? "Unfiled")
                            Spacer()
                            let forYou = store.openDecisions.filter { d in store.targets(in: pid).contains { $0.id == d.targetID } }.count
                            if forYou > 0 { Text("\(forYou) for you").font(.caption).foregroundStyle(.blue) }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

            if let id = selected, store.target(id) != nil {
                TargetDetailMac(targetID: id).frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Pick a target", systemImage: "scope", description: Text("Its path, walls and target dates appear here."))
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var projectKeys: [UUID?] {
        let grouped = Dictionary(grouping: store.openTargets, by: { $0.projectID })
        var keys: [UUID?] = store.ledger.projects.map { Optional($0.id) }.filter { grouped[$0] != nil }
        if grouped[nil] != nil { keys.append(nil) }
        return keys
    }
}

struct TargetRowMac: View {
    @Environment(MacStore.self) private var store
    let target: Target
    let color: Color

    var body: some View {
        let steps = store.tasks(for: target.id)
        let st = store.status(of: target.id)
        let current = steps.first { !$0.done }?.id
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(target.title).lineLimit(1)
                Spacer()
                if let due = target.due { Text(MacFormat.day(due)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                KindTag(kind: target.kind)
            }
            HStack(spacing: 3) {
                ForEach(steps) { s in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(s.done ? color : (s.id == current ? color.opacity(0.35) : Color.secondary.opacity(0.2)))
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(s.id == current ? color : .clear, lineWidth: 1))
                        .frame(height: 7)
                }
                if steps.isEmpty { RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.2)).frame(height: 7) }
                Spacer(minLength: 8)
                StateDot(state: st?.state)
                Text(st?.state.label ?? "").font(.caption).foregroundStyle(.secondary)
                Text(MacFormat.slack(st?.slackDays)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct TargetDetailMac: View {
    @Environment(MacStore.self) private var store
    let targetID: UUID
    @State private var newStep = ""
    @State private var newEffort = ""
    @State private var showDate = false
    @State private var picked = Date.now
    @State private var pickedKind: DeadlineKind = .goal
    @State private var confirmHard = false

    var body: some View {
        if let t = store.target(targetID) {
            let st = store.status(of: t.id)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let p = store.project(t.projectID) {
                        HStack(spacing: 6) { Circle().fill(p.color).frame(width: 8, height: 8); Text(p.name).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(t.title).font(.title2.weight(.semibold))
                    HStack(spacing: 8) {
                        Text(t.due.map { MacFormat.day($0) } ?? "no date").font(.callout)
                        KindTag(kind: t.kind)
                        StateDot(state: st?.state)
                        Text(st?.state.label ?? "").font(.callout).foregroundStyle(.secondary)
                        if let st { Text("· \(MacFormat.minutes(st.remainingMinutes)) left · \(MacFormat.slack(st.slackDays))").font(.callout).foregroundStyle(.secondary) }
                    }
                    if let why = t.whyItMatters, !why.isEmpty { Text(why).font(.callout).foregroundStyle(.secondary) }

                    GroupBox("Path") {
                        VStack(alignment: .leading, spacing: 8) {
                            let steps = store.tasks(for: t.id)
                            let current = steps.first { !$0.done }?.id
                            ForEach(steps) { s in
                                let step = store.step(of: s.id)
                                HStack(alignment: .top, spacing: 8) {
                                    Toggle("", isOn: Binding(get: { s.done }, set: { _ in store.toggleDone(taskID: s.id) }))
                                        .toggleStyle(.checkbox).labelsHidden()
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(s.text).strikethrough(s.done).fontWeight(s.id == current ? .semibold : .regular)
                                            if s.milestone { Text("milestone").font(.caption2).foregroundStyle(.orange) }
                                            if s.needsYou { Text("you").font(.caption2).foregroundStyle(.blue) }
                                        }
                                        if !s.done, let step {
                                            Text("target \(MacFormat.day(step.targetDate)) · no later than \(MacFormat.day(step.wall)) · \(MacFormat.minutes(s.plannedEffort))\(s.leadDays > 0 ? " + \(s.leadDays) d wait" : "")")
                                                .font(.caption).foregroundStyle(step.late ? .red : .secondary)
                                        }
                                        if let w = s.waitingOn, !w.isEmpty { Text("waiting on \(w)").font(.caption).foregroundStyle(.orange) }
                                    }
                                    Spacer()
                                    EffortField(task: s)
                                }
                            }
                            if steps.isEmpty { Text("No steps yet.").foregroundStyle(.secondary) }
                            HStack {
                                TextField("Add a step", text: $newStep).textFieldStyle(.roundedBorder).onSubmit(addStep)
                                TextField("min", text: $newEffort).textFieldStyle(.roundedBorder).frame(width: 56)
                                Button("Add", action: addStep).disabled(newStep.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                        .padding(4)
                    }

                    HStack {
                        Button(t.due == nil ? "Set a date" : "Move date") {
                            picked = t.due ?? .now; pickedKind = t.kind == .none ? .goal : t.kind; showDate = true
                        }
                        Button("Mark done") { store.markTargetDone(t.id) }
                        Spacer()
                    }
                }
                .padding(18)
            }
            .sheet(isPresented: $showDate) {
                VStack(spacing: 12) {
                    DatePicker("Date", selection: $picked, displayedComponents: .date).datePickerStyle(.graphical)
                    Picker("Kind", selection: $pickedKind) { Text("Hard deadline").tag(DeadlineKind.hard); Text("Goal").tag(DeadlineKind.goal) }.pickerStyle(.segmented)
                    HStack {
                        Button("Cancel") { showDate = false }
                        Spacer()
                        Button("Save") {
                            showDate = false
                            if t.kind == .hard, let due = t.due, !Calendar.current.isDate(picked, inSameDayAs: due) { confirmHard = true }
                            else { store.setDue(targetID: t.id, to: picked, kind: pickedKind) }
                        }.buttonStyle(.borderedProminent)
                    }
                }
                .padding(16).frame(width: 360)
            }
            .confirmationDialog("This is a hard deadline. Move it anyway?", isPresented: $confirmHard) {
                Button("Move it", role: .destructive) { store.setDue(targetID: t.id, to: picked, kind: pickedKind) }
                Button("Keep", role: .cancel) {}
            }
        }
    }

    private func addStep() {
        let text = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addStep(to: targetID, text: text, effortMinutes: Int(newEffort), milestone: false)
        newStep = ""; newEffort = ""
    }
}

/// Inline effort estimate editor: the number the engine plans with.
struct EffortField: View {
    @Environment(MacStore.self) private var store
    let task: ListItem
    @State private var text = ""

    var body: some View {
        TextField("min", text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 60)
            .multilineTextAlignment(.trailing)
            .onAppear { text = task.effortMinutes.map(String.init) ?? "" }
            .onSubmit { store.setEffort(taskID: task.id, minutes: Int(text)) }
            .help("Estimated minutes of your own work")
    }
}

struct AddTargetSheet: View {
    @Environment(MacStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var project = ""
    @State private var hasDate = true
    @State private var date = Date.now
    @State private var kind: DeadlineKind = .hard
    @State private var effort = ""
    @State private var why = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a deadline").font(.headline)
            TextField("What has to be done", text: $title).textFieldStyle(.roundedBorder)
            HStack {
                TextField("Project", text: $project).textFieldStyle(.roundedBorder)
                TextField("Minutes of work", text: $effort).textFieldStyle(.roundedBorder).frame(width: 130)
            }
            Toggle("Has a date", isOn: $hasDate)
            if hasDate {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Picker("Kind", selection: $kind) { Text("Hard deadline").tag(DeadlineKind.hard); Text("Goal").tag(DeadlineKind.goal) }.pickerStyle(.segmented)
            }
            TextField("Why it matters (optional)", text: $why).textFieldStyle(.roundedBorder)

            // Intake (v4.1): the cost of taking this on, before you do.
            let preview = store.previewImpact(title: title, due: hasDate ? date : nil, kind: kind, effortMinutes: Int(effort))
            GroupBox("If you take this on") {
                VStack(alignment: .leading, spacing: 4) {
                    if let st = preview.newState {
                        HStack { StateDot(state: st); Text("This one would be \(st.label) at current capacity.") }
                    }
                    if preview.impacts.isEmpty {
                        Text("Nothing already committed gets worse.").foregroundStyle(.secondary)
                    } else {
                        ForEach(preview.impacts) { imp in
                            HStack(spacing: 6) {
                                StateDot(state: imp.after)
                                Text(imp.title).lineLimit(1)
                                Spacer()
                                Text("\(imp.before.label) → \(imp.after.label)")
                                    .font(.caption).foregroundStyle(imp.after == .willMiss ? .red : .orange)
                                if let a = imp.slackAfter, let b = imp.slackBefore, a != b {
                                    Text("slack \(b) → \(a) d").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(preview.impacts.isEmpty ? "Take it on" : "Take it on anyway") {
                    store.addTarget(title: title.trimmingCharacters(in: .whitespaces), due: hasDate ? date : nil, kind: kind,
                                    projectName: project, why: why.isEmpty ? nil : why, effortMinutes: Int(effort))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}
