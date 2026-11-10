import Foundation
import Combine
import SwiftUI

@MainActor
final class TaskCaptureViewModel: ObservableObject {
    @Published private(set) var transcriptionText: String = ""
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var captureStatusMessage: String?
    @Published private(set) var pendingTasks: [CapturedTask] = []
    @Published private(set) var readingSections: [ReadingListSection] = []
    @Published private(set) var suggestedTags: [String] = []
    @Published private(set) var readingListError: String?

    private let speechService: SpeechCaptureServicing
    private let syncCoordinator: SyncCoordinating
    private let readingListManager: ReadingListManaging
    private var cancellables = Set<AnyCancellable>()

    init(speechService: SpeechCaptureServicing, syncCoordinator: SyncCoordinating, readingListManager: ReadingListManaging) {
        self.speechService = speechService
        self.syncCoordinator = syncCoordinator
        self.readingListManager = readingListManager
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
                self?.refreshSuggestedTags()
            }
            .store(in: &cancellables)

        readingListManager.readingItemsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                self?.readingSections = Self.groupReadingItems(items)
            }
            .store(in: &cancellables)
    }

    private func refreshTasks() async {
        let tasks = await syncCoordinator.loadCachedTasks()
        pendingTasks = tasks.sorted(by: { $0.timestamp > $1.timestamp })
        refreshSuggestedTags()
        let items = await readingListManager.loadItems()
        readingSections = Self.groupReadingItems(items)
    }

    private func refreshSuggestedTags() {
        let tags = pendingTasks
            .compactMap { $0.structured?.topics }
            .flatMap { $0 }
        suggestedTags = Array(Set(tags)).sorted()
    }

    func addArticle(title: String, urlString: String, tags: [String]) async -> Bool {
        do {
            _ = try await readingListManager.addManualArticle(title: title, urlString: urlString, tags: tags)
            readingListError = nil
            return true
        } catch {
            readingListError = "Unable to save article. Check the link and try again."
            return false
        }
    }

    func clearReadingListError() {
        readingListError = nil
    }

    private static func groupReadingItems(_ items: [ReadingItem]) -> [ReadingListSection] {
        var grouped: [String: [ReadingItem]] = [:]
        var untagged: [ReadingItem] = []

        for item in items {
            let tags = item.tags
            if tags.isEmpty {
                untagged.append(item)
            } else {
                for tag in tags {
                    grouped[tag, default: []].append(item)
                }
            }
        }

        let tagSections = grouped
            .map { key, value in
                ReadingListSection(id: key, title: key.capitalized, items: value.sorted(by: { $0.capturedAt > $1.capturedAt }))
            }
            .sorted(by: { $0.title < $1.title })

        var sections = tagSections
        if !untagged.isEmpty {
            sections.append(
                ReadingListSection(
                    id: "untagged",
                    title: "Untagged",
                    items: untagged.sorted(by: { $0.capturedAt > $1.capturedAt })
                )
            )
        }

        return sections
    }
}

struct ReadingListSection: Identifiable, Hashable {
    let id: String
    let title: String
    let items: [ReadingItem]
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

struct PreviewReadingListManager: ReadingListManaging {
    var readingItemsPublisher: AnyPublisher<[ReadingItem], Never> {
        Just([
            ReadingItem(title: "Design Systems 101", url: URL(string: "https://example.com/design")!, tags: ["design"], source: .manual)
        ]).eraseToAnyPublisher()
    }

    func loadItems() async -> [ReadingItem] {
        [ReadingItem(title: "Design Systems 101", url: URL(string: "https://example.com/design")!, tags: ["design"], source: .manual)]
    }

    func upsert(item: ReadingItem) async throws {}

    func addManualArticle(title: String, urlString: String, tags: [String]) async throws -> ReadingItem {
        ReadingItem(title: title, url: URL(string: urlString)!, tags: tags, source: .manual)
    }
}
#endif
