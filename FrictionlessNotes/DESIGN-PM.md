# FrictionlessNotes — Design v4 · the to-do that runs like a project manager

Companion to DESIGN.md (v3, capture) and UI-SPEC.md (Stage Whisper). This document adds the
layer on top: typed deadlines, a deterministic urgency engine, an AI planner that works out how
to get from here to there, and a Program surface that borrows the parts of the BMT Program PM
console that worked. It changes nothing about the capture surface.

## 1. What this is, in one paragraph

A thought goes in with zero friction (speak, type, photograph, say it in the car) and lands in
the ledger instantly, exactly as today. Behind it, three brains work at three speeds: the
on-device first pass tints the row in milliseconds; Gemma files it as a task, a deadline, a
project or a note in seconds; and a planner re-reads the whole ledger and rewrites the plan: which
hard deadlines are safe, which are at risk, what to do today, what to drop or move, and which
questions only Joshua can answer. The Program surface shows that plan the way the BMT Program
console shows its ledger: a Now strip, projects with paths, and self-contained decision cards. Hard deadlines are also served outward as a calendar feed
that Outlook and Google subscribe to; nothing is ever read from the work calendar.

## 2. Why this is not the BMT Program PM

The BMT Program ledger is aspirational: stages (Build → Live), threads that move when sessions
work, decisions that unblock work. Nothing there has a date that bites.

Here, dates bite. A grant deadline, a review due in ten days, a school form, a flight. So:

- **Every target carries a deadline kind.** `hard` (fixed, missing has a consequence the planner
  never moves) · `goal` (aspirational, the planner may propose moving it and says so) · `none`
  (backlog).
- **Urgency is arithmetic, not opinion.** Slack against hard deadlines is computed on the phone on
  every change, with no model in the loop, so "what's urgent" is always current and always the
  same answer for the same facts.
- **The model's job is judgment:** breaking a target into steps, estimating effort, spotting
  dependencies and collisions, writing the plain-words assessment, and asking when it can't
  decide.

## 3. Principles (added to DESIGN.md's five)

6. **Capture never waits on the planner.** A task is on the list and on the Now strip the moment
   Gemma files it; the planner refines, it never gates.
7. **Deadlines are typed.** Hard and goal are different objects to the engine and to the eye.
8. **Urgency is arithmetic; judgment is the model's.** Slack, overload and "will miss" come from
   dates and estimates. Decomposition, estimates and the brief come from the planner.
9. **Decisions come as cards that stand alone.** Question, why now, background, what each answer
   does, what happens if you don't answer. (The rule Joshua set for the BMT console on 2 Nov.)
10. **Plain words, five colours, one meaning each.** Blue = your move · green = on track ·
    orange = waiting or a goal slipping · red = a hard deadline at risk · purple = idea/scratch.
    Same vocabulary as `bmt-ui.css`, so the Mac console can share it later.

## 4. What carries over

| from | keep as is | extend |
|---|---|---|
| FrictionlessNotes capture | always-listening ledger, EarsEngine, MotionEndpointer, text composer, CarPlay scene, tap-to-correct + Lexicon, receipts with Undo/Move, SwiftData records (CloudKit-ready) | `Capture` gains nothing; filing output grows (§5) |
| FrictionlessNotes brain | `PipelineClient` seam, `CategoryFirstPass` (ANE), `GemmaPipeline` lenient JSON parsing, Ask (question vs capture) | Gemma's `FilingDecision` gains `deadline`, `deadlineKind`, `project`, `effortMinutes`, `waitingOn` (§6.2); Ask answers from the plan too ("what's due this week?") |
| FrictionlessNotes lists | `ListItem` with provenance, sticky `done` | `ListItem` becomes `Task` (same record, more fields) |
| mac-brain/organize.swift | the organize prompt (merge fragments, split topics, action items with due hints, alerts) | becomes the planner's "ingest" half (§6.3) |
| BMT Program ledger | projects (colour, lead, goal) · work items · decisions · paths (ordered steps, state derived, never kept by hand) · ideas/scratchpad · conflicts | threads → **waiting-on board** (people and external things instead of sessions); stages → task states; a work item's "who" → `waitingOn` |
| BMT Program console | Now strip (Doing now · Waiting on you · Ready) · Needs-you cards urgent first, deferred fold away · thread board with "last moved" and "new since your last visit" · path tracker with the current step outlined · demo mode + self-test | Now strip becomes **Due · At risk · Today** (§8) |
| BMT Program sweep + digest | hourly sweep files answers and triages stale rows · 07:45 digest | planner pass on every change (debounced) plus a morning pass; the digest becomes the morning brief notification |
| ASH 2026 planner | Supabase `accounts` + `sync` + `ics` edge functions, secret-code account, feed token, VTIMEZONE/stable-UID `.ics` | copied into a separate Supabase project that becomes the hub: ledger store, phone sync, calendar feed (§9.1) and the MCP server for assistants (§9.2) |
| BMT design system | system font, light/dark follow the Mac, grouped lists, one button shape, one status tag, one banner | adopted for the Mac console (phase 4); the phone keeps Stage Whisper |

