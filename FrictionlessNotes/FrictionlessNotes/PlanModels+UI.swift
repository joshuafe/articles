//
//  PlanModels+UI.swift
//  FrictionlessNotes
//
//  Stage Whisper colours for the PlanCore types (the package itself has no UI).
//  Five colours, one meaning each (DESIGN-PM.md §3): green on track, lamplight
//  at risk or slipping, the only red for a hard deadline that will be missed.
//

import SwiftUI

extension Project {
    var tint: Color { Color(hex: colourHex) }
}

extension TargetState {
    var tint: Color {
        switch self {
        case .onTrack, .done: Theme.statusDone
        case .atRisk, .slipping: Theme.lamplight
        case .willMiss: Theme.statusError
        case .backlog: Theme.inkFaint
        }
    }
}

extension DeadlineKind {
    var tint: Color {
        switch self {
        case .hard: Theme.ink
        case .goal: Theme.inkDim
        case .none: Theme.inkFaint
        }
    }
}

enum PlanFormat {
    /// "Mon Nov 9"
    static func day(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// "Nov 9" — for narrow columns
    static func shortDay(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "1 h 30 m" / "45 m"
    static func minutes(_ m: Int) -> String {
        let h = m / 60, r = m % 60
        if h == 0 { return "\(r) m" }
        return r == 0 ? "\(h) h" : "\(h) h \(r) m"
    }

    static func slack(_ days: Int?) -> String {
        guard let days else { return "" }
        if days < 0 { return "\(-days) d late" }
        return "\(days) d slack"
    }
}
