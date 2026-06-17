//
//  FrictionlessNotesApp.swift
//  FrictionlessNotes
//
//  Created by Joshua Fein on 12/29/25.
//  Round 1: always-listening home against the mock pipeline.
//  SwiftData + CloudKit arrive in round 2 (DESIGN.md build order step 2).
//

import SwiftUI

/// Captures the system completion handler when iOS relaunches the app in the
/// background to finish the model download.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            ModelDownloader.shared.backgroundCompletionHandler = completionHandler
        }
    }
}

@main
@MainActor
struct FrictionlessNotesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = CaptureStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(.dark)
        }
    }
}

/// Holds the icon-to-home hand-off: the splash waveform fades up, then dissolves
/// into the home, which is already black underneath — one continuous open.
struct RootView: View {
    @State private var showSplash = true

    var body: some View {
        ZStack {
            NavigationStack {
                HomeView()
            }
            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(1100))
            withAnimation(.easeInOut(duration: 0.5)) { showSplash = false }
        }
    }
}
