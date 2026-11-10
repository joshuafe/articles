import Foundation
import Combine
import Speech
import AVFoundation

struct SpeechTranscriptionUpdate {
    let text: String
    let isRecording: Bool
    let statusMessage: String?
}

protocol SpeechCaptureServicing {
    var transcriptionPublisher: AnyPublisher<SpeechTranscriptionUpdate, Never> { get }
    var capturedTaskPublisher: AnyPublisher<CapturedTask, Never> { get }

    func startRecording()
    func stopRecording()
}

final class SpeechCaptureService: NSObject, SpeechCaptureServicing {
    private let transcriptionSubject = PassthroughSubject<SpeechTranscriptionUpdate, Never>()
    private let capturedTaskSubject = PassthroughSubject<CapturedTask, Never>()

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer()
    private var currentSegments: [CapturedTask.Segment] = []

    var transcriptionPublisher: AnyPublisher<SpeechTranscriptionUpdate, Never> {
        transcriptionSubject.eraseToAnyPublisher()
    }

    var capturedTaskPublisher: AnyPublisher<CapturedTask, Never> {
        capturedTaskSubject.eraseToAnyPublisher()
    }

    func startRecording() {
        Task { @MainActor in
            guard await requestPermissions() else {
                transcriptionSubject.send(SpeechTranscriptionUpdate(text: "", isRecording: false, statusMessage: "Speech permission denied"))
                return
            }

            resetRecognition()

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            recognitionRequest?.shouldReportPartialResults = true

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }

            audioEngine.prepare()
            try? audioEngine.start()

            guard let recognitionRequest else { return }

            recognitionTask = recognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let finalText = result.bestTranscription.formattedString
                    self.captureSegments(from: result.bestTranscription)
                    self.transcriptionSubject.send(SpeechTranscriptionUpdate(text: finalText, isRecording: true, statusMessage: "Listening…"))
                    if result.isFinal {
                        self.finish(with: finalText)
                    }
                } else if let error {
                    self.transcriptionSubject.send(SpeechTranscriptionUpdate(text: "", isRecording: false, statusMessage: "Error: \(error.localizedDescription)"))
                }
            }

            transcriptionSubject.send(SpeechTranscriptionUpdate(text: "", isRecording: true, statusMessage: "Listening…"))
        }
    }

    func stopRecording() {
        audioEngine.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        let combinedText = currentSegments.map(\.text).joined(separator: " ")
        transcriptionSubject.send(SpeechTranscriptionUpdate(text: combinedText, isRecording: false, statusMessage: "Processing…"))
    }

    private func finish(with text: String) {
        audioEngine.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        let task = CapturedTask(rawText: text, segments: currentSegments)
        capturedTaskSubject.send(task)
        transcriptionSubject.send(SpeechTranscriptionUpdate(text: text, isRecording: false, statusMessage: "Captured"))
        currentSegments = []
    }

    private func resetRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        currentSegments = []
    }

    private func captureSegments(from transcription: SFTranscription) {
        currentSegments = transcription.segments.map { segment in
            CapturedTask.Segment(text: segment.substring, timestamp: segment.timestamp)
        }
    }

    private func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        let audioGranted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }

        return (speechStatus == .authorized) && audioGranted
    }
}
