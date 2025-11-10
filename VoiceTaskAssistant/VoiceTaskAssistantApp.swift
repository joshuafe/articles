import SwiftUI
import Combine

@main
struct VoiceTaskAssistantApp: App {
    @StateObject private var viewModel = TaskCaptureViewModel(
        speechService: SpeechCaptureService(),
        syncCoordinator: SyncCoordinator(
            repository: TaskRepository(),
            openAIService: OpenAIService(),
            deskSyncService: DailyDeskSyncService()
        )
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
    }
}
