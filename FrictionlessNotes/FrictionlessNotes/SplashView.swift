//
//  SplashView.swift
//  FrictionlessNotes
//
//  The icon, alive. The static black launch screen hands off to this: the small
//  waveform breathes up out of the dark, then dissolves into the home — so the
//  app open reads as one continuous motion from icon to first frame.
//

import SwiftUI

struct SplashView: View {
    @State private var lit = false

    // Same proportions as the app icon's de-emphasized mark.
    private let heights: [CGFloat] = [26,46,72,52,96,64,118,80,118,64,96,52,72,46,26]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.stage0.ignoresSafeArea()
                Canvas { ctx, size in
                    let barW: CGFloat = 4
                    let gap: CGFloat = 5
                    let n = heights.count
                    let total = CGFloat(n) * barW + CGFloat(n - 1) * gap
                    let startX = (size.width - total) / 2 + barW / 2
                    let baseline = size.height * 0.70
                    let maxH = heights.max() ?? 1
                    for (i, h) in heights.enumerated() {
                        let scaled = (h / maxH) * 44 * (lit ? 1 : 0.06)
                        let falloff = 1 - pow(abs(CGFloat(i) - CGFloat(n - 1) / 2) / (CGFloat(n - 1) / 2), 1.6)
                        let x = startX + CGFloat(i) * (barW + gap)
                        let rect = CGRect(x: x - barW / 2, y: baseline - scaled / 2,
                                          width: barW, height: scaled)
                        let path = Path(roundedRect: rect, cornerRadius: barW / 2)
                        ctx.fill(path, with: .color(Theme.live.opacity(max(falloff, 0.22) * (lit ? 1 : 0))))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { lit = true }
        }
    }
}
