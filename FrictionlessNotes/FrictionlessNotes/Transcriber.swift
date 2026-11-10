//
//  Transcriber.swift
//  FrictionlessNotes
//
//  Stub seam per UI-SPEC.md §6. Round 1 ships MockTranscriber;
//  ParakeetTranscriber (FluidAudio) replaces it in round 3 without touching a view.
//

import Foundation

@MainActor
protocol Transcriber: AnyObject {
    /// Begins emitting draft transcript updates (with RMS for the waveform).
    func start() -> AsyncStream<TranscriptUpdate>
    /// Ends the utterance, returns the final draft text.
    func stop() -> String
}

/// Canned utterances at ~280 ms word cadence with a synthetic RMS curve.
@MainActor
final class MockTranscriber: Transcriber {

    enum Script {
        case metformin
        case shopping
        case twoThoughts       // exercises split_capture
        case custom(String)

        var text: String {
            switch self {
            case .metformin:
                "remember to ask dr patel about the new met forman dosage before friday"
            case .shopping:
                "we need milk eggs and the good coffee from the place on fifth"
            case .twoThoughts:
                "call dana about the permit before friday … also an idea the app should feel like a screen that never had to turn on"
            case .custom(let s): s
            }
        }
    }

    private var continuation: AsyncStream<TranscriptUpdate>.Continuation?
    private var feeder: Task<Void, Never>?
    private var current = ""
    private var queued: [Script] = []

    func start() -> AsyncStream<TranscriptUpdate> {
        current = ""
        let (stream, cont) = AsyncStream.makeStream(of: TranscriptUpdate.self)
        continuation = cont
        if let script = queued.first {
            queued.removeFirst()
            feed(script)
        }
        return stream
    }

    func stop() -> String {
        feeder?.cancel()
        feeder = nil
        continuation?.finish()
        continuation = nil
        return current
    }

    /// Queue a script before calling start(), or inject mid-stream (voice resumes).
    func enqueue(_ script: Script) {
        if continuation == nil {
            queued.append(script)
        } else {
            feed(script)
        }
    }

    private func feed(_ script: Script) {
        let words = script.text.split(separator: " ").map(String.init)
        feeder?.cancel()
        feeder = Task { [weak self] in
            for (i, word) in words.enumerated() {
                guard let self, !Task.isCancelled else { return }
                if word == "…" {
                    // a long thinking pause inside the utterance
                    for _ in 0..<8 {
                        guard !Task.isCancelled else { return }
                        self.continuation?.yield(TranscriptUpdate(fullText: self.current, rms: 0.02))
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                    continue
                }
                self.current = self.current.isEmpty ? word : self.current + " " + word
                let rms = 0.25 + 0.55 * Float(abs(sin(Double(i) * 0.9))) + Float.random(in: -0.08...0.12)
                self.continuation?.yield(TranscriptUpdate(fullText: self.current, rms: min(max(rms, 0.05), 1.0)))
                try? await Task.sleep(for: .milliseconds(UInt64(Int.random(in: 220...340))))
            }
            // trail into silence
            guard let self else { return }
            for _ in 0..<4 {
                guard !Task.isCancelled else { return }
                self.continuation?.yield(TranscriptUpdate(fullText: self.current, rms: 0.03))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
