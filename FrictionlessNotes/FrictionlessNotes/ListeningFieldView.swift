//
//  ListeningFieldView.swift
//  FrictionlessNotes
//
//  M1 · The Listening Field — UI-SPEC.md §3.
//  Waveform horizon + live New York typesetting + thinking dim.
//  Silence is thinking, never a countdown.
//

import SwiftUI

struct ListeningFieldView: View {
    @Environment(CaptureStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Live draft, typeset in New York — the one expressive moment.
            if !store.draft.isEmpty {
                Text(store.draft)
                    .font(Typography.heroTranscript(23))
                    .foregroundStyle(Theme.ink)
                    .kerning(-0.3)
                    .lineSpacing(6)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.s5)
                    .padding(.bottom, Theme.s5)
                    .lineLimit(5)
            } else {
                Caret()
                    .padding(.horizontal, Theme.s5)
                    .padding(.bottom, Theme.s5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            WaveformHorizon(levels: store.levels)
                .frame(height: 96)
                .padding(.horizontal, Theme.s4)

            Text(store.thinking ? "still with you" : "listening")
                .micro()
                .padding(.top, Theme.s2)
                .padding(.bottom, Theme.s6)
        }
        .opacity(store.thinking ? 0.75 : 1.0)
        .animation(Motion.dimThinking, value: store.thinking)
        .contentShape(Rectangle())
        .onTapGesture { store.endCapture() } // tap = explicit stop
        .background(Theme.stage0)
    }
}

private struct Caret: View {
    @State private var visible = true
    var body: some View {
        Rectangle()
            .fill(Theme.live)
            .frame(width: 2, height: 22)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}

/// 44 bars, center-weighted falloff, drawn at display cadence.
struct WaveformHorizon: View {
    let levels: [Float]
    @State private var grown = false

    var body: some View {
        Canvas { context, size in
            let count = 44
            let barWidth: CGFloat = 3
            let gap = (size.width - CGFloat(count) * barWidth) / CGFloat(count - 1)
            let baseline = size.height * 0.62

            for i in 0..<count {
                let level = i < levels.count ? CGFloat(levels[i]) : 0
                let mapped = 4 + (96 - 4) * pow(level, 0.7)
                let height = min(mapped, size.height) * (grown ? 1 : 0.04)
                let falloff = 1 - pow(abs(CGFloat(i) - 22) / 22, 1.6)
                let x = CGFloat(i) * (barWidth + gap)
                let rect = CGRect(x: x, y: baseline - height / 2, width: barWidth, height: height)
                let path = Path(roundedRect: rect, cornerRadius: 1.5)
                context.fill(path, with: .color(Theme.live.opacity(max(falloff, 0.12))))
            }
        }
        .onAppear {
            // Bars grow *after* recording already started; haptic fired at t=0.
            withAnimation(.easeOut(duration: 0.25)) { grown = true }
        }
    }
}
