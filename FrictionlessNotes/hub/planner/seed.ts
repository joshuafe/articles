// Seed importer: pm-prototype/seed.json → Ledger (PlanCore SeedImporter.parse).
// Returns the short codes too (T1, T1.1, D1 …) so the reporter can print the
// prototype's labels and the tests can look rows up by them.

import type { Day } from "./dates.ts";
import { type DeadlineKind, type Decision, emptyLedger, type Horizon, INTERIM_CAPACITY, type Ledger, type Task, type Target } from "./models.ts";

export const SEED_COLOURS: Record<string, number> = {
  blue: 0x5BA8FF,
  teal: 0x6FD2E0,
  purple: 0xC792F2,
  orange: 0xF2A65A,
  green: 0x4CD98A,
  pink: 0xFF8FA3,
  yellow: 0xFFD66B,
};
export const PALETTE = [0x5BA8FF, 0x6FD2E0, 0xC792F2, 0xF2A65A, 0x4CD98A, 0xFF8FA3, 0xFFD66B];

export interface SeedCodes {
  targets: Record<string, string>; // uuid → "T1"
  tasks: Record<string, string>; // uuid → "T1.1"
  decisions: Record<string, string>; // uuid → "D1"
  byCode: Record<string, string>; // "T1" → uuid
}

export interface SeedResult {
  ledger: Ledger;
  today?: Day;
  codes: SeedCodes;
}

const kindOf = (v: unknown): DeadlineKind => (v === "hard" || v === "goal" || v === "none") ? v : "none";
const dayOf = (v: unknown): Day | undefined => typeof v === "string" && v.length >= 10 ? v.slice(0, 10) : undefined;

