# FrictionlessNotes — UI Spec v1 · "Stage Whisper"

Companion to DESIGN.md v3. Implementation-ready spec for the iOS app. Dark-first; SwiftUI, iOS 17+.

## 1. Design language: Stage Whisper

A stage whisper is projected restraint — theatrical, but hushed. The app is a dark quiet stage; the user's words are the only performer. Drama comes from motion, depth, typography, and light at exactly **three** moments (§3); everything else is still. Nothing decorative ever sits between the user and capture: the hot path (open → record → save) has zero animation gates and zero extra steps. Reference confidence: a great camera app's readiness; Things 3's calm.

Rules of restraint:

- One accent color on screen at a time.
- **Light is the signal** — status and drama communicate by luminance change more than hue.
- Chrome recedes during capture (non-essential controls dim to 40% while recording).
- Animation layers on top of a live UI, never in front of it.

### 1.1 Color tokens (dark-first; light mode derives by inverting the ink ramp onto warm paper `#F7F6F2`)

| token | hex (dark) | role |
|---|---|---|
| `stage0` | `#0B0B0F` | app background (near-black, blue-cooled) |
| `stage1` | `#15151B` | cards |
| `stage2` | `#1E1E26` | sheets / popovers |
| `hairline` | `#FFFFFF` @10% | separators, card strokes (0.5 pt) |
| `ink` | `#F4F4F8` | primary text |
| `inkDim` | `#9C9CA8` | secondary text |
| `inkFaint` | `#5E5E6A` | tertiary, placeholders |
| `live` | `#FF4F3D` | recording — the only saturated red in the app |
| `polish` | `#6FE3C2` | polish shimmer, "Improved transcript" affordance |
| `lamplight` | `#FFD66B` | warm highlight: receipts, due dates |

Status roles (lifecycle states; always a 6 pt dot + label, never color alone):

| state | token | hex | dot behavior |
|---|---|---|---|
| Saved | `statusSaved` | `#8E8E93` | static |
| Uploaded | `statusUploaded` | `#64B5FF` | static |
| Processing | `statusProcessing` | `#FFD66B` | breathing (`pulseProcessing`) |
| Done | `statusDone` | `#34D17B` | chip fades out after 3 s — done is the default, not a badge |
| Needs review | `statusReview` | `#FF9F0A` | static, persists |
| Error | `statusError` | `#FF453A` | static, persists |

Category accents — 2 pt leading tick on cards/rows; 12%-tint capsule backgrounds:

| todo | shopping | idea | note | journal | reference |
|---|---|---|---|---|---|
| `#5BA8FF` | `#4CD98A` | `#C792F2` | `#9C9CA8` | `#F2A65A` | `#6FD2E0` |

### 1.2 Typography

SF Pro everywhere — except the one expressive typographic moment: **the hero transcript is set in New York**, live during recording and in capture detail. Spoken thought gets typeset like prose; the UI around it stays engineering-grade sans.

| style | font | spec | usage |
|---|---|---|---|
| `heroTranscript` | New York | 28 pt medium, tracking −0.5, line 1.25 | live transcript overlay; detail hero text |
| `title` | SF Pro Display | 22 semibold | screen titles |
| `cardTitle` | SF Pro Text | 17 semibold | detail/sheet titles |
| `body` | SF Pro Text | 17 regular | previews, list items, answers |
| `caption` | SF Pro Text | 13 regular | chips, receipts, timestamps |
| `micro` | SF Pro Text | 11 medium, small caps | status labels, "MAC LAST ACTIVE 2M AGO" |

All styles map to Dynamic Type text styles and scale; `heroTranscript` caps at accessibility XL.

### 1.3 Spacing / radius / depth

| token | value |
|---|---|
| `s1…s8` | 4, 8, 12, 16, 20, 24, 32, 40 pt (4-pt grid) |
| `rCard` | 16 pt continuous |
| `rChip` | capsule |
| `rSheet` | 24 pt continuous, top corners |
| depth | no drop shadows on `stage0`; sheets get black 40% / blur-30 underlay. Depth = layered luminance (`stage0→1→2`), not shadow. |

### 1.4 SF Symbols rules

