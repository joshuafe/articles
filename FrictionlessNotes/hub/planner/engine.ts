// Tier 0 — the urgency engine (DESIGN-PM.md §6.1). A line-by-line port of
// PlanCore/PlanEngine.swift (itself a port of pm-prototype/engine.py); keep
// the three in step. Deterministic, no model, no I/O: a pure function from
// (today, capacity, targets, tasks) to a PlanAssessment.
//
// Two walks per target:
//   backwards from the deadline  → each step's WALL (latest finish for the end date to hold)
//   forwards from today, EDF     → each step's PLANNED window in real capacity, then its
//                                  TARGET DATE (planned end + buffer, never past the wall)

import { type Day, daysBetween, formatEEEMMMd, minDay, shiftDay } from "./dates.ts";
import {
  type Allocation,
  type CapacityModel,
  capacityMinutes,
  type DeadlineKind,
  type Decision,
  type PlanAssessment,
  type PlanStep,
  plannedEffort,
  type Target,
  type TargetState,
  type TargetStatus,
  type Task,
  byPathOrder,
} from "./models.ts";

export interface PlanInput {
  today: Day;
  capacity: CapacityModel;
  targets: Target[];
  tasks: Task[];
  horizonDays?: number;
  /** For reproducible tests; defaults to new Date(). */
  now?: Date;
}

/** Mutable per-step working state for the simulation. */
class Node {
  wall?: Day;
  latestStart?: Day;
  left: number;
  readyFrom: Day;
  plannedStart?: Day;
  plannedEnd?: Day;

  constructor(
    readonly task: Task,
    readonly target: Target | undefined,
    readonly index: number,
    readonly siblings: number,
    today: Day,
  ) {
    this.left = plannedEffort(task);
    this.readyFrom = today;
  }

  get lead(): number {
    return this.task.leadDays;
  }

  get kind(): DeadlineKind {
    if (this.target) return this.target.kind;
    return this.task.dueKind ?? "none";
  }
}

