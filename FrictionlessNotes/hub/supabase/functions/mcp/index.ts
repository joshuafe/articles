// mcp — the remote MCP server assistants attach to (DESIGN-PM.md §9.2).
//
// Streamable HTTP transport, stateless: every JSON-RPC request is a POST to
//   https://<ref>.supabase.co/functions/v1/mcp/<assistant token>
// (or with `Authorization: Bearer <token>` for clients that can send headers).
// GET returns 405 (no server-initiated stream), DELETE is a no-op.
//
// Tools are the ledger's verbs, nothing more: capture, list_plan, add_target,
// add_steps, update_step, propose, answer_decision, defer_decision, note_actual,
// plus `now` (also exposed as a resource and a prompt) and accept/reject for
// proposals. Mutations from an untrusted token become proposals; a trusted
// token (the Mac, Joshua's own Claude) writes directly. Every write appends to
// `events`; `now` returns the events since this token's cursor and advances it.

import { type Day, dayOf, isDay, shiftDay, todayIn } from "../../../planner/dates.ts";
import type { Decision, DeadlineKind, Ledger, Project, Target, Task } from "../../../planner/models.ts";
import { tasksFor } from "../../../planner/models.ts";
import { listPlan, nowText, summarizeChange } from "../../../planner/now.ts";
import {
  advanceCursor, type ApiToken, authenticate, currentPlan, type DB, decisionToRow, eventsSince, extractToken, json, loadState,
  logEvent, replan, serviceClient, targetToRow, taskToRow,
} from "../_shared/db.ts";

const SERVER_NAME = "frictionless-pm";
const SERVER_VERSION = "0.1.0";
const SUPPORTED_PROTOCOLS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

const INSTRUCTIONS = `This is Joshua's life project manager (FrictionlessNotes). Deadlines are typed: "hard" is never moved by the planner, "goal" may be, "none" is backlog. At the start of a conversation read the \`now\` resource (or call the \`now\` tool): it is the current plan plus what changed since you last looked. When Joshua states a commitment, a date or a "need to", call \`capture\`. When he says something is done, call \`update_step\` with done=true. Anything that moves a date, changes a kind, or adds/removes steps goes through \`propose\` (or lands as a proposal automatically): he accepts it on the phone or Mac. Never ask him to confirm a capture; just show the one-line receipt the tool returns.`;

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, DELETE, OPTIONS",
  "access-control-allow-headers": "authorization, content-type, mcp-session-id, mcp-protocol-version, accept",
  "access-control-expose-headers": "mcp-session-id, mcp-protocol-version",
};

// ── Tool catalogue ───────────────────────────────────────────────────────────

const str = (description: string) => ({ type: "string", description });
const int = (description: string) => ({ type: "integer", description });
const bool = (description: string) => ({ type: "boolean", description });
const kindSchema = { type: "string", enum: ["hard", "goal", "none"], description: "hard = fixed, never moved by the planner; goal = aspirational, may move; none = backlog" };

