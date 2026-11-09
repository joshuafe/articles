//
//  MacApp.swift
//  FrictionlessMac
//
//  Menu bar + full window (DESIGN-PM.md §8.4), in the unified Mac look the
//  BMT console settled on: system font, light and dark follow the Mac, grouped
//  lists, one button shape, five colours with one meaning each —
//  blue your move · green on track · orange waiting / at risk · red blocking · purple ideas.
//

import SwiftUI
import AppKit
import PlanCore

@main
struct FrictionlessMacApp: App {
    @State private var store = MacStore()

    var body: some Scene {
        WindowGroup("Program") {
            ProgramWindow()
                .environment(store)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1100, height: 720)

        MenuBarExtra {
            MenuBarNow()
                .environment(store)
        } label: {
            Label(menuTitle, systemImage: store.hasWillMiss ? "exclamationmark.circle.fill" : "circle.lefthalf.filled")
        }
        .menuBarExtraStyle(.window)
    }

    private var menuTitle: String {
        let n = store.openDecisions.count
        return n > 0 ? "\(n)" : ""
    }
}

enum Section: String, CaseIterable, Identifiable {
    case portfolio = "Portfolio", now = "Now", needsYou = "Needs you", projects = "Projects", time = "Time", ideas = "Ideas"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .portfolio: "square.grid.2x2"
        case .now: "sun.max"
        case .needsYou: "hand.raised"
        case .projects: "folder"
        case .time: "calendar"
        case .ideas: "lightbulb"
        }
    }
}

struct ProgramWindow: View {
    @Environment(MacStore.self) private var store
    @State private var section: Section = .portfolio
    @State private var showAdd = false

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label {
                    HStack {
                        Text(s.rawValue)
                        Spacer()
                        badge(for: s)
                    }
                } icon: {
                    Image(systemName: s.symbol)
                }
                .tag(s)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            Group {
                switch section {
                case .portfolio: PortfolioView()
                case .now: NowView()
                case .needsYou: DecisionsView()
                case .projects: ProjectsView()
                case .time: TimeView()
                case .ideas: IdeasView()
                }
            }
            .navigationTitle(section.rawValue)
            .navigationSubtitle(subtitle)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !store.demoSeedLoaded {
                    Button("Load November seed") { store.importDemoSeed() }
                }
                Button { showAdd = true } label: { Label("Add deadline", systemImage: "plus") }
                    .keyboardShortcut("n")
            }
        }
        .sheet(isPresented: $showAdd) { AddTargetSheet() }
        .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in store.replan() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if store.hubConfigured { Task { await store.hubRefresh() } }
        }
    }

    @ViewBuilder
    private func badge(for s: Section) -> some View {
        switch s {
        case .needsYou:
            let n = store.openDecisions.count
            if n > 0 { Text("\(n)").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1).background(Color.blue, in: Capsule()).foregroundStyle(.white) }
        case .now:
            let n = store.atRiskTargets.count
            if n > 0 { Text("\(n)").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1).background(store.hasWillMiss ? Color.red : Color.orange, in: Capsule()).foregroundStyle(.white) }
        default: EmptyView()
        }
    }

    private var subtitle: String {
        let saved = store.lastSaved.map { "saved \($0.formatted(date: .omitted, time: .shortened))" } ?? "ledger \(store.url.lastPathComponent)"
        var s = "plan \(store.assessment.computedAt.formatted(date: .omitted, time: .shortened)) · \(saved)"
        if let hub = store.hubStatus { s += " · \(hub)" }
        return s
    }
}

// MARK: - Shared pieces

struct StateDot: View {
    let state: TargetState?
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
    private var color: Color {
        switch state {
        case .onTrack, .done: .green
        case .atRisk, .slipping: .orange
        case .willMiss: .red
        case .backlog, .none: .secondary
        }
    }
}

extension Project {
    var color: Color {
        Color(red: Double((colourHex >> 16) & 0xFF) / 255, green: Double((colourHex >> 8) & 0xFF) / 255, blue: Double(colourHex & 0xFF) / 255)
    }
}

struct KindTag: View {
    let kind: DeadlineKind
    var body: some View {
        Text(kind == .hard ? "hard" : (kind == .goal ? "goal" : "no date"))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(kind == .hard ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.12), in: Capsule())
    }
}
