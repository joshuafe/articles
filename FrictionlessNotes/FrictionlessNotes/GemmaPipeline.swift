//
//  GemmaPipeline.swift
//  FrictionlessNotes
//
//  On-device brain backed by MLX Swift running a quantized Gemma 3. Replaces
//  Apple Foundation Models as the default brain: unlike Apple's prompt-only
//  small model, we own the whole prompt — heavy few-shot, the personal lexicon
//  injected verbatim, and eventually a LoRA tuned on the user's own corrections.
//
//  Same PipelineClient seam, same PipelineEvents, same FilingDecision shape as
//  OnDevicePipeline — so this is a drop-in swap with nothing in the views or the
//  store needing to change.
//
//  The model (~0.6–1 GB at 4-bit) downloads once via the HF Hub on first run;
//  captures that arrive before it's resident are held and drained when it loads,
//  mirroring the Parakeet ears download.
//
//  ── Version note ──────────────────────────────────────────────────────────
//  Built against the `mlx-swift-lm` package (MLXLLM + MLXLMCommon), high-level
//  API: `loadModel(id:)` → `ChatSession`. If you pin an older `mlx-swift-examples`
//  revision instead, the two call sites marked `MLX API` below are what change.
//

import Foundation

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon

/// One discrete list item the brain pulled out — a single task or product, with
/// an optional due hint and a short group label that ties related items together.
/// Decodes leniently: a bare "buy milk" string works as well as the full object.
private struct GemmaItem: Codable {
    var text: String
    var due: String?
    var group: String?

    private enum CodingKeys: String, CodingKey { case text, due, group }

    init(from decoder: Decoder) throws {
        if let bare = try? decoder.singleValueContainer().decode(String.self) {
            text = bare; due = nil; group = nil; return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        due = try? c.decodeIfPresent(String.self, forKey: .due) ?? nil
        group = try? c.decodeIfPresent(String.self, forKey: .group) ?? nil
    }
}

/// Codable mirror of FilingDecision — Gemma emits this as JSON (no @Generable,
/// that's Apple-only), and we parse it leniently: every field tolerates being
/// absent, so a reply truncated at the token cap (e.g. cut off inside `items`
/// before `confident`) still yields a usable result instead of being discarded.
/// A missing `confident` defaults to false, routing such a partial to review
/// rather than auto-filing it.
private struct GemmaFilingDecision: Codable {
    var polishedTranscript: String
    var summary: String
    var category: String
    /// Discrete items — each task in a to-do list, each product in a shopping
    /// list — with per-item due hints and grouping. Empty for single thoughts.
    var items: [GemmaItem]?
    var due: String?
    var confident: Bool
    var distinctThoughts: [String]?
    /// "question" when the speaker is asking something to be answered from their
    /// own notes; otherwise "capture" (default). Drives the Ask routing.
    var intent: String?

    private enum CodingKeys: String, CodingKey {
        case polishedTranscript, summary, category, items, due, confident, distinctThoughts, intent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        polishedTranscript = (try? c.decode(String.self, forKey: .polishedTranscript)) ?? ""
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        category = (try? c.decode(String.self, forKey: .category)) ?? "note"
        items = (try? c.decodeIfPresent([GemmaItem].self, forKey: .items)) ?? nil
        due = (try? c.decodeIfPresent(String.self, forKey: .due)) ?? nil
        confident = (try? c.decode(Bool.self, forKey: .confident)) ?? false
        distinctThoughts = (try? c.decodeIfPresent([String].self, forKey: .distinctThoughts)) ?? nil
        intent = (try? c.decodeIfPresent(String.self, forKey: .intent)) ?? nil
    }
}

@MainActor
final class GemmaPipeline: PipelineClient {

    /// MLX needs a real Metal GPU — never the simulator.
    static var isSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    /// Default: Gemma 3 1B instruction-tuned, 4-bit — small enough for a phone.
    /// Swap to a Gemma 3n effective-2B/4B build for stronger grouping once you
    /// confirm the device has the headroom, e.g.:
    ///   "mlx-community/gemma-3n-E2B-it-4bit"
    ///   "mlx-community/gemma-3n-E4B-it-4bit"
    static var modelID = "mlx-community/gemma-3-1b-it-4bit"

