// Shared by the feed, replan and mcp edge functions: the service-role client,
// token authentication, loading the ledger out of Postgres into the planner's
// types, and writing an assessment back. Row ↔ model mapping lives here so the
// planner stays free of snake_case.

import { Rest } from "./rest.ts";
import { plan } from "../../../planner/engine.ts";
import type {
  Area, CapacityModel, Decision, Idea, Ledger, PlanAssessment, PlanStep, Project, Target, TargetStatus, Task,
} from "../../../planner/models.ts";
import type { EventLike, ProposalLike } from "../../../planner/now.ts";
import { todayIn } from "../../../planner/dates.ts";

export type DB = Rest;

export function serviceClient(): DB {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY missing");
  return new Rest(url, key);
}

export interface ApiToken {
  id: string;
  name: string;
  kind: "assistant" | "device" | "feed";
  source: string;
  trusted: boolean;
}

/** Bearer header, `?t=` / `?token=` query, or a trailing path segment after the function name. */
export function extractToken(req: Request, fnName: string): string | null {
  const auth = req.headers.get("authorization");
  if (auth?.toLowerCase().startsWith("bearer ")) return auth.slice(7).trim();
  const url = new URL(req.url);
  const q = url.searchParams.get("t") ?? url.searchParams.get("token");
  if (q) return q;
  const parts = url.pathname.split("/").filter(Boolean);
  const i = parts.lastIndexOf(fnName);
  if (i >= 0 && parts.length > i + 1 && parts[i + 1].startsWith("fpm_")) return parts[i + 1];
  return null;
}

export async function authenticate(db: DB, token: string | null): Promise<ApiToken | null> {
  if (!token) return null;
  const { data, error } = await db.rpc("authenticate_token", { p_token: token });
  if (error) throw error;
  const row = Array.isArray(data) ? data[0] : data;
  if (!row || !row.id) return null;
  return { id: row.id, name: row.name, kind: row.kind, source: row.source, trusted: !!row.trusted };
}

// ── Row mapping ──────────────────────────────────────────────────────────────

type Row = Record<string, any>;

export const rowToArea = (r: Row): Area => ({ id: r.id, name: r.name, colourHex: r.colour_hex, intendedShare: r.intended_share, order: r.sort_order });
export const rowToProject = (r: Row): Project => ({
  id: r.id, name: r.name, colourHex: r.colour_hex, goal: r.goal, archived: r.archived, createdAt: r.created_at, areaID: r.area_id,
  horizon: r.horizon, status: r.status, narrative: r.narrative, people: r.people ?? [],
});
export const rowToTarget = (r: Row): Target => ({
  id: r.id, projectID: r.project_id, title: r.title, due: r.due, kind: r.kind, whyItMatters: r.why_it_matters,
  consequenceIfMissed: r.consequence_if_missed, done: r.done, doneAt: r.done_at, createdAt: r.created_at, sourceCaptureID: r.source_capture_id,
});
export const rowToTask = (r: Row): Task => ({
  id: r.id, text: r.text, category: r.category, group: r.group_label, due: r.due_hint, done: r.done, doneAt: r.done_at, createdAt: r.created_at,
  sourceCaptureID: r.source_capture_id, sourceActionID: r.source_action_id, projectID: r.project_id, targetID: r.target_id,
  pathOrder: r.path_order ?? 0, effortMinutes: r.effort_minutes, leadDays: r.lead_days ?? 0, milestone: !!r.milestone, needsYou: !!r.needs_you,
  waitingOn: r.waiting_on, dueDate: r.due_date, dueKind: r.due_kind, state: r.state ?? "todo", plannedBy: r.planned_by, actualMinutes: r.actual_minutes,
});
export const rowToDecision = (r: Row): Decision => ({
  id: r.id, code: r.code, projectID: r.project_id, targetID: r.target_id, question: r.question, whyNow: r.why_now, background: r.background,
  touches: r.touches, options: Array.isArray(r.options) ? r.options : [], ifUnanswered: r.if_unanswered, raisedBy: r.raised_by, askedAt: r.asked_at,
  answeredAt: r.answered_at, answer: r.answer, deferredUntil: r.deferred_until,
});
export const rowToIdea = (r: Row): Idea => ({ id: r.id, projectID: r.project_id, text: r.text, createdAt: r.created_at, sourceCaptureID: r.source_capture_id });
export const rowToCapacity = (r: Row | null): CapacityModel => ({
  minutesByWeekday: r?.minutes_by_weekday ?? [120, 120, 120, 120, 120, 300, 300],
  fixed: Array.isArray(r?.fixed) ? r!.fixed.map((f: Row) => ({ day: f.day, minutes: f.minutes, why: f.why ?? "" })) : [],
});