export function parseSeed(root: any, now: Date = new Date()): SeedResult {
  const ledger = emptyLedger();
  const nowISO = now.toISOString();
  const codes: SeedCodes = { targets: {}, tasks: {}, decisions: {}, byCode: {} };

  // Areas (optional; defaults otherwise)
  const areaIDs: Record<string, string> = {};
  const seedAreas: any[] = Array.isArray(root.areas) ? root.areas : [];
  if (seedAreas.length > 0) {
    seedAreas.forEach((a, i) => {
      if (typeof a.id !== "string" || typeof a.name !== "string") return;
      const id = crypto.randomUUID();
      areaIDs[a.id] = id;
      ledger.areas.push({
        id,
        name: a.name,
        colourHex: SEED_COLOURS[String(a.colour ?? "").toLowerCase()] ?? PALETTE[i % PALETTE.length],
        intendedShare: typeof a.share === "number" ? a.share : 0.1,
        order: i,
      });
    });
  } else {
    ledger.areas = [
      { id: crypto.randomUUID(), name: "Research", colourHex: 0x5BA8FF, intendedShare: 0.35, order: 0 },
      { id: crypto.randomUUID(), name: "Clinical", colourHex: 0xFF8FA3, intendedShare: 0.15, order: 1 },
      { id: crypto.randomUUID(), name: "Learning", colourHex: 0xC792F2, intendedShare: 0.15, order: 2 },
      { id: crypto.randomUUID(), name: "Teaching & service", colourHex: 0x4CD98A, intendedShare: 0.10, order: 3 },
      { id: crypto.randomUUID(), name: "Family", colourHex: 0xF2A65A, intendedShare: 0.15, order: 4 },
      { id: crypto.randomUUID(), name: "Health", colourHex: 0x6FD2E0, intendedShare: 0.10, order: 5 },
    ];
  }

  // Projects
  const projectIDs: Record<string, string> = {};
  ((root.projects ?? []) as any[]).forEach((p, i) => {
    if (typeof p.id !== "string" || typeof p.name !== "string") return;
    const id = crypto.randomUUID();
    projectIDs[p.id] = id;
    const horizon: Horizon = ["week", "month", "quarter", "year", "someday"].includes(p.horizon) ? p.horizon : "month";
    ledger.projects.push({
      id,
      name: p.name,
      colourHex: SEED_COLOURS[String(p.colour ?? "").toLowerCase()] ?? PALETTE[i % PALETTE.length],
      goal: p.goal ?? null,
      archived: false,
      createdAt: nowISO,
      areaID: areaIDs[p.area] ?? null,
      horizon,
      status: "active",
      narrative: p.narrative ?? null,
      people: Array.isArray(p.people) ? p.people : [],
    });
  });

  // Targets and their steps
  const targetIDs: Record<string, string> = {};
  for (const t of (root.targets ?? []) as any[]) {
    if (typeof t.id !== "string" || typeof t.title !== "string") continue;
    const target: Target = {
      id: crypto.randomUUID(),
      projectID: projectIDs[t.project] ?? null,
      title: t.title,
      due: dayOf(t.due) ?? null,
      kind: kindOf(t.kind),
      whyItMatters: t.why ?? null,
      done: false,
      createdAt: nowISO,
    };
    targetIDs[t.id] = target.id;
    codes.targets[target.id] = t.id;
    codes.byCode[t.id] = target.id;
    ledger.targets.push(target);
    ((t.steps ?? []) as any[]).forEach((s, order) => {
      if (typeof s.text !== "string") return;
      const task: Task = {
        id: crypto.randomUUID(),
        text: s.text,
        category: "todo",
        done: s.done === true,
        createdAt: nowISO,
        projectID: target.projectID,
        targetID: target.id,
        pathOrder: order,
        effortMinutes: typeof s.effort === "number" ? s.effort : null,
        leadDays: typeof s.lead_days === "number" ? s.lead_days : 0,
        milestone: s.milestone === true,
        needsYou: s.needs_you === true,
        dueDate: dayOf(s.due) ?? null,
        dueKind: s.due_kind != null ? kindOf(s.due_kind) : null,
        state: s.done === true ? "done" : "todo",
      };
      if (typeof s.id === "string") {
        codes.tasks[task.id] = s.id;
        codes.byCode[s.id] = task.id;
      }
      ledger.tasks.push(task);
    });
  }

  // Decisions
  for (const d of (root.decisions ?? []) as any[]) {
    if (typeof d.id !== "string" || typeof d.question !== "string") continue;
    const targetID = targetIDs[d.target] ?? null;
    const projectID = targetID ? (ledger.targets.find((t) => t.id === targetID)?.projectID ?? null) : null;
    const decision: Decision = {
      id: crypto.randomUUID(),
      code: d.id,
      projectID,
      targetID,
      question: d.question,
      whyNow: d.why_now ?? "",
      background: d.background ?? "",
      touches: d.touches ?? "",
      options: ((d.options ?? []) as any[]).filter((o) => typeof o.label === "string").map((o) => ({ label: o.label, does: o.does ?? "" })),
      ifUnanswered: d.if_unanswered ?? "",
      raisedBy: "user",
      askedAt: nowISO,
    };
    if (typeof d.answered === "string" && d.answered.length > 0) {
      const day = dayOf(d.answered);
      decision.answeredAt = day ? `${day}T00:00:00.000Z` : nowISO;
      decision.answer = d.answer ?? null;
    }
    codes.decisions[decision.id] = d.id;
    codes.byCode[d.id] = decision.id;
    ledger.decisions.push(decision);
  }

  // Capacity
  if (root.capacity && typeof root.capacity === "object") {
    const cap = root.capacity;
    const minutes = [...INTERIM_CAPACITY.minutesByWeekday];
    if (typeof cap.weekday_minutes === "number") for (let i = 0; i < 5; i++) minutes[i] = cap.weekday_minutes;
    if (typeof cap.weekend_minutes === "number") {
      minutes[5] = cap.weekend_minutes;
      minutes[6] = cap.weekend_minutes;
    }
    if (cap.pattern && typeof cap.pattern === "object") {
      ["mon", "tue", "wed", "thu", "fri", "sat", "sun"].forEach((k, i) => {
        if (typeof cap.pattern[k] === "number") minutes[i] = cap.pattern[k];
      });
    }
    const fixed = ((cap.fixed ?? []) as any[]).flatMap((fb) => {
      const day = dayOf(fb.date);
      return day && typeof fb.minutes === "number" ? [{ day, minutes: fb.minutes, why: fb.why ?? "" }] : [];
    });
    ledger.capacity = { minutesByWeekday: minutes, fixed };
  }

  return { ledger, today: dayOf(root.today), codes };
}
