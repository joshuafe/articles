import AVFoundation
import Foundation

@MainActor
final class VoiceReminderRecorder {
    enum State {
        case idle
        case recording
    }

    private(set) var state: State = .idle

    private let engine = AVAudioEngine()
    private var audioFileURL: URL?

    func prepare() throws {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
    }

    func start() throws {
        guard state == .idle else { return }

        let format = engine.inputNode.outputFormat(forBus: 0)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)

        engine.inputNode.removeTap(onBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            do {
                try file.write(from: buffer)
            } catch {
                print("Audio write error: \(error)")
            }
        }

        engine.prepare()
        try engine.start()

        state = .recording
        audioFileURL = tempURL
    }

    func stop() throws -> URL {
        guard state == .recording else {
            throw RecorderError.notRecording
        }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        state = .idle

        guard let url = audioFileURL else {
            throw RecorderError.missingFile
        }

        return url
    }

    enum RecorderError: LocalizedError {
        case notRecording
        case missingFile

        var errorDescription: String? {
            switch self {
            case .notRecording:
                return "The recorder is not currently running."
            case .missingFile:
                return "No audio file was created."
            }
        }
    }
}
