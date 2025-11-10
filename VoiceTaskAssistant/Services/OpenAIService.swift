import Foundation
import Combine

protocol OpenAIProcessing {
    func process(task: CapturedTask) async throws -> StructuredTask
}

struct OpenAIService: OpenAIProcessing {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func process(task: CapturedTask) async throws -> StructuredTask {
        var request = URLRequest(url: OpenAIConfig.baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.addValue("Bearer \(OpenAIConfig.apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = OpenAIRequest(task: task)
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw OpenAIError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        return decoded.toStructuredTask()
    }
}

private struct OpenAIRequest: Encodable {
    let model = "gpt-4.1-mini"
    let input: [Message]

    init(task: CapturedTask) {
        let system = Message(role: "system", content: "You are a helpful assistant that rewrites spoken to-do list items into structured plans with subtasks and reminders. Return JSON with summary, subtasks, and reminders.")
        let user = Message(role: "user", content: "Task: \(task.rawText)")
        input = [system, user]
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct OpenAIResponse: Decodable {
    let output: [Choice]

    struct Choice: Decodable {
        let content: [OutputContent]
    }

    struct OutputContent: Decodable {
        let text: String?
    }

    func toStructuredTask() throws -> StructuredTask {
        guard let jsonString = output.first?.content.first?.text,
              let data = jsonString.data(using: .utf8) else {
            throw OpenAIError.invalidResponse
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StructuredTask.self, from: data)
    }
}

enum OpenAIError: Error {
    case invalidResponse
}
