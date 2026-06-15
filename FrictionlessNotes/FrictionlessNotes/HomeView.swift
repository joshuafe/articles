//
//  HomeView.swift
//  FrictionlessNotes
//
//  Home — the always-listening Ledger. No tab bar, no record button.
//  Speak → the room goes dark (M1). Pull down → keyboard. UI-SPEC.md §4.1.
//

import SwiftUI

struct HomeView: View {
    @Environment(CaptureStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var composerFocused: Bool
    @State private var composerText = ""

    private var isLive: Bool { store.listening == .live }

    var body: some View {
        ZStack {
            Theme.stage0.ignoresSafeArea()

            // The quiet stage: date, ledger, horizon.
            VStack(spacing: 0) {
                dateline
                    .padding(.top, Theme.s2)
                    .padding(.bottom, Theme.s4)

                if store.captures.isEmpty && !isLive {
                    firstRun
                } else {
                    LedgerView()
                }

                Spacer(minLength: 0)

                bottomWhisper
                if store.macStatus.isNoteworthy {
                    MacStatusPill(status: store.macStatus)
                        .padding(.bottom, Theme.s2)
                }
                ListeningHorizon(live: isLive, muted: store.earsMuted)
                    .padding(.top, Theme.s3)
                    .padding(.bottom, store.showDebugBar ? Theme.s8 : Theme.s3)
                    .contentShape(Rectangle())
                    .onTapGesture { store.toggleEarsMuted() }
            }
            .opacity(isLive ? 0 : 1)
            .animation(Motion.roomGoesDark, value: isLive)

            // The room gone dark: the Listening Field.
            if isLive {
                ListeningFieldView()
                    .transition(.opacity)
                    .zIndex(1)
            }

            if store.showComposer {
                composer
                    .zIndex(2)
            }

            // Debug bar stays on top of everything, incl. the live Listening Field,
            // so endpoint signals can be sent mid-capture.
            if store.showDebugBar {
                VStack {
                    Spacer()
                    DebugBar()
                        .padding(.bottom, Theme.s1)
                }
                .zIndex(3)
            }
        }
        .animation(Motion.roomGoesDark, value: isLive)
        .gesture(pullDownToType)
        .onTapGesture(count: 3) { store.showDebugBar.toggle() }
        .navigationDestination(for: UUID.self) { id in
            CaptureDetailView(captureID: id)
        }
        .task { await store.startEars() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                store.endCapture()
            case .active:
                // Resume an interrupted model download / restart the mic.
                if store.ears.needsStart {
                    Task { await store.startEars() }
                }
            default:
                break
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(false)
        .preferredColorScheme(.dark)
    }

    // MARK: Pieces

    private var dateline: some View {
        VStack(spacing: Theme.s1) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .micro()
            if let status = store.earsStatus {
                Text(status)
                    .micro(Theme.lamplight.opacity(0.7))
                    .onTapGesture {
                        Task { await store.startEars() }
                    }
            }
            if let status = store.brainStatus {
                BrainStatusLine(text: status, progress: store.brainProgress)
                    .onTapGesture { store.retryBrain() }
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var firstRun: some View {
        VStack {
            Spacer()
            Text("Say something. I\u{2019}ll do the rest.")
                .font(Typography.ledgerLine)
                .foregroundStyle(Theme.inkFaint)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var bottomWhisper: some View {
        Group {
            if store.earsMuted {
                Text("hushed — tap the light to listen")
            } else if store.brainStatus != nil && store.processingCount > 0 {
                Text("waiting for the brain")
            } else if store.processingCount > 0 {
                Text(store.processingCount == 1 ? "one polishing" : "\(store.processingCount) polishing")
            } else if !store.captures.isEmpty {
                Text("everything handled")
            }
        }
        .micro()
        .padding(.bottom, Theme.s3)
    }

    private var composer: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.s3) {
                TextField("", text: $composerText, axis: .vertical)
                    .focused($composerFocused)
                    .font(Typography.heroTranscript(20))
                    .foregroundStyle(Theme.ink)
                    .tint(Theme.live)
                    .lineLimit(1...4)
                    .onSubmit(submitComposer)

                Button(action: submitComposer) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(composerText.isEmpty ? Theme.inkFaint : Theme.ink)
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.s4)
            .background(Theme.stage1, in: RoundedRectangle(cornerRadius: Theme.rCard))
            .overlay(RoundedRectangle(cornerRadius: Theme.rCard).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .padding(.horizontal, Theme.s4)
            .padding(.top, Theme.s8)

            Spacer()
        }
        .background(Theme.stage0.opacity(0.65).onTapGesture { closeComposer() })
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var pullDownToType: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                guard !isLive, !store.showComposer else { return }
                if value.translation.height > 60 && abs(value.translation.width) < 80 {
                    withAnimation(Motion.springCaptureOpen) { store.showComposer = true }
                    composerFocused = true
                }
            }
    }

    private func submitComposer() {
        store.captureText(composerText)
        closeComposer()
    }

    private func closeComposer() {
        composerText = ""
        composerFocused = false
        withAnimation(Motion.fadeStatus) { store.showComposer = false }
    }
}

/// The 1 pt baseline of light — the always-on promise that it's listening.
struct ListeningHorizon: View {
    var live: Bool
    var muted: Bool = false
    @State private var bright = false

    var body: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(Theme.live)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.s6)
            .opacity(muted ? 0.04 : (bright ? 0.18 : 0.10))
            .animation(Motion.fadeStatus, value: muted)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                    bright = true
                }
            }
    }
}

/// The Gemma download / warm-up line — a quiet status with a slim, determinate
/// progress thread while the ~1 GB weights stream in on first launch.
struct BrainStatusLine: View {
    let text: String
    var progress: Double?

    var body: some View {
        VStack(spacing: 4) {
            Text(text)
                .micro(Theme.lamplight.opacity(0.7))
            if let progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.hairline)
                        Capsule().fill(Theme.lamplight.opacity(0.6))
                            .frame(width: max(2, geo.size.width * progress))
                    }
                }
                .frame(width: 120, height: 2)
                .animation(Motion.fadeStatus, value: progress)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

struct MacStatusPill: View {
    let status: MacStatus

    var body: some View {
        Text(status.line)
            .micro(Theme.inkDim)
            .padding(.horizontal, Theme.s3)
            .padding(.vertical, Theme.s1)
            .background(Theme.stage2, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// Round 1 "simulator keys" — the MockEndpointer's keyboard. Triple-tap to hide.
struct DebugBar: View {
    @Environment(CaptureStore.self) private var store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.s2) {
                debugButton("voice") { store.voiceBegan(script: .metformin) }
                debugButton("shopping") { store.voiceBegan(script: .shopping) }
                debugButton("2-thought") { store.voiceBegan(script: .twoThoughts) }
                debugButton("think") { store.sendEndpoint(.thinkingSilence) }
                debugButton("resume") { store.sendEndpoint(.voiceResumed) }
                debugButton("disposal") { store.sendEndpoint(.disposalDetected) }
                debugButton("pocket") { store.sendEndpoint(.pocketed) }
                debugButton(store.macOffline ? "mac: off" : "mac: on") { store.toggleOffline() }
            }
            .padding(.horizontal, Theme.s4)
        }
    }

    private func debugButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Typography.micro)
                .foregroundStyle(Theme.inkFaint)
                .padding(.horizontal, Theme.s2)
                .padding(.vertical, Theme.s1)
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
