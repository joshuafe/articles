# FrictionlessNotes — Design v3

Zero-friction capture. Speak, type, or photograph; everything else is automatic. The phone captures; the Mac Studio thinks; **iCloud is the wire**. Visual/interaction spec: **UI-SPEC.md**.

## Principles

1. **Capture never waits on intelligence.** Every input is committed locally and the UI resets instantly. Processing is async; the user never watches a spinner to save a thought.
2. **Raw input is immutable.** Audio, text, and photos are kept as captured. All intelligence (transcripts, categories, list mutations) is derived and re-runnable.
3. **LLM actions are auditable and undoable.** Every mutation the model makes is logged and reversible.
4. **No server to administer.** CloudKit private database is the transport — no open ports, no firewall rules, no Tailscale. The Mac runs an ordinary app.
5. **Transport-agnostic pipeline.** The Mac agent's pipeline code takes a Capture and returns results; swapping iCloud for a direct connection later (snappier Q&A) touches nothing else.

## System overview

```
iPhone (SwiftUI)                          Mac Studio (menu-bar agent, Swift)
┌──────────────────────┐                 ┌────────────────────────────────┐
│ capture UI           │                 │ observes new records           │
│ Parakeet ASR (local) │    CloudKit     │  ├─ Parakeet re-run (audio)    │
│ Vision OCR (photos)  │◀── private DB ─▶│  ├─ Ollama gemma3 (image→text) │
│ SwiftData (synced)   │   (iCloud)      │  ├─ Ollama gpt-oss:120b (brain)│
│ lists + ask UI       │                 │  └─ writes results back        │
└──────────────────────┘                 └────────────────────────────────┘
```

**Division of labor — three models:** gpt-oss:120b is text-only, so everything non-text is converted to text before it thinks:

| role | model | runs |
|---|---|---|
| ears | Parakeet TDT v3 (600M, CoreML via FluidAudio) | **on the iPhone** — and in the Mac agent for fallback/re-runs |
| ears (fallback, **v2**) | whisper-large-v3 via WhisperKit | deferred — in v1, low-confidence Parakeet audio routes to `needsReview` instead |
| eyes | gemma3:27b via Ollama | Mac, localhost HTTP |
| brain | gpt-oss:120b via Ollama | Mac, localhost HTTP — includes a transcript-polish pass |

Both Ollama calls are outbound to localhost — no incoming connections, no firewall prompts.

## Transport: CloudKit-synced SwiftData

One shared model package; both apps use SwiftData with CloudKit mirroring (same private-DB container). iCloud handles auth, NAT traversal, offline queuing, and change push for free.

- iOS writes a `Capture` (status `saved`) → CloudKit ack flips it to `uploaded` → Mac agent gets a remote-change notification, sets `processing` → writes results, sets `done` → syncs back → phone UI updates. Every transition is user-visible (lifecycle chip), and a waiting capture is fully alive — draft transcript readable and editable, never an empty placeholder.
- Q&A works the same way: a `Question` record goes up; an `Answer` record comes back.
- Media (audio/photo) stored as `@Attribute(.externalStorage)` data → CKAsset under the hood; MB-scale files are fine.
- SwiftData+CloudKit constraints respected: all properties defaulted or optional, no unique constraints, optional relationships.
- Requires the paid Apple Developer Program (CloudKit container + entitlements on both apps).

**Latency honesty:** CloudKit sync is typically a few seconds, occasionally longer; it is not real-time. The capture-first design absorbs this completely — capture and draft transcript are instant and local. Q&A is where lag is felt; acceptable for v1, and the v2 escape hatch is a direct LAN/Tailscale path behind the same pipeline interface.

## iOS app

**Entry points — zero-press by design:**

- Opening the app by any path (icon, Action Button, widget, Control Center) lands on the **always-listening ledger**: the mic is live and VAD-gated from the first frame. Speak and it captures; scroll and nothing is recorded — no audio is retained and no capture object exists until voice activity is detected. There is no record button anywhere.
- Type: pull down → keyboard. Photo: swipe up → shutter. Each one gesture; neither touches the mic.
- **Pre-warmed start:** audio session configured and `prepareToRecord` run before the UI is interactive, with a rolling pre-buffer — the first word is never clipped. Distinct start/stop haptics make capture eyes-free.
- **Stop is a physical signal, not a silence guess (`EndpointEngine`):** silence never ends a capture — thinking pauses are expected; the field only dims. Capture ends on: disposal motion (sustained ≥ ~70° attitude change *while VAD-silent* — rotation during speech is ignored), proximity sensor (pocket), screen lock / backgrounding, an explicit tap, or a ~3-minute silence cap. Over-recording is free: raw audio is immutable, and enrich can `split_capture` a multi-thought recording.
- First run invites the first capture with the empty ledger; mic permission is requested on first open (the surface listens), camera at first shutter. No save, no title, no folder picker — ever.

