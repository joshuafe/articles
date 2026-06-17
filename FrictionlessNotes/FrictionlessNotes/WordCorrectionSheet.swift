//
//  WordCorrectionSheet.swift
//  FrictionlessNotes
//
//  M5 · Tap-to-correct (UI-SPEC.md §detail, DESIGN.md §personal lexicon).
//  The hero transcript becomes a field of individually tappable words; tapping
//  one opens this sheet — candidate chips drawn from what the user has already
//  taught, plus a free field. Saving patches the transcript and teaches the
//  lexicon a (heard → meant) pair. A quiet 2 s toast confirms.
//

import SwiftUI

// MARK: - Tappable transcript

/// The hero transcript rendered as wrap-flowing, individually tappable words.
/// Visual match to the plain hero `Text`; each word reports its index on tap.
struct TappableTranscript: View {
    let text: String
    var size: CGFloat = 28
    var onTapWord: (_ index: Int, _ word: String) -> Void

    var body: some View {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        FlowLayout(lineSpacing: 7, wordSpacing: 0) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                Button {
                    onTapWord(index, token)
                } label: {
                    // Trailing space keeps natural word gaps and the tap target wide.
                    Text(index < tokens.count - 1 ? token + " " : token)
                        .font(Typography.heroTranscript(size))
                        .foregroundStyle(Theme.ink)
                        .kerning(-0.5)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Minimal wrapping layout — flows subviews left→right, wrapping on overflow.
struct FlowLayout: Layout {
    var lineSpacing: CGFloat = 6
    var wordSpacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layout(subviews, maxWidth: maxWidth)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: maxWidth == .infinity ? 0 : maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = layout(subviews, maxWidth: bounds.width)
        for item in rows {
            subviews[item.index].place(
                at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + item.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(item.size))
        }
    }

    private struct Placed { let index: Int; let x: CGFloat; let y: CGFloat; let size: CGSize
        var height: CGFloat { size.height } }

    private func layout(_ subviews: Subviews, maxWidth: CGFloat) -> [Placed] {
        var placed: [Placed] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            placed.append(Placed(index: index, x: x, y: y, size: size))
            x += size.width + wordSpacing
            lineHeight = max(lineHeight, size.height)
        }
        return placed
    }
}

// MARK: - Correction sheet

struct WordCorrectionSheet: View {
    let heardWord: String
    let candidates: [String]
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool
    @State private var text: String

    init(heardWord: String, candidates: [String], onSave: @escaping (String) -> Void) {
        self.heardWord = heardWord
        self.candidates = candidates
        self.onSave = onSave
        _text = State(initialValue: heardWord)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s5) {
            Text("correct this word")
                .micro(Theme.inkFaint)

            TextField("", text: $text)
                .font(Typography.heroTranscript(28))
                .foregroundStyle(Theme.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .submitLabel(.done)
                .onSubmit(save)
                .padding(.bottom, Theme.s2)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                }

            if !suggestionChips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.s2) {
                        ForEach(suggestionChips, id: \.self) { candidate in
                            Button { text = candidate } label: {
                                Text(candidate)
                                    .font(Typography.caption)
                                    .foregroundStyle(Theme.polish)
                                    .padding(.horizontal, Theme.s3)
                                    .padding(.vertical, Theme.s2)
                                    .background(Theme.polish.opacity(0.10),
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("save", action: save)
                    .font(Typography.body)
                    .foregroundStyle(trimmed.isEmpty ? Theme.inkFaint : Theme.polish)
                    .buttonStyle(.plain)
                    .disabled(trimmed.isEmpty)
            }
            .padding(.top, Theme.s2)
        }
        .padding(Theme.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.stage2)
        .onAppear { fieldFocused = true }
    }

    /// Learned terms plus a capitalized form, minus the word as-heard.
    private var suggestionChips: [String] {
        var seen = Set<String>([heardWord.lowercased()])
        var chips: [String] = []
        let capitalized = heardWord.prefix(1).uppercased() + heardWord.dropFirst()
        for c in [capitalized] + candidates {
            let key = c.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            chips.append(c)
        }
        return Array(chips.prefix(6))
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}