    /// If the weights are bundled in the app (the `GemmaModel` folder reference),
    /// load them from there — no first-run download, works offline immediately.
    /// Absent (e.g. a build without the bundled folder) → fall back to the Hub.
    static var bundledModelDirectory: URL? {
        guard let dir = Bundle.main.url(forResource: "GemmaModel", withExtension: nil),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path)
        else { return nil }
        return dir
    }

    let events: AsyncStream<PipelineEvent>
    private let cont: AsyncStream<PipelineEvent>.Continuation

    var offline: Bool = false {
        didSet { if !offline { drain() } }
    }
    var lexiconProvider: (() -> String)?

    /// Optional UI hooks (Parakeet-style). The store may observe these to show
    /// "warming the brain…" / download progress; unused hooks are harmless.
    var onStatus: ((String?) -> Void)?   // nil clears the line
    var onProgress: ((Double) -> Void)?

    private var held: [Capture] = []
    var heldCount: Int { held.count }

    private(set) var refileLog: [(capture: UUID, action: UUID, to: NoteCategory?)] = []

    // All MLX work — loading ~1 GB of weights and running token generation —
    // lives on the GemmaEngine actor (below), off the main thread, so it can
    // never block the UI. This @MainActor class owns only state and events and
    // simply awaits the engine.
    private let engine = GemmaEngine()
    private var ready = false

    private static let instructionsBody = """
        You file a person's spoken thoughts into structured JSON.

        Categorize the whole recording:
          todo      — actions the speaker intends to do
          shopping  — things to buy
          idea      — a notion or proposal
          note      — facts worth keeping
          journal   — feelings or reflections
          reference — names, numbers, addresses

        Fix transcription errors gently (punctuation, casing, obvious mishearings) \
        but keep the speaker's words — never invent content.

        ITEMS: When the recording is a LIST (several to-dos, or several things to \
        buy), break it into one entry per discrete item in "items". For each item:
          • "text": the single task or product, imperative and concise.
          • "due": a short date hint ONLY when the speaker says or clearly implies \
            one ("by friday", "before the 20th", "tomorrow"). Resolve relative to \
            today's date, given below. Use a short form like "fri" or "jun 20". \
            Otherwise null. Never guess a due date that wasn't implied.
          • "group": a short lowercase label tying RELATED items together (e.g. \
            several permit tasks → "permit"; groceries → "groceries"). Items with \
            no natural sibling get their own group. Keep groups meaningful, not \
            one-per-item and not everything-in-one.
        A single, non-list thought leaves "items" empty.

        distinctThoughts: leave empty UNLESS the recording holds two or more \
        entirely UNRELATED subjects (e.g. a work task AND a grocery run) — then put \
        each subject's full text as a separate string and leave everything else \
        minimal.

        intent: set "question" ONLY when the speaker is ASKING something to be \
        answered from their own past notes ("what did I decide about the permit", \
        "when is my dentist appointment"). A reminder to DO something ("ask Dana \
        about the permit", "remind me to call the vet") is NOT a question — it's a \
        capture/todo. Default "capture".

        Respond with ONLY a JSON object — no markdown fences, no prose — exactly:
        {
          "polishedTranscript": "string",
          "summary": "string (<=8 words, lowercase, no period)",
          "category": "todo|shopping|idea|note|journal|reference",
          "items": [ { "text": "string", "due": "fri or null", "group": "label" } ],
          "due": "overall due hint or null",
          "confident": true,
          "distinctThoughts": [],
          "intent": "capture"
        }

        Example — input "I need to call dana about the permit before friday, then \
        email the inspector the photos, oh and grab milk and coffee on the way home":
        {
          "polishedTranscript": "Call Dana about the permit before Friday, then email the inspector the photos. Also grab milk and coffee on the way home.",
          "summary": "permit calls and a grocery stop",
          "category": "todo",
          "items": [
            { "text": "Call Dana about the permit", "due": "fri", "group": "permit" },
            { "text": "Email the inspector the photos", "due": null, "group": "permit" },
            { "text": "Buy milk", "due": null, "group": "groceries" },
            { "text": "Buy coffee", "due": null, "group": "groceries" }
          ],
          "due": "fri",
          "confident": true,
          "distinctThoughts": []
        }

        Be decisive; set "confident" false only when genuinely ambiguous.
        """

    private var loading = false

    init() {
        (events, cont) = AsyncStream.makeStream(of: PipelineEvent.self)
        Task { await self.warm() }
    }

