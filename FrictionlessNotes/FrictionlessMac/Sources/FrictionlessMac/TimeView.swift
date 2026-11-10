//
//  TimeView.swift
//  FrictionlessMac
//
//  "When do I realistically have time?" — the next two weeks as capacity versus
//  what the plan has already placed, day by day. Pick a day and see what fits
//  the free minutes, most pressing first; pick a weekday to change its capacity.
//

import SwiftUI
import PlanCore

struct TimeView: View {
    @Environment(MacStore.self) private var store
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: .now)
    @State private var days = 14

    private var dayList: [Date] {
        let start = Calendar.current.startOfDay(for: .now)
        return (0..<days).map { Calendar.current.date(byAdding: .day, value: $0, to: start)! }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Next \(days) days").font(.headline)
                    Spacer()
                    Picker("", selection: $days) { Text("7").tag(7); Text("14").tag(14); Text("28").tag(28) }.pickerStyle(.segmented).frame(width: 140)
                }
                .padding([.horizontal, .top], 16)
                List(dayList, id: \.self, selection: $selectedDay) { day in
                    DayBar(day: day, capacity: store.capacity(on: day), hard: store.committedHard(on: day), flexible: store.committedFlexible(on: day))
                        .tag(day)
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                Text(selectedDay.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.title3.weight(.semibold))
                let cap = store.capacity(on: selectedDay), hard = store.committedHard(on: selectedDay)
                let flex = store.committedFlexible(on: selectedDay), free = store.free(on: selectedDay)
                Text("\(MacFormat.minutes(cap)) capacity · \(MacFormat.minutes(hard)) for hard deadlines · \(MacFormat.minutes(flex)) flexible · \(MacFormat.minutes(free)) realistically free")
                    .foregroundStyle(.secondary)
                Text("Free means not claimed by a hard deadline. Flexible work (goals, backlog) is what the plan would do with it; you can choose otherwise.")
                    .font(.caption).foregroundStyle(.secondary)
                CapacityEditor(day: selectedDay)

                GroupBox("Planned") {
                    let work = store.work(on: selectedDay)
                    if work.isEmpty { Text("Nothing placed here.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    ForEach(work, id: \.task.id) { e in
                        HStack {
                            Text(e.task.text).lineLimit(1)
                            Spacer()
                            Text(store.target(e.task.targetID)?.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(MacFormat.minutes(e.minutes)).font(.caption).monospacedDigit()
                        }
                    }
                }
                GroupBox("What fits the free time") {
                    let fits = store.whatFits(minutes: free).prefix(8)
                    if free == 0 { Text("No free minutes on this day.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    else if fits.isEmpty { Text("Nothing open fits \(MacFormat.minutes(free)).").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    ForEach(Array(fits)) { task in
                        HStack {
                            let kind = store.target(task.targetID)?.kind ?? (task.dueKind ?? .none)
                            KindTag(kind: kind)
                            Text(task.text).lineLimit(1)
                            Spacer()
                            Text(MacFormat.minutes(task.plannedEffort)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            if let w = store.step(of: task.id)?.wall { Text("by \(MacFormat.day(w))").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Spacer()
            }
            .padding(18)
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct DayBar: View {
    let day: Date
    let capacity: Int
    let hard: Int
    let flexible: Int

    var body: some View {
        let isToday = Calendar.current.isDateInToday(day)
        let over = hard > capacity
        let free = max(0, capacity - hard)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption.weight(isToday ? .bold : .regular))
                Text(day.formatted(.dateTime.month(.abbreviated).day())).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                let scale = CGFloat(max(capacity, hard + flexible, 1))
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15)).frame(width: w * CGFloat(capacity) / scale)
                    HStack(spacing: 0) {
                        Rectangle().fill(over ? Color.red : Color.blue).frame(width: w * CGFloat(hard) / scale)
                        Rectangle().fill(Color.blue.opacity(0.3)).frame(width: w * CGFloat(flexible) / scale)
                    }
                    .clipShape(Capsule())
                }
            }
            .frame(height: 10)
            Text(capacity == 0 ? "no capacity" : "\(MacFormat.minutes(free)) free")
                .font(.caption).monospacedDigit().foregroundStyle(over ? .red : (free == 0 ? .orange : .secondary)).frame(width: 90, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .help("Blue: hard-deadline work · light blue: flexible (goals, backlog) · grey: capacity")
    }
}

/// Change the weekday's capacity pattern from the day you're looking at.
struct CapacityEditor: View {
    @Environment(MacStore.self) private var store
    let day: Date

    var body: some View {
        let weekday = (Calendar.current.component(.weekday, from: day) + 5) % 7
        let name = day.formatted(.dateTime.weekday(.wide))
        HStack {
            Text("Every \(name):").font(.caption).foregroundStyle(.secondary)
            Stepper(value: Binding(
                get: { store.ledger.capacity.minutesByWeekday[weekday] },
                set: { v in var c = store.ledger.capacity; c.minutesByWeekday[weekday] = max(0, v); store.setCapacity(c) }
            ), in: 0...720, step: 30) {
                Text(MacFormat.minutes(store.ledger.capacity.minutesByWeekday[weekday])).monospacedDigit()
            }
            .font(.caption)
            Spacer()
        }
    }
}

struct IdeasView: View {
    @Environment(MacStore.self) private var store
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Jot something", text: $text).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add", action: add).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List(store.ledger.ideas) { idea in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(Color.purple).frame(width: 6, height: 6).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(idea.text)
                        HStack(spacing: 6) {
                            if let p = store.project(idea.projectID) { Text(p.name).font(.caption).foregroundStyle(.secondary) }
                            Text(idea.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(16)
    }

    private func add() { store.addIdea(text, projectID: nil); text = "" }
}
