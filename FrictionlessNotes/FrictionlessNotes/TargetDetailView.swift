//
//  TargetDetailView.swift
//  FrictionlessNotes
//
//  One target (DESIGN-PM.md §8.3): the title and its typed date as the hero,
//  why it matters, the path with walls and target dates, remaining vs slack,
//  and the one capture it came from. Moving a hard date asks first.
//

import SwiftUI

struct TargetDetailView: View {
    @Environment(CaptureStore.self) private var store
    let targetID: UUID

    @State private var showDatePicker = false
    @State private var pickedDate = Date.now
    @State private var pickedKind: DeadlineKind = .goal
    @State private var confirmHardMove = false
    @State private var newStep = ""

    private var target: Target? { store.target(targetID) }

    var body: some View {
        ZStack {
            Theme.stage0.ignoresSafeArea()
            if let target {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.s5) {
                        hero(target)
                        stateLine(target)
                        if let why = target.whyItMatters, !why.isEmpty {
                            Text(why).font(Typography.caption).foregroundStyle(Theme.inkDim)
                        }
                        path(target)
                        addStepField(target)
                        provenance(target)
                        actions(target)
                        Spacer(minLength: Theme.s8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.s5)
                }
                .scrollIndicators(.hidden)
            }
        }
        .toolbarBackground(Theme.stage0, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $showDatePicker) { datePicker }
        .confirmationDialog("This is a hard deadline. Move it anyway?", isPresented: $confirmHardMove, titleVisibility: .visible) {
            Button("Move it", role: .destructive) { store.setDue(targetID: targetID, to: pickedDate, kind: pickedKind) }
            Button("Keep", role: .cancel) {}
        }
    }

    private func hero(_ t: Target) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            if let p = store.project(t.projectID) {
                HStack(spacing: Theme.s2) {
                    RoundedRectangle(cornerRadius: 1).fill(p.tint).frame(width: 2, height: 12)
                    Text(p.name).micro(Theme.inkDim)
                }
            }
            Text(t.title)
                .font(Typography.heroTranscript(24))
                .foregroundStyle(Theme.ink)
            HStack(spacing: Theme.s2) {
                Text(t.due.map { PlanFormat.day($0) } ?? "no date")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.lamplight)
                Text(t.kind.label).micro(t.kind.tint)
            }
        }
    }

    private func stateLine(_ t: Target) -> some View {
        let st = store.status(of: t.id)
        return HStack(spacing: Theme.s2) {
            Circle().fill(st?.state.tint ?? Theme.inkFaint).frame(width: 6, height: 6)
            Text(st?.state.label ?? "").micro(Theme.inkDim)
            if let st {
                Text("· \(PlanFormat.minutes(st.remainingMinutes)) left · \(PlanFormat.slack(st.slackDays))").micro(Theme.inkFaint)
            }
        }
    }

    private func path(_ t: Target) -> some View {
        let steps = store.tasks(for: t.id)
        return VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(spacing: Theme.s2) {
                RoundedRectangle(cornerRadius: 1).fill(Theme.inkDim).frame(width: 2, height: 12)
                Text("path").micro(Theme.inkDim)
                Spacer()
                Text("\(steps.filter(\.done).count) of \(steps.count)").micro(Theme.inkFaint)
            }
            let current = steps.first { !$0.done }?.id
            ForEach(steps) { s in
                let step = store.step(of: s.id)
                HStack(alignment: .top, spacing: Theme.s3) {
                    Button { store.toggleDone(itemID: s.id) } label: {
                        Image(systemName: s.done ? "checkmark.square.fill" : (s.id == current ? "square.dashed.inset.filled" : "square"))
                            .font(.system(size: 18))
                            .foregroundStyle(s.done ? Theme.statusDone : (s.id == current ? Theme.lamplight : Theme.inkFaint))
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Theme.s2) {
                            Text(s.text)
                                .font(Typography.ledgerLine)
                                .foregroundStyle(s.done ? Theme.inkFaint : Theme.inkLedger)
                                .strikethrough(s.done, color: Theme.inkFaint)
                            if s.milestone { Text("milestone").micro(Theme.lamplight.opacity(0.7)) }
                            if s.needsYou { Text("you").micro(Theme.statusUploaded) }
                        }
                        if !s.done, let step {
                            HStack(spacing: Theme.s2) {
                                Text("target \(PlanFormat.day(step.targetDate))").micro(step.late ? Theme.statusError : Theme.inkDim)
                                Text("· no later than \(PlanFormat.day(step.wall))").micro(Theme.inkFaint)
                                Text("· \(PlanFormat.minutes(s.plannedEffort))\(s.leadDays > 0 ? " + \(s.leadDays) d wait" : "")").micro(Theme.inkFaint)
                            }
                        }
                        if let w = s.waitingOn, !w.isEmpty {
                            Text("waiting on \(w)").micro(Theme.lamplight.opacity(0.7))
                        }
                    }
                }
            }
            if steps.isEmpty {
                Text("no steps yet — add the first below").micro(Theme.inkFaint)
            }
        }
    }

    private func addStepField(_ t: Target) -> some View {
        HStack(spacing: Theme.s2) {
            TextField("", text: $newStep, prompt: Text("add a step").foregroundStyle(Theme.inkFaint))
                .font(Typography.caption)
                .foregroundStyle(Theme.ink)
                .onSubmit(submitStep)
            Button(action: submitStep) {
                Image(systemName: "plus.circle").foregroundStyle(newStep.isEmpty ? Theme.inkFaint : Theme.ink)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.s3)
        .background(Theme.stage1, in: RoundedRectangle(cornerRadius: Theme.rCard))
    }

    private func submitStep() {
        let text = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addStep(to: targetID, text: text, effortMinutes: nil)
        newStep = ""
    }

    @ViewBuilder
    private func provenance(_ t: Target) -> some View {
        if let cid = t.sourceCaptureID, let c = store.captures.first(where: { $0.id == cid }) {
            NavigationLink(value: c.id) {
                HStack(spacing: Theme.s2) {
                    Image(systemName: "link").font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
                    Text(c.ledgerLine).micro(Theme.inkFaint).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func actions(_ t: Target) -> some View {
        HStack(spacing: Theme.s4) {
            Button(t.due == nil ? "set a date" : "move date") {
                pickedDate = t.due ?? .now
                pickedKind = t.kind == .none ? .goal : t.kind
                showDatePicker = true
            }
            Button("done") { store.markTargetDone(t.id) }
        }
        .font(Typography.caption)
        .foregroundStyle(Theme.polish)
        .buttonStyle(.plain)
    }

    private var datePicker: some View {
        VStack(spacing: Theme.s4) {
            DatePicker("", selection: $pickedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(Theme.lamplight)
            Picker("", selection: $pickedKind) {
                Text("hard deadline").tag(DeadlineKind.hard)
                Text("goal").tag(DeadlineKind.goal)
            }
            .pickerStyle(.segmented)
            Button("save") {
                showDatePicker = false
                if let t = target, t.kind == .hard, t.due != nil,
                   !Calendar.current.isDate(pickedDate, inSameDayAs: t.due!) {
                    confirmHardMove = true
                } else {
                    store.setDue(targetID: targetID, to: pickedDate, kind: pickedKind)
                }
            }
            .font(Typography.cardTitle)
            .foregroundStyle(Theme.ink)
        }
        .padding(Theme.s5)
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.stage2)
        .preferredColorScheme(.dark)
    }
}
