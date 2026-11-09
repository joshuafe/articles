# frictionless-pm · the hub

The server side of FrictionlessNotes' life project manager (DESIGN-PM.md §9): its own
Supabase project, `frictionless-pm`, holding the ledger, serving the calendar feed Outlook
and Google subscribe to, re-running the deterministic planner every half hour, and speaking
MCP to Claude, ChatGPT and Gemini. The Mac app syncs with it; `ledger.json` stays as the
offline cache.

```
hub/
  planner/                  TypeScript port of PlanCore (engine, models, seed importer, ICS, now)
  supabase/migrations/      1 ledger tables + RLS · 2 SQL verbs · 3 pg_cron
  supabase/functions/       feed · replan · mcp · sync   (+ _shared/db.ts, rest.ts)
  scripts/                  bundle.sh (one file per function) · setup.sql (tokens, cron)
  deno.json                 deno task test | check | bundle
```

## Running the tests

```bash
cd hub && deno task test        # 17 tests: PlanEngineTests + SeedImporterTests ported, schedule.md byte-for-byte, ICS, now
cd hub && deno task check       # type-check planner + functions
cd ../PlanCore && swift test    # the Swift engine the port mirrors
```

## Deploying (first time)

1. Create the Supabase project `frictionless-pm` (its own project; nothing shared with ash2026-planner).
2. Apply the three migrations in order (dashboard SQL editor, `supabase db push`, or the MCP `apply_migration`).
3. Deploy the four functions **with JWT verification off** — they authenticate their own tokens:
   `deno task bundle` writes `dist/<fn>.js`; deploy each as `index.ts` (MCP `deploy_edge_function`,
   `verify_jwt: false`), or `supabase functions deploy <fn> --no-verify-jwt` from `hub/`.
4. Run `scripts/setup.sql` with `<ref>` filled in. It sets `settings.hub_url`, stores the cron token in
   Vault, and prints five bearer tokens **once**: `mac`, `feed`, `claude`, `chatgpt`, `gemini`.
5. `select cron.job_run_details …` after 30 minutes confirms the scheduled re-plan; `POST /functions/v1/replan`
   with the mac token runs it now.

Tokens are revoked with `update api_tokens set revoked_at = now() where name = '…'`; an assistant is promoted
to write directly (no proposals) with `update api_tokens set trusted = true where name = '…'`.

## Endpoints

| | |
|---|---|
| `GET  /functions/v1/feed?t=<feed token>` | text/calendar: deadlines + milestone steps on their planned dates |
| `…&m=0` / `…&blocks=1` | deadlines only / everything incl. timed work blocks |
| `POST /functions/v1/replan` | run the engine, store the assessment, raise/clear `E-` decisions (trusted token) |
| `POST /functions/v1/mcp/<assistant token>` | MCP, streamable HTTP, JSON-RPC 2.0 |
| `GET/POST /functions/v1/sync` | the Mac: pull the snapshot / push a change batch (device token) |

## Calendar subscription (never a one-time import)

The URL is `https://<ref>.supabase.co/functions/v1/feed?t=<feed token>`. Add `&blocks=1` if you want
the planned work blocks as timed events too.

- **Google Calendar** (web): left sidebar → *Other calendars* **+** → **From URL** → paste → *Add calendar*.
  Google re-fetches every 12–24 h; the feed sends `Cache-Control: max-age=300` and an ETag so re-polls are
  cheap. (Google ignores `REFRESH-INTERVAL`; there is no way to make it poll faster.)
- **Outlook** (work, web or new Outlook): *Add calendar* → **Subscribe from web** → paste → name it
  *Deadlines*. Microsoft 365 re-fetches roughly every 3 hours.
- **Outlook classic / desktop**: *File → Account Settings → Internet Calendars → New* → paste.
- **Apple Calendar**: *File → New Calendar Subscription* → paste → set auto-refresh to every 5 minutes.

Each target is one all-day event titled `<title> · hard` (opaque) or `· goal` (tentative); each milestone
step is an all-day event on the date the engine chose (`<step> · 2 of 5 · <project>`) with its wall
("No later than …") and estimate in the description. UIDs are stable (`target-<id>`, `step-<id>`) and
`SEQUENCE` rises when a date moves, so a re-plan updates events in place instead of duplicating them;
a done target or step disappears at the next poll.

## MCP connectors