**On-device transcription at full quality:** Parakeet TDT v3 (FluidAudio, CoreML on the Neural Engine, iOS 17+) transcribes on the phone — whisper-large-class accuracy (~2% WER LibriSpeech, no hallucinations) at real-time speed, offline, 600M params. Apple's Speech APIs are not used. Because the phone already produces a server-grade transcript, the Mac doesn't re-transcribe by default; it runs a gpt-oss **polish pass** (punctuation, names, homophones, personal vocabulary); audio Parakeet flags as low-confidence routes to `needsReview` (the whisper-large-v3 fallback is v2). `finalTranscript` = polished text.

**Transcript lifecycle is visible state:** **Draft** (on-device ASR, immediate) → **Polished** (Mac). Polish never silently hard-swaps text being read or edited: on a visible card, changed tokens animate a brief diff highlight (~600 ms decay); if the user is mid-edit, polish is held behind a non-destructive "Improved transcript available" affordance. A user edit always wins over pending polish (see conflict semantics). Word-level **tap-to-correct**: tap a word → candidate list + free field; the correction patches the transcript, is stored as a (heard → meant) lexicon pair, and confirms quietly ("Got it — I'll remember 'Beauchamp'").

**Photos:** Vision framework OCR runs on-device (free, instant); OCR text rides along with the image. Gemma adds a scene/content caption on the Mac; gpt-oss sees both.

**Offline:** everything works with no connectivity — SwiftData is local-first; CloudKit drains the queue whenever the network returns. Lists are readable and check-off-able offline; mutations sync later.

**Surfaces (full visual/interaction spec: UI-SPEC.md):**

- Capture detail shows **one hero text** — the best available transcript; OCR / VLM caption / summary sit behind a single disclosure. Feed cards: summary as title, transcript as body preview, lifecycle chip.
- **Filing receipt:** every auto-filing action surfaces as a transient tappable receipt on the capture ("→ Added to Shopping: milk, eggs") with one-tap Undo / Move-to; inferred due dates are always printed on the receipt, never silent. List items carry provenance — a link back to the source capture.
- **Ask** is an inbox of question→answer pairs that resolve over time, not a chat: "Thinking on your Mac…" while pending, an immediate honest "Mac offline" when unreachable, a local notification when an answer arrives in the background, citations as tappable chips.
- **Needs-review** is a calm finite queue of one-decision cards — the model's best guess + its reason, one-tap accept or pick-other; quiet badge; ignored items safely age into plain notes after 7 days.
- **Ambient Mac reachability:** the app always knows what to expect — "Mac last active 2 m ago" / "Mac offline — 3 waiting".

## Mac agent

A menu-bar Swift app (login item). No Python, no web server.

**Pipeline per capture:**

1. `transcribe` — only if needed: Parakeet re-run for captures that arrived audio-only; low-confidence audio → `needsReview` (whisper-large-v3 fallback is v2)
2. `see` — gemma3:27b caption via Ollama, merged with phone OCR text (photo captures)
3. `enrich` — gpt-oss:120b, one call with tool schema → polished transcript, summary, category, zero or more actions; calls `split_capture` first when a recording contains multiple distinct thoughts
4. `apply` — execute actions, log each to `ActionLog`, set status `done`

**Tool schema (enrich step):**

| tool | args |
|---|---|
| `file_capture` | category: todo \| shopping \| idea \| note \| journal \| reference |
| `add_list_item` | list, text, qty? |
| `create_todo` | text, due?, priority? |
| `needs_review` | reason — used when confidence is low; never guess |
| `split_capture` | segments — divide one recording into N captures (thinking pauses make multi-thought recordings normal); each segment is enriched and filed independently |

Every applied action surfaces on the phone as the filing receipt (Undo / Move-to); inferred `due` dates always appear on the receipt. The polish pass never overwrites a user-edited transcript (the agent checks `userEditedAt` before writing `finalTranscript`).

**Personal lexicon:** a synced table of terms the user actually says — medical/scientific vocabulary, product names, person names (incl. non-English spellings). Sources (v1): manual transcript corrections in the app — each stored as a (heard → meant) pair — and a one-time iOS Contacts seed; entities gpt-oss extracts from captures are v2. The polish pass injects the relevant lexicon into its prompt (the v2 whisper fallback will get it via `initial_prompt`). No model training required; improves continuously.

**Q&A:** agent watches for `Question` records → retrieval over its **local** index (SQLite FTS5 in v1; embeddings via an Ollama embed model are v2 — built from synced text, the index itself never syncs) → gpt-oss answers → writes `Answer` with capture IDs as citations. The phone fires a local notification when an answer lands while the app is backgrounded.

## Data model (shared SwiftData package, CloudKit-mirrored)

