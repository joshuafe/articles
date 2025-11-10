import Foundation
import SwiftUI

@MainActor
final class DeskCompanionViewModel: ObservableObject {
    @Published private(set) var tasks: [DailySummary.TaskEntry] = []
    private let reader = DailySummaryReader()

    func loadDailySummary() async {
        do {
            tasks = try await reader.readSummary().tasks
        } catch {
            tasks = []
        }
    }

    func refresh() {
        Task { await loadDailySummary() }
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