export const targetToRow = (t: Target): Row => ({
  id: t.id, project_id: t.projectID ?? null, title: t.title, due: t.due ?? null, kind: t.kind, why_it_matters: t.whyItMatters ?? null,
  consequence_if_missed: t.consequenceIfMissed ?? null, done: t.done, done_at: t.doneAt ?? null, created_at: t.createdAt, source_capture_id: t.sourceCaptureID ?? null,
});
export const taskToRow = (t: Task): Row => ({
  id: t.id, text: t.text, category: t.category, group_label: t.group ?? null, due_hint: t.due ?? null, done: t.done, done_at: t.doneAt ?? null,
  created_at: t.createdAt, source_capture_id: t.sourceCaptureID ?? null, source_action_id: t.sourceActionID ?? null, project_id: t.projectID ?? null,
  target_id: t.targetID ?? null, path_order: t.pathOrder, effort_minutes: t.effortMinutes ?? null, lead_days: t.leadDays, milestone: t.milestone,
  needs_you: t.needsYou, waiting_on: t.waitingOn ?? null, due_date: t.dueDate ?? null, due_kind: t.dueKind ?? null, state: t.state,
  planned_by: t.plannedBy ?? null, actual_minutes: t.actualMinutes ?? null,
});
export const decisionToRow = (d: Decision): Row => ({
  id: d.id, code: d.code, project_id: d.projectID ?? null, target_id: d.targetID ?? null, question: d.question, why_now: d.whyNow,
  background: d.background, touches: d.touches, options: d.options, if_unanswered: d.ifUnanswered, raised_by: d.raisedBy, asked_at: d.askedAt,
  answered_at: d.answeredAt ?? null, answer: d.answer ?? null, deferred_until: d.deferredUntil ?? null,
});

// ── Loading ──────────────────────────────────────────────────────────────────

export interface Settings {
  timezone: string;
  horizonDays: number;
  calendarName: string;
}

export interface HubState {
  ledger: Ledger;
  settings: Settings;
  proposals: ProposalLike[];
  /** The stored assessment, if replan has ever run. */
  assessment: PlanAssessment | null;
  /** Latest event id. */
  version: number;
  raw: Row;
}

export async function loadState(db: DB): Promise<HubState> {
  const { data, error } = await db.rpc("ledger_snapshot");
  if (error) throw error;
  const snap = data as Row;
  const ledger: Ledger = {
    areas: (snap.areas ?? []).map(rowToArea),
    projects: (snap.projects ?? []).map(rowToProject),
    targets: (snap.targets ?? []).map(rowToTarget),
    tasks: (snap.tasks ?? []).map(rowToTask),
    decisions: (snap.decisions ?? []).map(rowToDecision),
    ideas: (snap.ideas ?? []).map(rowToIdea),
    capacity: rowToCapacity(snap.capacity),
  };
  const s = snap.settings ?? {};
  const settings: Settings = {
    timezone: s.timezone ?? "America/New_York",
    horizonDays: s.horizon_days ?? 120,
    calendarName: s.calendar_name ?? "Deadlines (FrictionlessNotes)",
  };
  let assessment: PlanAssessment | null = null;
  if (snap.assessment && snap.assessment.computed_at) {
    const steps: Record<string, PlanStep> = {};
    for (const r of snap.assessment.steps ?? []) {
      steps[r.task_id] = {
        taskID: r.task_id, targetID: r.target_id, index: r.idx, wall: r.wall, latestStart: r.latest_start, plannedStart: r.planned_start,
        plannedEnd: r.planned_end, targetDate: r.target_date, late: r.late, minutesLeft: r.minutes_left,
      };
    }
    const targets: Record<string, TargetStatus> = {};
    for (const r of snap.assessment.targets ?? []) {
      targets[r.target_id] = { targetID: r.target_id, state: r.state, slackDays: r.slack_days, lateTaskIDs: r.late_task_ids ?? [], remainingMinutes: r.remaining_minutes };
    }
    const allocations: Record<string, { taskID: string; minutes: number }[]> = {};
    for (const r of snap.assessment.allocations ?? []) (allocations[r.day] ??= []).push({ taskID: r.task_id, minutes: r.minutes });
    assessment = { computedAt: snap.assessment.computed_at, today: snap.assessment.today, steps, targets, allocations, raised: [] };
  }
  return { ledger, settings, proposals: snap.proposals ?? [], assessment, version: snap.version ?? 0, raw: snap };
}

// ── Replan: run the engine and store the assessment ──────────────────────────