```
Capture     id, createdAt, kind(audio|text|photo),
            deviceTranscript, finalTranscript, userEditedAt,
            ocrText, vlmCaption, summary, category,
            status(saved|uploaded|processing|done|needsReview|error),
            media(.externalStorage)
List        id, name, kind(todo|shopping|custom)
ListItem    id, list→, text, qty, done, due, priority, sourceCapture→, createdAt
ActionLog   id, capture→, tool, argsJSON, appliedAt, undone
Question    id, text, askedAt, status
Answer      id, question→, text, citedCaptureIDs, answeredAt
LexiconEntry id, term, misheardForms, domain, source(correction|extracted|contacts), addedAt
```

Mac-local only (not synced): FTS + embedding index, rebuilt from synced records.

`ActionLog` is the audit/undo trail: undo = reverse the mutation, set `undone=true`, never delete raw data. Filing corrections (receipt Undo / Move-to, review-queue re-categorization) are logged as `refile` entries — a learning signal the enrich prompt consumes for future categorization. Phone-side undo writes an `UndoRequest`-style flag the agent honors (or the agent's mutation is directly reversed locally — both sides converge via sync).

**Conflict semantics:** CloudKit last-writer-wins per record is acceptable, with explicit rules on top: captures are append-only; list items are small and single-user; deletes are tombstones (`done`/`undone` flags rather than hard deletes where it matters); **a user edit always wins over pending polish** — once `userEditedAt` is set, the agent never writes `finalTranscript` and the phone suppresses any late-arriving polish (offered at most behind a non-destructive "Improved transcript available" affordance, never auto-applied); **`done=true` is sticky** — a check-off survives any sync merge (merge = OR of the `done` flags).

**Failure modes:** Mac asleep/offline → captures accumulate in iCloud, drain when it wakes (agent runs at login; Mac set to never sleep or wake for network); the phone shows the ambient reachability line ("Mac last active 2 m ago" / "Mac offline — 3 waiting") rather than leaving the user guessing. Ollama error → status `error`, capture stays visible as raw, retryable. Low confidence → `needsReview`, surfaced as the one-decision queue; ignored items age into plain notes.

## v1 scope

**In:** always-listening voice + text/photo capture (pre-warmed, VAD-gated, motion-endpointed via `EndpointEngine`, multi-thought splitting); on-device Parakeet transcription with visible Draft→Polished lifecycle + diff highlight; word-level tap-to-correct feeding the lexicon (manual corrections + Contacts seed); Gemma caption + on-device OCR for photos; auto-categorize with tappable filing receipts (undo / move-to, surfaced due dates); Ask inbox with FTS5-only retrieval; check-off (sticky `done`); undo; needs-review one-decision queue; in-context first-run.

**Out (v2+):** whisper-large fallback transcription; embedding retrieval for Ask; model-extracted lexicon entities; own-voice gating in busy places (enroll Joshua's voice via FluidAudio speaker embeddings; captures start only for the enrolled speaker); instruction execution ("move everything to Monday"); reminders/calendar integration; direct LAN/Tailscale transport for snappy Q&A; Apple Watch; multi-user.

## Build order

1. iOS home (always-listening ledger) against a **mock pipeline** (UI-SPEC.md "Implementation round 1"): pre-warmed VAD-gated recording, mock `EndpointEngine`, draft transcript, ledger rows, polish diff + filing receipts driven by `MockPipeline`
2. Shared SwiftData package + CloudKit container; both app targets syncing the schema; `saved→uploaded→processing→done` lifecycle wired end-to-end
3. Mac agent skeleton: menu-bar app, remote-change observation, Parakeet re-run for audio-only captures, reachability heartbeat
4. Enrichment: gpt-oss tool schema + Gemma vision; polish delivery (edit-wins rule), list mutations + `ActionLog` + receipts
5. iOS lists UI: check-off (sticky `done`), undo/move-to, provenance links; needs-review queue; word-level correction + lexicon (Contacts seed)
6. Ask: FTS5 index on Mac, `Question`/`Answer` flow, ask inbox + answer notification
7. Action Button intent + widget; first-run flow; hardening (retries, re-run pipeline command)

---
*v3 (2026-06-09): folded UX review — visible Draft→Polished transcript lifecycle (user edit wins over polish), `saved/uploaded/processing/done` status + ambient Mac reachability, filing receipts with undo/move-to logged as learning signal, Ask inbox model, pre-warmed capture, one-decision review queue, sticky `done`; v1 scoped to FTS5 retrieval, no whisper fallback, manual+Contacts lexicon; UI split out to UI-SPEC.md.*
*v3.1 (2026-06-09): dead-screen direction — always-listening home ledger (VAD-gated, no record button, no tab bar); `EndpointEngine` stop via disposal motion / pocket / lock, silence never stops; `split_capture` tool; countdown ring removed.*