- Symbol weight always matches adjacent text weight; `.regular` default, `.medium` in chips.
- Monochrome rendering; `.hierarchical` only on `inkDim` surfaces; `.palette` never.
- `.fill` variants exclusively for active states (`mic` → `mic.fill` while recording).
- Canonical set: `mic` capture · `keyboard` text · `camera` photo · `arrow.uturn.backward` undo · `tray` review · `questionmark.bubble` ask · `link` provenance · `checkmark.circle` check-off · `desktopcomputer` Mac status · `character.book.closed` lexicon · `sparkle` polish affordance (the only sparkle in the app).

## 2. Motion + haptics

All springs interruptible (`.spring(response:dampingFraction:)`); durations are decays, never gates. **The capture hot path never animates:** record start/stop response, text-field focus, camera shutter, and the local save are instant state changes — animation may follow them, never precede or delay them.

| name | curve | timing | used by |
|---|---|---|---|
| `springCaptureOpen` | spring(0.32, 0.86) | — | capture chrome settling in *after* recording is already live; sheet presentation |
| `shimmerPolish` | ease-out | 600 ms decay, 18 ms/token stagger | polish diff highlight (M2) |
| `slideReceipt` | spring(0.38, 0.80) in; ease-in 250 ms out | visible 5 s | filing receipt (M3) |
| `checkOff` | ease-out | 200 ms fill + 150 ms strike wipe | list check-off |
| `pulseProcessing` | sine, opacity 0.55↔1.0 | 1.8 s loop | processing dot, "Thinking on your Mac…" |
| `breatheListening` | amplitude-driven | continuous 60 fps | waveform field (M1) |
| `dimThinking` | ease-out | 400 ms in, holds | thinking-silence dim + "still with you" |
| `roomGoesDark` | ease-in-out | 250 ms | ledger fades out as the Listening Field rises |
| `fadeStatus` | ease-in-out | 300 ms | chip transitions, done-chip departure |

Never animated: switching capture modes, error states (appear instantly), list scrolling (no parallax), anything in the first 100 ms of a capture.

Haptic vocabulary — one physical sentence per event; never two haptics within 250 ms; all generators `prepare()`d alongside the audio pre-warm:

| event | generator | pattern |
|---|---|---|
| record start | impact `.rigid` | single, 1.0 |
| record stop | impact `.soft` | double, 80 ms apart, 0.7 |
| capture saved (text/photo) | impact `.light` | single, 0.6 |
| filed (receipt appears) | impact `.soft` | single, 0.5 — quieter than save |
| correction learned | impact `.light` | single, 0.4 |
| answer arrived (foreground) | impact `.soft` | double, 120 ms apart, 0.5 |
| check-off | impact `.light` | single, 0.5 |
| review accept | impact `.light` | single, 0.4 |
| error / Mac offline at ask | notification `.warning` | system |

## 3. Signature moments — exactly three; everything else stays quiet

### M1 · The Listening Field
The recording visualization. Screen dims to `stage0`; chrome drops to 40% (`fadeStatus`). A horizon of light: 44 vertical bars, 3 pt wide, `s1` gaps, baseline at 62% height, drawn in `TimelineView(.animation)` + `Canvas` at 60 fps. Bar height = EMA of RMS (α 0.3) log-mapped to 4–96 pt; color `live` at center with opacity falloff `1−(|i−22|/22)^1.6` toward the edges. Above the horizon, the draft transcript typesets live in `heroTranscript` (New York): latest ~3 lines, older lines fading to `inkFaint` and sliding up 12 pt per line (spring 0.4/0.9). Bars grow from zero over 250 ms *after* recording has already started — the `record start` haptic fires at t=0, not at animation start. **Silence = thinking, never a countdown:** after 2.5 s below VAD threshold the field dims 25% (`dimThinking`) and "still with you" appears in `micro`; it waits indefinitely (3-min cap only). Any voice restores instantly, no animation. Stop comes from the `EndpointEngine` — disposal rotation while silent, pocket, lock, or tap: `record stop` haptic; bars collapse to a 1 pt line that travels into the new ledger row's position — a single shared-geometry move, 350 ms, the only hero transition in the app. A disposal-stop completes even as the phone goes dark in a pocket — the haptic is the receipt.