export function plan(input: PlanInput): PlanAssessment {
  const today = input.today;
  const horizonDays = input.horizonDays ?? 120;
  const horizon = shiftDay(today, horizonDays);
  const cap = (day: Day) => capacityMinutes(input.capacity, day);

  // ── Group open tasks into paths ──────────────────────────────────────────
  const paths: Node[][] = [];
  const pathOf = new Map<Node, Node[]>();
  const openTargets = input.targets.filter((t) => !t.done);
  const targetByID = new Map<string, Target>();
  for (const t of openTargets) targetByID.set(t.id, t);

  for (const t of openTargets) {
    const steps = input.tasks.filter((k) => k.targetID === t.id && !k.done).sort(byPathOrder);
    if (steps.length === 0) continue;
    const path = steps.map((k, i) => new Node(k, t, i, steps.length, today));
    paths.push(path);
  }
  // Standalone tasks (no live target) are one-step paths of their own.
  for (const task of input.tasks) {
    if (task.done || task.category !== "todo") continue;
    if (task.targetID && targetByID.has(task.targetID)) continue;
    paths.push([new Node(task, undefined, 0, 1, today)]);
  }
  for (const path of paths) for (const n of path) pathOf.set(n, path);

  // ── Backward walk: walls and latest starts ───────────────────────────────
  const floor = shiftDay(today, -365);
  for (const path of paths) {
    let lf: Day | undefined = path[0]?.target?.due ?? undefined;
    for (let i = path.length - 1; i >= 0; i--) {
      const node = path[i];
      const own = node.task.dueDate ?? undefined;
      const wall = minDay(lf, own);
      node.wall = wall;
      if (!wall) continue;
      let remaining = plannedEffort(node.task);
      let day = wall;
      while (remaining > 0 && day > floor) {
        remaining -= cap(day);
        if (remaining > 0) day = shiftDay(day, -1);
      }
      node.latestStart = day;
      lf = shiftDay(day, -node.lead);
    }
  }

  // ── Forward walk: earliest-deadline-first, by urgency class ──────────────
  const all = paths.flat();
  const urgencyClass = (n: Node, day: Day): number => {
    switch (n.kind) {
      case "hard":
        return n.latestStart && n.latestStart <= day ? 0 : 2;
      case "goal":
        return n.wall && n.wall < day ? 1 : 3;
      case "none":
        return 4;
    }
  };
  type Rank = [number, Day, Day, number];
  const rank = (n: Node, day: Day): Rank => [urgencyClass(n, day), n.wall ?? horizon, n.target?.due ?? horizon, n.index];
  const lessThan = (a: Rank, b: Rank): boolean => {
    if (a[0] !== b[0]) return a[0] < b[0];
    if (a[1] !== b[1]) return a[1] < b[1];
    if (a[2] !== b[2]) return a[2] < b[2];
    return a[3] < b[3];
  };

  const allocations: Record<Day, Allocation[]> = {};
  let day = today;
  while (day <= horizon) {
    let free = cap(day);
    while (free > 0) {
      let pick: Node | undefined;
      let pickRank: Rank | undefined;
      for (const n of all) {
        if (n.left <= 0 || n.readyFrom > day) continue;
        if (n.index > 0 && pathOf.get(n)![n.index - 1].left !== 0) continue;
        const r = rank(n, day);
        if (!pick || lessThan(r, pickRank!)) {
          pick = n;
          pickRank = r;
        }
      }
      if (!pick) break;
      const take = Math.min(free, pick.left);
      pick.left -= take;
      free -= take;
      if (!pick.plannedStart) pick.plannedStart = day;
      (allocations[day] ??= []).push({ taskID: pick.task.id, minutes: take });
      if (pick.left === 0) {
        pick.plannedEnd = day;
        const next = pick.index + 1;
        const path = pathOf.get(pick)!;
        if (next < path.length) {
          path[next].readyFrom = pick.lead > 0 ? shiftDay(day, pick.lead + 1) : day;
        }
      }
    }
    day = shiftDay(day, 1);
  }

  // ── Target dates, lateness, states ───────────────────────────────────────
  const steps: Record<string, PlanStep> = {};
  const statuses: Record<string, TargetStatus> = {};
  const raised: Decision[] = [];
  const nowISO = (input.now ?? new Date()).toISOString();

  for (const path of paths) {
    const lateIDs: string[] = [];
    let remaining = 0;
    for (const node of path) {
      const effort = plannedEffort(node.task);
      remaining += effort;
      const buffer = Math.max(1, Math.ceil(effort / 240));
      let targetDate: Day | undefined;
      let late = false;
      if (node.plannedEnd) {
        if (node.wall) {
          targetDate = minDay(node.wall, shiftDay(node.plannedEnd, buffer));
          late = node.plannedEnd > node.wall;
        } else {
          targetDate = node.plannedEnd;
        }
      } else {
        late = node.wall !== undefined; // never fit inside the horizon
      }
      if (late) lateIDs.push(node.task.id);
      steps[node.task.id] = {
        taskID: node.task.id,
        targetID: node.target?.id ?? null,
        index: node.index,
        wall: node.wall ?? null,
        latestStart: node.latestStart ?? null,
        plannedStart: node.plannedStart ?? null,
        plannedEnd: node.plannedEnd ?? null,
        targetDate: targetDate ?? null,
        late,
        minutesLeft: node.left,
      };
    }
    const target = path[0]?.target;
    const last = path[path.length - 1];
    if (!target || !last) continue;
    let slack: number | null = null;
    if (last.plannedEnd && last.wall) slack = daysBetween(last.plannedEnd, last.wall);
    let state: TargetState;
    switch (target.kind) {
      case "hard":
        state = lateIDs.length > 0 ? "willMiss" : ((slack ?? 99) < 2 ? "atRisk" : "onTrack");
        break;
      case "goal":
        state = lateIDs.length > 0 ? "slipping" : "onTrack";
        break;
      case "none":
        state = "backlog";
        break;
    }
    statuses[target.id] = { targetID: target.id, state, slackDays: slack, lateTaskIDs: lateIDs, remainingMinutes: remaining };
    if (state === "willMiss") {
      const firstLate = path.find((n) => lateIDs.includes(n.task.id))!;
      const dueText = target.due ? formatEEEMMMd(target.due) : "its date";
      raised.push({
        id: crypto.randomUUID(),
        code: `E-${target.id.slice(0, 4).toUpperCase()}`,
        projectID: target.projectID ?? null,
        targetID: target.id,
        question: `“${target.title}” can’t be finished by ${dueText} at current capacity. What gives?`,
        whyNow: `${firstLate.task.text} lands on ${firstLate.plannedEnd ? formatEEEMMMd(firstLate.plannedEnd) : "never"} but had to finish by ${
          firstLate.wall ? formatEEEMMMd(firstLate.wall) : "?"
        }.`,
        background: "Hard deadline; the engine never moves it. Everything due earlier was placed first (earliest deadline first).",
        touches: "This target and whatever you choose to move.",
        options: [
          { label: "Add hours", does: "Raise capacity on named days; the plan re-runs." },
          { label: "Move a goal out", does: "Pushes a goal target’s steps after this one." },
          { label: "Shrink the scope", does: "Cut or shorten steps." },
        ],
        ifUnanswered: "It stays red; the step named above runs late.",
        raisedBy: "engine",
        askedAt: nowISO,
      });
    }
  }
  for (const t of input.targets) {
    if (t.done) statuses[t.id] = { targetID: t.id, state: "done", slackDays: null, lateTaskIDs: [], remainingMinutes: 0 };
  }
  for (const t of openTargets) {
    if (statuses[t.id]) continue;
    // a target with no open steps yet: on track if its date is ahead, else at risk of being forgotten
    const slack = t.due ? daysBetween(today, t.due) : null;
    const state: TargetState = t.kind === "none" ? "backlog" : ((slack ?? 99) < 2 ? "atRisk" : "onTrack");
    statuses[t.id] = { targetID: t.id, state, slackDays: slack, lateTaskIDs: [], remainingMinutes: 0 };
  }

  return { computedAt: nowISO, today, steps, targets: statuses, allocations, raised };
}
