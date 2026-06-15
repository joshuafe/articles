//
//  LedgerView.swift
//  FrictionlessNotes
//
//  The day as a quiet ledger — rows of ink on black, status lives in the tick.
//

import SwiftUI

struct LedgerView: View {
    @Environment(CaptureStore.self) private var store

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.s5) {
                if store.reviewCount > 0 {
                    reviewPin
                }
                ForEach(store.captures) { capture in
                    VStack(alignment: .leading, spacing: Theme.s2) {
                        NavigationLink(value: capture.id) {
                            LedgerRowView(capture: capture)
                        }
                        .buttonStyle(.plain)

                        ForEach(capture.actions) { action in
                            FilingReceiptView(captureID: capture.id, action: action)
                                .padding(.leading, Theme.s4)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.s4)
            .padding(.top, Theme.s3)
            .animation(Motion.springCaptureOpen, value: store.captures)
        }
        .scrollIndicators(.hidden)
    }

    private var reviewPin: some View {
        HStack(spacing: Theme.s2) {
            Circle().fill(Theme.statusReview).frame(width: 6, height: 6)
            Text("needs review · \(store.reviewCount)")
                .micro(Theme.inkDim)
        }
        .padding(.bottom, Theme.s1)
    }
}

struct LedgerRowView: View {
    let capture: Capture

    var body: some View {
        HStack(alignment: .center, spacing: Theme.s3) {
            tick

            lineText
                .font(Typography.ledgerLine)
                .foregroundStyle(capture.status == .processing ? Theme.inkFaint : Theme.inkLedger)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(relativeTime)
                .font(Typography.micro)
                .foregroundStyle(Theme.inkFaint)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var tick: some View {
        switch capture.status {
        case .processing, .uploaded:
            BreathingDot(color: capture.provisionalCategory?.tint ?? Theme.statusProcessing)
        case .saved:
            Circle().fill(capture.provisionalCategory?.tint ?? Theme.statusSaved)
                .frame(width: 5, height: 5)
        case .needsReview:
            Circle().fill(Theme.statusReview).frame(width: 5, height: 5)
        case .error:
            Circle().fill(Theme.statusError).frame(width: 5, height: 5)
        case .done:
            RoundedRectangle(cornerRadius: 1)
                .fill((capture.category ?? .note).tint)
                .frame(width: 2, height: 16)
        }
    }

    @ViewBuilder
    private var lineText: some View {
        if let arrived = capture.polishArrivedAt,
           Date.now.timeIntervalSince(arrived) < 1.2,
           let previous = capture.previousTranscript {
            PolishDiffText(oldText: previous,
                           newText: capture.bestTranscript,
                           font: Typography.ledgerLine,
                           baseColor: Theme.inkLedger)
        } else {
            Text(capture.ledgerLine + (capture.kind == .photo ? "  · photo" : ""))
        }
    }

    private var relativeTime: String {
        let seconds = Date.now.timeIntervalSince(capture.createdAt)
        if seconds < 90 { return "now" }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter.string(from: capture.createdAt)
    }
}

struct BreathingDot: View {
    let color: Color
    @State private var bright = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(bright ? 1.0 : 0.45)
            .onAppear {
                withAnimation(Motion.pulseProcessing) { bright = true }
            }
    }
}