The server URL is `https://<ref>.supabase.co/functions/v1/mcp/<assistant token>` — the token rides in the
path because connector UIs have no header field. Use a different token per assistant (the cursor is
per token, so each one learns what the others and the phone did).

**Claude (claude.ai)** — *Settings → Connectors → Add custom connector*: name `Frictionless PM`, URL as
above, no OAuth. In a Project (or in Personal preferences) add the standing instruction:

> At the start of a conversation read the `now` resource from Frictionless PM. When I state a commitment,
> a date or a "need to", call `capture`. When I say something is done, call `update_step` with done=true.
> Never ask me to confirm a capture; show the receipt line.

**Claude Code** — `claude mcp add --transport http frictionless-pm https://<ref>.supabase.co/functions/v1/mcp/<token>`;
a `SessionStart` hook that calls the `now` tool makes it true background.

**ChatGPT** — *Settings → Apps & Connectors → Advanced → Developer mode* on, then *Create* a connector:
name, the URL above, authentication **None**. ChatGPT uses tools only, so `now` is also a tool; put the
same four-line protocol in *Custom instructions*. Enable the connector in a chat with the **+** menu.

**Gemini CLI** — in `~/.gemini/settings.json`:
```json
{ "mcpServers": { "frictionless-pm": { "httpUrl": "https://<ref>.supabase.co/functions/v1/mcp/<token>" } } }
```
and the protocol in `GEMINI.md`. The Gemini API's MCP support takes the same URL. The consumer Gemini app
cannot attach a custom MCP server yet; its path is the calendar feed (read) until Google ships connectors.

### Verbs

`now` · `capture(text)` · `list_plan(scope)` · `add_target(title, due?, kind?, why?, project?, steps?)` ·
`add_steps(target, steps[])` · `update_step(id, done?, effort_minutes?, lead_days?, text?)` ·
`propose(target|step, change, evidence)` · `answer_decision(id, option)` · `defer_decision(id, until)` ·
`note_actual(step, minutes)` · `accept_proposal(id)` · `reject_proposal(id)` (trusted only).

Rules (§9.2): `capture` and "done" are allowed for every token. Anything that moves a date, changes a kind,
or adds or edits steps becomes a **proposal** unless the token is trusted; proposals show up in `now` for
every assistant and in `ledger_snapshot.proposals` for the apps, and expire after seven days. Every write
appends to `events`; `now` returns the events since this token's cursor ("since you last looked") and
advances it.

## Mac app

Create `~/Library/Application Support/FrictionlessNotes/hub.json`:
```json
{ "url": "https://<ref>.supabase.co", "key": "fpm_mac_…" }
```
On launch the Mac pulls the hub's ledger (or, if the hub is empty and the Mac is not, pushes its ledger up
once), pushes the changed rows after every commit, and pulls again every minute. `ledger.json` is still
written on every change and is what the app opens when the hub is unreachable. Without `hub.json` nothing
changes from the file-only app.

## Planner tier (later)

The scheduled function that calls Claude Opus 5.5 (`claude-opus-5-5`) for decompositions, estimates and the
brief (§6.3) slots in next to `replan`: same `loadState`, output applied with `apply_changes` as proposals.
Not built yet.

## Live deployment (2026-11-09)

The hub runs in Supabase project `frictionless-pm`, ref `zxslnlhnfsaglobsfodn` (us-east-1, Free plan, its own
project). Applied there: the three migrations above plus `fix_apply_changes_state_cast`, which carried the
enum-cast fix now folded into `20261108000002_functions.sql`; a fresh install needs only the three files.
The four functions are deployed with JWT verification off from the minified bundles `deno task bundle` writes.
Tokens and the feed/MCP URLs live only in `~/Library/Application Support/FrictionlessNotes/hub-tokens.txt`
(the Mac's device token is in `hub.json` beside it); nothing secret is in this repo.

Verified on deploy: the feed returns `text/calendar` with one all-day VEVENT per open dated target and per
milestone step; the MCP endpoint answers `initialize`, `tools/call now|list_plan|capture`, and
`resources/read frictionless://now`; an untrusted `add_target` lands as a proposal; `trigger_replan()` from
Postgres reaches `replan` with the Vault token (HTTP 200); the Mac app seeded the empty hub from its
`ledger.json` and picked up a hub-side capture on its next 60-second refresh.