## 5. Data model

Value structs everywhere, `@Model` records at the boundary, same pattern as `Capture`/`CaptureRecord`.
All records CloudKit-ready (optional/defaulted, no unique constraints).

```
Project    id, name, colour, goal, kind(work|personal), archived
Target     id, project→, title, due: Date?, kind(hard|goal|none),
           whyItMatters, consequenceIfMissed, done, doneAt,
           sourceCaptureID
Task       id (= today's ListItem), text, project→, target→?, state(todo|doing|waiting|done),
           effortMinutes?, dependsOn:[Task], waitingOn: String? (a person or an event),
           due: Date?, dueKind(hard|goal|none)  — a task may carry its own date,
           category(todo|shopping), group, done, doneAt, createdAt,
           sourceCaptureID, sourceActionID
Path       id, target→, steps:[PathStep]            — the route from here to there
PathStep   order, task→, needsYou: Bool, milestone: Bool,
           effortMinutes (your work), leadDays (elapsed waiting: a reviewer, a shipment),
           latestFinish: Date, plannedStart: Date, plannedEnd: Date, targetDate: Date
           — state and all four dates are derived by the engine (§6.1), never typed in;
           effort and lead come from the planner, calibrated by actuals (§10)
Decision   id, project→, target→?, question, whyNow, background, touches,
           options:[{label, consequence}], ifUnanswered, askedAt, answeredAt?, answer?,
           deferredUntil?
Idea       id, project→?, text, createdAt, sourceCaptureID?
Assessment id, computedAt, engine|planner, perTarget:[TargetStatus], today:[Task],
           overloads:[Overload], brief: String, proposals:[Proposal]
TargetStatus  target→, remainingMinutes, slackDays, state(onTrack|atRisk|willMiss|done)
Overload      window (week), committedMinutes, capacityMinutes
Proposal      kind(moveGoal|dropTask|splitTarget|reestimate), text, applied: Bool
Document   id, title, kind(pdf|article|url|note|image), scope(project→|target→|task→),
           storageKey (hub object store), sourceURL?, addedFrom(phone|mac|claude|chatgpt|gemini|email),
           extractedText (server-side, page-stamped), summary (planner, one paragraph),
           tags:[String], bytes, addedAt
           — syllabi, articles, idea notes, forms: anything the work needs at hand.
           The file itself lives in the hub; the app and the assistants read the text.
Capture       unchanged (immutable raw input)
LexiconEntry  unchanged
```

`ListItem` is renamed `Task` in code with a migration shim; the record keeps its table.

## 6. The three brains

### 6.1 Tier 0 — the urgency engine (phone, deterministic, every change)

Runs in `CaptureStore` on any mutation, in under a millisecond. No model.

- **Remaining work for a target** = Σ `effortMinutes` of its open tasks (default 30 min when
  unestimated; the planner fills real estimates later).
- **Capacity** = `dailyCapacityMinutes` × working days (setting; default 180 min/day, Mon–Fri).
  Phase 3 subtracts calendar events.
- **Schedulability (earliest-deadline-first):** order hard targets by due date; walk them
  accumulating remaining work; a target's **slack** = working minutes between now and its due date
  minus the cumulative work of it and every hard target due before it.
- **States:** `willMiss` when slack < 0 · `atRisk` when slack < buffer (default: 20% of remaining
  work, at least one working day) · else `onTrack`. Goals use the same arithmetic but at most
  reach `atRisk`, and the planner is asked to propose a new date instead of raising an alarm.
