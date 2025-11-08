import Foundation

struct OpenAITranscriptionService {
    enum ServiceError: LocalizedError {
        case missingAPIKey
        case invalidResponse
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "OpenAI API key missing from configuration."
            case .invalidResponse:
                return "The transcription response was not valid."
            case .transcriptionFailed(let message):
                return message
            }
        }
    }

    private let apiKeyProvider: () -> String?
    private let session: URLSession

    init(apiKeyProvider: @escaping () -> String?, session: URLSession = .shared) {
        self.apiKeyProvider = apiKeyProvider
        self.session = session
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let apiKey = apiKeyProvider() else {
            throw ServiceError.missingAPIKey
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let body = try buildBody(boundary: boundary, audioURL: audioURL)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ServiceError.transcriptionFailed(message)
        }

        let transcription = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return transcription.text
    }

    private func buildBody(boundary: String, audioURL: URL) throws -> Data {
        var data = Data()
        let lineBreak = "\r\n"

        data.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"model\"\(lineBreak + lineBreak)".data(using: .utf8)!)
        data.append("gpt-4o-mini-transcribe\(lineBreak)".data(using: .utf8)!)

        let audioData = try Data(contentsOf: audioURL)
        data.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"file\"; filename=\"reminder.m4a\"\(lineBreak)".data(using: .utf8)!)
        data.append("Content-Type: audio/mp4\(lineBreak + lineBreak)".data(using: .utf8)!)
        data.append(audioData)
        data.append(lineBreak.data(using: .utf8)!)

        data.append("--\(boundary)--\(lineBreak)".data(using: .utf8)!)
        return data
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
}
