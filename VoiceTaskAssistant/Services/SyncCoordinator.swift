import Foundation
import Combine
import Network

protocol SyncCoordinating {
    var processedTaskPublisher: AnyPublisher<CapturedTask, Never> { get }
    var pendingTasksPublisher: AnyPublisher<[CapturedTask], Never> { get }

    func initialize()
    func enqueue(task: CapturedTask)
    func loadCachedTasks() async -> [CapturedTask]
}

final class SyncCoordinator: SyncCoordinating {
    private let repository: TaskRepository
    private let openAIService: OpenAIProcessing
    private let deskSyncService: DailyDeskSyncService
    private let readingListRepository: ReadingListManaging
    private let queue = DispatchQueue(label: "SyncCoordinator")
    private var syncWorkItem: DispatchWorkItem?
    private var monitor: NWPathMonitor?

    private var cachedTasks: [CapturedTask] = []

    private let processedTaskSubject = PassthroughSubject<CapturedTask, Never>()
    private let pendingTasksSubject = CurrentValueSubject<[CapturedTask], Never>([])

    init(repository: TaskRepository, openAIService: OpenAIProcessing, deskSyncService: DailyDeskSyncService, readingListRepository: ReadingListManaging) {
        self.repository = repository
        self.openAIService = openAIService
        self.deskSyncService = deskSyncService
        self.readingListRepository = readingListRepository
    }

    var processedTaskPublisher: AnyPublisher<CapturedTask, Never> {
        processedTaskSubject.eraseToAnyPublisher()
    }

    var pendingTasksPublisher: AnyPublisher<[CapturedTask], Never> {
        pendingTasksSubject.eraseToAnyPublisher()
    }

    func initialize() {
        Task { @MainActor in
            let tasks = await repository.loadTasks()
            cachedTasks = tasks
            pendingTasksSubject.send(tasks)
            setUpNetworkMonitoring()
            scheduleDailyDeskSync()
        }
    }

    func enqueue(task: CapturedTask) {
        queue.async { [weak self] in
            guard let self else { return }
            self.cachedTasks.append(task)
            self.pendingTasksSubject.send(self.cachedTasks)
            Task {
                try? await self.repository.save(task: task)
                await self.attemptSync()
            }
        }
    }

    func loadCachedTasks() async -> [CapturedTask] {
        await repository.loadTasks()
    }

    private func setUpNetworkMonitoring() {
        monitor = NWPathMonitor()
        monitor?.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            if path.status == .satisfied {
                Task { await self.attemptSync() }
            }
        }
        monitor?.start(queue: queue)
    }

    private func attemptSync() async {
        let pending = cachedTasks.filter { $0.status == .pending || $0.status == .failed }
        guard !pending.isEmpty else { return }

        for var task in pending {
            task.status = .syncing
            await updateCached(task)
            do {
                let structured = try await openAIService.process(task: task)
                task.status = .processed
                task.structured = structured
                await updateCached(task)
                processedTaskSubject.send(task)
                try await repository.update(task: task)
                await deskSyncService.record(task: task)
                await handleReadingReferences(for: task, structured: structured)
            } catch {
                task.status = .failed
                await updateCached(task)
                processedTaskSubject.send(task)
                try? await repository.update(task: task)
            }
        }
    }

    private func handleReadingReferences(for task: CapturedTask, structured: StructuredTask) async {
        for reference in structured.readingList {
            let combinedTags = Array(Set(reference.tags + structured.topics)).sorted()
            let item = ReadingItem(
                title: reference.title,
                url: reference.url,
                tags: combinedTags,
                capturedAt: Date(),
                source: .task,
                relatedTaskID: task.id
            )
            try? await readingListRepository.upsert(item: item)
        }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let matches = detector.matches(
            in: task.rawText,
            options: [],
            range: NSRange(location: 0, length: (task.rawText as NSString).length)
        )
        let referencedURLs = Set(structured.readingList.map { $0.url })
        for match in matches {
            guard let range = Range(match.range, in: task.rawText) else { continue }
            let linkText = String(task.rawText[range])
            guard let url = URL(string: linkText), !referencedURLs.contains(url) else { continue }
            let item = ReadingItem(
                title: structured.summary,
                url: url,
                tags: structured.topics,
                capturedAt: Date(),
                source: .task,
                relatedTaskID: task.id
            )
            try? await readingListRepository.upsert(item: item)
        }
    }

    private func updateCached(_ task: CapturedTask) async {
        if let index = cachedTasks.firstIndex(where: { $0.id == task.id }) {
            cachedTasks[index] = task
        } else {
            cachedTasks.append(task)
        }
        pendingTasksSubject.send(cachedTasks)
    }

    private func scheduleDailyDeskSync() {
        deskSyncService.scheduleMorningSync {
            Task { await self.performDeskSync() }
        }
    }

    private func performDeskSync() async {
        let processed = cachedTasks.filter { $0.status == .processed }
        await deskSyncService.publishDailySummary(tasks: processed)
    }
}