const TOOLS = [
  {
    name: "now",
    description: "The Now strip (hard deadlines by date with slack, what is at risk, today's planned work), open decisions, pending proposals, and everything that changed since this assistant last looked. Read it at the start of a conversation. About 300 tokens.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "capture",
    description: "The frictionless door: file any sentence Joshua said as a raw capture (a todo in the inbox). Use it for commitments, dates, 'need to', ideas. Never ask him to confirm; return the receipt line.",
    inputSchema: {
      type: "object",
      properties: { text: str("What he said, verbatim or lightly cleaned"), source: str("Where it came from (optional, defaults to this token's source)") },
      required: ["text"],
      additionalProperties: false,
    },
  },
  {
    name: "list_plan",
    description: "The full plan: Now strip, this week's capacity vs committed minutes, every open target with its dated path (each step's wall, planned window and target date), loose tasks, open decisions and pending proposals.",
    inputSchema: {
      type: "object",
      properties: { scope: str("all (default) | now | targets | tasks | decisions | proposals | project:<name>") },
      additionalProperties: false,
    },
  },
  {
    name: "add_target",
    description: "Add a dated outcome (a deadline) with its kind. Trusted tokens create it; others propose it for Joshua to accept.",
    inputSchema: {
      type: "object",
      properties: {
        title: str("The outcome, e.g. 'R21 resubmission'"),
        due: str("YYYY-MM-DD (optional)"),
        kind: kindSchema,
        why: str("Why it matters (optional)"),
        project: str("Project name; created if new (optional)"),
        effort_minutes: int("Estimate for the first step if you have one (optional)"),
        steps: {
          type: "array",
          description: "Optional decomposition: ordered steps",
          items: { type: "object", properties: { text: str("Step"), effort_minutes: int("Your work in minutes"), lead_days: int("Elapsed waiting after this step"), milestone: bool("Worth a calendar date"), needs_you: bool("Only Joshua can do it") }, required: ["text"] },
        },
      },
      required: ["title"],
      additionalProperties: false,
    },
  },
  {
    name: "add_steps",
    description: "Append ordered steps (a decomposition worked out in conversation) to an existing target. Trusted tokens write; others propose.",
    inputSchema: {
      type: "object",
      properties: {
        target: str("Target id or a unique fragment of its title"),
        steps: {
          type: "array",
          items: { type: "object", properties: { text: str("Step"), effort_minutes: int("Your work in minutes"), lead_days: int("Elapsed waiting after this step"), milestone: bool("Worth a calendar date"), needs_you: bool("Only Joshua can do it") }, required: ["text"] },
        },
      },
      required: ["target", "steps"],
      additionalProperties: false,
    },
  },
  {
    name: "update_step",
    description: "Mark a step done (allowed for every token when Joshua said so), or change its effort, lead days or text (trusted tokens write; others propose).",
    inputSchema: {
      type: "object",
      properties: { id: str("Step (task) id or a unique fragment of its text"), done: bool("Done?"), effort_minutes: int("New estimate"), lead_days: int("New lead time"), text: str("New wording") },
      required: ["id"],
      additionalProperties: false,
    },
  },
  {
    name: "propose",
    description: "Propose a change to a target or step — a date, a kind, a title, an effort, scope — with evidence. Lands as a receipt Joshua accepts or ignores; nothing moves until he does.",
    inputSchema: {
      type: "object",
      properties: {
        target: str("Target id or title fragment (one of target/step)"),
        step: str("Step id or text fragment (one of target/step)"),
        change: {
          type: "object",
          description: "Fields to change",
          properties: { due: str("YYYY-MM-DD or null"), kind: kindSchema, title: str("New title"), text: str("New step text"), effort_minutes: int("New estimate"), lead_days: int("New lead time"), done: bool("Done"), why: str("Why it matters") },
          additionalProperties: true,
        },
        evidence: str("Where this comes from: 'email from the instructor on Nov 10'"),
      },
      required: ["change"],
      additionalProperties: false,
    },
  },
  {
    name: "answer_decision",
    description: "Answer an open decision card with one of its options (or free text), as Joshua said in this conversation.",
    inputSchema: { type: "object", properties: { id: str("Decision id or code (D3, E-1A2B)"), option: str("Option label, or the answer in words") }, required: ["id", "option"], additionalProperties: false },
  },
  {
    name: "defer_decision",
    description: "Fold a decision away until a date.",
    inputSchema: { type: "object", properties: { id: str("Decision id or code"), until: str("YYYY-MM-DD, or a number of days (default 3)") }, required: ["id"], additionalProperties: false },
  },
  {
    name: "note_actual",
    description: "'That took 40 minutes' — record what a step really took (the learning loop).",
    inputSchema: { type: "object", properties: { step: str("Step id or text fragment"), minutes: int("Minutes it took") }, required: ["step", "minutes"], additionalProperties: false },
  },
  {
    name: "accept_proposal",
    description: "Apply a pending proposal (trusted tokens only — this is Joshua's accept).",
    inputSchema: { type: "object", properties: { id: str("Proposal id") }, required: ["id"], additionalProperties: false },
  },
  {
    name: "reject_proposal",
    description: "Dismiss a pending proposal (trusted tokens only).",
    inputSchema: { type: "object", properties: { id: str("Proposal id"), note: str("Why (optional)") }, required: ["id"], additionalProperties: false },
  },
];

// ── Helpers ──────────────────────────────────────────────────────────────────

class ToolError extends Error {}

function text(t: string, structured?: unknown) {
  return { content: [{ type: "text", text: t }], ...(structured !== undefined ? { structuredContent: structured } : {}) };
}

