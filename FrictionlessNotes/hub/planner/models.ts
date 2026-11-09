// The project-manager value types (PlanCore/PlanModels.swift, Ledger.swift)
// in TypeScript. Field names follow the Swift structs; dates that are
// calendar dates in Swift (`due`, `dueDate`, `FixedBlock.day`) are Days
// ('YYYY-MM-DD'), instants (`createdAt`, `doneAt`, `askedAt`) are ISO-8601.

import { type Day, weekdayMondayFirst } from "./dates.ts";

export type NoteCategory = "todo" | "shopping" | "idea" | "note" | "journal" | "reference";
export type DeadlineKind = "hard" | "goal" | "none";
export type TaskState = "todo" | "doing" | "waiting" | "done";
export type Horizon = "week" | "month" | "quarter" | "year" | "someday";
export type ProjectStatus = "active" | "waiting" | "paused" | "done";
export type TargetState = "onTrack" | "atRisk" | "willMiss" | "slipping" | "done" | "backlog";

export interface Area {
  id: string;
  name: string;
  colourHex: number;
  intendedShare: number;
  order: number;
}

export interface Project {
  id: string;
  name: string;
  colourHex: number;
  goal?: string | null;
  archived: boolean;
  createdAt: string;
  areaID?: string | null;
  horizon: Horizon;
  status: ProjectStatus;
  narrative?: string | null;
  people: string[];
}

export interface Target {
  id: string;
  projectID?: string | null;
  title: string;
  due?: Day | null;
  kind: DeadlineKind;
  whyItMatters?: string | null;
  consequenceIfMissed?: string | null;
  done: boolean;
  doneAt?: string | null;
  createdAt: string;
  sourceCaptureID?: string | null;
}

/** Swift `ListItem` — a checkable list item and, on a path, the planner's task. */
export interface Task {
  id: string;
  text: string;
  category: NoteCategory;
  group?: string | null;
  due?: string | null; // spoken hint, display only
  done: boolean;
  doneAt?: string | null;
  createdAt: string;
  sourceCaptureID?: string | null;
  sourceActionID?: string | null;
  projectID?: string | null;
  targetID?: string | null;
  pathOrder: number;
  effortMinutes?: number | null;
  leadDays: number;
  milestone: boolean;
  needsYou: boolean;
  waitingOn?: string | null;
  dueDate?: Day | null;
  dueKind?: DeadlineKind | null;
  state: TaskState;
  plannedBy?: string | null;
  actualMinutes?: number | null;
}

/** Effort the engine plans with. Unestimated work counts as half an hour. */
export function plannedEffort(t: Task): number {
  return t.effortMinutes ?? 30;
}

export interface DecisionOption {
  label: string;
  does: string;
}

export interface Decision {
  id: string;
  code: string;
  projectID?: string | null;
  targetID?: string | null;
  question: string;
  whyNow: string;
  background: string;
  touches: string;
  options: DecisionOption[];
  ifUnanswered: string;
  raisedBy: string; // engine | planner | user
  askedAt: string;
  answeredAt?: string | null;
  answer?: string | null;
  deferredUntil?: string | null;
}

export function decisionIsOpen(d: Decision, now: Date = new Date()): boolean {
  if (d.answeredAt) return false;
  if (d.deferredUntil && Date.parse(d.deferredUntil) > now.getTime()) return false;
  return true;
}

export function decisionIsDeferred(d: Decision, now: Date = new Date()): boolean {
  return !d.answeredAt && !!d.deferredUntil && Date.parse(d.deferredUntil) > now.getTime();
}

export interface Idea {
  id: string;
  projectID?: string | null;
  text: string;
  createdAt: string;
  sourceCaptureID?: string | null;
}

export interface FixedBlock {
  day: Day;
  minutes: number;
  why: string;
}

/** Minutes of focused work the engine may schedule per day. Monday-first. */
export interface CapacityModel {
  minutesByWeekday: number[]; // index 0 = Monday … 6 = Sunday
  fixed: FixedBlock[];
}

export const INTERIM_CAPACITY: CapacityModel = {
  minutesByWeekday: [120, 120, 120, 120, 120, 300, 300],
  fixed: [],
};

export function capacityMinutes(c: CapacityModel, day: Day): number {
  const i = weekdayMondayFirst(day);
  const base = i < c.minutesByWeekday.length ? c.minutesByWeekday[i] : 0;
  const reserved = c.fixed.filter((f) => f.day === day).reduce((s, f) => s + f.minutes, 0);
  return Math.max(0, base - reserved);
}

export interface Ledger {
  areas: Area[];
  projects: Project[];
  targets: Target[];
  tasks: Task[];
  decisions: Decision[];
  ideas: Idea[];
  capacity: CapacityModel;
}

export function emptyLedger(): Ledger {
  return { areas: [], projects: [], targets: [], tasks: [], decisions: [], ideas: [], capacity: { ...INTERIM_CAPACITY, fixed: [] } };
}

/** The ordered steps of a target's path (Ledger.tasks(for:)). */
export function tasksFor(ledger: Ledger, targetID: string): Task[] {
  return ledger.tasks.filter((t) => t.targetID === targetID).sort(byPathOrder);
}

export function byPathOrder(a: Task, b: Task): number {
  if (a.pathOrder !== b.pathOrder) return a.pathOrder - b.pathOrder;
  return (Date.parse(a.createdAt) || 0) - (Date.parse(b.createdAt) || 0);
}

// ── Assessment (§6.1 output) ─────────────────────────────────────────────────

export const TARGET_STATE_SEVERITY: Record<TargetState, number> = {
  willMiss: 0,
  atRisk: 1,
  slipping: 2,
  onTrack: 3,
  backlog: 4,
  done: 5,
};

export const TARGET_STATE_LABEL: Record<TargetState, string> = {
  onTrack: "on track",
  atRisk: "at risk",
  willMiss: "will miss",
  slipping: "slipping",
  done: "done",
  backlog: "backlog",
};

export interface PlanStep {
  taskID: string;
  targetID?: string | null;
  index: number;
  wall?: Day | null;
  latestStart?: Day | null;
  plannedStart?: Day | null;
  plannedEnd?: Day | null;
  targetDate?: Day | null;
  late: boolean;
  minutesLeft: number;
}

export interface TargetStatus {
  targetID: string;
  state: TargetState;
  slackDays?: number | null;
  lateTaskIDs: string[];
  remainingMinutes: number;
}

export interface Allocation {
  taskID: string;
  minutes: number;
}

export interface PlanAssessment {
  computedAt: string;
  today: Day;
  steps: Record<string, PlanStep>; // by task id
  targets: Record<string, TargetStatus>; // by target id
  allocations: Record<Day, Allocation[]>; // by day
  raised: Decision[]; // engine-raised "what gives?" cards
}

export function todaysCut(a: PlanAssessment): Allocation[] {
  return a.allocations[a.today] ?? [];
}

export function committedMinutes(a: PlanAssessment, day: Day): number {
  return (a.allocations[day] ?? []).reduce((s, x) => s + x.minutes, 0);
}