### M2 · The Polish Sweep
Polish arriving on a visible transcript. Word-level diff (longest-common-subsequence) finds changed tokens; each cross-fades old→new **in place** with a `polish`-tinted underline + 12% background that ignites left→right, 18 ms stagger per changed token, each decaying over 600 ms (`shimmerPolish`). Height-stable: new text renders into the same line boxes via crossfade — never a reflow jump mid-read; unchanged tokens never move. **If the user is editing:** no sweep — a one-line bar slides under the editor (`sparkle` + "Improved transcript available", `caption`/`polish`); tap → side-by-side diff sheet with Apply / Keep mine; saving a user edit silently discards the pending polish. Off-screen rows take polished text with no animation — the sweep only plays in front of eyes that were reading the draft.

### M3 · The Filing Receipt
The moment the Mac files a thought. On `done` with actions, a slim receipt slides from beneath the ledger row (`slideReceipt`): `stage2` capsule, hairline stroke, leading category tick, `caption` text — "→ Shopping: milk, eggs" with the list name in `lamplight`. Inferred due dates always printed: "→ Todo: call Dana — **due Fri**". Trailing "Undo" text button. Tap body → Move-to sheet (one-tap list picker); tap Undo → action reversed, receipt flips to "Removed" and fades. Auto-settles after 5 s into a permanent compact provenance footer on the row (category chip + list name). Arrival = `filed` haptic. Multiple actions stack receipts 4 pt apart, 80 ms stagger. Undo and Move-to both log a `refile` learning signal.

## 4. Screens (v1)

Navigation: **no tab bar, no record button — one dark surface.** Home is the always-listening Ledger; the mic is live and VAD-gated from the first frame (nothing recorded or saved until voice is detected). Speak → the room goes dark: the ledger fades out and the Listening Field takes the stage (M1). Edge swipes: **Lists** (right edge) · **Ask** (left edge). Pull down → keyboard (text capture); swipe up → camera. Needs-review is a pinned ledger row with a quiet count; Settings is a long-press on the date line. **First run:** the empty ledger with one `inkFaint` line — "Say something. I'll do the rest." Mic permission is requested on first open (the surface listens); camera on first shutter.

### 4.1 Home — the always-listening Ledger
- **Layout:** `stage0`-black. Top: date line in `micro` (long-press → Settings). Body: today's ledger rows (§4.2). Bottom: the **listening horizon** — a 1 pt baseline of `live` at 10–18% opacity, breathing slowly; the only always-on light, the quiet promise that it's already listening. `MacStatusPill` appears above it only when noteworthy.
- **Mic live + VAD-gated from first frame.** No audio retained, no capture created until voice is detected. The system mic indicator is accepted as honest.
- **Speak → the room goes dark:** ledger fades to black over 250 ms while the Listening Field (M1) rises from the horizon — recording began before the animation did (pre-buffer stitches the first word).
- **Pre-warm:** on appear (and inside the AppIntent before UI), audio session active + `prepareToRecord` + rolling 1.5 s pre-buffer.
- **Stop (`EndpointEngine`):** disposal rotation while VAD-silent · pocket (proximity) · lock/background · tap · 3-min silence cap. Silence alone only dims (M1). On stop: collapse-to-row (M1 exit), `record stop` haptic.
- **Other inputs:** pull down → keyboard (send = instant save, row appears); swipe up → camera (shutter; OCR on save). Neither touches the mic.

### 4.2 Ledger (scrolls back through the days)
- **Row, not card** — ink on black, no container: 2 pt category tick of light · one line of New York (`body` size, `ink` at 80%) — summary once filed, first draft line until then · relative time in `micro` trailing. Photo captures append "· photo" in `micro`. 56 pt thumbnail only in detail.
- **Status lives in the tick:** processing = tick replaced by a breathing `lamplight` dot (`pulseProcessing`); saved/uploaded = `statusSaved`/`statusUploaded` dot; done = the category tick, quietly (no chip, no badge — handled is the default). needsReview/error dots persist.
- Receipts (M3) slide beneath the newest row as actions land, then settle into its footer as the provenance row.
- A waiting row is **fully alive**: tap → detail with editable draft. Never an empty placeholder.
- Days separated by `micro` date lines; bottom whisper when relevant: "everything handled · one polishing".
- Pinned row when review queue non-empty: `tray` "needs review · 3" with `statusReview` dot.
- **Detail:** ONE hero text in `heroTranscript` — `finalTranscript ?? deviceTranscript ?? ocrText`. Below, a single quiet disclosure "Details" → OCR text, VLM caption, summary, audio player, ActionLog. **Tap-to-correct:** tap any word → `WordCorrectionSheet` (lexicon candidates + free field); on save the transcript patches, the (heard → meant) pair is stored, a 2 s toast confirms "Got it — I'll remember 'Beauchamp'", `correction learned` haptic. Polish arriving here follows M2 rules (incl. the editing hold).