function findTarget(ledger: Ledger, ref: string): Target {
  const r = ref.trim();
  const byID = ledger.targets.find((t) => t.id === r);
  if (byID) return byID;
  const open = ledger.targets.filter((t) => !t.done);
  const exact = open.filter((t) => t.title.toLowerCase() === r.toLowerCase());
  if (exact.length === 1) return exact[0];
  const partial = open.filter((t) => t.title.toLowerCase().includes(r.toLowerCase()));
  if (partial.length === 1) return partial[0];
  if (partial.length > 1) throw new ToolError(`"${ref}" matches ${partial.length} targets: ${partial.map((t) => `${t.title} (${t.id.slice(0, 8)})`).join("; ")}`);
  throw new ToolError(`no open target matches "${ref}"`);
}

function findTask(ledger: Ledger, ref: string): Task {
  const r = ref.trim();
  const byID = ledger.tasks.find((t) => t.id === r);
  if (byID) return byID;
  const open = ledger.tasks.filter((t) => !t.done);
  const exact = open.filter((t) => t.text.toLowerCase() === r.toLowerCase());
  if (exact.length === 1) return exact[0];
  const partial = open.filter((t) => t.text.toLowerCase().includes(r.toLowerCase()));
  if (partial.length === 1) return partial[0];
  if (partial.length > 1) throw new ToolError(`"${ref}" matches ${partial.length} steps: ${partial.map((t) => `${t.text} (${t.id.slice(0, 8)})`).join("; ")}`);
  throw new ToolError(`no open step matches "${ref}"`);
}

function findDecision(ledger: Ledger, ref: string): Decision {
  const r = ref.trim();
  const d = ledger.decisions.find((x) => x.id === r) ?? ledger.decisions.find((x) => x.code.toLowerCase() === r.toLowerCase() && !x.answeredAt) ??
    ledger.decisions.find((x) => x.code.toLowerCase() === r.toLowerCase());
  if (!d) throw new ToolError(`no decision "${ref}"`);
  return d;
}

function asKind(v: unknown, fallback: DeadlineKind): DeadlineKind {
  return v === "hard" || v === "goal" || v === "none" ? v : fallback;
}

function asDay(v: unknown, tz: string): Day | null {
  if (v === null || v === undefined || v === "") return null;
  if (typeof v !== "string") throw new ToolError(`date must be YYYY-MM-DD, got ${JSON.stringify(v)}`);
  const d = dayOf(v, tz);
  if (!d) throw new ToolError(`date must be YYYY-MM-DD, got "${v}"`);
  return d;
}

const PALETTE = [0x5BA8FF, 0x6FD2E0, 0xC792F2, 0xF2A65A, 0x4CD98A, 0xFF8FA3, 0xFFD66B];

interface Ctx {
  db: DB;
  token: ApiToken;
  source: string;
  tz: string;
}

async function applyChanges(ctx: Ctx, changes: Record<string, unknown>) {
  const { data, error } = await ctx.db.rpc("apply_changes", { p: changes, p_source: ctx.source, p_token: ctx.token.id });
  if (error) throw new ToolError(`write failed: ${error.message}`);
  return data as { applied: number; version: number };
}

async function replanNow(ctx: Ctx) {
  const state = await loadState(ctx.db);
  return await replan(ctx.db, state, ctx.source, ctx.token.id);
}

interface StepSpec { text: string; effort_minutes?: number; lead_days?: number; milestone?: boolean; needs_you?: boolean }

function stepRows(target: Target, startOrder: number, steps: StepSpec[], plannedBy: string): Task[] {
  const now = new Date().toISOString();
  return steps.filter((s) => typeof s?.text === "string" && s.text.trim()).map((s, i) => ({
    id: crypto.randomUUID(), text: s.text.trim(), category: "todo", done: false, createdAt: now, projectID: target.projectID ?? null, targetID: target.id,
    pathOrder: startOrder + i, effortMinutes: typeof s.effort_minutes === "number" ? s.effort_minutes : null, leadDays: typeof s.lead_days === "number" ? s.lead_days : 0,
    milestone: !!s.milestone, needsYou: !!s.needs_you, state: "todo", plannedBy,
  }));
}

async function ensureProject(ctx: Ctx, ledger: Ledger, name: string | undefined): Promise<Project | null> {
  const n = name?.trim();
  if (!n) return null;
  const existing = ledger.projects.find((p) => p.name.toLowerCase() === n.toLowerCase());
  if (existing) return existing;
  const p: Project = { id: crypto.randomUUID(), name: n, colourHex: PALETTE[ledger.projects.length % PALETTE.length], archived: false, createdAt: new Date().toISOString(), horizon: "month", status: "active", people: [] };
  await applyChanges(ctx, {
    projects: [{ id: p.id, name: p.name, colour_hex: p.colourHex, goal: null, archived: false, created_at: p.createdAt, area_id: null, horizon: "month", status: "active", narrative: null, people: [] }],
  });
  ledger.projects.push(p);
  return p;
}

