//
//  Theme.swift
//  FrictionlessNotes
//
//  Stage Whisper design tokens — UI-SPEC.md §1
//

import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}

enum Theme {
    // Stage (backgrounds)
    static let stage0 = Color(hex: 0x000000)        // dead screen — true black
    static let stage1 = Color(hex: 0x15151B)        // cards/sheets level 1
    static let stage2 = Color(hex: 0x1E1E26)        // sheets / popovers
    static let hairline = Color.white.opacity(0.10)

    // Ink
    static let ink = Color(hex: 0xF4F4F8)
    static let inkLedger = Color(hex: 0xC9C9D2)
    static let inkDim = Color(hex: 0x9C9CA8)
    static let inkFaint = Color(hex: 0x5E5E6A)

    // Signals
    static let live = Color(hex: 0xFF4F3D)          // the only saturated red
    static let polish = Color(hex: 0x6FE3C2)
    static let lamplight = Color(hex: 0xFFD66B)

    // Status
    static let statusSaved = Color(hex: 0x8E8E93)
    static let statusUploaded = Color(hex: 0x64B5FF)
    static let statusProcessing = Color(hex: 0xFFD66B)
    static let statusDone = Color(hex: 0x34D17B)
    static let statusReview = Color(hex: 0xFF9F0A)
    static let statusError = Color(hex: 0xFF453A)

    // Spacing (4-pt grid)
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let s6: CGFloat = 24
    static let s7: CGFloat = 32
    static let s8: CGFloat = 40

    static let rCard: CGFloat = 16
    static let rSheet: CGFloat = 24
}

// Typography — the hero transcript is New York (serif); everything else SF Pro.
enum Typography {
    static func heroTranscript(_ size: CGFloat = 28) -> Font {
        .system(size: size, weight: .medium, design: .serif)
    }
    static let ledgerLine = Font.system(size: 16, weight: .regular, design: .serif)
    static let title = Font.system(size: 22, weight: .semibold)
    static let cardTitle = Font.system(size: 17, weight: .semibold)
    static let body = Font.system(size: 17, weight: .regular)
    static let caption = Font.system(size: 13, weight: .regular)
    static let micro = Font.system(size: 11, weight: .medium)
}

// Micro label style: quiet small-caps whisper
struct MicroLabel: ViewModifier {
    var color: Color = Theme.inkFaint
    func body(content: Content) -> some View {
        content
            .font(Typography.micro)
            .textCase(.uppercase)
            .kerning(1.4)
            .foregroundStyle(color)
    }
}

extension View {
    func micro(_ color: Color = Theme.inkFaint) -> some View {
        modifier(MicroLabel(color: color))
    }
}