export interface ReplanResult {
  assessment: PlanAssessment;
  movedSteps: number;
  raisedNew: number;
  raisedCleared: number;
  sequences: { targets: Record<string, number>; steps: Record<string, number> };
}

/**
 * Runs the engine over the current ledger and stores plan_steps / target_status /
 * allocations, bumping a step's `sequence` when its target_date moved so the
 * calendar feed's VEVENTs update in place. Reconciles engine-raised decisions
 * by target the way MacStore.mergeEngineDecisions does: drop unanswered engine
 * cards whose target is no longer will-miss, add one for each newly will-miss
 * target that has none open (the `E-` code makes re-raising idempotent).
 */
export async function replan(db: DB, state: HubState, source: string, tokenId: string | null = null): Promise<ReplanResult> {
  const today = todayIn(state.settings.timezone);
  const a = plan({ today, capacity: state.ledger.capacity, targets: state.ledger.targets, tasks: state.ledger.tasks, horizonDays: state.settings.horizonDays });

  // Existing sequences / target dates
  const { data: oldSteps, error: e1 } = await db.from("plan_steps").select("task_id, target_date, sequence");
  if (e1) throw e1;
  const oldByTask = new Map<string, Row>((oldSteps ?? []).map((r: Row) => [r.task_id, r]));
  const { data: tgtRows, error: e2 } = await db.from("targets").select("id, version");
  if (e2) throw e2;
  const seqTargets: Record<string, number> = {};
  for (const r of tgtRows ?? []) seqTargets[r.id] = r.version ?? 0;

  let moved = 0;
  const seqSteps: Record<string, number> = {};
  const stepRows: Row[] = Object.values(a.steps).map((s) => {
    const old = oldByTask.get(s.taskID);
    let seq = old?.sequence ?? 0;
    if (old && (old.target_date ?? null) !== (s.targetDate ?? null)) {
      seq += 1;
      moved += 1;
    }
    seqSteps[s.taskID] = seq;
    return {
      task_id: s.taskID, target_id: s.targetID ?? null, idx: s.index, wall: s.wall ?? null, latest_start: s.latestStart ?? null,
      planned_start: s.plannedStart ?? null, planned_end: s.plannedEnd ?? null, target_date: s.targetDate ?? null, late: s.late,
      minutes_left: s.minutesLeft, sequence: seq, computed_at: a.computedAt,
    };
  });
  const statusRows: Row[] = Object.values(a.targets).map((t) => ({
    target_id: t.targetID, state: t.state, slack_days: t.slackDays ?? null, late_task_ids: t.lateTaskIDs, remaining_minutes: t.remainingMinutes, computed_at: a.computedAt,
  }));
  const allocRows: Row[] = [];
  for (const [day, list] of Object.entries(a.allocations)) list.forEach((al, i) => allocRows.push({ day, position: i, task_id: al.taskID, minutes: al.minutes }));

  // Write (plan_steps: upsert then prune; target_status: upsert then prune; allocations: replace)
  const keepSteps = new Set(Object.keys(a.steps));
  if (stepRows.length) { const { error } = await db.from("plan_steps").upsert(stepRows); if (error) throw error; }
  const staleSteps = [...oldByTask.keys()].filter((id) => !keepSteps.has(id));
  if (staleSteps.length) { const { error } = await db.from("plan_steps").delete().in("task_id", staleSteps); if (error) throw error; }
  if (statusRows.length) { const { error } = await db.from("target_status").upsert(statusRows); if (error) throw error; }
  {
    const { data: oldStatus } = await db.from("target_status").select("target_id");
    const keep = new Set(Object.keys(a.targets));
    const stale = (oldStatus ?? []).map((r: Row) => r.target_id).filter((id: string) => !keep.has(id));
    if (stale.length) { const { error } = await db.from("target_status").delete().in("target_id", stale); if (error) throw error; }
  }
  { const { error } = await db.from("allocations").delete().gte("position", 0); if (error) throw error; }
  for (let i = 0; i < allocRows.length; i += 500) {
    const { error } = await db.from("allocations").insert(allocRows.slice(i, i + 500));
    if (error) throw error;
  }
  { const { error } = await db.from("assessments").insert({ computed_at: a.computedAt, today, source, step_count: stepRows.length, raised: a.raised.length }); if (error) throw error; }

  // Engine decisions
  const raisedTargets = new Set(a.raised.map((d) => d.targetID));
  const openEngine = state.ledger.decisions.filter((d) => d.raisedBy === "engine" && !d.answeredAt);
  const toClear = openEngine.filter((d) => !raisedTargets.has(d.targetID ?? ""));
  if (toClear.length) {
    const { error } = await db.from("decisions").delete().in("id", toClear.map((d) => d.id));
    if (error) throw error;
    for (const d of toClear) await logEvent(db, source, tokenId, "cleared", "decision", d.id, `${d.code} · no longer will-miss`);
  }
  const toRaise = a.raised.filter((d) => !openEngine.some((o) => o.targetID === d.targetID));
  if (toRaise.length) {
    const { error } = await db.from("decisions").insert(toRaise.map(decisionToRow));
    if (error) throw error;
    for (const d of toRaise) await logEvent(db, source, tokenId, "raised", "decision", d.id, `${d.code} · ${d.question}`);
  }
  if (moved > 0 || toRaise.length || toClear.length) {
    await logEvent(db, source, tokenId, "replanned", "plan", null, `${moved} step date${moved === 1 ? "" : "s"} moved, ${toRaise.length} raised, ${toClear.length} cleared`);
  }
  // keep the in-memory ledger's decisions in step for callers that render right after
  state.ledger.decisions = state.ledger.decisions.filter((d) => !toClear.some((c) => c.id === d.id)).concat(toRaise);
  return { assessment: a, movedSteps: moved, raisedNew: toRaise.length, raisedCleared: toClear.length, sequences: { targets: seqTargets, steps: seqSteps } };
}

