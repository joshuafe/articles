import Foundation
import Combine

protocol ReadingListManaging: Sendable {
    var readingItemsPublisher: AnyPublisher<[ReadingItem], Never> { get }
    func loadItems() async -> [ReadingItem]
    func upsert(item: ReadingItem) async throws
    @discardableResult
    func addManualArticle(title: String, urlString: String, tags: [String]) async throws -> ReadingItem
}

enum ReadingListError: Error {
    case invalidURL
}

actor ReadingListRepository: ReadingListManaging {
    private let fileURL: URL
    private var cache: [ReadingItem] = []
    private let fileManager: FileManager
    nonisolated private let subject = CurrentValueSubject<[ReadingItem], Never>([])

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        #if os(iOS)
        let directory = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.example.voicetaskassistant")
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        #else
        let directory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        #endif
        fileURL = directory.appendingPathComponent("readingList.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ReadingItem].self, from: data) {
            cache = decoded
        }
        cache.sort(by: { $0.capturedAt > $1.capturedAt })
        subject.send(cache)
    }

    nonisolated var readingItemsPublisher: AnyPublisher<[ReadingItem], Never> {
        subject.eraseToAnyPublisher()
    }

    func loadItems() async -> [ReadingItem] {
        if cache.isEmpty, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ReadingItem].self, from: data) {
            cache = decoded
            cache.sort(by: { $0.capturedAt > $1.capturedAt })
            subject.send(cache)
        }
        return cache
    }

    func upsert(item: ReadingItem) async throws {
        var normalized = normalize(item: item)
        if let index = cache.firstIndex(where: { $0.url == normalized.url }) {
            var existing = cache[index]
            existing.title = normalized.title.isEmpty ? existing.title : normalized.title
            existing.tags = merge(existing.tags, with: normalized.tags)
            existing.capturedAt = max(existing.capturedAt, normalized.capturedAt)
            existing.source = normalized.source
            existing.relatedTaskID = normalized.relatedTaskID ?? existing.relatedTaskID
            cache[index] = existing
        } else {
            cache.append(normalized)
        }
        try persist()
    }

    @discardableResult
    func addManualArticle(title: String, urlString: String, tags: [String]) async throws -> ReadingItem {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              !url.absoluteString.isEmpty else {
            throw ReadingListError.invalidURL
        }
        let item = ReadingItem(
            title: title.isEmpty ? url.absoluteString : title,
            url: url,
            tags: normalize(tags: tags),
            capturedAt: Date(),
            source: .manual,
            relatedTaskID: nil
        )
        try await upsert(item: item)
        return item
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        cache = cache.sorted(by: { $0.capturedAt > $1.capturedAt })
        let data = try encoder.encode(cache)
        try data.write(to: fileURL, options: [.atomic])
        subject.send(cache)
    }

    private func normalize(item: ReadingItem) -> ReadingItem {
        var normalized = item
        normalized.tags = normalize(tags: item.tags)
        return normalized
    }

    private func normalize(tags: [String]) -> [String] {
        Array(
            Set(
                tags
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
    }

    private func merge(_ lhs: [String], with rhs: [String]) -> [String] {
        Array(Set(lhs + rhs)).sorted()
    }
}
