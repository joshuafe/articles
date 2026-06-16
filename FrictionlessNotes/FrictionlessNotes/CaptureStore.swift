//
//  CaptureStore.swift
//  FrictionlessNotes
//
//  State machine: always-listening home, capture lifecycle, pipeline events.
//  Real ears (EarsEngine + MotionEndpointer) and mock paths coexist behind
//  the same seams; the debug bar remains the simulator's motion stand-in.
//

import SwiftUI
import AVFoundation
import Observation
import SwiftData

@MainActor
@Observable
final class CaptureStore {

    /// Shared instance so the CarPlay scene and the SwiftUI app drive the same
    /// ledger and pipeline — a thought captured in the car lands in the app.
    static let shared = CaptureStore()

    // MARK: Live capture state
    enum ListeningState: Equatable { case idle, live }
    enum CaptureSource { case mic, mock }

    var listening: ListeningState = .idle
    var draft: String = ""
    var levels: [Float] = Array(repeating: 0, count: 44)
    var thinking = false
    var justFinalizedID: UUID?
    private var source: CaptureSource = .mock
    /// While true, a CarPlay button capture owns the ears (see handleEars).
    private var carPlayActive = false

    // MARK: Ears state
    var earsReady = false
    var earsStatus: String?            // "downloading ears…" / error line

    // MARK: Brain state (Gemma download / warm-up)
    var brainStatus: String?           // "downloading the brain… 42%" / nil when ready
    var brainProgress: Double?         // 0…1 while loading, nil otherwise

    // MARK: Data
    var captures: [Capture] = []
    var macStatus: MacStatus = .online(lastActiveMinutes: 0)
    var showComposer = false
    var showDebugBar = true

    // MARK: Services
    let transcriber = MockTranscriber()
    let pipeline: any PipelineClient
    let brainName: String
    let lexicon = Lexicon()
    /// Stage-1 instant category guess (ANE), painted ahead of the brain. See CategoryFirstPass.
    private let firstPass = CategoryFirstPass()

    // MARK: Tap-to-correct feedback
    /// Non-nil briefly after a correction — drives the quiet confirmation toast.
    var correctionToast: String?
    let reachability = MockMacReachability()
    let ears = EarsEngine()
    let motion = MotionEndpointer()

    private var eventTask: Task<Void, Never>?
    private var earsTask: Task<Void, Never>?
    private var reachabilityTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?

    // MARK: Persistence (local SwiftData — CloudKit-ready schema)
    private let modelContainer: ModelContainer? = try? ModelContainer(
        for: CaptureRecord.self, LexiconEntryRecord.self)
    private var persistTask: Task<Void, Never>?