/** Apply a change set (the body of a proposal, or a trusted tool call). */
async function applyChangeSet(ctx: Ctx, ledger: Ledger, kind: string, change: Record<string, any>): Promise<string> {
  switch (kind) {
    case "add_target": {
      const project = await ensureProject(ctx, ledger, change.project);
      const due = asDay(change.due, ctx.tz);
      const target: Target = {
        id: crypto.randomUUID(), projectID: project?.id ?? null, title: String(change.title).trim(), due, kind: due ? asKind(change.kind, "goal") : "none",
        whyItMatters: change.why ?? null, done: false, createdAt: new Date().toISOString(),
      };
      const steps: StepSpec[] = Array.isArray(change.steps) && change.steps.length ? change.steps : [{ text: target.title, effort_minutes: change.effort_minutes }];
      const tasks = stepRows(target, 0, steps, ctx.source);
      await applyChanges(ctx, { targets: [targetToRow(target)], tasks: tasks.map(taskToRow) });
      return `→ Target: ${target.title}${due ? ` — due ${due} · ${target.kind}` : " — no date"}${project ? ` · ${project.name}` : ""} · ${tasks.length} step${tasks.length === 1 ? "" : "s"} (id ${target.id})`;
    }
    case "add_steps": {
      const target = findTarget(ledger, String(change.target));
      const existing = tasksFor(ledger, target.id);
      const start = (existing.length ? Math.max(...existing.map((t) => t.pathOrder)) : -1) + 1;
      const tasks = stepRows(target, start, change.steps ?? [], ctx.source);
      if (!tasks.length) throw new ToolError("no steps given");
      await applyChanges(ctx, { tasks: tasks.map(taskToRow) });
      return `→ ${tasks.length} step${tasks.length === 1 ? "" : "s"} added to "${target.title}": ${tasks.map((t) => t.text).join("; ")}`;
    }
    case "update_step":
    case "change": {
      if (change.target && !change.step && !change.id) {
        const t = findTarget(ledger, String(change.target));
        const updated: Target = { ...t };
        const bits: string[] = [];
        if ("due" in change) { updated.due = asDay(change.due, ctx.tz); bits.push(`due ${updated.due ?? "none"}`); if (!updated.due) updated.kind = "none"; }
        if ("kind" in change && change.kind) { updated.kind = asKind(change.kind, t.kind); bits.push(updated.kind); }
        if (change.title) { updated.title = String(change.title).trim(); bits.push(`title "${updated.title}"`); }
        if ("why" in change) { updated.whyItMatters = change.why ?? null; bits.push("why"); }
        if (change.done === true) {
          updated.done = true; updated.doneAt = new Date().toISOString(); bits.push("done");
          const steps = tasksFor(ledger, t.id).filter((s) => !s.done).map((s) => ({ ...s, done: true, doneAt: updated.doneAt, state: "done" as const }));
          await applyChanges(ctx, { targets: [targetToRow(updated)], tasks: steps.map(taskToRow) });
          return `→ "${t.title}" done (${steps.length} open step${steps.length === 1 ? "" : "s"} checked off)`;
        }
        await applyChanges(ctx, { targets: [targetToRow(updated)] });
        return `→ "${updated.title}": ${bits.join(", ") || "no change"}`;
      }
      const ref = change.step ?? change.id;
      if (!ref) throw new ToolError("give a target or a step");
      const task = findTask(ledger, String(ref));
      const updated: Task = { ...task };
      const bits: string[] = [];
      if ("effort_minutes" in change && change.effort_minutes !== undefined) { updated.effortMinutes = change.effort_minutes === null ? null : Number(change.effort_minutes); bits.push(`effort ${updated.effortMinutes ?? "unestimated"} min`); }
      if ("lead_days" in change && change.lead_days !== undefined) { updated.leadDays = Number(change.lead_days) || 0; bits.push(`lead ${updated.leadDays} d`); }
      if (change.text) { updated.text = String(change.text).trim(); bits.push(`text "${updated.text}"`); }
      if ("due" in change) { updated.dueDate = asDay(change.due, ctx.tz); if (change.kind) updated.dueKind = asKind(change.kind, "goal"); bits.push(`own date ${updated.dueDate ?? "none"}`); }
      if ("milestone" in change) { updated.milestone = !!change.milestone; bits.push(updated.milestone ? "milestone" : "not a milestone"); }
      if ("needs_you" in change) { updated.needsYou = !!change.needs_you; bits.push(updated.needsYou ? "needs you" : "delegable"); }
      if ("done" in change && typeof change.done === "boolean") {
        updated.done = change.done; updated.doneAt = change.done ? new Date().toISOString() : null; updated.state = change.done ? "done" : "todo";
        bits.push(change.done ? "done" : "reopened");
      }
      const rows: Record<string, unknown> = { tasks: [taskToRow(updated)] };
      if (updated.targetID && typeof change.done === "boolean") {
        const target = ledger.targets.find((t) => t.id === updated.targetID);
        if (target) {
          const open = ledger.tasks.filter((s) => s.targetID === target.id && s.id !== updated.id && !s.done).length + (updated.done ? 0 : 1);
          const tDone = open === 0;
          if (tDone !== target.done) rows.targets = [targetToRow({ ...target, done: tDone, doneAt: tDone ? new Date().toISOString() : null })];
        }
      }
      await applyChanges(ctx, rows);
      return `→ "${updated.text}": ${bits.join(", ") || "no change"}`;
    }
    default:
      throw new ToolError(`unknown change kind "${kind}"`);
  }
}

