import SwiftUI

@main
struct ReminderBoardApp: App {
    @StateObject private var captureCoordinator = ReminderCaptureCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(captureCoordinator)
                .task {
                    await captureCoordinator.prepareAudioSession()
                }
        }
        .defaultSize(width: 480, height: 640)
    }
}
