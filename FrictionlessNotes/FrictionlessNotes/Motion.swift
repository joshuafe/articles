//
//  Motion.swift
//  FrictionlessNotes
//
//  Stage Whisper motion system — UI-SPEC.md §2
//  All springs interruptible; durations are decays, never gates.
//  The capture hot path never animates.
//

import SwiftUI

enum Motion {
    /// Capture chrome settling in after recording is already live; sheets.
    static let springCaptureOpen = Animation.spring(response: 0.32, dampingFraction: 0.86)

    /// Ledger fades out as the Listening Field rises. 250 ms.
    static let roomGoesDark = Animation.easeInOut(duration: 0.25)

    /// Polish diff highlight decay. 600 ms per token; 18 ms stagger handled per-token.
    static let shimmerPolish = Animation.easeOut(duration: 0.6)
    static let shimmerStagger: Double = 0.018

    /// Filing receipt entrance / exit.
    static let slideReceiptIn = Animation.spring(response: 0.38, dampingFraction: 0.80)
    static let slideReceiptOut = Animation.easeIn(duration: 0.25)
    static let receiptVisibleSeconds: Double = 5.0

    /// List check-off.
    static let checkOff = Animation.easeOut(duration: 0.2)

    /// Breathing for processing dots and "thinking on your Mac…". 1.8 s loop.
    static let pulseProcessing = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)

    /// Thinking-silence dim. 400 ms in, holds.
    static let dimThinking = Animation.easeOut(duration: 0.4)

    /// Chip transitions, done-chip departure.
    static let fadeStatus = Animation.easeInOut(duration: 0.3)

    /// The only hero transition: bars collapse into the new ledger row. 350 ms.
    static let collapseToRow = Animation.easeInOut(duration: 0.35)
}
