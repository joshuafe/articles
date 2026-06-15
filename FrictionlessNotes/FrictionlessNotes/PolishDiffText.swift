//
//  PolishDiffText.swift
//  FrictionlessNotes
//
//  M2 · The Polish Sweep — word-level LCS diff; changed tokens ignite in
//  `polish` and decay to ink over 600 ms. Height-stable: the base text renders
//  final ink immediately; the highlight is an overlay with identical metrics
//  that fades out (opacity is animatable; attributed colors are not).
//  Per-token left→right stagger is a round-2 refinement.
//

import SwiftUI

struct PolishDiffText: View {
    let oldText: String
    let newText: String
    var font: Font = Typography.heroTranscript(28)
    var baseColor: Color = Theme.ink

    @State private var ignited = true

    var body: some View {
        let tokens = newText.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let changed = Self.changedTokenIndices(old: oldText, new: newText)

        ZStack(alignment: .topLeading) {
            Text(attributed(tokens: tokens, changed: changed, layer: .base))
                .font(font)
                .lineSpacing(6)
            Text(attributed(tokens: tokens, changed: changed, layer: .highlight))
                .font(font)
                .lineSpacing(6)
                .opacity(ignited ? 1 : 0)
        }
        .onAppear {
            withAnimation(Motion.shimmerPolish.delay(0.15)) {
                ignited = false
            }
        }
    }

    private enum Layer { case base, highlight }

    private func attributed(tokens: [String], changed: Set<Int>, layer: Layer) -> AttributedString {
        var result = AttributedString()
        for (i, token) in tokens.enumerated() {
            var piece = AttributedString(token)
            switch layer {
            case .base:
                piece.foregroundColor = baseColor
            case .highlight:
                if changed.contains(i) {
                    piece.foregroundColor = Theme.polish
                    piece.underlineStyle = .single
                    piece.backgroundColor = Theme.polish.opacity(0.12)
                } else {
                    piece.foregroundColor = .clear
                }
            }
            result += piece
            if i < tokens.count - 1 { result += AttributedString(" ") }
        }
        return result
    }

    /// Word-level LCS: indices in `new` that aren't part of the common subsequence.
    static func changedTokenIndices(old: String, new: String) -> Set<Int> {
        let a = old.split(separator: " ").map { normalize(String($0)) }
        let b = new.split(separator: " ").map { normalize(String($0)) }
        guard !a.isEmpty, !b.isEmpty else { return Set(b.indices) }

        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j]
                    ? dp[i + 1][j + 1] + 1
                    : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var common = Set<Int>()
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                common.insert(j); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return Set(b.indices).subtracting(common)
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }
}
