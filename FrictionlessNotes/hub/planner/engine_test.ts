// The urgency engine on dates — DESIGN-PM.md §6.1. A port of
// PlanCore/Tests/PlanCoreTests/PlanEngineTests.swift; same cases, same numbers.

import { assert, assertEquals } from "@std/assert";
import { daysBetween } from "./dates.ts";
import { plan, type PlanInput } from "./engine.ts";
import { type CapacityModel, capacityMinutes, type DeadlineKind, type Target, type Task, todaysCut } from "./models.ts";

/** Sunday Nov 8 2026 — the seed's "today". */
const TODAY = "2026-11-08";
const CREATED = "2026-11-08T12:00:00.000Z";

function input(targets: Target[], tasks: Task[], capacity: CapacityModel = { minutesByWeekday: [120, 120, 120, 120, 120, 300, 300], fixed: [] }): PlanInput {
  return { today: TODAY, capacity, targets, tasks };
}

function target(title: string, due: string, kind: DeadlineKind): Target {
  return { id: crypto.randomUUID(), title, due, kind, done: false, createdAt: CREATED };
}

function step(text: string, effort: number, targetID: string, order: number,
  opts: { lead?: number; milestone?: boolean; due?: string; dueKind?: DeadlineKind; done?: boolean } = {}): Task {
  return {
    id: crypto.randomUUID(), text, category: "todo", done: opts.done ?? false, createdAt: CREATED,
    targetID, pathOrder: order, effortMinutes: effort, leadDays: opts.lead ?? 0, milestone: opts.milestone ?? false,
    needsYou: false, dueDate: opts.due ?? null, dueKind: opts.dueKind ?? null, state: opts.done ? "done" : "todo",
  };
}

Deno.test("walls walk back from the deadline", () => {
  // 600 minutes of draft at 120/weekday, must finish by Nov 21 (Sat, 300): wall for the draft is Nov 21,
  // its latest start walks back over Nov 21(300), 20(120), 19(120), 18(120) → Nov 18.
  const t = target("Manuscript", "2026-12-15", "hard");
  const draft = step("Complete the draft", 600, t.id, 0, { milestone: true });
  const send = step("Send to readers", 30, t.id, 1, { lead: 10, due: "2026-12-01", dueKind: "hard" });
  const incorporate = step("Incorporate comments", 240, t.id, 2);
  const a = plan(input([t], [draft, send, incorporate]));

  assertEquals(a.steps[send.id].wall, "2026-12-01"); // its own hard date caps the wall
  assertEquals(a.steps[draft.id].wall, "2026-11-21"); // 10 days of lead before Dec 1, then the send's 30 min on Dec 1
  assertEquals(a.steps[draft.id].latestStart, "2026-11-18");
  assertEquals(a.steps[incorporate.id].wall, "2026-12-15");
});

Deno.test("hard deadlines outrank goals today", () => {
  const talk = target("Presentation", "2026-11-09", "hard");
  const slides = step("Finalize slides", 120, talk.id, 0);
  const overdue = target("Back assignments", "2026-11-08", "goal");
  const a1 = step("Assignment A", 90, overdue.id, 0);
  const cap: CapacityModel = { minutesByWeekday: [150, 150, 150, 150, 150, 300, 300], fixed: [{ day: "2026-11-09", minutes: 120, why: "the talk" }] };
  const a = plan(input([talk, overdue], [slides, a1], cap));

  const todayIDs = todaysCut(a).map((x) => x.taskID);
  assertEquals(todayIDs[0], slides.id); // the hard step that must start now goes first
  assert(todayIDs.includes(a1.id)); // the overdue goal fills what's left today
  assertEquals(a.targets[talk.id].state, "atRisk"); // one day of slack
  assertEquals(a.steps[slides.id].plannedEnd, TODAY);
});

