import SwiftUI
import Combine

@main
struct VoiceTaskAssistantApp: App {
    @StateObject private var viewModel: TaskCaptureViewModel

    init() {
        let readingRepository = ReadingListRepository()
        let deskSyncService = DailyDeskSyncService(readingRepository: readingRepository)
        let coordinator = SyncCoordinator(
            repository: TaskRepository(),
            openAIService: OpenAIService(),
            deskSyncService: deskSyncService,
            readingListRepository: readingRepository
        )
        _viewModel = StateObject(
            wrappedValue: TaskCaptureViewModel(
                speechService: SpeechCaptureService(),
                syncCoordinator: coordinator,
                readingListManager: readingRepository
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
    }
}
