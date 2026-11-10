import Foundation
import SwiftUI

@MainActor
final class DeskCompanionViewModel: ObservableObject {
    @Published private(set) var tasks: [DailySummary.TaskEntry] = []
    @Published private(set) var readingSections: [ReadingSection] = []
    @Published private(set) var suggestedTags: [String] = []
    @Published private(set) var readingListError: String?

    private let reader = DailySummaryReader()
    private let readingClient = ReadingListClient()

    func loadDailySummary() async {
        do {
            let summary = try await reader.readSummary()
            tasks = summary.tasks
            suggestedTags = extractTags(from: summary.tasks)
            readingSections = Self.groupReadingItems(summary.readingList.map { $0.asReadingItem() })
        } catch {
            tasks = []
            readingSections = []
            suggestedTags = []
        }
    }

    func refresh() {
        Task {
            await loadDailySummary()
            await loadReadingList()
        }
    }

    func loadReadingList() async {
        do {
            let items = try readingClient.loadItems()
            readingSections = Self.groupReadingItems(items)
            readingListError = nil
        } catch {
            readingListError = "Unable to load reading list."
        }
    }

    func addArticle(title: String, url: String, tags: [String]) {
        do {
            _ = try readingClient.addArticle(title: title, urlString: url, tags: tags)
            readingListError = nil
            Task { await loadReadingList() }
        } catch {
            readingListError = "Could not save article. Check the link."
        }
    }

    private func extractTags(from tasks: [DailySummary.TaskEntry]) -> [String] {
        Array(
            Set(
                tasks
                    .flatMap { $0.topics }
                    .map { $0.lowercased() }
            )
        ).sorted()
    }

    private static func groupReadingItems(_ items: [ReadingItem]) -> [ReadingSection] {
        var grouped: [String: [ReadingItem]] = [:]
        var untagged: [ReadingItem] = []

        for item in items {
            if item.tags.isEmpty {
                untagged.append(item)
            } else {
                for tag in item.tags {
                    grouped[tag, default: []].append(item)
                }
            }
        }

        let sections = grouped
            .map { key, value in
                ReadingSection(id: key, title: key.capitalized, items: value.sorted(by: { $0.capturedAt > $1.capturedAt }))
            }
            .sorted(by: { $0.title < $1.title })

        var allSections = sections
        if !untagged.isEmpty {
            allSections.append(
                ReadingSection(
                    id: "untagged",
                    title: "Untagged",
                    items: untagged.sorted(by: { $0.capturedAt > $1.capturedAt })
                )
            )
        }
        return allSections
    }
}

struct DailySummaryReader {
    private let appGroupIdentifier = "group.com.example.voicetaskassistant"

    func readSummary() async throws -> DailySummary {
        let url = try await summaryURL()
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(DailySummary.self, from: data)
    }

    private func summaryURL() async throws -> URL {
        #if os(macOS)
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return containerURL.appendingPathComponent("dailySummary.json")
        }
        #endif
        let fallback = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("dailySummary.json")
        if !FileManager.default.fileExists(atPath: fallback.path) {
            FileManager.default.createFile(atPath: fallback.path, contents: nil)
        }
        return fallback
    }
}

struct ReadingSection: Identifiable, Hashable {
    let id: String
    let title: String
    let items: [ReadingItem]
}

private extension DailySummary.ReadingEntry {
    func asReadingItem() -> ReadingItem {
        ReadingItem(
            id: id,
            title: title,
            url: url,
            tags: tags,
            capturedAt: capturedAt,
            source: source
        )
    }
}