Deno.test("a hard target that cannot fit raises what gives", () => {
  const t = target("Impossible", "2026-11-09", "hard");
  const big = step("Twelve hours of work", 720, t.id, 0);
  const a = plan(input([t], [big]));

  assertEquals(a.targets[t.id].state, "willMiss");
  assertEquals(a.steps[big.id].late, true);
  assertEquals(a.raised.length, 1);
  assertEquals(a.raised[0].targetID, t.id);
  assertEquals(a.raised[0].raisedBy, "engine");
  assertEquals(a.raised[0].code, `E-${t.id.slice(0, 4).toUpperCase()}`);
});

Deno.test("goals slip instead of missing", () => {
  const g = target("Exam prep", "2026-11-09", "goal");
  const big = step("Review everything", 720, g.id, 0);
  const a = plan(input([g], [big]));

  assertEquals(a.targets[g.id].state, "slipping");
  assertEquals(a.raised.length, 0); // goals never raise the red card
});

Deno.test("lead days delay the next step", () => {
  const t = target("Review", "2026-12-15", "hard");
  const send = step("Send", 30, t.id, 0, { lead: 10 });
  const after = step("After", 60, t.id, 1);
  const a = plan(input([t], [send, after]));

  assertEquals(daysBetween(a.steps[send.id].plannedEnd!, a.steps[after.id].plannedStart!), 11);
});

Deno.test("target date never passes the wall", () => {
  const t = target("Midterm", "2026-11-13", "hard");
  const s1 = step("Model", 180, t.id, 0);
  const s2 = step("Write-up", 120, t.id, 1, { milestone: true });
  const a = plan(input([t], [s1, s2]));

  for (const s of [s1, s2]) {
    const p = a.steps[s.id];
    assert(p.targetDate! <= p.wall!);
    assert(p.targetDate! >= p.plannedEnd!);
  }
});

Deno.test("checking off recomputes everything", () => {
  const t = target("Midterm", "2026-11-13", "hard");
  const s1 = step("Model", 180, t.id, 0);
  const s2 = step("Write-up", 120, t.id, 1);
  const tight: CapacityModel = { minutesByWeekday: [120, 120, 120, 120, 120, 100, 100], fixed: [] };
  const before = plan(input([t], [s1, s2], tight));
  const s1Done = { ...s1, done: true, state: "done" as const };
  const after = plan(input([t], [s1Done, s2], tight));

  assert(before.steps[s2.id].plannedStart! > after.steps[s2.id].plannedStart!);
  assertEquals(after.steps[s1.id], undefined); // done steps leave the plan
  assert((after.targets[t.id].slackDays ?? 0) >= (before.targets[t.id].slackDays ?? 0));
});

Deno.test("capacity pattern is Monday-first", () => {
  const cap: CapacityModel = { minutesByWeekday: [10, 20, 30, 40, 50, 60, 70], fixed: [] };
  assertEquals(capacityMinutes(cap, "2026-11-09"), 10); // Monday
  assertEquals(capacityMinutes(cap, "2026-11-08"), 70); // Sunday
  assertEquals(capacityMinutes(cap, "2026-11-14"), 60); // Saturday
});

Deno.test("standalone todo tasks are one-step paths with their own kind", () => {
  const loose: Task = { ...step("Renew passport", 60, "", 0, { due: "2026-11-10", dueKind: "hard" }), targetID: null };
  const a = plan(input([], [loose]));
  assertEquals(a.steps[loose.id].wall, "2026-11-10");
  assertEquals(todaysCut(a)[0].taskID, loose.id);
  assertEquals(Object.keys(a.targets).length, 0); // no target, no status row
});

Deno.test("a target with no open steps is judged on its date alone", () => {
  const soon = target("Form", "2026-11-09", "hard");
  const far = target("Grant", "2027-01-20", "hard");
  const done = { ...target("Old", "2026-10-01", "hard"), done: true };
  const a = plan(input([soon, far, done], []));
  assertEquals(a.targets[soon.id].state, "atRisk");
  assertEquals(a.targets[far.id].state, "onTrack");
  assertEquals(a.targets[done.id].state, "done");
});
