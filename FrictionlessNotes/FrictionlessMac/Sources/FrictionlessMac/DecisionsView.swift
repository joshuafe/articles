//
//  DecisionsView.swift
//  FrictionlessMac
//
//  "Needs you": self-contained decision cards (DESIGN-PM.md §7), engine-raised
//  first, with one button per answer and what each answer does.
//

import SwiftUI
import PlanCore

struct DecisionsView: View {
    @Environment(MacStore.self) private var store

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if store.openDecisions.isEmpty {
                    ContentUnavailableView("Nothing needs you", systemImage: "checkmark.circle",
                                           description: Text("Decisions appear here when the engine or the planner can't settle something alone."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
                ForEach(store.openDecisions) { d in
                    DecisionCard(decision: d)
                }
                if !store.deferredDecisions.isEmpty {
                    Text("\(store.deferredDecisions.count) deferred").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

struct DecisionCard: View {
    @Environment(MacStore.self) private var store
    let decision: Decision

    var body: some View {
        let isEngine = decision.raisedBy == "engine"
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(decision.code).font(.caption.weight(.semibold)).foregroundStyle(isEngine ? .red : .secondary)
                if let t = store.target(decision.targetID) {
                    Text(store.project(t.projectID)?.name ?? t.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(decision.askedAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            }
            Text(decision.question).font(.title3.weight(.semibold))
            field("Why now", decision.whyNow)
            field("Background", decision.background)
            field("Touches", decision.touches)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(decision.options.enumerated()), id: \.offset) { i, o in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Button(o.label) { store.answer(decisionID: decision.id, option: o) }
                            .buttonStyle(.borderedProminent)
                            .tint(i == 0 ? .blue : .secondary)
                        Text(o.does).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Text("If you don't answer: \(decision.ifUnanswered)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Defer 3 days") { store.deferDecision(decisionID: decision.id) }.buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isEngine ? Color.red.opacity(0.6) : Color.secondary.opacity(0.25)))
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            Text(value).font(.callout)
        }
    }
}