    init() {
        // Brain selection, in order of preference:
        //   1. Gemma via MLX — the chosen on-device brain (real device only).
        //   2. Apple Foundation Models — fallback where MLX can't run but
        //      Apple Intelligence is available.
        //   3. Timed mock — simulator, older devices, demos.
        #if canImport(MLXLLM)
        if GemmaPipeline.isSupported {
            pipeline = GemmaPipeline()
            brainName = "gemma"
        } else if #available(iOS 26.0, *), OnDevicePipeline.isSupported {
            pipeline = OnDevicePipeline()
            brainName = "on-device"
        } else {
            pipeline = MockPipeline()
            brainName = "demo brain"
        }
        #else
        if #available(iOS 26.0, *), OnDevicePipeline.isSupported {
            pipeline = OnDevicePipeline()
            brainName = "on-device"
        } else {
            pipeline = MockPipeline()
            brainName = "demo brain"
        }
        #endif
        Haptics.prepare()
        subscribe()
        // The brain reads the personal lexicon just before filing each capture,
        // so a just-taught correction applies to the very next thought.
        pipeline.lexiconProvider = { [weak self] in
            self?.lexicon.promptInjection() ?? ""
        }
        // Surface the Gemma download / warm-up on the home screen, mirroring ears.
        #if canImport(MLXLLM)
        if let gemma = pipeline as? GemmaPipeline {
            gemma.onStatus = { [weak self] status in
                withAnimation(Motion.fadeStatus) { self?.brainStatus = status }
            }
            gemma.onProgress = { [weak self] fraction in
                self?.brainProgress = fraction < 1 ? fraction : nil
            }
        }
        #endif
        motion.onSignal = { [weak self] signal in self?.sendEndpoint(signal) }
        motion.isVadSilent = { [weak self] in self?.thinking ?? true }
        loadPersisted()
    }

    private func subscribe() {
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.pipeline.events { self.apply(event) }
        }
        reachabilityTask = Task { [weak self] in
            guard let self else { return }
            for await status in self.reachability.status { self.macStatus = status }
        }
        earsTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.ears.events { self.handleEars(event) }
        }
    }

    // MARK: Real ears

    /// Called from HomeView on first appearance — requests the mic in context
    /// (the surface listens; that's the permission moment) and starts the engine.
    func startEars() async {
        guard !ears.isRunning else { return }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            earsStatus = "mic permission denied — settings › privacy"
            return
        }
        await ears.start()
    }

    func stopEarsIfRunning() {
        if ears.isRunning { ears.stop() }
    }

    /// Tap the brain status line to re-attempt a failed/incomplete model load.
    func retryBrain() {
        #if canImport(MLXLLM)
        (pipeline as? GemmaPipeline)?.retryLoad()
        #endif
    }

    var earsMuted = false

    /// Tap the listening horizon — the light dims and the mic goes cold.
    func toggleEarsMuted() {
        if listening == .live { endCapture() }
        earsMuted.toggle()
        ears.setMuted(earsMuted)
        Haptics.checkOff()
    }

    private func handleEars(_ event: EarsEvent) {
        // While CarPlay drives a capture it owns the session — handle only status
        // here so the home doesn't also endpoint and double-file the recording.
        if carPlayActive {
            switch event {
            case .ready: earsReady = true; earsStatus = nil
            case .modelStatus(let s): earsStatus = s
            case .error(let s): earsStatus = s
            default: break
            }
            return
        }
        switch event {
        case .ready:
            earsReady = true
            earsStatus = nil
        case .modelStatus(let s):
            earsStatus = s
        case .error(let s):
            earsStatus = s
        case .voiceStarted:
            print("[ears→store] voiceStarted (listening=\(listening), muted=\(earsMuted))")
            guard listening == .idle else { return }
            source = .mic
            enterLive()
        case .partial(let text, _):
            guard listening == .live, source == .mic else { return }
            draft = text
        case .level(let rms):
            guard listening == .live, source == .mic else { return }
            pushLevel(rms)
        case .thinkingSilence:
            guard listening == .live else { return }
            withAnimation(Motion.dimThinking) { thinking = true }
            motion.noteSilence(true)
        case .voiceResumed:
            // "Resumed" while idle means the ears' utterance got stuck (e.g. a mock
            // capture ended without finalizing them) — no fresh .voiceStarted would
            // ever fire, so new recordings silently fail. Clear it so the next
            // speech starts clean.
            if listening == .idle {
                print("[ears→store] voiceResumed while idle — clearing stuck ears state")
                ears.reset()
            }
            thinking = false
            motion.noteSilence(false)
        }
    }

    // MARK: Mock voice (debug bar / simulator)

    func voiceBegan(script: MockTranscriber.Script) {
        guard listening == .idle else {
            transcriber.enqueue(script)
            thinking = false
            return
        }
        source = .mock
        enterLive()
        transcriber.enqueue(script)
        let stream = transcriber.start()
        transcriptTask = Task { [weak self] in
            for await update in stream {
                guard let self else { return }
                self.draft = update.fullText
                self.pushLevel(update.rms)
                if update.rms > 0.1 { self.thinking = false }
            }
        }
    }

    // MARK: Shared lifecycle

    private func enterLive() {
        listening = .live
        thinking = false
        draft = ""
        levels = Array(repeating: 0, count: 44)
        Haptics.recordStart()
        motion.begin()
    }

    /// Endpoint signals arrive here from MotionEndpointer, the debug bar, or taps.
    func sendEndpoint(_ signal: EndpointSignal) {
        switch signal {
        case .voiceStarted:
            break
        case .thinkingSilence:
            guard listening == .live else { return }
            withAnimation(Motion.dimThinking) { thinking = true }
        case .voiceResumed:
            thinking = false
        case .disposalDetected, .pocketed, .silenceCapped:
            endCapture()
        }
    }

    /// Stop — physical signal or tap. Saves instantly; the UI resets.
    func endCapture() {
        guard listening == .live else { return }
        motion.end()
        let endedSource = source
        listening = .idle
        thinking = false
        let mockText = endedSource == .mock ? finishMock() : ""
        draft = ""

        if endedSource == .mock {
            ears.reset()   // a mock capture leaves the always-on ears' utterance dangling
            guard !mockText.isEmpty else { return }
            Haptics.recordStop()
            insertAndSubmit(Capture(kind: .audio, deviceTranscript: mockText))
        } else {
            Haptics.recordStop()
            Task { [weak self] in
                guard let self else { return }
                let text = await self.ears.finalize()
                guard !text.isEmpty else { return }
                self.insertAndSubmit(Capture(kind: .audio, deviceTranscript: text))
            }
        }
    }

    private func finishMock() -> String {
        transcriptTask?.cancel()
        return transcriber.stop()
    }

    func captureText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Haptics.captureSaved()
        insertAndSubmit(Capture(kind: .text, deviceTranscript: trimmed))
    }

    // MARK: CarPlay capture

    /// True while the CarPlay scene is driving a button capture.
    var isCarPlayCapturing: Bool { carPlayActive }

    /// Start a button-driven capture from CarPlay. Reuses the phone's ears and
    /// pipeline, so a thought spoken in the car lands in the same ledger.
    func carPlayBeginCapture() async {
        carPlayActive = true
        earsMuted = false
        ears.setMuted(false)
        await startEars()        // no-op if the ears are already running
    }

    /// Finish the CarPlay capture: transcribe the utterance and submit it.
    @discardableResult
    func carPlayEndCapture() async -> Capture? {
        carPlayActive = false
        let text = (await ears.finalize()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        Haptics.recordStop()
        let capture = Capture(kind: .audio, deviceTranscript: text)
        insertAndSubmit(capture)
        return capture
    }

    private func pushLevel(_ rms: Float) {
        levels.removeFirst()
        levels.append(rms)
    }

    private func insertAndSubmit(_ capture: Capture) {
        captures.insert(capture, at: 0)
        justFinalizedID = capture.id
        pipeline.submit(capture)
        refreshMacStatus()
        runFirstPass(on: capture)
        schedulePersist()
    }

    /// Stage 1: paint an instant ANE category guess on the ledger tick, ahead of
    /// the brain's authoritative filing. Best-effort and silent when no model loaded.
    private func runFirstPass(on capture: Capture) {
        let id = capture.id
        let text = capture.deviceTranscript
        Task { [weak self] in
            guard let guess = await self?.firstPass.classify(text) else { return }
            self?.applyProvisionalGuess(id, guess)
        }
    }

    private func applyProvisionalGuess(_ id: UUID, _ guess: NoteCategory) {
        mutate(id) { c in
            // Never override a result that already filed for real.
            guard c.category == nil, c.status != .done, c.status != .needsReview else { return }
            c.provisionalCategory = guess
        }
    }

    // MARK: Pipeline events

    private func apply(_ event: PipelineEvent) {
        switch event {
        case .statusChanged(let id, let status):
            mutate(id) { $0.status = status }

        case .polish(let id, let newText, let summary):
            mutate(id) { c in
                guard c.userEditedAt == nil else { return } // edit wins
                c.previousTranscript = c.bestTranscript
                c.finalTranscript = newText
                c.summary = summary
                c.polishArrivedAt = .now
            }

        case .filed(let id, let category, let actions):
            mutate(id) { c in
                c.category = category
                c.actions.append(contentsOf: actions)
                c.status = .done
            }
            Haptics.filed()

        case .needsReview(let id, let guess, let reason):
            mutate(id) { c in
                c.status = .needsReview
                // Prefer the Stage-1 ANE guess when present: a parse failure sends a
                // generic `.note`, but the classifier usually has a better idea.
                c.reviewGuess = c.provisionalCategory ?? guess
                c.reviewReason = reason
            }

        case .split(let id, let children):
            if let index = captures.firstIndex(where: { $0.id == id }) {
                captures.remove(at: index)
                captures.insert(contentsOf: children, at: index)
                schedulePersist()
            }
        }
    }

    private func mutate(_ id: UUID, _ change: (inout Capture) -> Void) {
        guard let index = captures.firstIndex(where: { $0.id == id }) else { return }
        change(&captures[index])
        schedulePersist()
    }

    // MARK: Persistence (local SwiftData)

    /// Recall the ledger from disk on launch, then resume anything that was
    /// mid-flight when the app last closed (the on-device brain doesn't auto-resume).
    private func loadPersisted() {
        guard let context = modelContainer?.mainContext else { return }
        lexicon.attach(context)
        let descriptor = FetchDescriptor<CaptureRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        guard let records = try? context.fetch(descriptor) else { return }
        captures = records.map(Capture.init(record:))
        for capture in captures where capture.status != .done && capture.status != .needsReview {
            pipeline.submit(capture)
        }
    }

    /// Debounced save — coalesces the burst of events a single capture emits.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.persistNow()
        }
    }

    /// Reconcile the in-memory ledger into SwiftData: upsert each capture, drop
    /// records no longer present.
    private func persistNow() {
        guard let context = modelContainer?.mainContext else { return }
        let existing = (try? context.fetch(FetchDescriptor<CaptureRecord>())) ?? []
        var byID: [UUID: CaptureRecord] = [:]
        for record in existing { byID[record.id] = record }
        let liveIDs = Set(captures.map(\.id))
        for capture in captures {
            if let record = byID[capture.id] {
                record.update(from: capture)
            } else {
                context.insert(CaptureRecord(capture))
            }
        }
        for record in existing where !liveIDs.contains(record.id) {
            context.delete(record)
        }
        try? context.save()
    }

    // MARK: Receipt actions (refile = learning signal)

    func undo(captureID: UUID, actionID: UUID) {
        mutate(captureID) { c in
            if let i = c.actions.firstIndex(where: { $0.id == actionID }) {
                c.actions[i].undone = true
            }
        }
        pipeline.refile(captureID: captureID, actionID: actionID, to: nil)
    }

    func move(captureID: UUID, actionID: UUID, to category: NoteCategory) {
        mutate(captureID) { c in
            c.category = category
            if let i = c.actions.firstIndex(where: { $0.id == actionID }) {
                c.actions[i].category = category
                c.actions[i].listName = category.rawValue
            }
        }
        pipeline.refile(captureID: captureID, actionID: actionID, to: category)
    }

    // MARK: Tap-to-correct (DESIGN.md §personal lexicon)

    /// Patch one word in a capture's transcript and teach the lexicon the
    /// (heard → meant) pair. The user's edit wins over any pending/future polish.
    func applyCorrection(captureID: UUID, wordIndex: Int, to meant: String) {
        let replacement = meant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty else { return }

        var heardCore: String?
        mutate(captureID) { c in
            var tokens = c.bestTranscript
                .split(separator: " ", omittingEmptySubsequences: false)
                .map(String.init)
            guard tokens.indices.contains(wordIndex) else { return }

            let (core, trailing) = Self.splitTrailingPunctuation(tokens[wordIndex])
            guard !core.isEmpty else { return }
            heardCore = core

            tokens[wordIndex] = replacement + trailing
            let patched = tokens.joined(separator: " ")

            c.previousTranscript = c.bestTranscript
            c.finalTranscript = patched      // the edit becomes canonical
            c.userEditedAt = .now            // polish never overrides an edit
        }

        guard let heard = heardCore else { return }
        // Only teach when the word actually changed (a confirming tap is a no-op).
        if heard.caseInsensitiveCompare(replacement) != .orderedSame {
            lexicon.learn(meant: replacement, heard: heard)
            mutate(captureID) { c in
                c.actions.append(FilingAction(
                    tool: .learned,
                    text: "learned \u{201C}\(replacement)\u{201D}",
                    category: .reference))
            }
        }
        Haptics.correctionLearned()
        showCorrectionToast(replacement)
    }

    private func showCorrectionToast(_ term: String) {
        withAnimation(Motion.fadeStatus) {
            correctionToast = "Got it — I'll remember \u{201C}\(term)\u{201D}"
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(Motion.fadeStatus) { self?.correctionToast = nil }
        }
    }

    /// Split a display token into its word core and any trailing punctuation,
    /// so replacing "metformin?" keeps the "?" and teaches just "metformin".
    private static func splitTrailingPunctuation(_ token: String) -> (core: String, trailing: String) {
        var core = token
        var trailing = ""
        while let last = core.last, last.isPunctuation || last.isSymbol {
            trailing = String(last) + trailing
            core.removeLast()
        }
        return (core, trailing)
    }

    func resolveReview(captureID: UUID, as category: NoteCategory) {
        mutate(captureID) { c in
            c.category = category
            c.status = .done
            c.actions.append(FilingAction(tool: .fileCapture, text: "filed",
                                          listName: category.rawValue, category: category))
        }
        Haptics.checkOff()
    }

    // MARK: Offline simulation

    func toggleOffline() {
        pipeline.offline.toggle()
        refreshMacStatus()
    }

    private func refreshMacStatus() {
        if pipeline.offline {
            reachability.set(.offline(waiting: pipeline.heldCount))
        } else {
            reachability.set(.online(lastActiveMinutes: 0))
        }
    }

    var macOffline: Bool {
        if case .offline = macStatus { true } else { false }
    }

    var reviewCount: Int {
        captures.filter { $0.status == .needsReview }.count
    }

    var processingCount: Int {
        captures.filter { $0.status == .processing || $0.status == .uploaded || $0.status == .saved }.count
    }
}
