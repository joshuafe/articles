// The `now` resource and `list_plan` tool (DESIGN-PM.md §9.2): the Now strip
// (Due · At risk · Today), targets with their dated paths, open decisions and
// pending proposals, rendered compactly for an assistant. Pure functions over
// a Ledger and a PlanAssessment.

import { type Day, formatEEEMMMd, shiftDay } from "./dates.ts";
import {
  type Allocation,
  capacityMinutes,
  committedMinutes,
  type Decision,
  decisionIsOpen,
  type Ledger,
  type PlanAssessment,
  type Target,
  TARGET_STATE_LABEL,
  type TargetState,
  tasksFor,
} from "./models.ts";

export interface ProposalLike {
  id: string;
  kind: string;
  target_id?: string | null;
  task_id?: string | null;
  change: unknown;
  evidence?: string | null;
  source: string;
  created_at: string;
  expires_at: string;
}

export interface EventLike {
  id: number;
  at: string;
  source: string;
  kind: string;
  entity: string;
  entity_id?: string | null;
  summary: string;
}

export interface PlanView {
  today: Day;
  computedAt: string;
  due: { id: string; title: string; due: Day; kind: string; state: TargetState; slackDays: number | null; project?: string }[];
  atRisk: { id: string; title: string; state: TargetState; reason: string }[];
  today_cut: { taskId: string; text: string; minutes: number; target?: string }[];
  capacityToday: number;
  committedToday: number;
  decisions: Decision[];
  proposals: ProposalLike[];
}

export function planView(ledger: Ledger, a: PlanAssessment, proposals: ProposalLike[] = [], now = new Date()): PlanView {
  const taskByID = new Map(ledger.tasks.map((t) => [t.id, t]));
  const targetByID = new Map(ledger.targets.map((t) => [t.id, t]));
  const projectByID = new Map(ledger.projects.map((p) => [p.id, p]));
  const open = ledger.targets.filter((t) => !t.done);
  const hard = open.filter((t) => t.kind === "hard" && t.due).sort((x, y) => (x.due! < y.due! ? -1 : x.due! > y.due! ? 1 : 0));
  const due = hard.map((t) => {
    const st = a.targets[t.id];
    return {
      id: t.id, title: t.title, due: t.due!, kind: t.kind, state: st?.state ?? "onTrack", slackDays: st?.slackDays ?? null,
      project: t.projectID ? projectByID.get(t.projectID)?.name : undefined,
    };
  });
  const atRisk = open
    .filter((t) => ["willMiss", "atRisk", "slipping"].includes(a.targets[t.id]?.state))
    .sort((x, y) => sev(a.targets[x.id].state) - sev(a.targets[y.id].state))
    .map((t) => {
      const st = a.targets[t.id];
      let reason = `${st.slackDays ?? "?"} d slack`;
      if (st.lateTaskIDs.length > 0) {
        const s = taskByID.get(st.lateTaskIDs[0]);
        const ps = s ? a.steps[s.id] : undefined;
        if (s && ps) reason = `${s.text} lands ${ps.plannedEnd ? formatEEEMMMd(ps.plannedEnd) : "never"}, had to finish by ${ps.wall ? formatEEEMMMd(ps.wall) : "?"}`;
      }
      return { id: t.id, title: t.title, state: st.state, reason };
    });
  const today_cut = (a.allocations[a.today] ?? []).map((al: Allocation) => {
    const t = taskByID.get(al.taskID);
    const tg = t?.targetID ? targetByID.get(t.targetID) : undefined;
    return { taskId: al.taskID, text: t?.text ?? "?", minutes: al.minutes, target: tg?.title };
  });
  return {
    today: a.today,
    computedAt: a.computedAt,
    due,
    atRisk,
    today_cut,
    capacityToday: capacityMinutes(ledger.capacity, a.today),
    committedToday: committedMinutes(a, a.today),
    decisions: ledger.decisions.filter((d) => decisionIsOpen(d, now)).sort((x, y) => (x.raisedBy === "engine" ? 0 : 1) - (y.raisedBy === "engine" ? 0 : 1)),
    proposals,
  };
}

function sev(s: TargetState): number {
  return ({ willMiss: 0, atRisk: 1, slipping: 2, onTrack: 3, backlog: 4, done: 5 } as Record<TargetState, number>)[s];
}

function slackText(d: number | null | undefined): string {
  if (d === null || d === undefined) return "";
  return d < 0 ? ` · ${-d} d late` : ` · ${d} d slack`;
}

