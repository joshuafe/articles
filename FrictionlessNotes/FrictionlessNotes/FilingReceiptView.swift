//
//  FilingReceiptView.swift
//  FrictionlessNotes
//
//  M3 · The Filing Receipt — the moment the Mac files a thought.
//  Slides from beneath the row, Undo / Move-to, settles into provenance.
//

import SwiftUI

struct FilingReceiptView: View {
    @Environment(CaptureStore.self) private var store
    let captureID: UUID
    let action: FilingAction

    @State private var settled = false
    @State private var showMoveDialog = false

    var body: some View {
        Group {
            if action.undone {
                removedLine
            } else if settled {
                provenanceLine
            } else {
                receipt
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(Motion.receiptVisibleSeconds))
            withAnimation(Motion.slideReceiptOut) { settled = true }
        }
    }

    private var receipt: some View {
        HStack(spacing: Theme.s2) {
            RoundedRectangle(cornerRadius: 1)
                .fill((action.category ?? .note).tint)
                .frame(width: 2, height: 12)

            Group {
                Text("\u{2192} ").foregroundStyle(Theme.inkFaint)
                + Text(action.listName ?? action.tool.rawValue).foregroundStyle(Theme.lamplight)
                + Text(action.tool == .learned ? "" : " · \(action.text)").foregroundStyle(Theme.inkDim)
                + Text(action.due != nil ? "  due \(action.due!)" : "").foregroundStyle(Theme.lamplight)
            }
            .font(Typography.caption)
            .lineLimit(1)

            Spacer(minLength: Theme.s2)

            if action.tool != .learned {
                Button("undo") { undo() }
                    .font(Typography.caption)
                    .foregroundStyle(Theme.inkDim)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.s3)
        .padding(.vertical, Theme.s2)
        .background(Theme.stage2, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        .contentShape(Capsule())
        .onTapGesture { if action.tool != .learned { showMoveDialog = true } }
        .confirmationDialog("Move to…", isPresented: $showMoveDialog, titleVisibility: .visible) {
            ForEach(NoteCategory.allCases, id: \.self) { category in
                Button(category.rawValue) {
                    store.move(captureID: captureID, actionID: action.id, to: category)
                }
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var provenanceLine: some View {
        HStack(spacing: Theme.s2) {
            Circle()
                .fill((action.category ?? .note).tint)
                .frame(width: 4, height: 4)
            Text(action.listName ?? action.tool.rawValue)
                .micro(Theme.inkFaint)
            if let due = action.due {
                Text("due \(due)").micro(Theme.lamplight.opacity(0.7))
            }
        }
        .transition(.opacity)
    }

    private var removedLine: some View {
        Text("removed")
            .micro(Theme.inkFaint)
            .transition(.opacity)
    }

    private func undo() {
        withAnimation(Motion.slideReceiptOut) {
            store.undo(captureID: captureID, actionID: action.id)
        }
    }
}
