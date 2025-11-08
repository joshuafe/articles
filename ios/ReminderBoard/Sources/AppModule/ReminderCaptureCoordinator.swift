import Foundation
import SwiftUI

@MainActor
final class ReminderCaptureCoordinator: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case ready
        case recording
        case transcribing
        case uploading

        var buttonTitle: String {
            switch self {
            case .idle, .ready:
                return "Start Recording"
            case .recording:
                return "Stop Recording"
            case .transcribing:
                return "Transcribing…"
            case .uploading:
                return "Updating board…"
            }
        }

        var buttonIcon: String {
            switch self {
            case .idle, .ready:
                return "mic"
            case .recording:
                return "stop.circle"
            case .transcribing:
                return "waveform"
            case .uploading:
                return "arrow.up.circle"
            }
        }

        var displayTitle: String {
            switch self {
            case .idle:
                return "Ready"
            case .ready:
                return "Ready"
            case .recording:
                return "Recording"
            case .transcribing:
                return "Transcribing"
            case .uploading:
                return "Publishing"
            }
        }

        var visualIcon: String {
            switch self {
            case .idle, .ready:
                return "mic"
            case .recording:
                return "waveform"
            case .transcribing:
                return "ellipsis"
            case .uploading:
                return "icloud.and.arrow.up"
            }
        }

        var visualColor: Color {
            switch self {
            case .idle, .ready:
                return .blue
            case .recording:
                return .red
            case .transcribing:
                return .purple
            case .uploading:
                return .green
            }
        }

        var visualScale: CGFloat {
            switch self {
            case .idle, .ready:
                return 0.85
            case .recording:
                return 1.05
            case .transcribing:
                return 0.9
            case .uploading:
                return 0.95
            }
        }
    }

    @Published var state: State = .idle
    @Published var statusMessage: String = "Call Siri and say “Capture reminder” to begin."
    @Published var lastSuccessfulReminder: String?

    private let recorder = VoiceReminderRecorder()
    private let transcriptionService: OpenAITranscriptionService
    private let reminderUploader: ReminderUploader

    init(preview: Bool = false) {
        if preview {
            transcriptionService = OpenAITranscriptionService(apiKeyProvider: { "demo" })
            reminderUploader = ReminderUploader(configuration: .preview)
            statusMessage = "Preview ready"
            lastSuccessfulReminder = "Buy milk and eggs on the way home."
            state = .ready
        } else {
            transcriptionService = OpenAITranscriptionService(apiKeyProvider: {
                Bundle.main.object(forInfoDictionaryKey: "OpenAIAPIKey") as? String
            })
            reminderUploader = ReminderUploader(configuration: .live)
        }
        super.init()

    }

    func prepareAudioSession() async {
        do {
            try recorder.prepare()
            state = .ready
            statusMessage = "Ready to capture reminders."
        } catch {
            state = .idle
            statusMessage = "Microphone unavailable: \(error.localizedDescription)"
        }
    }

    func bindToIntentNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleIntentTrigger), name: ReminderCaptureNotifications.beginCapture, object: nil)
    }

    func unbindFromIntentNotifications() {
        NotificationCenter.default.removeObserver(self, name: ReminderCaptureNotifications.beginCapture, object: nil)
    }

    @objc
    private func handleIntentTrigger() {
        guard state == .ready || state == .idle else { return }
        Task { await startRecording() }
    }

    func startRecording() async {
        do {
            try recorder.start()
            state = .recording
            statusMessage = "Listening…"
        } catch {
            state = .idle
            statusMessage = "Recording failed: \(error.localizedDescription)"
        }
    }

    func stopRecording() async {
        guard case .recording = state else { return }
        do {
            let url = try recorder.stop()
            state = .transcribing
            statusMessage = "Sending audio to OpenAI…"
            defer { try? FileManager.default.removeItem(at: url) }
            let transcription = try await transcriptionService.transcribe(audioURL: url)
            state = .uploading
            statusMessage = "Updating display…"
            try await reminderUploader.upload(reminder: transcription)
            state = .ready
            lastSuccessfulReminder = transcription
            statusMessage = "Reminder published."
        } catch {
            state = .ready
            statusMessage = "Could not publish reminder: \(error.localizedDescription)"
        }
    }

}
