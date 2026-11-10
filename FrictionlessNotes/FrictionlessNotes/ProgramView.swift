//
//  ProgramView.swift
//  FrictionlessNotes
//
//  The Program surface (DESIGN-PM.md §8.2): the Now strip (Due · At risk ·
//  Today), the decision cards that need Joshua, and the projects with their
//  targets. Phone-first, one column, Stage Whisper tokens. Everything on it is
//  Tier-0 data, so it never lags the ledger.
//

import SwiftUI

struct ProgramView: View {
    @Environment(CaptureStore.self) private var store
    @State private var ideaText = ""

    var body: some View {
        ZStack {
            Theme.stage0.ignoresSafeArea()
            if store.openTargets.isEmpty && store.openDecisions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.s6) {
                        header
                        nowStrip
                        if !store.openDecisions.isEmpty { needsYou }
                        projects
                        ideasPane
                        listsLink
                    }
                    .padding(.horizontal, Theme.s4)
                    .padding(.top, Theme.s4)
                    .padding(.bottom, Theme.s8)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle("program")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.stage0, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    // MARK: Header — the counts

    private var header: some View {
        let forYou = store.openDecisions.count
        let risk = store.atRiskTargets.count
        let hard = store.hardTargetsByDue.count
        return HStack(spacing: Theme.s3) {
            countPill("\(forYou) for you", tint: forYou > 0 ? Theme.statusUploaded : Theme.inkFaint)
            countPill("\(risk) at risk", tint: risk > 0 ? (store.hasWillMiss ? Theme.statusError : Theme.lamplight) : Theme.inkFaint)
            countPill("\(hard) hard", tint: Theme.inkDim)
            Spacer()
            Text("plan \(store.assessment.computedAt.formatted(date: .omitted, time: .shortened))")
                .micro(Theme.inkFaint)
        }
    }

    private func countPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .micro(tint)
            .padding(.horizontal, Theme.s2)
            .padding(.vertical, Theme.s1)
            .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 0.5))
    }

    // MARK: Now strip

    private var nowStrip: some View {
        VStack(alignment: .leading, spacing: Theme.s5) {
            section("due", tint: Theme.inkDim) {
                if store.hardTargetsByDue.isEmpty {
                    quiet("no hard deadlines")
                }
                ForEach(store.hardTargetsByDue.prefix(6)) { t in
                    let st = store.status(of: t.id)
                    NavigationLink(value: TargetRoute(id: t.id)) {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.s3) {
                            Text(PlanFormat.shortDay(t.due)).micro(Theme.lamplight.opacity(0.8)).frame(width: 52, alignment: .leading)
                            Text(t.title).font(Typography.ledgerLine).foregroundStyle(Theme.inkLedger).lineLimit(1)
                            Spacer(minLength: Theme.s2)
                            Circle().fill(st?.state.tint ?? Theme.inkFaint).frame(width: 6, height: 6)
                            Text(PlanFormat.slack(st?.slackDays)).micro(Theme.inkFaint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            section("at risk", tint: store.hasWillMiss ? Theme.statusError : Theme.lamplight) {
                if store.atRiskTargets.isEmpty {
                    quiet("nothing at risk")
                }
                ForEach(store.atRiskTargets) { t in
                    let st = store.status(of: t.id)
                    NavigationLink(value: TargetRoute(id: t.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Theme.s2) {
                                Circle().fill(st?.state.tint ?? Theme.inkFaint).frame(width: 6, height: 6)
                                Text(t.title).font(Typography.ledgerLine).foregroundStyle(Theme.inkLedger).lineLimit(1)
                            }
                            Text(riskReason(t, st)).micro(Theme.inkDim)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            section("today", tint: Theme.inkDim) {
                if store.todaysWork.isEmpty {
                    quiet("nothing scheduled today")
                }
                ForEach(store.todaysWork, id: \.task.id) { entry in
                    HStack(alignment: .top, spacing: Theme.s3) {
                        Button { store.toggleDone(itemID: entry.task.id) } label: {
                            Image(systemName: entry.task.done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18))
                                .foregroundStyle(entry.task.done ? Theme.statusDone : Theme.inkFaint)
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.task.text)
                                .font(Typography.ledgerLine)
                                .foregroundStyle(entry.task.done ? Theme.inkFaint : Theme.inkLedger)
                                .strikethrough(entry.task.done, color: Theme.inkFaint)
                                .lineLimit(2)
                            Text("\(PlanFormat.minutes(entry.minutes)) · \(store.target(entry.task.targetID)?.title ?? "backlog")")
                                .micro(Theme.inkFaint)
                        }
                    }
                }
            }
        }
    }

    private func riskReason(_ t: Target, _ st: TargetStatus?) -> String {
        guard let st else { return "" }
        if let lateID = st.lateTaskIDs.first,
           let task = store.listItems.first(where: { $0.id == lateID }),
           let step = store.step(of: lateID) {
            return "\(task.text) lands \(PlanFormat.day(step.plannedEnd)), wall \(PlanFormat.day(step.wall))"
        }
        return "\(st.state.label) · \(PlanFormat.slack(st.slackDays))"
    }

    // MARK: Needs you — decision cards

    private var needsYou: some View {
        section("needs you", tint: Theme.statusUploaded) {
            ForEach(store.openDecisions) { d in
                DecisionCardView(decision: d)
            }
            if !store.deferredDecisions.isEmpty {
                Text("\(store.deferredDecisions.count) deferred").micro(Theme.inkFaint)
            }
        }
    }

    // MARK: Projects

    private var projects: some View {
        section("projects", tint: Theme.inkDim) {
            let grouped = Dictionary(grouping: store.openTargets, by: { $0.projectID })
            let projectIDs = store.projects.map { Optional($0.id) }.filter { grouped[$0] != nil } + (grouped[nil] != nil ? [nil] : [])
            ForEach(projectIDs, id: \.self) { pid in
                ProjectRow(project: store.project(pid), targets: store.targets(in: pid) )
            }
        }
    }

    // MARK: Ideas

    private var ideasPane: some View {
        section("ideas & scratchpad", tint: Color(hex: 0xC792F2)) {
            HStack(spacing: Theme.s2) {
                TextField("", text: $ideaText, prompt: Text("jot something").foregroundStyle(Theme.inkFaint))
                    .font(Typography.caption)
                    .foregroundStyle(Theme.ink)
                    .onSubmit { store.addIdea(ideaText); ideaText = "" }
                Button { store.addIdea(ideaText); ideaText = "" } label: {
                    Image(systemName: "arrow.up.circle").foregroundStyle(ideaText.isEmpty ? Theme.inkFaint : Theme.ink)
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.s3)
            .background(Theme.stage1, in: RoundedRectangle(cornerRadius: Theme.rCard))
            ForEach(store.ideas.prefix(8)) { idea in
                HStack(alignment: .top, spacing: Theme.s2) {
                    Circle().fill(Color(hex: 0xC792F2)).frame(width: 4, height: 4).padding(.top, 7)
                    Text(idea.text).font(Typography.caption).foregroundStyle(Theme.inkDim)
                }
            }
        }
    }

    private var listsLink: some View {
        NavigationLink(value: LedgerRoute.lists) {
            HStack(spacing: Theme.s2) {
                Text("\u{25B8}").micro(Theme.inkFaint)
                Text(store.openShoppingCount > 0 ? "\(store.openShoppingCount) to buy" : "lists").micro(Theme.inkFaint)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Pieces

    private var emptyState: some View {
        VStack(spacing: Theme.s3) {
            Text("nothing with a date yet")
                .font(Typography.ledgerLine)
                .foregroundStyle(Theme.inkFaint)
            Text("say a deadline and it lands here with its path")
                .micro(Theme.inkFaint)
            Button("load the November seed") { store.importDemoSeed() }
                .font(Typography.caption)
                .foregroundStyle(Theme.lamplight)
                .buttonStyle(.plain)
                .padding(.top, Theme.s4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.s6)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(spacing: Theme.s2) {
                RoundedRectangle(cornerRadius: 1).fill(tint).frame(width: 2, height: 12)
                Text(title).micro(Theme.inkDim)
            }
            content()
        }
    }

    private func quiet(_ text: String) -> some View {
        Text(text).micro(Theme.inkFaint)
    }
}

/// One self-contained decision card (DESIGN-PM.md §7).
struct DecisionCardView: View {
    @Environment(CaptureStore.self) private var store
    let decision: Decision
    @State private var open = false

    var body: some View {
        let isEngine = decision.raisedBy == "engine"
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(spacing: Theme.s2) {
                Text(decision.code).micro(isEngine ? Theme.statusError : Theme.inkFaint)
                if let t = store.target(decision.targetID) {
                    Text(store.project(t.projectID)?.name ?? t.title).micro(Theme.inkFaint).lineLimit(1)
                }
                Spacer()
                Button(open ? "less" : "more") { withAnimation(Motion.fadeStatus) { open.toggle() } }
                    .font(Typography.micro)
                    .foregroundStyle(Theme.inkFaint)
                    .buttonStyle(.plain)
            }
            Text(decision.question)
                .font(Typography.cardTitle)
                .foregroundStyle(Theme.ink)
            Text(decision.whyNow)
                .font(Typography.caption)
                .foregroundStyle(Theme.inkDim)
            if open {
                field("background", decision.background)
                field("touches", decision.touches)
                field("if you don\u{2019}t answer", decision.ifUnanswered)
            }
            VStack(alignment: .leading, spacing: Theme.s2) {
                ForEach(Array(decision.options.enumerated()), id: \.offset) { i, option in
                    Button { store.answer(decisionID: decision.id, option: option) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                            Text(option.label)
                                .font(Typography.caption)
                                .foregroundStyle(i == 0 ? Theme.stage0 : Theme.ink)
                                .padding(.horizontal, Theme.s3)
                                .padding(.vertical, Theme.s1 + 2)
                                .background(i == 0 ? Theme.statusUploaded : Theme.stage2, in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                            Text(option.does).micro(Theme.inkFaint).lineLimit(2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button("defer 3 days") { store.deferDecision(decisionID: decision.id) }
                    .font(Typography.micro)
                    .foregroundStyle(Theme.inkFaint)
                    .buttonStyle(.plain)
                    .padding(.top, Theme.s1)
            }
        }
        .padding(Theme.s4)
        .background(Theme.stage1, in: RoundedRectangle(cornerRadius: Theme.rCard))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rCard)
                .strokeBorder(isEngine ? Theme.statusError.opacity(0.6) : Theme.hairline, lineWidth: isEngine ? 1 : 0.5))
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).micro(Theme.inkFaint)
            Text(value).font(Typography.caption).foregroundStyle(Theme.inkDim)
        }
    }
}

/// A project with its open targets as compact path trackers.
struct ProjectRow: View {
    @Environment(CaptureStore.self) private var store
    let project: Project?
    let targets: [Target]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(spacing: Theme.s2) {
                RoundedRectangle(cornerRadius: 1).fill(project?.tint ?? Theme.inkFaint).frame(width: 2, height: 14)
                Text(project?.name ?? "unfiled").font(Typography.cardTitle).foregroundStyle(Theme.ink)
                Spacer()
                let forYou = store.openDecisions.filter { d in targets.contains { $0.id == d.targetID } }.count
                if forYou > 0 { Text("\(forYou) for you").micro(Theme.statusUploaded) }
            }
            ForEach(targets) { t in
                NavigationLink(value: TargetRoute(id: t.id)) {
                    TargetTrackerRow(target: t, tint: project?.tint ?? Theme.inkDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.s4)
        .background(Theme.stage1, in: RoundedRectangle(cornerRadius: Theme.rCard))
        .overlay(RoundedRectangle(cornerRadius: Theme.rCard).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// One target: title, date with kind, state, and its path as boxes with the
/// current step outlined.
struct TargetTrackerRow: View {
    @Environment(CaptureStore.self) private var store
    let target: Target
    let tint: Color

    var body: some View {
        let steps = store.tasks(for: target.id)
        let st = store.status(of: target.id)
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                Text(target.title).font(Typography.ledgerLine).foregroundStyle(Theme.inkLedger).lineLimit(1)
                Spacer(minLength: Theme.s2)
                if let due = target.due {
                    Text("\(PlanFormat.day(due)) · \(target.kind.rawValue)").micro(Theme.lamplight.opacity(0.8))
                }
            }
            HStack(spacing: 3) {
                let current = steps.first { !$0.done }?.id
                ForEach(steps) { s in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(s.done ? tint : (s.id == current ? tint.opacity(0.35) : Theme.hairline))
                        .frame(height: 6)
                        .overlay(RoundedRectangle(cornerRadius: 1).strokeBorder(s.id == current ? tint : .clear, lineWidth: 1))
                }
                if steps.isEmpty {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.hairline).frame(height: 6)
                }
                Spacer(minLength: Theme.s2)
                Circle().fill(st?.state.tint ?? Theme.inkFaint).frame(width: 6, height: 6)
                Text(st?.state.label ?? "").micro(Theme.inkFaint)
            }
        }
        .contentShape(Rectangle())
    }
}