async function propose(ctx: Ctx, kind: string, change: Record<string, unknown>, evidence: string | undefined, targetId: string | null, taskId: string | null, summary: string) {
  const row = { kind, target_id: targetId, task_id: taskId, change, evidence: evidence ?? null, source: ctx.source, token_id: ctx.token.id };
  const { data, error } = await ctx.db.from("proposals").insert(row).select("id, expires_at").single();
  if (error) throw new ToolError(`could not record the proposal: ${error.message}`);
  await logEvent(ctx.db, ctx.source, ctx.token.id, "proposed", "proposal", data.id, `${ctx.source} proposes ${kind}: ${summary}${evidence ? ` (${evidence})` : ""}`, { change, target_id: targetId, task_id: taskId });
  return text(`→ Proposed (${ctx.source}): ${summary}${evidence ? ` · evidence: ${evidence}` : ""}. Joshua accepts or ignores it on the phone or Mac; it expires ${String(data.expires_at).slice(0, 10)}. (proposal ${data.id})`, { proposalId: data.id, status: "pending" });
}

// ── Tool dispatch ────────────────────────────────────────────────────────────

async function callTool(ctx: Ctx, name: string, args: Record<string, any>) {
  switch (name) {
    case "now": {
      const { state, assessment } = await currentPlan(ctx.db, ctx.source);
      const { events, latest } = await eventsSince(ctx.db, ctx.token.id);
      const t = nowText(state.ledger, assessment, state.proposals, events);
      await advanceCursor(ctx.db, ctx.token.id, latest);
      return text(t);
    }
    case "list_plan": {
      const { state, assessment } = await currentPlan(ctx.db, ctx.source);
      const view = listPlan(state.ledger, assessment, String(args.scope ?? "all"), state.proposals);
      return text(JSON.stringify(view, null, 1), view);
    }
    case "capture": {
      const t = String(args.text ?? "").trim();
      if (!t) throw new ToolError("nothing to capture");
      const task: Task = { id: crypto.randomUUID(), text: t, category: "todo", group: "inbox", done: false, createdAt: new Date().toISOString(), pathOrder: 0, leadDays: 0, milestone: false, needsYou: false, state: "todo", plannedBy: ctx.source };
      const { error } = await ctx.db.from("tasks").insert(taskToRow(task));
      if (error) throw new ToolError(error.message);
      await logEvent(ctx.db, ctx.source, ctx.token.id, "captured", "task", task.id, t, { via: args.source ?? ctx.source });
      await replanNow(ctx);
      return text(`→ Captured: ${t} (inbox · id ${task.id})`, { taskId: task.id });
    }
    case "add_target": {
      const { ledger } = await loadState(ctx.db);
      const summary = `${args.title}${args.due ? ` · ${args.kind ?? "goal"} ${args.due}` : ""}${args.project ? ` · ${args.project}` : ""}`;
      if (!ctx.token.trusted) return await propose(ctx, "add_target", args, undefined, null, null, `new target ${summary}`);
      const receipt = await applyChangeSet(ctx, ledger, "add_target", args);
      const r = await replanNow(ctx);
      return text(receipt + statusLine(r));
    }
    case "add_steps": {
      const { ledger } = await loadState(ctx.db);
      const target = findTarget(ledger, String(args.target));
      if (!ctx.token.trusted) {
        return await propose(ctx, "add_steps", { ...args, target: target.id }, undefined, target.id, null, `${(args.steps ?? []).length} steps for "${target.title}"`);
      }
      const receipt = await applyChangeSet(ctx, ledger, "add_steps", { ...args, target: target.id });
      const r = await replanNow(ctx);
      return text(receipt + statusLine(r));
    }
    case "update_step": {
      const { ledger } = await loadState(ctx.db);
      const task = findTask(ledger, String(args.id));
      const { id: _id, ...rest } = args;
      const onlyDone = Object.keys(rest).every((k) => k === "done");
      if (!ctx.token.trusted && !onlyDone) {
        // done is allowed for everyone; the rest is a proposal
        const direct = typeof rest.done === "boolean" ? await applyChangeSet(ctx, ledger, "update_step", { id: task.id, done: rest.done }) : null;
        const { done: _d, ...proposed } = rest;
        const p = await propose(ctx, "update_step", { id: task.id, ...proposed }, undefined, task.targetID ?? null, task.id, `"${task.text}": ${summarizeChange(proposed)}`);
        if (direct) p.content.unshift({ type: "text", text: direct });
        return p;
      }
      const receipt = await applyChangeSet(ctx, ledger, "update_step", { id: task.id, ...rest });
      const r = await replanNow(ctx);
      return text(receipt + statusLine(r));
    }
    case "propose": {
      const { ledger } = await loadState(ctx.db);
      const change = (args.change ?? {}) as Record<string, unknown>;
      let targetId: string | null = null, taskId: string | null = null, what = "";
      if (args.step) { const t = findTask(ledger, String(args.step)); taskId = t.id; targetId = t.targetID ?? null; what = `step "${t.text}"`; }
      else if (args.target) { const t = findTarget(ledger, String(args.target)); targetId = t.id; what = `"${t.title}"`; }
      else throw new ToolError("name a target or a step");
      const body = { ...change, ...(taskId ? { step: taskId } : { target: targetId }) };
      return await propose(ctx, "change", body, args.evidence, targetId, taskId, `${what}: ${summarizeChange(change)}`);
    }
    case "answer_decision": {
      const { ledger } = await loadState(ctx.db);
      const d = findDecision(ledger, String(args.id));
      if (d.answeredAt) throw new ToolError(`${d.code} was already answered: ${d.answer}`);
      const opt = String(args.option ?? "").trim();
      const match = d.options.find((o) => o.label.toLowerCase() === opt.toLowerCase()) ?? d.options.find((o) => o.label.toLowerCase().includes(opt.toLowerCase()));
      const answered: Decision = { ...d, answeredAt: new Date().toISOString(), answer: match?.label ?? opt, deferredUntil: null };
      await applyChanges(ctx, { decisions: [decisionToRow(answered)] });
      const r = await replanNow(ctx);
      return text(`→ ${d.code} answered: ${answered.answer}${match ? ` — ${match.does}` : ""}${statusLine(r)}`);
    }
    case "defer_decision": {
      const { ledger } = await loadState(ctx.db);
      const d = findDecision(ledger, String(args.id));
      let until: Day;
      const u = args.until;
      if (u === undefined || u === null || u === "") until = shiftDay(todayIn(ctx.tz), 3);
      else if (typeof u === "number" || /^\d{1,3}$/.test(String(u))) until = shiftDay(todayIn(ctx.tz), Number(u));
      else if (isDay(String(u))) until = String(u);
      else throw new ToolError("until must be YYYY-MM-DD or a number of days");
      const deferred: Decision = { ...d, deferredUntil: `${until}T12:00:00.000Z` };
      await applyChanges(ctx, { decisions: [decisionToRow(deferred)] });
      return text(`→ ${d.code} deferred until ${until}`);
    }
    case "note_actual": {
      const { ledger } = await loadState(ctx.db);
      const task = findTask(ledger, String(args.step));
      const minutes = Number(args.minutes);
      if (!Number.isFinite(minutes) || minutes < 0) throw new ToolError("minutes must be a number");
      await applyChanges(ctx, { tasks: [taskToRow({ ...task, actualMinutes: Math.round(minutes) })] });
      return text(`→ "${task.text}" took ${Math.round(minutes)} min${task.effortMinutes ? ` (estimated ${task.effortMinutes})` : ""}`);
    }
    case "accept_proposal":
    case "reject_proposal": {
      if (!ctx.token.trusted) throw new ToolError("only a trusted token can resolve proposals; Joshua accepts them on the phone or Mac");
      const { data: p, error } = await ctx.db.from("proposals").select("*").eq("id", String(args.id)).maybeSingle();
      if (error) throw new ToolError(error.message);
      if (!p) throw new ToolError("no such proposal");
      if (p.status !== "pending") throw new ToolError(`proposal is already ${p.status}`);
      if (name === "reject_proposal") {
        await ctx.db.from("proposals").update({ status: "rejected", resolved_at: new Date().toISOString(), note: args.note ?? null }).eq("id", p.id);
        await logEvent(ctx.db, ctx.source, ctx.token.id, "rejected", "proposal", p.id, `${p.source}'s ${p.kind} rejected${args.note ? `: ${args.note}` : ""}`);
        return text(`→ Proposal from ${p.source} rejected.`);
      }
      const { ledger } = await loadState(ctx.db);
      const receipt = await applyChangeSet({ ...ctx, source: `${ctx.source} (accepting ${p.source})` }, ledger, p.kind, p.change);
      await ctx.db.from("proposals").update({ status: "accepted", resolved_at: new Date().toISOString() }).eq("id", p.id);
      await logEvent(ctx.db, ctx.source, ctx.token.id, "accepted", "proposal", p.id, `${p.source}'s ${p.kind} accepted: ${summarizeChange(p.change)}`);
      const r = await replanNow(ctx);
      return text(`→ Accepted ${p.source}'s proposal. ${receipt}${statusLine(r)}`);
    }
    default:
      throw new ToolError(`unknown tool "${name}"`);
  }
}