### 4.3 Lists
- Index: rows with category tick, name, open-count. Tap → list.
- **Item row:** `checkmark.circle` (tap = `checkOff` motion + haptic; `done` is sticky across sync) · text `body` · due chip in `lamplight` when present · qty suffix · trailing `link` glyph → source capture (provenance). Swipe: delete (tombstone), move.
- Done items sink into a collapsed "Done" section. No celebration — quiet.

### 4.4 Ask inbox
- Not a chat. Top: ask field (`questionmark.bubble`, "Ask your notes…"); submit clears instantly and the question becomes an inbox card below.
- **Question card states:** Thinking — `pulseProcessing` dot + "Thinking on your Mac…" · Mac offline — immediate honest "Mac offline — will answer when it's back" (`statusError` dot, no spinner) · Answered — answer in `body` + citation chips (capsule, `caption`, source snippet; tap → capture detail) · Failed — retry.
- Background arrival → local notification "Answer ready"; opening scrolls to the card with a 300 ms `fadeStatus` highlight. No theatrics — M-moments are capture-only.

### 4.5 Needs-review queue
- A calm finite list, not a swipe deck. Each row = **one decision**: best guess + reason ("Looks like a **todo** — 'call' + a date", reason in `inkDim`), transcript preview, two controls — **Accept** (fills guess) and **Other…** (category picker). Either way one tap; row exits 250 ms ease-in, count decrements.
- Quiet badge only (pinned-row count). Items untouched 7 days auto-file as plain notes (ActionLog entry, no notification).

### 4.6 Settings (minimal)
- **Mac:** status line — last active, queue depth ("3 waiting").
- **Lexicon:** entries (term, heard-forms, source icon), swipe-delete, manual add; one-time "Seed from Contacts" with count.
- **Permissions:** mic / camera / notifications rows deep-linking to system settings.
- **Data:** media storage used; "Re-run pipeline" debug action.

## 5. Component inventory

| component | screen(s) | responsibility | tokens / motion |
|---|---|---|---|
| `ListeningSurface` | Home | always-on VAD-gated mic; owns room-goes-dark + collapse-to-row | `roomGoesDark`; start/stop haptics |
| `ListeningHorizon` | Home | 1 pt breathing baseline — the always-on light | `live` @ 10–18%, `breatheListening` |
| `EndpointEngine` | Home (service) | fuses VAD + Core Motion attitude + proximity/lock into stop signals | — |
| `ListeningFieldView` | Home | M1 waveform horizon + thinking dim | `live`, `breatheListening`, `dimThinking` |
| `LiveTranscriptView` | Home | New York draft lines materializing/fading | `heroTranscript` |
| `MacStatusPill` | Home, Settings | ambient reachability ("Mac offline — 3 waiting") | `micro`, `stage2` |
| `LedgerRow` | Ledger | tick of light, one serif line, time; status in the tick; receipts attach | category accents, `pulseProcessing` |
| `LifecycleChip` | Detail | saved→uploaded→processing→done (+review/error) dot+label | status tokens, `pulseProcessing`, `fadeStatus` |
| `FilingReceipt` | Ledger, Detail | M3 receipt; Undo / Move-to; due dates | `lamplight`, `slideReceipt`; `filed` haptic |
| `PolishDiffText` | Ledger, Detail | M2 token-diff shimmer; height-stable crossfade | `polish`, `shimmerPolish` |
| `ImprovedTranscriptBar` | Detail (editing) | held polish → side-by-side diff sheet | `polish`, `sparkle` |
| `HeroTranscript` | Detail | the one best text, New York | `heroTranscript` |
| `DetailDisclosure` | Detail | OCR/caption/summary/audio/log behind one fold | `inkDim` |
| `WordCorrectionSheet` | Detail | candidates + field; saves (heard→meant) | `stage2`, `rSheet`; correction haptic |
| `ListItemRow` | Lists | check-off, due chip, provenance link | `checkOff`, category accents |
| `ProvenanceLink` | Lists, Ledger | jump to source capture | `link`, `caption` |
| `AskComposer` | Ask | question field; instant enqueue | `body` |
| `QuestionCard` | Ask | thinking/offline/answered/failed states | status tokens, `pulseProcessing` |
| `CitationChip` | Ask | tappable source → capture detail | capsule, `caption` |
| `ReviewRow` | Review | one decision: guess + reason, Accept/Other | `statusReview` |
| `LexiconEditor` | Settings | entries CRUD + Contacts seed | `caption` |
| `FirstRunOverlay` | Capture | invitation copy; in-context permission triggers | `inkFaint` |

