//
//  EarsEngine.swift
//  FrictionlessNotes
//
//  Real ears: AVAudioEngine mic capture → Silero VAD gate → Parakeet TDT v3
//  (FluidAudio, CoreML). Always listening, VAD-gated: nothing is kept until
//  voice is detected; a rolling pre-buffer protects the first word.
//  Live partials come from re-transcribing the utterance buffer (~1 s cadence —
//  Parakeet is ~190x realtime, so this is trivially cheap).
//

import AVFoundation
import FluidAudio

enum EarsEvent: Sendable {
    case ready
    case modelStatus(String)           // "downloading ears…" etc.
    case voiceStarted
    case partial(text: String, rms: Float)
    case level(rms: Float)             // while live but between partials
    case thinkingSilence
    case voiceResumed
    case error(String)
}

@MainActor
final class EarsEngine {

    let events: AsyncStream<EarsEvent>
    private let cont: AsyncStream<EarsEvent>.Continuation

    private let engine = AVAudioEngine()
    // Written once on MainActor before the tap installs; read on the tap thread.
    nonisolated(unsafe) private var converter: AVAudioConverter?
    private var asr: AsrManager?
    private var vad: VadManager?
    private var vadState: VadStreamState?

    // 16 kHz mono pipeline
    nonisolated(unsafe) private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                                 sampleRate: 16_000, channels: 1,
                                                                 interleaved: false)!

    // Rolling pre-buffer (~1.5 s) so the first word is never clipped.
    private var preBuffer: [Float] = []
    private let preBufferMax = 24_000

    // Current utterance accumulation (speech + pauses, capped ~4 min).
    private(set) var utterance: [Float] = []
    private let utteranceMax = 16_000 * 240

    private var inUtterance = false
    private var silentChunks = 0
    private var speechStreak = 0          // consecutive speech chunks before start
    private var emaRms: Float = 0         // energy floor — rejects distant voices
    private var pendingVadSamples: [Float] = []
    private var transcribing = false
    private var lastPartialAt = Date.distantPast
    private(set) var isRunning = false
    private(set) var muted = false

    /// Busy-environment tuning: an utterance starts only after `startChunksRequired`
    /// consecutive VAD-speech chunks (256 ms each) AND sustained energy above
    /// `startRmsFloor`. The pre-buffer covers the gate delay, so no words are lost.
    private let startChunksRequired = 2
    private let startRmsFloor: Float = 0.12

    func setMuted(_ value: Bool) {
        muted = value
        if muted {
            preBuffer = []
            pendingVadSamples = []
            speechStreak = 0
        }
    }

    init() {
        (events, cont) = AsyncStream.makeStream(of: EarsEvent.self)
    }

    private var starting = false

    /// Load models (downloads from Hugging Face on first run) and start the mic.
    /// Safe to call repeatedly — resumes an interrupted download.
    func start() async {
        guard !isRunning, !starting else { return }
        starting = true
        defer { starting = false }
        do {
            if asr == nil {
                let repoDir = try await ensureModelsStaged()
                let models = try await AsrModels.load(from: repoDir, version: .v3)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                asr = manager
                vad = try await VadManager(config: VadConfig(defaultThreshold: 0.85))
                vadState = await vad?.makeStreamState()
            }
            try configureSession()
            try startEngine()
            isRunning = true
            cont.yield(.ready)
        } catch {
            cont.yield(.error("ears interrupted — tap to retry"))
        }
    }

    var needsStart: Bool { !isRunning }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// Ensure the Parakeet bundles are staged on disk (background download that
    /// survives suspension). Returns the repo folder for AsrModels.load(from:).
    private func ensureModelsStaged() async throws -> URL {
        if ModelDownloader.isStaged() {
            return ModelDownloader.repoDirectory
        }
        cont.yield(.modelStatus("downloading ears… 0%"))
        let downloader = ModelDownloader.shared
        return try await withCheckedThrowingContinuation { continuation in
            downloader.onProgress = { [weak self] fraction in
                self?.cont.yield(.modelStatus("downloading ears… \(Int(fraction * 100))%"))
            }
            downloader.onComplete = { result in
                downloader.onProgress = nil
                downloader.onComplete = nil
                continuation.resume(with: result)
            }
            downloader.start()
        }
    }

    /// Capture ended (motion/pocket/lock/tap/cap): final pass over the utterance.
    func finalize() async -> String {
        inUtterance = false
        let samples = utterance
        utterance = []
        preBuffer = []
        guard let asr, samples.count > 4_000 else { return "" }
        do {
            var decoderState = try TdtDecoderState()
            let result = try await asr.transcribe(samples, decoderState: &decoderState)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            cont.yield(.error("transcription failed: \(error.localizedDescription)"))
            return ""
        }
    }

    // MARK: Audio plumbing

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.convert(buffer)
            guard !samples.isEmpty else { return }
            Task { @MainActor in
                self.ingest(samples)
            }
        }
        engine.prepare()
        try engine.start()
    }

    /// Runs on the tap's realtime thread — pure math, no actor state.
    private nonisolated func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converter else { return [] }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    // MARK: Stream logic (MainActor)

    private func ingest(_ samples: [Float]) {
        guard !muted else { return }
        var rms: Float = 0
        for s in samples { rms += s * s }
        rms = min(sqrt(rms / Float(max(samples.count, 1))) * 6, 1.0)
        emaRms = 0.7 * emaRms + 0.3 * rms

        if inUtterance {
            utterance.append(contentsOf: samples)
            if utterance.count > utteranceMax { inUtterance = false }
            cont.yield(.level(rms: rms))
            maybeTranscribePartial()
        } else {
            preBuffer.append(contentsOf: samples)
            if preBuffer.count > preBufferMax {
                preBuffer.removeFirst(preBuffer.count - preBufferMax)
            }
        }

        pendingVadSamples.append(contentsOf: samples)
        while pendingVadSamples.count >= 4096 {
            let chunk = Array(pendingVadSamples.prefix(4096))
            pendingVadSamples.removeFirst(4096)
            runVad(on: chunk)
        }
    }

    private func runVad(on chunk: [Float]) {
        guard let vad, let state = vadState else { return }
        Task { @MainActor in
            do {
                let result = try await vad.processStreamingChunk(
                    chunk, state: state, config: .default,
                    returnSeconds: false, timeResolution: 2)
                self.vadState = result.state
                self.handleVad(probability: result.probability)
            } catch {
                // VAD hiccups are non-fatal; keep listening.
            }
        }
    }

    private func handleVad(probability: Float) {
        let speaking = probability > 0.85
        if speaking {
            silentChunks = 0
            if !inUtterance {
                speechStreak += 1
                // Sustained speech at close-range energy — not a passing voice.
                guard speechStreak >= startChunksRequired, emaRms > startRmsFloor else { return }
                speechStreak = 0
                inUtterance = true
                utterance = preBuffer          // stitch the pre-roll in
                preBuffer = []
                cont.yield(.voiceStarted)
            } else {
                cont.yield(.voiceResumed)
            }
        } else {
            speechStreak = 0
            if inUtterance {
                silentChunks += 1
                // 4096 samples ≈ 256 ms; ~10 chunks ≈ 2.5 s of silence = thinking.
                if silentChunks == 10 {
                    cont.yield(.thinkingSilence)
                }
            }
        }
    }

    private func maybeTranscribePartial() {
        guard !transcribing,
              Date.now.timeIntervalSince(lastPartialAt) > 1.0,
              let asr, utterance.count > 8_000 else { return }
        transcribing = true
        lastPartialAt = .now
        let snapshot = utterance
        Task { @MainActor in
            defer { self.transcribing = false }
            do {
                var decoderState = try TdtDecoderState()
                let result = try await asr.transcribe(snapshot, decoderState: &decoderState)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    self.cont.yield(.partial(text: text, rms: 0))
                }
            } catch {
                // partials are best-effort
            }
        }
    }
}
