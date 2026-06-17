# Round 1 — build notes & demo script

Round 1 per UI-SPEC §6: the always-listening home + ledger, fully working against
mocks. No Mac, no CloudKit, no SwiftData yet. All three signature moments are
demonstrable in the simulator.

## Run it

Open `FrictionlessNotes.xcodeproj` in Xcode, pick any iPhone simulator, Run.
No packages, no entitlements, no permissions needed in round 1 (the mock
transcriber never touches the mic).

## What's where

| file | role |
|---|---|
| Theme / Motion / Haptics | Stage Whisper tokens, curves, haptic vocabulary |
| Models | plain-struct `Capture`, statuses, `PipelineEvent`, `EndpointSignal` |
| Transcriber | `Transcriber` seam + `MockTranscriber` (canned scripts, ~280 ms cadence, synthetic RMS) |
| PipelineClient | `PipelineClient` seam + `MockPipeline` (uploaded +1 s · processing +2 s · polish +4 s · filed +4.5 s; every 5th → needsReview; offline flag; split for the 2-thought script) |
| Endpointer | `Endpointer` seam + `MockEndpointer`; `MacReachability` mock |
| CaptureStore | state machine; applies pipeline events; undo/move-to refile log |
| HomeView | always-listening ledger, room-goes-dark, pull-down composer, horizon, debug bar |
| ListeningFieldView | M1 — waveform + live New York typesetting + thinking dim |
| LedgerView | rows, status-in-the-tick, receipts attach |
| PolishDiffText | M2 — LCS diff, polish shimmer (overlay fade) |
| FilingReceiptView | M3 — receipt → undo/move-to → settles into provenance |
| CaptureDetailView | hero transcript, lifecycle chip, review card, details disclosure |

## Demo script (the debug bar is the MockEndpointer's keyboard; triple-tap toggles it)

1. Cold open → black, date line, horizon breathing, "Say something…"
2. Tap **voice** → room goes dark, words typeset live ("met forman" mishearing included), waveform breathes.
3. Tap **think** → field dims, "still with you". It waits. Tap **resume**.
4. Tap **disposal** (or **pocket**) → stop haptic, capture collapses into a ledger row.
5. Watch the tick: saved → uploaded → breathing (processing) → at ~4 s the polish sweep
   runs ("metformin" ignites and decays) → receipt slides out: "→ todo · ask Dr. Patel — due fri"
   plus "learned 'metformin'".
6. Tap the receipt → Move-to; or **undo** → "removed" (both logged as refile learning signals).
7. Tap **2-thought** → speak → disposal → one row becomes **two** (split_capture), each filed separately.
8. Tap **mac: on** to flip offline → captures hold at saved, pill shows "mac offline — N waiting";
   flip back → queue drains.
9. Pull down from the top → serif composer → type → instant row.
10. Every 5th capture lands in needs review → open it → one-decision card (accept / other…).
11. Tap any row → detail: hero New York text, lifecycle chip (done fades after 3 s), details disclosure.

## Known round-1 simplifications (intentional)

- Mock transcriber only — real mic + Parakeet (FluidAudio SPM) is round 3, behind the `Transcriber` seam.
- Polish shimmer fades as one pass; per-token 18 ms stagger is a round-2 refinement.
- Collapse-to-row is a fade/settle, not yet a shared-geometry flight.
- Camera path and word-level tap-to-correct arrive with rounds 2–3 (spec §6 ordering).
- `justFinalizedID` is wired for the row-highlight refinement but unused so far.

## Real ears (added after round 1)

The app now has actual hearing — FluidAudio SPM dependency (added directly to the
project file), `EarsEngine.swift` (AVAudioEngine mic → Silero VAD gate → Parakeet
TDT v3, 1.5 s pre-buffer, live partials by re-transcribing the utterance ~1/s),
and `MotionEndpointer.swift` (Core Motion disposal ≥70° while silent, proximity
pocket, 3-min cap). Mic permission is requested on first open; models (~600 MB)
download from Hugging Face on first run — the date line shows "downloading ears…".

**Testing with real voice:** run, grant mic, wait for model download, then just
talk. The simulator uses the Mac's microphone; motion/proximity don't exist there,
so the debug bar remains the stop signal (tap also works). On a real iPhone,
put the phone down mid-sentence and feel the stop haptic.

**Possible first-build fixups** (FluidAudio API names verified against README,
but minor renames are possible): `VadStreamState` type name, `VadConfig`
parameter labels, `AsrResult.text`. Paste any error and they're one-line fixes.

## Round 2 (next)

Shared SwiftData package + CloudKit container; swap `MockPipeline` for the
CloudKit-backed client without touching a view (DESIGN.md build order step 2).
Requires the paid Apple Developer Program (fix the Xcode login first).