## 6. Implementation round 1

Goal: **capture surface + feed fully working against a mock pipeline** — every state and all three signature moments demonstrable with no Mac, no CloudKit.

Order:

1. `Theme.swift` (§1 tokens), `Motion.swift` (§2 curves), `Haptics.swift` (vocabulary, pre-prepared generators).
2. Model layer as plain structs first (`Capture`, `CaptureStatus`, `FilingAction`); SwiftData arrives in build-order step 2 of DESIGN.md.
3. **Stub seams:**
   - `protocol Transcriber { func start() -> AsyncStream<TranscriptUpdate>; func stop() async -> String }` — `ParakeetTranscriber` (FluidAudio, wraps the existing `AudioCaptureManager` pre-warm) and `MockTranscriber` (canned tokens at ~280 ms cadence + fake RMS for the waveform).
   - `protocol PipelineClient { func submit(_ c: Capture); var events: AsyncStream<PipelineEvent> { get } }` with `PipelineEvent = .statusChanged(id, CaptureStatus) | .polish(id, newText) | .filed(id, [FilingAction]) | .needsReview(id, guess, reason)`. `MockPipeline`: uploaded +1 s · processing +2 s · polish +4 s (canned diffs incl. a homophone fix) · filed +4.5 s (one receipt with an inferred due date) · 1-in-5 `needsReview`; a toggleable offline flag.
   - `protocol MacReachability { var status: AsyncStream<MacStatus> { get } }` — mock cycles online / offline / queue-depth.
   - `protocol Endpointer { var signals: AsyncStream<EndpointSignal> { get } }` with `EndpointSignal = .voiceStarted | .thinkingSilence | .disposalDetected | .pocketed | .silenceCapped`. `MotionEndpointer` (VAD + CMDeviceMotion attitude + proximity/lock fusion) and `MockEndpointer` (simulator keys trigger each signal).
4. Home: `ListeningSurface` + `ListeningHorizon` + pre-warm wiring, `ListeningFieldView` + `LiveTranscriptView` with thinking-dim (M1 complete incl. room-goes-dark), text-entry path.
5. Ledger: `LedgerRow` + status-in-the-tick driven by `PipelineEvent`s; the M1 collapse-to-row transition.
6. `PolishDiffText` (M2) on card and detail; `HeroTranscript` + `DetailDisclosure`.
7. `FilingReceipt` (M3) with Undo/Move-to calling back into `PipelineClient` (mock logs the `refile`).
8. `MacStatusPill` + offline states.

**Exit criteria (demo script):** cold-open → already listening, ledger visible; speak → room goes dark, words typeset; pause 30 s → it dims and waits; speak again → restores; simulate disposal rotation → stop haptic, collapse-to-row; watch Draft → uploaded → processing → polish sweep → receipt (mock emits a `split_capture` once: one recording becomes two rows); tap Undo; toggle mock offline and see the honest states. Round 2 swaps `MockPipeline` for the CloudKit-backed client without touching a view.

---
*UI-SPEC v1 (2026-06-09) — companion to DESIGN.md v3.*
*UI-SPEC v1.1 (2026-06-09): dead-screen revision — always-listening Ledger home (no tab bar, no record button), room-goes-dark capture, ledger rows replace cards, `EndpointEngine` stop signals, thinking-dim replaces countdown ring.*