- **Backward scheduling (the trick).** A deadline is never served as one date. The engine
  decides when each composite part should be done from three inputs:
  1. **the other obligations** — every other target's steps competing for the same days, the
     recurring commitments (clinic days, teaching, call) entered as capacity patterns, and events
     from the personal calendars Joshua allows; the work calendar is invisible, so a standing
     "unseen load" fraction is reserved on work days;
  2. **a reasonable expectation of how long each part takes** — the planner's `effortMinutes`
     (Joshua's own work) and `leadDays` (elapsed waiting on someone else), calibrated against
     the actuals log (§10), with a buffer that grows when the estimate has no history behind it;
  3. **the deadline and its kind** — the wall for a hard target, a movable line for a goal.
  Two walks. Backwards from the deadline: each step's `latestFinish` = the next step's latest
  start; its latest start = `latestFinish` minus lead time minus effort spread over capacity.
  That is the wall. Forwards from today, earliest-deadline-first across all targets: each step is
  placed into real working time as `plannedStart`/`plannedEnd`, and its **`targetDate`** is the
  date the engine chooses for it: planned end plus the step's buffer, never later than the wall.
  Target dates are the dates the calendar shows and the dates Joshua is held to; the wall appears
  only as "no later than" in the description. A step whose planned end passes its wall is late,
  and that is what makes its target `atRisk` or `willMiss` — the alarm names the step, not just
  the date. Steps the planner marks `milestone` ("figures done", "draft to co-authors") are the
  ones served to the calendar (§9.1). Re-planning, a check-off, a new hard target or a changed
  capacity pattern moves every target date in one pass, in under a millisecond.
- **Today** = the open tasks on the critical path of the earliest at-risk or will-miss hard target,
  then the next hard target's first step, then goal steps, cut at today's capacity.
- **Overload** = any coming week whose committed hard work exceeds capacity.

Everything the Now strip shows comes from this engine, so it is right even when the planner is
offline, out of budget or disagreeing with itself.

### 6.2 Tier 1 — Gemma filing (phone, seconds, exists)

`GemmaFilingDecision` grows five fields, each lenient/optional, with the same few-shot style:

```
"deadline": "2026-11-21 or null",     "deadlineKind": "hard|goal|null",
"project": "short label or null",     "effortMinutes": 45,
"waitingOn": "person or event, or null"
```

Prompt rules: a date spoken with "must", "due", "deadline", "by Friday or else" → `hard`;
"I'd like to", "aim", "ideally", "try to" → `goal`; never invent a date. Receipts print the kind:
"→ Task: FAIMI corrected copy — **due Mon 2 Nov · hard**". Undo/Move keep working; a new receipt
action "make it a goal" flips the kind and logs a refile signal (learning data).

The ANE first pass stays as it is.

### 6.3 Tier 2 — the planner (Claude Opus 5.5, minutes, new)

One structured call per pass. Input: a compact JSON snapshot of the ledger (open targets, tasks,
decisions, ideas, the last assessment, Tier-0 numbers, today's date, capacity). Output: one JSON
object the engine can apply:

```
decompositions  [{targetID, steps:[{text, effortMinutes, dependsOnIndex, needsYou}]}]
estimates       [{taskID, effortMinutes, reason}]
links           [{taskID, targetID | projectID}]            — things Gemma filed without a home
conflicts       [{taskIDs, text}]                            — same day, same person, same resource
decisions       [{question, whyNow, background, touches, options, ifUnanswered, targetID?}]
proposals       [{kind, text, targetID?, taskID?, newDue?}]  — move a goal, drop, split, re-estimate
brief           "three or four plain sentences: what's safe, what's at risk, what today is for"
```

Decomposition is the planner's main job: a target arrives as one line ("R21 resubmission due the
20th") and must leave as an ordered path with, per step, a reasonable effort estimate, a lead time
when someone else is in the loop, dependencies, which steps are milestones worth a calendar date,
and which need Joshua rather than anyone else. The engine does the dating; the planner never
writes a date except a proposed new goal date. Estimates must be defended in one clause each
("two figures, you took 90 min each last time"), so a bad one can be corrected on the receipt.

Rules in the system prompt: a hard date is never moved, only flagged; goals may be moved with the
reason stated; never create a task the user didn't imply; ask (a decision) rather than guess when a
deadline kind or an owner is ambiguous; keep the brief in the Morning Brief voice (observe, hand
over, never command, never pad).

Mechanics:
- Messages API over HTTPS from the phone (`URLSession`; there is no Swift SDK), model
  `claude-opus-5-5`, adaptive thinking (default), `output_config.format` with the JSON schema
  above so the reply can't be malformed, `max_tokens` 16000. The system prompt and schema go first
  and never change, so prompt caching covers them; the ledger snapshot comes last.
- Cadence: debounced 90 s after the last change, plus a morning pass (notification = the brief),
  plus "re-plan now" in the Program surface. A pass on a 200-item ledger is ~15k input tokens:
  cents, not dollars, even at twenty passes a day.
- Apply = diff, not overwrite: decompositions add tasks (with provenance `plannedBy`), estimates
  fill blanks or replace planner-made estimates only (a user estimate wins), decisions land as
  cards, proposals wait for a tap. Every applied change is logged like a `FilingAction`, so it
  shows as a receipt and can be undone.
- Fallbacks: no network → Tier 0 keeps the Now strip honest and the Program surface says
  "plan from Tuesday 07:40". Alternative backend, same contract, behind the same seam: the Mac
  brain (`mac-brain/organize.swift` → Ollama `gpt-oss:120b`) via CloudKit, for a fully local
  setup. Decide once (§11, question 1).

## 7. Decisions: the card format

Copied from the BMT console on 2 Nov, because it is what made that console usable from a phone.
A card always carries: the question in plain words · why now · background · what it touches ·
one button per answer with what that answer does · "if you don't answer: …" · "defer" which folds
it away until a date. Answering writes the answer and `answeredAt` and re-runs Tier 0 at once; the
planner picks it up on the next pass. No relay, no sweep: the thing that acts on the answer is the
app itself.

Decisions come from three places: the planner (ambiguity, over-commitment: "two hard deadlines
collide on the 20th, which slips?"), the engine (`willMiss` on a hard target always raises
"what gives?" with the planner's proposals as the options), and Joshua himself (an idea with a
question mark files as a decision to self).

## 8. Surfaces

### 8.1 Home (unchanged, plus one line)

The always-listening ledger stays exactly as UI-SPEC §4.1. The lists affordance line becomes the
**Now whisper**: "2 hard this week · 1 at risk · 4 today" in `micro`, red only when something is
`willMiss`. Tap → Program.

### 8.2 Program (new; left-edge swipe, the Ask slot in the spec moves to a long-press)

Phone-first single column in Stage Whisper tokens, the BMT layout rearranged for dates:

1. **Now strip** — three boxes: **Due** (hard targets by date, slack printed: "FAIMI corrected copy ·
   Mon · 1.5 d slack"), **At risk** (red, with the one-line reason from the engine), **Today**
   (the engine's cut, checkable in place). The strip is Tier-0 data, so it never lags.
2. **Needs you** — decision cards, will-miss first, then at-risk, then planner questions, then
   proposals to accept; deferred fold away. Same header counts as the BMT console: "3 for you ·
   2 waiting on others · 1 slipping goal".
3. **Projects** — one row per project with its colour, a progress bar (done minutes / total), the
   next hard date and a "for you" count. Tap → the project: targets as path trackers (boxes, current
   step outlined, YOU-marked steps), its tasks grouped by state, its conflicts, its ideas.
4. **Waiting on** — the thread board reborn: one row per person or external thing, what you're
   waiting for in words, since when, "new" since your last look.
5. **Ideas & scratchpad** — purple, per project, one box to jot; a jot is a capture (provenance).

Planner provenance is visible but quiet: a task the planner added shows "planned" in the
`micro` footer the way a filed row shows its category; the brief sits at the top of Program in
`heroTranscript` serif, one paragraph, timestamped.

### 8.3 Target detail

Hero: the title and the date with its kind in words ("hard deadline" / "goal"). Then: why it
matters, consequence if missed, the path, remaining vs slack, the capture it came from. Buttons:
move (goals only; moving a hard date asks "are you sure, this is a hard deadline"), split, done.

### 8.4 Mac (phase 4)

A read-mostly console in the `bmt-ui.css` look over the same CloudKit-synced store: Now strip
across the top, projects left, Needs-you centre, waiting-on right, ideas bottom. Answer buttons
work there too. Same selftest discipline as the BMT console (demo mode, a read-only check against
the real store).

## 9. Inputs (the "multiple mechanisms")

| input | status | lands as |
|---|---|---|
| voice, always-listening (phone) | built | capture → Gemma → task/target |
| typed composer (pull down) | built | same |
| CarPlay mic button | built | same |
| photo + OCR (swipe up) | planned in v3 | same, OCR text as the transcript |
| **Share sheet extension** | phase 3 | a URL, mail or PDF becomes a capture with the source attached |
| **App Intent** (Siri, Action Button, Shortcuts) | phase 3 | "add a hard deadline: …" straight to Gemma, no UI |
| **Lock-screen / Home widget** | phase 3 | one-tap mic and the Now strip's three numbers |
| **Personal calendar read** (EventKit, only calendars Joshua ticks) | phase 3 | events reduce capacity; "due"/"submit" titles become goal targets to confirm. The work calendar is never read (§9.1) |
| **Mac menu bar hotkey** | phase 4 | text capture to the same store |
| Ask ("what's due this week?") | built (keyword) | answered from the assessment, not just the notes |

Every input is a `Capture` first, so every task, target and idea can be traced back to the words
that made it.

### 9.1 Calendar out, never in

The work calendar can't be read (HIPAA), so the app **serves** a calendar to Outlook and Google
instead of reading theirs. Two routes, both one-way:

- **A live subscription feed, never a one-time file (phase 2).** Calendar apps are given a URL
  they keep re-fetching, so the calendar follows the ledger for as long as the subscription
  exists; a downloaded `.ics` is deliberately not offered, because it freezes the moment it is
  imported. The pattern is the ASH 2026 planner's, copied into **its own Supabase project**
  (`frictionless-pm`; nothing shared with `ash2026-planner`, which stays a conference tool with
  public data): one `accounts` row per secret code, and an edge function `ics?t=<feed token>` that renders the
  current ledger on every request as a VCALENDAR with a VTIMEZONE block, stable UIDs and a
  `SEQUENCE` that increments when a target changes, so a moved deadline updates in place and a
  done one disappears. Outlook subscribes with "Add calendar → Subscribe from web", Google with
  "Other calendars → From URL", Apple Calendar with "New Calendar Subscription". The phone pushes
  a minimal projection on every change (title, date, kind, project, status, slack); nothing else
  leaves the device. The feed token is separate from the sync code, so sharing the feed never
  exposes the account.
  Refresh cadence is the subscriber's, not ours: Outlook desktop and Microsoft 365 re-fetch
  roughly every 3 hours, Apple Calendar at whatever interval is chosen (down to every 5 minutes),
  Google only every several hours and sometimes longer. That is fine for deadlines and wrong for
  "today" tasks, so the feed carries targets and dated tasks only. For the personal Google
  calendar, phase 3 can add a direct write through the Google Calendar API (OAuth to Joshua's own
  account, not the work one), which lands in seconds; the work Outlook calendar stays on the
  subscription because nothing else is permitted there.
- **EventKit write (phase 3).** A dedicated "Deadlines" calendar on the phone, written with
  EventKit, for any Google or iCloud account already on the device. Instant, no backend, but it
  can't reach a managed work Outlook, which is why the feed comes first.

What the feed shows is the route, not the list. For each target it serves the composite parts
the engine dated (§6.1):

- the deadline itself: an all-day event titled with its kind ("FAIMI corrected copy · hard"); a
  goal is tentative (`TRANSP:TRANSPARENT`); an at-risk target carries the late step and its slack
  in the description;
- each milestone step as its own all-day event on its **`targetDate`** ("Figures done · 2 of 5 ·
  R21"), the date the engine chose for it given everything else; the description carries the
  wall ("no later than Nov 15") and the estimate it was built on;
- optionally (`&blocks=1`), the planned work blocks as timed events (`plannedStart`–`plannedEnd`),
  which is the calendar version of "today": they move whenever the plan re-runs.

A target that moves, a step checked off, or a re-plan updates every one of these in place (same
UID, higher `SEQUENCE`); undated, unplanned tasks never appear. Feed variants per account, like
the ASH planner's `&m=1`: deadlines only · deadlines and milestones · everything with blocks.

### 9.2 Assistants as inputs and editors (MCP)

Conversations with Claude, ChatGPT and Gemini must be able to add, change and complete tasks,
targets and decisions, so the ledger has to be reachable by all three. The one interface they
share is the Model Context Protocol, so the Supabase project (§9.1) also hosts a **remote MCP
server** over HTTPS with a per-assistant token. Its tools are the ledger's verbs, nothing more:

```
capture(text, source)                 — the frictionless door: any sentence, filed by the same Gemma/planner path
list_plan(scope)                      — the Now strip, targets with paths, target dates, decisions
add_target(title, due?, kind?, why?)  — a deadline with its kind
add_steps(target, steps[])            — a decomposition the assistant worked out in conversation
update_step(id, effort?, lead_days?, done?, text?)
propose(target|step, change, evidence)  — a date, kind, scope or step change; lands as a receipt to accept
answer_decision(id, option)
defer_decision(id, until)
note_actual(step, minutes)            — "that took 40 minutes"
```

Every write carries `source: claude | chatgpt | gemini | phone | mac` and is logged as a receipt
the phone shows, undoable like any filing action; a write from an assistant never bypasses the
engine, so target dates recompute the same way. Hookup: Claude (claude.ai, Claude Code, this
session) attaches it as a custom connector; ChatGPT attaches it as a custom MCP connector
(developer-mode connectors); Gemini reaches it from Gemini CLI and the Gemini API's MCP support
today, with the consumer Gemini app to be verified before it is promised. The feed token
(§9.1) and the MCP tokens are separate and each revocable.

**Both directions, by example.** ChatGPT, reading an email with your Gmail connector, sees the
D&I instructor move assignment 4 to Nov 27. It calls `propose(target T5, due 2026-11-27, source
chatgpt, evidence "email from … on Nov 10")`. The hub records a proposal, not a change; the
phone shows a receipt ("ChatGPT proposes: D&I assignment 4 → Nov 27 · accept / ignore"), the
next `now` read in any assistant lists it under proposals, and the date moves only when you
accept, in whichever place you happen to be. The reverse: you say "midterm's done" to the phone in
the car; the next time you open ChatGPT it reads `now`, sees under *since you last looked* that
the midterm is done and the back assignments are now today's work, and talks to you from that
plan without being told.

Two rules make this safe:

- **Propose, don't overwrite.** Assistants may `capture` freely (a capture is raw input, like a
  spoken thought) and may mark something done when you said so in that conversation. Anything
  that moves a date, changes a kind, adds or removes steps, or touches a hard deadline is a
  `propose`, which lands as a receipt with its evidence and the assistant's name. You accept or
  ignore it anywhere; ignored proposals expire in seven days. The engine never schedules from an
  unaccepted proposal.
- **A cursor per assistant.** Every token has a last-read mark; `now` returns the current plan
  plus a *since you last looked* block (added, done, moved, proposed, by whom), so each assistant
  learns about work that arrived through the phone, the Mac, another assistant or email, and the
  block stays short because it is only the delta.

**Making it background, not a tool you have to remember.** Attaching the MCP server gives each
assistant the verbs; what makes it ambient is a standing instruction in each account plus one
cheap read at the start of every conversation:

- The server exposes a `now` resource (and a `/now` prompt) that returns the Now strip and the
  open decisions in about 300 tokens, so pulling it into every chat costs nothing noticeable.
- The same four-line protocol goes into each platform's standing-instruction slot: *at the start
  of a conversation read `now`; when I state a commitment, a date or a "need to", call
  `capture`; when I say something is done, call `update_step`; never ask me to confirm a capture,
  just show the receipt line.* Claude: a Project instruction and a user-level `CLAUDE.md` rule for
  Claude Code (a `SessionStart` hook can inject `now` without being asked, which is true
  background); ChatGPT: the connector plus Custom Instructions / Memory; Gemini CLI:
  `settings.json` MCP entry plus `GEMINI.md`.
- The consumer Gemini app can't attach a custom MCP server yet, so its background path is the
  calendar: it already reads the personal Google calendar the feed is subscribed to (read side),
  and anything it is asked to add goes into a dedicated "FrictionlessNotes inbox" Google Tasks
  list or calendar that the hub polls and captures (write side). An email capture address
  (`capture@…` forwarded into the hub) is the universal fallback every assistant can reach.
- Scheduled passes (the morning brief, the planner) run server-side, so the assistants always
  read a plan that is already current rather than planning in the chat.

### 9.3 Documents: kept with the work, served by MCP

Tasks, targets and projects carry documents: a syllabus on the modeling class, the reviewer
guidelines on the manuscript, three articles on the ASH talk, a page of ideas. The hub stores
the file (Supabase Storage, private bucket) and, on upload, extracts its text once (PDF text,
OCR for scans and photos, readable text for a URL) with page or section stamps, and asks the
planner for a one-paragraph summary and tags. From then on the document is reachable three ways:

- **In the app**: a Documents row on the project, target and task detail (count, titles, open
  the file); the phone's photo capture and Share-sheet extension, the Mac's drag-and-drop and
  menu-bar drop target, and the email capture address all add documents with the capture as
  provenance; a document attached to a task is inherited by its target and project views.
- **To assistants, as context**: the `now` resource lists the documents attached to today's
  items by title and id, and `read_document(id, range?)` returns extracted text in token-bounded
  chunks with page stamps, so Claude or ChatGPT can read the syllabus when the midterm comes up
  without being handed the file. `search_documents(query, scope?)` finds the right one first
  (keyword now, embeddings later, same upgrade path as Ask).
- **To assistants, for active work**: `document_url(id)` returns a short-lived signed link to the
  original file for a session that needs the whole PDF, and `attach_document(scope, url|text|
  file)` lets a conversation save what it found (a paper it located, a draft it wrote) back onto
  the task, as a proposal if it would replace something and as a plain attachment otherwise.

Documents never enter the engine: they don't schedule anything. They are the material next to
the work, and the point of serving them through MCP is that any conversation about a project
starts with the same pile you would have open on your desk. Nothing from the clinical side goes
here: the hub is for personal and academic material, and the capture address refuses attachments
that look like records.

Added MCP verbs: `list_documents(scope)`, `read_document(id, range?)`, `search_documents(query,
scope?)`, `document_url(id)`, `attach_document(scope, source)`.

**Consequence for the backbone.** With three assistants writing, the ledger's home is the
Supabase Postgres, not CloudKit: the phone syncs to it (newest-wins per record, the ASH
planner's `sync` pattern), the Mac console reads it, the feed renders from it, and the planner
(§6.3) can run server-side as a Supabase scheduled function calling Claude, which also settles
§11 question 1. The engine (§6.1) still runs on the phone for instant answers and once more on
the server so assistants see the same numbers. CloudKit is dropped from phase 4.

Because the work calendar is invisible to the app, capacity (§6.1) can only be the manual setting
minus events from calendars Joshua explicitly allows. The planner is told that the real day is
busier than it can see, and biases its "today" cut accordingly.

## 10. Learning loop

Three free signals, all already logged or one line away:

- **Refiles** (Undo, Move, "make it a goal"): labels for the ANE classifier and few-shot lines
  for Gemma, as today.
- **Actuals vs estimates**: when a task is checked off, the elapsed `doing` time (or a quick
  "took: 15 / 45 / 90 min" on the receipt) is stored; the planner gets the last 50 pairs in its
  snapshot and is told to calibrate.
- **Decision answers**: the planner sees how past decisions were answered (defer vs act, move vs
  hold) and is told not to re-ask settled kinds of question.

## 11. Open questions for Joshua

1. **Where does the planner run?** With the Supabase hub (§9.2) the natural place is a
   server-side scheduled function calling Claude Opus 5.5, with the phone able to request a pass
   on demand. The Mac-brain alternative (Ollama, fully local) stays possible behind the same seam
   but can't serve the assistants. Confirm the server-side choice.
2. **Capacity source.** Manual minutes-per-day, minus only the personal calendars Joshua ticks
   (the work calendar stays unread, §9.1). Is a per-weekday setting enough, or should Program
   let him mark "clinic day / lab day" patterns?
3. **Scope of the app.** Keep notes, journal and reference captures in the same ledger (they
   still file, they just don't enter the engine), or split the project-manager into its own app?
   (Recommended: same app; the capture surface is the whole point.)

## 11b. v4.1 — from a to-do list to a life project manager

Joshua's reaction to phase 1 (2026-11-08): "this looks like a to-do list and I want it to be a
life project manager." The gap is structural: the unit on screen was the task with a date. v4.1
reorganizes around what he is committed to, with time as the scarce resource shared among them.

1. **Areas and a portfolio.** Life areas (research, clinical, learning, teaching and service,
   family, health; renamed and reweighted by him) each with an *intended share* of working time.
   Projects live in areas and carry a goal, a one-paragraph narrative of where they stand, people,
   a horizon (week · month · quarter · year · someday), a status, a health reading derived from
   their targets (worst open target), the next milestone with its engine-chosen date, remaining
   work, and when they were last touched. The Mac home is this portfolio; an area with no project
   or no planned time is flagged in words, not hidden.
2. **Horizons and a roadmap.** Milestones laid across the coming weeks per project, red where a
   step runs past its wall, so collisions months out are a picture.
3. **Balance.** Planned minutes per area for the coming week against the intended share, from
   the same scheduler; neglect is stated plainly ("nothing planned in Family, Health this week").
4. **Intake, not adding.** A new commitment shows its cost before it is accepted: the engine
   re-plans with it included and lists every existing target whose state or slack gets worse,
   and what state the new one would land in. The button reads "Take it on" / "Take it on anyway".
   (Built on the Mac's Add deadline sheet; the phone gets the same card when a captured deadline
   would collide.)
5. **Rhythms (next).** Morning brief from the assessment, an evening check-in that records what
   happened, a weekly review that walks each area; capacity learns recurring life commitments.
6. **The Now strip stays, demoted** to the menu bar and its own page.

Model additions in `PlanCore`: `Area` (name, colour, intendedShare, order), `Project` gains
`areaID`, `horizon`, `status`, `narrative`, `people`; `Ledger` gains `areas`. Older ledgers decode
with defaults and get the default areas on first open.

## 12. Build order

**Where the code lives (as of 2026-11-08).** `PlanCore/` is a local Swift package shared by both
apps: the value types (§5), the Tier-0 engine (§6.1, `PlanEngine.swift`, a port of
`pm-prototype/engine.py`), the JSON ledger and the seed importer, with `swift test` covering the
engine and the seed. The iPhone app links it from the Xcode project; the Mac app is the package
`FrictionlessMac/` (menu-bar Now strip, Now · Needs you · Projects · Time · Ideas), wrapped into an
app bundle by `FrictionlessMac/make-app.sh` and reading `~/Library/Application Support/
FrictionlessNotes/ledger.json` until the hub replaces the file. The order below was changed on
2026-11-08: core first, then the Mac app, then the phone's Program surface.

1. **Typed deadlines + engine + Program surface (phone, no new infra).** `Target`, `Task` (from
   `ListItem`), `Decision`, `Idea`, `Project` records; Tier-0 engine with unit tests on dates and
   slack; Gemma schema extension with receipts printing the kind; Program surface sections 1–3
   and the Now whisper; target detail. Exit: speak "the R21 resubmission is due the 20th, hard;
   I'd like the figures done by Friday" → one hard target, one goal, both on the Now strip with
   correct slack; add three steps to the target by hand and see them dated backwards from the
   20th; check one off and watch every date recompute.
2. **Planner.** API client behind the `PipelineClient`-style seam (`Planner` protocol, `MockPlanner`
   for the simulator), structured output, apply-as-diff with receipts and undo, decision cards,
   the brief, re-plan button, morning pass + notification. Exit: a 30-item ledger with two
   colliding hard dates produces a "what gives?" card whose options are the planner's proposals,
   and answering it re-plans within two minutes.
   **Also here: the calendar feed** (§9.1) in its own Supabase project, lifted from the ASH
   planner's functions, so decomposed deadlines reach Outlook and Google from the first week the
   engine is trusted. Exit: a hard target spoken on the phone appears in work Outlook at the next
   subscription refresh as the deadline plus its milestone dates, and checking off a step moves
   the remaining milestones rather than duplicating them.
3. **Inputs and documents.** Document storage, text extraction and the Documents rows (§9.3);
   Share sheet, App Intent + Action Button, widget, personal-calendar capacity
   subtraction and EventKit "Deadlines" calendar, waiting-on board, ideas pane, actuals capture. Exit: a deadline arrives by Siri
   with the phone in a pocket and shows up at risk on the lock-screen widget.
4. **Mac, sync and assistants.** Phone ↔ Supabase sync (the ASH `sync` pattern), the MCP server
   with its tools and per-assistant tokens, Mac console in the `bmt-ui.css` look over the same
   store, menu-bar capture, learning loop in the planner prompt. Exit: say "add a hard deadline:
   grant report Dec 20" in ChatGPT, see it on the phone's Now strip with its steps dated, and
   answer its first decision from this Claude session.

---
*v4 (2026-11-08): written after reviewing the BMT Program PM session (ledger, console, sweep,
digest, unified design system). Carries over its ledger shape, decision-card format, Now strip
and path trackers; replaces its aspirational stages with typed deadlines and a deterministic
urgency engine; adds a Claude-backed planner behind a seam.*
