import Foundation

struct ReminderUploader {
    struct Configuration {
        let baseURL: URL
        let apiKey: String?

        static let live = Configuration(
            baseURL: URL(string: "http://192.168.1.50:8000")!,
            apiKey: nil
        )

        static let preview = Configuration(
            baseURL: URL(string: "http://localhost")!,
            apiKey: nil
        )
    }

    enum UploadError: LocalizedError {
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The reminder service returned an unexpected response."
            }
        }
    }

    private let configuration: Configuration
    private let session: URLSession

    init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func upload(reminder: String) async throws {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("reminders"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = configuration.apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }

        let payload = ReminderPayload(text: reminder, createdAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(payload)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw UploadError.invalidResponse
        }
    }
}

private struct ReminderPayload: Encodable {
    let text: String
    let createdAt: Date
}
