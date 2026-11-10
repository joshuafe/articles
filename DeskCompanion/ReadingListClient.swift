import Foundation

struct ReadingListClient {
    private let appGroupIdentifier = "group.com.example.voicetaskassistant"
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func loadItems() throws -> [ReadingItem] {
        let url = try storageURL()
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let decoded = try JSONDecoder().decode([ReadingItem].self, from: data)
        return decoded.sorted(by: { $0.capturedAt > $1.capturedAt })
    }

    func addArticle(title: String, urlString: String, tags: [String]) throws -> ReadingItem {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              !url.absoluteString.isEmpty else {
            throw URLError(.badURL)
        }

        var items = (try? loadItems()) ?? []
        let normalizedTags = normalize(tags: tags)
        let newItem = ReadingItem(
            title: title.isEmpty ? url.absoluteString : title,
            url: url,
            tags: normalizedTags,
            capturedAt: Date(),
            source: .companion
        )

        if let index = items.firstIndex(where: { $0.url == newItem.url }) {
            var existing = items[index]
            if !title.isEmpty { existing.title = title }
            existing.tags = Array(Set(existing.tags + normalizedTags)).sorted()
            existing.capturedAt = Date()
            existing.source = .companion
            items[index] = existing
        } else {
            items.append(newItem)
        }

        try persist(items: items)
        return newItem
    }

    private func storageURL() throws -> URL {
        #if os(macOS)
        if let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            let fileURL = containerURL.appendingPathComponent("readingList.json")
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            return fileURL
        }
        #endif
        let fallback = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("readingList.json")
        if !fileManager.fileExists(atPath: fallback.path) {
            fileManager.createFile(atPath: fallback.path, contents: nil)
        }
        return fallback
    }

    private func persist(items: [ReadingItem]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let sorted = items.sorted(by: { $0.capturedAt > $1.capturedAt })
        let data = try encoder.encode(sorted)
        try data.write(to: try storageURL(), options: [.atomic])
    }

    private func normalize(tags: [String]) -> [String] {
        Array(
            Set(
                tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
    }
}
