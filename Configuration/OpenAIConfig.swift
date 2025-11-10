import Foundation

struct OpenAIConfig {
    static var apiKey: String {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "OpenAIAPIKey") as? String, !key.isEmpty else {
            assertionFailure("Missing OpenAI API key. Add OpenAIAPIKey to Info.plist or use secure storage.")
            return ""
        }
        return key
    }

    static let baseURL = URL(string: "https://api.openai.com/v1")!
}