    // MARK: Model loading

    /// Re-attempt a failed/incomplete load — wired to the status line's tap.
    func retryLoad() {
        guard !ready, !loading else { return }
        Task { await self.warm() }
    }

    private func warm() async {
        guard !ready, !loading else { return }
        loading = true
        onStatus?("warming the brain…")
        do {
            // All the heavy lifting — downloading/loading ~1 GB of weights and
            // the prewarm inference — happens inside the engine actor, off the
            // main thread. The progress closure hops back here to drive the UI.
            try await engine.load(directory: Self.bundledModelDirectory,
                                  modelID: Self.modelID) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.onProgress?(fraction)
                    self.onStatus?(fraction < 1
                        ? "downloading the brain… \(Int(fraction * 100))%"
                        : "warming the brain…")
                }
            }
            self.ready = true
            self.loading = false
            self.onStatus?(nil)
            self.drain()
        } catch {
            self.loading = false
            self.onStatus?("couldn\u{2019}t load the brain — tap to retry")
        }
    }

    /// Today, spelled out — injected so the brain can resolve "by friday" etc.
    private static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f.string(from: Date())
    }

    // MARK: PipelineClient

    func submit(_ capture: Capture) {
        guard !offline, ready else {
            held.append(capture)
            return
        }
        process(capture)
    }

    func refile(captureID: UUID, actionID: UUID, to category: NoteCategory?) {
        refileLog.append((captureID, actionID, category))
    }

    func answer(query: String, context: String) async -> String {
        let instructions = """
            Answer the user's question using ONLY the notes provided. If the notes \
            don't contain the answer, say so plainly — never guess. Be concise: one \
            or two sentences, calm and plain.
            """
        let message = context.isEmpty
            ? "I have no notes yet.\n\nQuestion: \u{201C}\(query)\u{201D}"
            : "Notes:\n\(context)\n\nQuestion: \u{201C}\(query)\u{201D}"
        let raw = ((try? await engine.generate(instructions: instructions, userMessage: message)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "I couldn\u{2019}t find that in your notes." : raw
    }

    private func drain() {
        guard ready, !offline else { return }
        let queue = held
        held.removeAll()
        for c in queue { process(c) }
    }

    // MARK: Filing

    private func process(_ capture: Capture) {
        cont.yield(.statusChanged(capture.id, .processing))

        // ── Stage 1 ─────────────────────────────────────────────────────────
        // The instant ANE category guess runs brain-agnostically in CaptureStore
        // (see CategoryFirstPass) and has already tinted the ledger tick by now.
        // A future fast-path could escalate here: skip Gemma entirely when that
        // guess is confident and the capture is trivial.

        let lexicon = lexiconProvider?() ?? ""
        let userMessage = lexicon.isEmpty
            ? "Thought: \u{201C}\(capture.deviceTranscript)\u{201D}"
            : "\(lexicon)\nThought: \u{201C}\(capture.deviceTranscript)\u{201D}"
        // System prompt (instructions + today's date) goes in the session's
        // instructions slot so the chat template frames it as the system role.
        let instructions = "\(Self.instructionsBody)\n\nToday's date: \(Self.todayString())."

        Task { [weak self] in
            guard let self else { return }
            let started = Date()
            do {
                // Inference runs on the engine actor — off the main thread — so
                // the GPU drives generation while the main thread stays free.
                // Only the resulting String crosses back; the fresh per-capture
                // session is created inside the engine (no history bleed).
                let raw = try await self.engine.generate(instructions: instructions,
                                                         userMessage: userMessage)
                print("[Gemma] reply in \(String(format: "%.1f", Date().timeIntervalSince(started)))s:\n\(raw)")

                var decision = Self.parse(raw)
                if decision == nil {
                    // Small models sometimes wrap JSON in prose or overrun the token
                    // cap. parse() already repairs fences/commas/truncation; if it
                    // still can't, give the model one stricter shot before review.
                    print("[Gemma] reply unparseable — one strict-JSON retry")
                    let strict = userMessage +
                        "\n\nReturn ONLY the JSON object — no markdown fences, no commentary."
                    let retry = try await self.engine.generate(instructions: instructions,
                                                               userMessage: strict)
                    decision = Self.parse(retry)
                }
                guard let decision else {
                    print("[Gemma] could not parse JSON after retry")
                    self.cont.yield(.needsReview(capture.id, guess: .note,
                        reason: "couldn't read the brain's reply"))
                    return
                }
                self.apply(decision, to: capture)
            } catch {
                print("[Gemma] generation error after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(error)")
                self.cont.yield(.needsReview(capture.id, guess: .note,
                    reason: "on-device model failed"))
            }
        }
    }

    /// Lenient JSON extraction. Tolerates ```json fences and trailing prose by
    /// taking the first brace-balanced object; if the reply was cut off at the
    /// token cap, repairs the truncation (closes a dangling string, drops a
    /// trailing comma, appends the still-open brackets) before decoding. Returns
    /// nil only when nothing with real content survives — the caller retries once.
    private static func parse(_ raw: String) -> GemmaFilingDecision? {
        let cleaned = raw.replacingOccurrences(of: "```json", with: "")
                         .replacingOccurrences(of: "```", with: "")
        guard let start = cleaned.firstIndex(of: "{") else { return nil }
        let body = String(cleaned[start...])
        guard let json = balancedObject(in: body) ?? repairTruncated(body) else { return nil }
        let decoded = decode(json) ?? decode(stripTrailingCommas(json))
        // Never let an empty / contentless object blank a capture — treat as a miss.
        guard let d = decoded,
              !d.polishedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return d
    }

    private static func decode(_ json: String) -> GemmaFilingDecision? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GemmaFilingDecision.self, from: data)
    }

    private static func stripTrailingCommas(_ s: String) -> String {
        s.replacingOccurrences(of: ",\\s*}", with: "}", options: .regularExpression)
         .replacingOccurrences(of: ",\\s*]", with: "]", options: .regularExpression)
    }

    /// First fully brace-balanced { … } object, respecting strings and escapes;
    /// nil if the braces never balance (truncated output).
    private static func balancedObject(in s: String) -> String? {
        var depth = 0, inString = false, escaped = false
        var out = ""
        for ch in s {
            out.append(ch)
            if escaped { escaped = false; continue }
            if inString {
                if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]": depth -= 1; if depth == 0 { return out }
            default: break
            }
        }
        return nil
    }

    /// Best-effort repair of a truncated object: close a dangling string, strip a
    /// trailing comma/colon, and append closers for any still-open arrays/objects
    /// (innermost first). Anything still malformed simply fails to decode.
    private static func repairTruncated(_ s: String) -> String? {
        var stack: [Character] = [], inString = false, escaped = false
        for ch in s {
            if escaped { escaped = false; continue }
            if inString {
                if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{", "[": stack.append(ch)
            case "}": if stack.last == "{" { stack.removeLast() }
            case "]": if stack.last == "[" { stack.removeLast() }
            default: break
            }
        }
        guard !stack.isEmpty || inString else { return nil }
        var out = s
        if inString { out.append("\"") }
        while let last = out.last,
              last == " " || last == "\n" || last == "\t" || last == "," || last == ":" {
            out.removeLast()
        }
        for opener in stack.reversed() { out.append(opener == "{" ? "}" : "]") }
        return out
    }

    private func category(from raw: String) -> NoteCategory {
        NoteCategory(rawValue: raw.lowercased().trimmingCharacters(in: .whitespaces)) ?? .note
    }

    private func apply(_ decision: GemmaFilingDecision, to capture: Capture) {
        // A question → hand off to the Ask path instead of filing.
        if decision.intent == "question" {
            let q = decision.polishedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            cont.yield(.isQuestion(capture.id, query: q.isEmpty ? capture.deviceTranscript : q))
            return
        }
        // Multi-thought recording → split into children, file each.
        if let thoughts = decision.distinctThoughts, thoughts.count > 1 {
            let children = thoughts.map {
                Capture(kind: capture.kind, deviceTranscript: $0, status: .processing)
            }
            cont.yield(.split(capture.id, into: children))
            for child in children { process(child) }
            return
        }

        cont.yield(.polish(capture.id,
                           newText: decision.polishedTranscript,
                           summary: decision.summary))

        guard decision.confident else {
            cont.yield(.needsReview(capture.id,
                                    guess: category(from: decision.category),
                                    reason: "low confidence"))
            return
        }

        let category = category(from: decision.category)
        let items = (decision.items ?? [])
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var actions: [FilingAction] = []

        if !items.isEmpty, category == .todo || category == .shopping {
            // A list → one receipt per discrete item, kept adjacent by group so
            // related items read together, each carrying its own due hint.
            let tool: FilingAction.Tool = category == .shopping ? .addListItem : .createTodo
            for item in Self.orderByGroup(items).prefix(20) {
                actions.append(FilingAction(
                    tool: tool,
                    text: item.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    listName: item.group ?? category.rawValue,
                    due: item.due,
                    category: category))
            }
        } else {
            switch category {
            case .todo:
                actions.append(FilingAction(tool: .createTodo,
                    text: decision.summary, listName: "todo",
                    due: decision.due, category: .todo))
            default:
                actions.append(FilingAction(tool: .fileCapture, text: "filed",
                    listName: category.rawValue, category: category))
            }
        }
        cont.yield(.filed(capture.id, category: category, actions: actions))
    }

    /// Stable ordering that keeps items with the same group adjacent, in the
    /// order the groups first appeared — so related items read as a cluster.
    private static func orderByGroup(_ items: [GemmaItem]) -> [GemmaItem] {
        var order: [String] = []
        for item in items {
            let g = item.group ?? ""
            if !order.contains(g) { order.append(g) }
        }
        return items.enumerated().sorted { a, b in
            let ga = order.firstIndex(of: a.element.group ?? "") ?? 0
            let gb = order.firstIndex(of: b.element.group ?? "") ?? 0
            return ga == gb ? a.offset < b.offset : ga < gb
        }.map(\.element)
    }
}

/// Owns the MLX model and every call into MLX, on its own background executor.
/// This is the whole point of the split: loading ~1 GB of weights and running
/// token generation are heavy, partly-synchronous CPU work that drives the GPU
/// and blocks the calling thread on each `eval()`. Keeping all of it off
/// `@MainActor` means that blocking lands on a background cooperative thread,
/// never the main one. `GemmaPipeline` stays on the main actor and only awaits
/// this actor; only Sendable values (Strings, the progress fraction) ever cross
/// the boundary — the model and its sessions never leave.
private actor GemmaEngine {

    enum EngineError: Error { case notLoaded }

    private var model: ModelContext?

    // A tiny FIFO mutex so two captures never run inference concurrently: MLX
    // shares one Metal command stream and isn't safe for concurrent `eval`, and
    // a multi-thought capture fans out into several process() calls at once.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
    }

    private func release() {
        busy = false
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    /// Load weights (bundled → cache → Hub download) and prewarm Metal kernels.
    /// `progress` reports 0…1 during a first-run download.
    func load(directory: URL?,
              modelID: String,
              progress: @escaping @Sendable (Double) -> Void) async throws {
        // ── MLX API (mlx-swift-lm 2.x) ──: prefer weights bundled in the app
        // (instant, offline); otherwise download from the HF Hub on first run
        // (then load from cache) with a live progress %.
        let container: ModelContext
        if let directory {
            container = try await loadModel(directory: directory)
        } else {
            container = try await loadModel(id: modelID) { p in
                progress(p.fractionCompleted)
            }
        }
        // Prewarm: the FIRST inference triggers Metal kernel compilation, which
        // can stall for many seconds. Do it now, while the pipeline still shows
        // "warming the brain…", so the first real capture is fast.
        var warmParams = GenerateParameters()
        warmParams.maxTokens = 1
        _ = try? await ChatSession(container, generateParameters: warmParams)
            .respond(to: "ready?")
        model = container
    }

    /// Run one filing and return the model's raw reply. Serialized via the mutex
    /// so concurrent captures queue rather than collide on the GPU.
    func generate(instructions: String, userMessage: String) async throws -> String {
        guard let model else { throw EngineError.notLoaded }
        await acquire()
        defer { release() }
        // A fresh ChatSession per call = independent filing (no history bleed).
        let session = ChatSession(model, instructions: instructions,
                                  generateParameters: Self.makeParameters())
        return try await session.respond(to: userMessage)
    }

    /// Low-temperature, length-capped decoding — clean JSON, bounded runtime so
    /// a capture can never hang indefinitely on "polishing".
    private static func makeParameters(maxTokens: Int = 1024) -> GenerateParameters {
        var p = GenerateParameters()
        p.maxTokens = maxTokens
        p.temperature = 0.2
        return p
    }
}
#endif
