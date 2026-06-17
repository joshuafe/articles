//
//  ListsView.swift
//  FrictionlessNotes
//
//  The lists surface — the actionable home for filed todos and shopping items.
//  Quiet, check-off-able, grouped, with provenance back to the source capture.
//

import SwiftUI

/// Navigation route for the lists surface (distinct from the capture-id route).
enum LedgerRoute: Hashable { case lists }

struct ListsView: View {
    @Environment(CaptureStore.self) private var store

    var body: some View {
        ZStack {
            Theme.stage0.ignoresSafeArea()
            if store.todoItems.isEmpty && store.shoppingItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.s6) {
                        section("to do", items: store.todoItems, tint: NoteCategory.todo.tint)
                        section("shopping", items: store.shoppingItems, tint: NoteCategory.shopping.tint)
                    }
                    .padding(.horizontal, Theme.s4)
                    .padding(.top, Theme.s4)
                    .animation(Motion.springCaptureOpen, value: store.listItems)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle("lists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.stage0, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    @ViewBuilder
    private func section(_ title: String, items: [ListItem], tint: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.s3) {
                HStack(spacing: Theme.s2) {
                    RoundedRectangle(cornerRadius: 1).fill(tint).frame(width: 2, height: 12)
                    Text(title).micro(Theme.inkDim)
                    Spacer()
                    let open = items.filter { !$0.done }.count
                    Text(open > 0 ? "\(open)" : "done").micro(Theme.inkFaint)
                }
                ForEach(ordered(items)) { item in
                    ListItemRow(item: item)
                }
            }
        }
    }

    /// Open items first, then by group (keeps a cluster together), newest first.
    private func ordered(_ items: [ListItem]) -> [ListItem] {
        items.sorted { a, b in
            if a.done != b.done { return !a.done }
            if (a.group ?? "") != (b.group ?? "") { return (a.group ?? "") < (b.group ?? "") }
            return a.createdAt > b.createdAt
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.s3) {
            Text("nothing filed yet")
                .font(Typography.ledgerLine)
                .foregroundStyle(Theme.inkFaint)
            Text("speak a to-do or a shopping list and it lands here")
                .micro(Theme.inkFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.s6)
    }
}

struct ListItemRow: View {
    @Environment(CaptureStore.self) private var store
    let item: ListItem

    var body: some View {
        HStack(alignment: .top, spacing: Theme.s3) {
            Button { store.toggleDone(itemID: item.id) } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(item.done ? item.category.tint : Theme.inkFaint)
            }
            .buttonStyle(.plain)

            content
                .frame(maxWidth: .infinity, alignment: .leading)

            if let due = item.due, !item.done {
                Text("due \(due)").micro(Theme.lamplight.opacity(0.7))
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.text)
                .font(Typography.ledgerLine)
                .foregroundStyle(item.done ? Theme.inkFaint : Theme.inkLedger)
                .strikethrough(item.done, color: Theme.inkFaint)
                .lineLimit(2)
            if let group = item.group, !group.isEmpty {
                Text(group).micro(Theme.inkFaint)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let captureID = item.sourceCaptureID {
            NavigationLink(value: captureID) { label }
                .buttonStyle(.plain)
        } else {
            label
        }
    }
}