function statusLine(r: Awaited<ReturnType<typeof replanNow>>): string {
  const bits: string[] = [];
  if (r.movedSteps) bits.push(`${r.movedSteps} date${r.movedSteps === 1 ? "" : "s"} moved`);
  if (r.raisedNew) bits.push(`${r.raisedNew} new "what gives?"`);
  if (r.raisedCleared) bits.push(`${r.raisedCleared} alarm${r.raisedCleared === 1 ? "" : "s"} cleared`);
  const willMiss = Object.values(r.assessment.targets).filter((t) => t.state === "willMiss").length;
  if (willMiss) bits.push(`${willMiss} hard target${willMiss === 1 ? "" : "s"} will miss`);
  return bits.length ? ` · plan re-run: ${bits.join(", ")}` : "";
}

// ── JSON-RPC ─────────────────────────────────────────────────────────────────

interface RpcRequest { jsonrpc: "2.0"; id?: string | number | null; method: string; params?: any }

function ok(id: RpcRequest["id"], result: unknown) {
  return { jsonrpc: "2.0", id: id ?? null, result };
}
function err(id: RpcRequest["id"], code: number, message: string, data?: unknown) {
  return { jsonrpc: "2.0", id: id ?? null, error: { code, message, ...(data !== undefined ? { data } : {}) } };
}