/** Sequences for the feed without re-planning: targets.version and plan_steps.sequence. */
export async function loadSequences(db: DB): Promise<{ targets: Record<string, number>; steps: Record<string, number> }> {
  const [{ data: t }, { data: s }] = await Promise.all([db.from("targets").select("id, version"), db.from("plan_steps").select("task_id, sequence")]);
  const targets: Record<string, number> = {};
  for (const r of t ?? []) targets[r.id] = r.version ?? 0;
  const steps: Record<string, number> = {};
  for (const r of s ?? []) steps[r.task_id] = r.sequence ?? 0;
  return { targets, steps };
}

/** Is the stored assessment current? True when nothing was written since it was computed and it was computed today. */
export function assessmentIsCurrent(state: HubState, lastEventAt: string | null): boolean {
  if (!state.assessment) return false;
  if (state.assessment.today !== todayIn(state.settings.timezone)) return false;
  if (lastEventAt && Date.parse(lastEventAt) > Date.parse(state.assessment.computedAt)) return false;
  return true;
}

export async function lastEventAt(db: DB): Promise<string | null> {
  const { data } = await db.from("events").select("at").order("id", { ascending: false }).limit(1);
  return data?.[0]?.at ?? null;
}

/** Load state and make sure the assessment is fresh (replanning if not). */
export async function currentPlan(db: DB, source: string): Promise<{ state: HubState; assessment: PlanAssessment; sequences: ReplanResult["sequences"] }> {
  const state = await loadState(db);
  const last = await lastEventAt(db);
  if (assessmentIsCurrent(state, last)) {
    return { state, assessment: state.assessment!, sequences: await loadSequences(db) };
  }
  const r = await replan(db, state, source);
  return { state, assessment: r.assessment, sequences: r.sequences };
}

// ── Events & cursors ─────────────────────────────────────────────────────────

export async function logEvent(db: DB, source: string, tokenId: string | null, kind: string, entity: string, entityId: string | null, summary: string, payload: unknown = null): Promise<number> {
  const { data, error } = await db.rpc("log_event", { p_source: source, p_token: tokenId, p_kind: kind, p_entity: entity, p_entity_id: entityId, p_summary: summary, p_payload: payload });
  if (error) throw error;
  return data as number;
}

export async function eventsSince(db: DB, tokenId: string, excludeOwn = true): Promise<{ events: EventLike[]; latest: number }> {
  const { data: cur } = await db.from("cursors").select("last_event_id").eq("token_id", tokenId).maybeSingle();
  const since = cur?.last_event_id ?? 0;
  let q = db.from("events").select("id, at, source, kind, entity, entity_id, summary, token_id").gt("id", since).order("id", { ascending: true }).limit(200);
  const { data, error } = await q;
  if (error) throw error;
  const all = (data ?? []) as (EventLike & { token_id: string | null })[];
  const latest = all.length ? all[all.length - 1].id : since;
  const events = excludeOwn ? all.filter((e) => e.token_id !== tokenId) : all;
  return { events, latest };
}

export async function advanceCursor(db: DB, tokenId: string, toEventId: number): Promise<void> {
  const { error } = await db.from("cursors").upsert({ token_id: tokenId, last_event_id: toEventId, last_read_at: new Date().toISOString() });
  if (error) throw error;
}

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json; charset=utf-8", ...headers } });
}
