import Foundation
import Combine
import SwiftUI

@MainActor
final class TaskCaptureViewModel: ObservableObject {
    @Published private(set) var transcriptionText: String = ""
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var captureStatusMessage: String?
    @Published private(set) var pendingTasks: [CapturedTask] = []

    private let speechService: SpeechCaptureServicing
    private let syncCoordinator: SyncCoordinating
    private var cancellables = Set<AnyCancellable>()

    init(speechService: SpeechCaptureServicing, syncCoordinator: SyncCoordinating) {
        self.speechService = speechService
        self.syncCoordinator = syncCoordinator
        bind()
    }

    func startup() {
        syncCoordinator.initialize()
        Task { await refreshTasks() }
    }

    func resume() {
        Task { await refreshTasks() }
    }

    func toggleCapture() {
        if isRecording {
            stopCapture()
        } else {
            startCapture()
        }
    }

    private func startCapture() {
        captureStatusMessage = "Listening…"
        speechService.startRecording()
    }

    private func stopCapture() {
        speechService.stopRecording()
    }

    private func bind() {
        speechService.transcriptionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                self?.transcriptionText = update.text
                self?.isRecording = update.isRecording
                self?.captureStatusMessage = update.statusMessage
            }
            .store(in: &cancellables)

        speechService.capturedTaskPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] task in
                guard let self else { return }
                self.transcriptionText = ""
                self.captureStatusMessage = "Saved for sync"
                self.pendingTasks.insert(task, at: 0)
                self.syncCoordinator.enqueue(task: task)
            }
            .store(in: &cancellables)

        syncCoordinator.processedTaskPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] task in
                guard let index = self?.pendingTasks.firstIndex(where: { $0.id == task.id }) else { return }
                self?.pendingTasks[index] = task
            }
            .store(in: &cancellables)

        syncCoordinator.pendingTasksPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tasks in
                self?.pendingTasks = tasks
            }
            .store(in: &cancellables)
    }

    private func refreshTasks() async {
        let tasks = await syncCoordinator.loadCachedTasks()
        pendingTasks = tasks.sorted(by: { $0.timestamp > $1.timestamp })
    }
}

#if DEBUG
struct PreviewSpeechService: SpeechCaptureServicing {
    var transcriptionPublisher: AnyPublisher<SpeechTranscriptionUpdate, Never> {
        Just(SpeechTranscriptionUpdate(text: "Buy groceries", isRecording: false, statusMessage: "Preview"))
            .eraseToAnyPublisher()
    }

    var capturedTaskPublisher: AnyPublisher<CapturedTask, Never> {
        Empty().eraseToAnyPublisher()
    }

    func startRecording() {}
    func stopRecording() {}
}

struct PreviewSyncCoordinator: SyncCoordinating {
    var processedTaskPublisher: AnyPublisher<CapturedTask, Never> { Empty().eraseToAnyPublisher() }
    var pendingTasksPublisher: AnyPublisher<[CapturedTask], Never> {
        Just([CapturedTask(rawText: "Pick up dry cleaning")]).eraseToAnyPublisher()
    }

    func initialize() {}
    func enqueue(task: CapturedTask) {}
    func loadCachedTasks() async -> [CapturedTask] { [CapturedTask(rawText: "Pick up dry cleaning")] }
}
#endif