async function handle(ctx: Ctx, r: RpcRequest): Promise<unknown | undefined> {
  const isNotification = r.id === undefined;
  switch (r.method) {
    case "initialize": {
      const requested = r.params?.protocolVersion;
      const protocolVersion = SUPPORTED_PROTOCOLS.includes(requested) ? requested : "2025-03-26";
      return ok(r.id, {
        protocolVersion,
        capabilities: { tools: { listChanged: false }, resources: { subscribe: false, listChanged: false }, prompts: { listChanged: false } },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
        instructions: INSTRUCTIONS,
      });
    }
    case "notifications/initialized":
    case "notifications/cancelled":
    case "notifications/roots/list_changed":
      return undefined;
    case "ping":
      return ok(r.id, {});
    case "tools/list":
      return ok(r.id, { tools: TOOLS });
    case "tools/call": {
      const name = String(r.params?.name ?? "");
      const args = (r.params?.arguments ?? {}) as Record<string, unknown>;
      if (!TOOLS.some((t) => t.name === name)) return err(r.id, -32602, `unknown tool "${name}"`);
      try {
        return ok(r.id, await callTool(ctx, name, args));
      } catch (e) {
        if (e instanceof ToolError) return ok(r.id, { content: [{ type: "text", text: `✗ ${e.message}` }], isError: true });
        console.error(`tool ${name} failed`, e);
        return ok(r.id, { content: [{ type: "text", text: `✗ ${name} failed: ${(e as Error)?.message ?? e}` }], isError: true });
      }
    }
    case "resources/list":
      return ok(r.id, {
        resources: [
          { uri: "frictionless://now", name: "now", title: "Now", description: "The Now strip, open decisions, pending proposals and what changed since you last looked (~300 tokens).", mimeType: "text/markdown" },
          { uri: "frictionless://plan", name: "plan", title: "Plan", description: "Every open target with its dated path, as JSON.", mimeType: "application/json" },
        ],
      });
    case "resources/templates/list":
      return ok(r.id, { resourceTemplates: [] });
    case "resources/read": {
      const uri = String(r.params?.uri ?? "");
      if (uri === "frictionless://now") {
        const res = await callTool(ctx, "now", {});
        return ok(r.id, { contents: [{ uri, mimeType: "text/markdown", text: res.content[0].text }] });
      }
      if (uri === "frictionless://plan") {
        const res = await callTool(ctx, "list_plan", { scope: "all" });
        return ok(r.id, { contents: [{ uri, mimeType: "application/json", text: res.content[0].text }] });
      }
      return err(r.id, -32002, `unknown resource ${uri}`);
    }
    case "prompts/list":
      return ok(r.id, { prompts: [{ name: "now", title: "Now", description: "Start a conversation from the current plan.", arguments: [] }] });
    case "prompts/get": {
      if (r.params?.name !== "now") return err(r.id, -32602, "unknown prompt");
      const res = await callTool(ctx, "now", {});
      return ok(r.id, {
        description: "The current plan",
        messages: [{ role: "user", content: { type: "text", text: `Here is my current plan. Talk to me from it; don't recite it.\n\n${res.content[0].text}` } }],
      });
    }
    default:
      if (isNotification) return undefined;
      return err(r.id, -32601, `method not found: ${r.method}`);
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  const url = new URL(req.url);
  if (req.method === "GET") {
    // Health check / discovery hint without a token; no SSE stream is offered.
    const tok = extractToken(req, "mcp");
    if (!tok) return json({ name: SERVER_NAME, version: SERVER_VERSION, transport: "streamable-http", hint: "POST JSON-RPC to this URL with your token in the path or as a Bearer header" }, 200, CORS);
    return new Response("Method Not Allowed: this server does not open a server-to-client stream", { status: 405, headers: { ...CORS, allow: "POST, DELETE, OPTIONS" } });
  }
  if (req.method === "DELETE") return new Response(null, { status: 200, headers: CORS });
  if (req.method !== "POST") return new Response("POST only", { status: 405, headers: { ...CORS, allow: "POST, DELETE, OPTIONS" } });

  const db = serviceClient();
  const token = await authenticate(db, extractToken(req, "mcp"));
  if (!token || token.kind === "feed") {
    return json({ jsonrpc: "2.0", id: null, error: { code: -32001, message: "unauthorized: put an assistant token in the URL path (/mcp/<token>) or an Authorization: Bearer header" } }, 401, {
      ...CORS,
      "www-authenticate": 'Bearer realm="frictionless-pm"',
    });
  }
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json(err(null, -32700, "parse error"), 400, CORS);
  }
  const { data: settingsRow } = await db.from("settings").select("timezone").eq("id", 1).maybeSingle();
  const ctx: Ctx = { db, token, source: token.source, tz: settingsRow?.timezone ?? "America/New_York" };
  const requests: RpcRequest[] = Array.isArray(body) ? body : [body as RpcRequest];
  const responses: unknown[] = [];
  for (const r of requests) {
    if (!r || r.jsonrpc !== "2.0" || typeof r.method !== "string") {
      responses.push(err((r as any)?.id ?? null, -32600, "invalid request"));
      continue;
    }
    const res = await handle(ctx, r);
    if (res !== undefined) responses.push(res);
  }
  const headers = { ...CORS, "mcp-protocol-version": String(req.headers.get("mcp-protocol-version") ?? "2025-03-26") };
  if (responses.length === 0) return new Response(null, { status: 202, headers });
  return json(Array.isArray(body) ? responses : responses[0], 200, headers);
});
