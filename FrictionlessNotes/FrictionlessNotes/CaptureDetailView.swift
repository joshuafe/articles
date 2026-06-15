//
//  CaptureDetailView.swift
//  FrictionlessNotes
//
//  One hero text; machinery behind a single disclosure.
//

import SwiftUI

struct CaptureDetailView: View {
    @Environment(CaptureStore.self) private var store
    let captureID: UUID

    @State private var detailsOpen = false
    @State private var correctionTarget: WordTarget?

    /// Identifies the tapped word for the correction sheet.
    private struct WordTarget: Identifiable {
        let id = UUID()
        let index: Int
        let word: String
    }

    private var capture: Capture? {
        store.captures.first { $0.id == captureID }
    }

    var body: some View {
        ZStack {
            Theme.stage0.ignoresSafeArea()
            if let capture {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.s5) {
                        hero(capture)
                        LifecycleChip(status: capture.status)

                        if capture.status == .needsReview {
                            reviewCard(capture)
                        }

                        ForEach(capture.actions) { action in
                            FilingReceiptView(captureID: capture.id, action: action)
                        }

                        details(capture)
                        Spacer(minLength: Theme.s8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.s5)
                }
                .scrollIndicators(.hidden)
            }

            if let toast = store.correctionToast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, Theme.s4)
                        .padding(.vertical, Theme.s3)
                        .background(Theme.stage2, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                        .padding(.bottom, Theme.s7)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .allowsHitTesting(false)
            }
        }
        .toolbarBackground(Theme.stage0, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(item: $correctionTarget) { target in
            WordCorrectionSheet(
                heardWord: target.word.trimmingCharacters(in: .punctuationCharacters),
                candidates: store.lexicon.promptTerms()
            ) { meant in
                store.applyCorrection(captureID: captureID,
                                      wordIndex: target.index, to: meant)
            }
        }
    }

    @ViewBuilder
    private func hero(_ capture: Capture) -> some View {
        if let arrived = capture.polishArrivedAt,
           Date.now.timeIntervalSince(arrived) < 4,
           let previous = capture.previousTranscript {
            PolishDiffText(oldText: previous, newText: capture.bestTranscript)
        } else {
            // Tap any word to correct it — patches the text and teaches the lexicon.
            TappableTranscript(text: capture.bestTranscript) { index, word in
                correctionTarget = WordTarget(index: index, word: word)
            }
        }
    }

    private func reviewCard(_ capture: Capture) -> some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            if let guess = capture.reviewGuess, let reason = capture.reviewReason {
                Text("looks like a \(guess.rawValue) — \(reason)")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.inkDim)
                HStack(spacing: Theme.s3) {
                    Button("accept") {
                        store.resolveReview(captureID: capture.id, as: guess)
                    }
                    .font(Typography.caption)
                    .foregroundStyle(Theme.polish)
                    .buttonStyle(.plain)

                    Menu {
                        ForEach(NoteCategory.allCases, id: \.self) { category in
                            Button(category.rawValue) {
                                store.resolveReview(captureID: capture.id, as: category)
                            }
                        }
                    } label: {
                        Text("other…")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.inkDim)
                    }
                }
            }
        }
        .padding(Theme.s4)
        .background(Theme.stage1, in: RoundedRectangle(cornerRadius: Theme.rCard))
        .overlay(RoundedRectangle(cornerRadius: Theme.rCard).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }

    private func details(_ capture: Capture) -> some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            Button {
                withAnimation(Motion.fadeStatus) { detailsOpen.toggle() }
            } label: {
                Text(detailsOpen ? "details —" : "details +")
                    .micro(Theme.inkFaint)
            }
            .buttonStyle(.plain)

            if detailsOpen {
                VStack(alignment: .leading, spacing: Theme.s3) {
                    detailField("heard", capture.deviceTranscript)
                    if let summary = capture.summary {
                        detailField("summary", summary)
                    }
                    if let category = capture.category {
                        detailField("category", category.rawValue)
                    }
                    detailField("kind", capture.kind.rawValue)
                }
                .transition(.opacity)
            }
        }
        .padding(.top, Theme.s4)
    }

    private func detailField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).micro(Theme.inkFaint)
            Text(value)
                .font(Typography.caption)
                .foregroundStyle(Theme.inkDim)
        }
    }
}

struct LifecycleChip: View {
    let status: CaptureStatus
    @State private var visible = true

    var body: some View {
        HStack(spacing: Theme.s2) {
            if status == .processing || status == .uploaded {
                BreathingDot(color: status.tint)
            } else {
                Circle().fill(status.tint).frame(width: 6, height: 6)
            }
            Text(status.label).micro(Theme.inkDim)
        }
        .opacity(visible ? 1 : 0)
        .task(id: status) {
            visible = true
            if status == .done {
                try? await Task.sleep(for: .seconds(3))
                withAnimation(Motion.fadeStatus) { visible = false }
            }
        }
    }
}
