//
//  Haptics.swift
//  FrictionlessNotes
//
//  Haptic vocabulary — UI-SPEC.md §2.
//  One physical sentence per event; never two haptics within 250 ms.
//

import UIKit

@MainActor
enum Haptics {
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let notify = UINotificationFeedbackGenerator()

    private static var lastFired = Date.distantPast

    /// Call alongside the audio pre-warm so generators are ready at t=0.
    static func prepare() {
        rigid.prepare(); soft.prepare(); light.prepare(); notify.prepare()
    }

    private static func gate() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastFired) > 0.25 else { return false }
        lastFired = now
        return true
    }

    /// Record start — single rigid, full strength. Fires at t=0 of capture.
    static func recordStart() {
        guard gate() else { return }
        rigid.impactOccurred(intensity: 1.0)
    }

    /// Record stop — double soft, 80 ms apart. The receipt in your pocket.
    static func recordStop() {
        guard gate() else { return }
        soft.impactOccurred(intensity: 0.7)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            soft.impactOccurred(intensity: 0.7)
        }
    }

    static func captureSaved() {
        guard gate() else { return }
        light.impactOccurred(intensity: 0.6)
    }

    /// Filed — quieter than save.
    static func filed() {
        guard gate() else { return }
        soft.impactOccurred(intensity: 0.5)
    }

    static func correctionLearned() {
        guard gate() else { return }
        light.impactOccurred(intensity: 0.4)
    }

    /// Answer arrived (foreground) — double soft, 120 ms apart.
    static func answerArrived() {
        guard gate() else { return }
        soft.impactOccurred(intensity: 0.5)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            soft.impactOccurred(intensity: 0.5)
        }
    }

    static func checkOff() {
        guard gate() else { return }
        light.impactOccurred(intensity: 0.5)
    }

    static func warning() {
        guard gate() else { return }
        notify.notificationOccurred(.warning)
    }
}