/** The ~300-token text an assistant reads at the start of every conversation. */
export function nowText(ledger: Ledger, a: PlanAssessment, proposals: ProposalLike[] = [], since: EventLike[] = [], now = new Date()): string {
  const v = planView(ledger, a, proposals, now);
  const L: string[] = [];
  L.push(`# Now · ${formatEEEMMMd(v.today)} (plan ${v.computedAt.slice(0, 16).replace("T", " ")} UTC)`);
  L.push("");
  L.push("## Due (hard, by date)");
  if (v.due.length === 0) L.push("- nothing dated");
  for (const d of v.due.slice(0, 8)) L.push(`- ${d.due} · ${d.title} · ${TARGET_STATE_LABEL[d.state]}${slackText(d.slackDays)}`);
  L.push("");
  L.push("## At risk");
  if (v.atRisk.length === 0) L.push("- nothing");
  for (const r of v.atRisk) L.push(`- ${r.title} · ${TARGET_STATE_LABEL[r.state]} · ${r.reason}`);
  L.push("");
  L.push(`## Today (${v.committedToday} of ${v.capacityToday} min)`);
  if (v.today_cut.length === 0) L.push("- nothing scheduled");
  for (const t of v.today_cut) L.push(`- ${t.minutes} min · ${t.text}${t.target ? ` (${t.target})` : ""}`);
  if (v.decisions.length > 0) {
    L.push("");
    L.push(`## Needs you (${v.decisions.length})`);
    for (const d of v.decisions.slice(0, 5)) {
      L.push(`- [${d.code}] ${d.question}` + (d.options.length ? ` — options: ${d.options.map((o) => o.label).join(" / ")}` : ""));
    }
  }
  if (v.proposals.length > 0) {
    L.push("");
    L.push(`## Proposals waiting (${v.proposals.length})`);
    for (const p of v.proposals.slice(0, 5)) L.push(`- ${p.source} proposes ${p.kind}: ${summarizeChange(p.change)}${p.evidence ? ` (${p.evidence})` : ""}`);
  }
  L.push("");
  L.push("## Since you last looked");
  if (since.length === 0) L.push("- nothing new");
  for (const e of since.slice(-12)) L.push(`- ${e.at.slice(0, 16).replace("T", " ")} · ${e.source} ${e.kind} ${e.entity}: ${e.summary}`);
  if (since.length > 12) L.push(`- … and ${since.length - 12} more`);
  return L.join("\n");
}

export function summarizeChange(change: unknown): string {
  if (change && typeof change === "object") {
    return Object.entries(change as Record<string, unknown>)
      .filter(([, v]) => v !== undefined && v !== null)
      .map(([k, v]) => `${k}=${typeof v === "string" ? v : JSON.stringify(v)}`)
      .join(", ")
      .slice(0, 200);
  }
  return String(change);
}

/** Full plan for `list_plan`: every open target with its dated path. */
export function listPlan(ledger: Ledger, a: PlanAssessment, scope = "all", proposals: ProposalLike[] = [], now = new Date()) {
  const v = planView(ledger, a, proposals, now);
  const projectByID = new Map(ledger.projects.map((p) => [p.id, p]));
  const wantTargets = scope === "all" || scope === "targets" || scope.startsWith("project:");
  const projectFilter = scope.startsWith("project:") ? scope.slice(8).trim().toLowerCase() : null;
  const targets = !wantTargets ? [] : ledger.targets
    .filter((t) => !t.done)
    .filter((t) => !projectFilter || (t.projectID && projectByID.get(t.projectID)?.name.toLowerCase().includes(projectFilter)))
    .sort((x, y) => ((x.due ?? "9999") < (y.due ?? "9999") ? -1 : (x.due ?? "9999") > (y.due ?? "9999") ? 1 : 0))
    .map((t: Target) => {
      const st = a.targets[t.id];
      return {
        id: t.id,
        title: t.title,
        due: t.due ?? null,
        kind: t.kind,
        project: t.projectID ? projectByID.get(t.projectID)?.name ?? null : null,
        state: st?.state ?? null,
        slackDays: st?.slackDays ?? null,
        remainingMinutes: st?.remainingMinutes ?? 0,
        whyItMatters: t.whyItMatters ?? null,
        steps: tasksFor(ledger, t.id).map((s) => {
          const ps = a.steps[s.id];
          return {
            id: s.id, text: s.text, done: s.done, effortMinutes: s.effortMinutes ?? null, leadDays: s.leadDays,
            milestone: s.milestone, needsYou: s.needsYou, waitingOn: s.waitingOn ?? null,
            wall: ps?.wall ?? null, plannedStart: ps?.plannedStart ?? null, plannedEnd: ps?.plannedEnd ?? null,
            targetDate: ps?.targetDate ?? null, late: ps?.late ?? false,
          };
        }),
      };
    });
  const loose = (scope === "all" || scope === "tasks")
    ? ledger.tasks.filter((t) => !t.done && t.category === "todo" && (!t.targetID || !ledger.targets.some((x) => x.id === t.targetID && !x.done)))
      .map((t) => ({ id: t.id, text: t.text, dueDate: t.dueDate ?? null, dueKind: t.dueKind ?? null, effortMinutes: t.effortMinutes ?? null, targetDate: a.steps[t.id]?.targetDate ?? null }))
    : [];
  const week: { day: Day; capacity: number; committed: number }[] = [];
  for (let i = 0; i < 7; i++) {
    const d = shiftDay(a.today, i);
    week.push({ day: d, capacity: capacityMinutes(ledger.capacity, d), committed: committedMinutes(a, d) });
  }
  return {
    today: v.today,
    computedAt: v.computedAt,
    now: { due: v.due, atRisk: v.atRisk, today: v.today_cut, capacityToday: v.capacityToday, committedToday: v.committedToday },
    week,
    targets,
    looseTasks: loose,
    decisions: (scope === "all" || scope === "decisions" || scope === "now") ? v.decisions : [],
    proposals: (scope === "all" || scope === "proposals" || scope === "now") ? v.proposals : [],
  };
}
