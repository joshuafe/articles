import Foundation

protocol TaskPersisting {
    func save(task: CapturedTask) async throws
    func update(task: CapturedTask) async throws
    func loadTasks() async -> [CapturedTask]
}

actor TaskRepository: TaskPersisting {
    private let fileURL: URL
    private var cache: [CapturedTask] = []

    init(fileManager: FileManager = .default) {
        let directory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = directory.appendingPathComponent("capturedTasks.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([CapturedTask].self, from: data) {
            cache = decoded
        }
    }

    func save(task: CapturedTask) async throws {
        cache.append(task)
        try await persist()
    }

    func update(task: CapturedTask) async throws {
        if let index = cache.firstIndex(where: { $0.id == task.id }) {
            cache[index] = task
            try await persist()
        }
    }

    func loadTasks() async -> [CapturedTask] {
        if cache.isEmpty, let data = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONDecoder().decode([CapturedTask].self, from: data) {
                cache = decoded
            }
        }
        return cache
    }

    private func persist() async throws {
        let data = try JSONEncoder().encode(cache)
        try data.write(to: fileURL, options: [.atomic])
    }
}
