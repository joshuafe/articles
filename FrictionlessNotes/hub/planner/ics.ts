// The calendar feed (DESIGN-PM.md §9.1): the route, not the list. For each
// target the engine dated, serve the deadline, each milestone step on its
// targetDate, and optionally the planned work blocks. Stable UIDs and a
// SEQUENCE that rises when a date moves, so a subscriber updates in place.
//
// Pure: takes a ledger, an assessment and the sequence numbers the hub keeps,
// returns the text/calendar body. RFC 5545 folding and escaping included.

import { compactDay, type Day, dayToUTC, shiftDay, weekdayMondayFirst } from "./dates.ts";
import { type Ledger, type PlanAssessment, type Target, TARGET_STATE_LABEL, type Task, tasksFor } from "./models.ts";

export type FeedVariant = "deadlines" | "milestones" | "blocks";

export interface ICSOptions {
  ledger: Ledger;
  assessment: PlanAssessment;
  variant: FeedVariant;
  calendarName: string;
  timeZone: string;
  /** SEQUENCE per target id and per task id (the hub bumps these when a date moves). */
  sequences?: { targets?: Record<string, number>; steps?: Record<string, number> };
  /** DTSTAMP; defaults to now. */
  stamp?: Date;
  /** UID domain suffix. */
  domain?: string;
  /** Hint to subscribers; Google ignores it, Apple honours it. */
  refreshMinutes?: number;
}

const VTIMEZONES: Record<string, string[]> = {
  "America/New_York": [
    "BEGIN:VTIMEZONE", "TZID:America/New_York",
    "BEGIN:STANDARD", "DTSTART:20071104T020000", "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU", "TZOFFSETFROM:-0400", "TZOFFSETTO:-0500", "TZNAME:EST", "END:STANDARD",
    "BEGIN:DAYLIGHT", "DTSTART:20070311T020000", "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU", "TZOFFSETFROM:-0500", "TZOFFSETTO:-0400", "TZNAME:EDT", "END:DAYLIGHT",
    "END:VTIMEZONE",
  ],
  "America/Chicago": [
    "BEGIN:VTIMEZONE", "TZID:America/Chicago",
    "BEGIN:STANDARD", "DTSTART:20071104T020000", "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU", "TZOFFSETFROM:-0500", "TZOFFSETTO:-0600", "TZNAME:CST", "END:STANDARD",
    "BEGIN:DAYLIGHT", "DTSTART:20070311T020000", "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU", "TZOFFSETFROM:-0600", "TZOFFSETTO:-0500", "TZNAME:CDT", "END:DAYLIGHT",
    "END:VTIMEZONE",
  ],
  "America/Los_Angeles": [
    "BEGIN:VTIMEZONE", "TZID:America/Los_Angeles",
    "BEGIN:STANDARD", "DTSTART:20071104T020000", "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU", "TZOFFSETFROM:-0700", "TZOFFSETTO:-0800", "TZNAME:PST", "END:STANDARD",
    "BEGIN:DAYLIGHT", "DTSTART:20070311T020000", "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU", "TZOFFSETFROM:-0800", "TZOFFSETTO:-0700", "TZNAME:PDT", "END:DAYLIGHT",
    "END:VTIMEZONE",
  ],
};

export function escapeText(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/;/g, "\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
}

/** RFC 5545 §3.1: lines longer than 75 octets are folded with CRLF + space. */
export function foldLine(line: string): string {
  const enc = new TextEncoder();
  const out: string[] = [];
  let cur = "";
  let curBytes = 0;
  const limit = () => (out.length === 0 ? 75 : 74); // continuation lines start with a space
  for (const ch of line) {
    const b = enc.encode(ch).length;
    if (curBytes + b > limit()) {
      out.push(cur);
      cur = "";
      curBytes = 0;
    }
    cur += ch;
    curBytes += b;
  }
  out.push(cur);
  return out.map((l, i) => (i === 0 ? l : " " + l)).join("\r\n");
}

function stampOf(d: Date): string {
  return d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
}

function hms(day: Day, hour: number, minute: number): string {
  return `${compactDay(day)}T${String(hour).padStart(2, "0")}${String(minute).padStart(2, "0")}00`;
}

export function renderICS(opts: ICSOptions): string {
  const { ledger, assessment: a, variant, timeZone } = opts;
  const stamp = stampOf(opts.stamp ?? new Date());
  const domain = opts.domain ?? "frictionless-pm";
  const seqT = opts.sequences?.targets ?? {};
  const seqS = opts.sequences?.steps ?? {};
  const refresh = opts.refreshMinutes ?? 60;
  const projectByID = new Map(ledger.projects.map((p) => [p.id, p]));
  const taskByID = new Map(ledger.tasks.map((t) => [t.id, t]));
  const L: string[] = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//FrictionlessNotes//frictionless-pm hub//EN",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    `X-WR-CALNAME:${escapeText(opts.calendarName)}`,
    `X-WR-TIMEZONE:${timeZone}`,
    `REFRESH-INTERVAL;VALUE=DURATION:PT${refresh}M`,
    `X-PUBLISHED-TTL:PT${refresh}M`,
    ...(VTIMEZONES[timeZone] ?? VTIMEZONES["America/New_York"]),
  ];

  const allday = (uid: string, day: Day, title: string, desc: string, transparent: boolean, seq: number, lastMod?: string) => {
    L.push(
      "BEGIN:VEVENT",
      `UID:${uid}@${domain}`,
      `DTSTAMP:${stamp}`,
      ...(lastMod ? [`LAST-MODIFIED:${lastMod}`] : []),
      `SEQUENCE:${seq}`,
      `DTSTART;VALUE=DATE:${compactDay(day)}`,
      `DTEND;VALUE=DATE:${compactDay(shiftDay(day, 1))}`,
      `SUMMARY:${escapeText(title)}`,
      `DESCRIPTION:${escapeText(desc)}`,
      transparent ? "TRANSP:TRANSPARENT" : "TRANSP:OPAQUE",
      "END:VEVENT",
    );
  };

  const openTargets = ledger.targets.filter((t) => !t.done);
  for (const t of openTargets) {
    if (!t.due) continue;
    const st = a.targets[t.id];
    const steps = tasksFor(ledger, t.id).filter((s) => !s.done);
    const n = steps.length;
    const project = t.projectID ? projectByID.get(t.projectID) : undefined;

    // The deadline itself: an all-day event titled with its kind; a goal is tentative.
    const descParts: string[] = [];
    if (st) {
      descParts.push(TARGET_STATE_LABEL[st.state] + (st.slackDays !== null && st.slackDays !== undefined ? `; ${st.slackDays} d slack` : ""));
      if (st.lateTaskIDs.length > 0) {
        const late = taskByID.get(st.lateTaskIDs[0]);
        const ps = late ? a.steps[late.id] : undefined;
        if (late && ps) descParts.push(`Late step: ${late.text} (planned ${ps.plannedEnd ?? "never"}, no later than ${ps.wall ?? "?"})`);
      }
    }
    if (t.whyItMatters) descParts.push(t.whyItMatters);
    if (t.consequenceIfMissed) descParts.push(`If missed: ${t.consequenceIfMissed}`);
    if (project) descParts.push(`Project: ${project.name}`);
    if (n > 0) descParts.push(`${n} step${n === 1 ? "" : "s"} open · ${st?.remainingMinutes ?? 0} min remaining`);
    const kindLabel = t.kind === "hard" ? "hard" : t.kind === "goal" ? "goal" : "no date";
    allday(`target-${t.id}`, t.due, `${t.title} · ${kindLabel}`, descParts.join("\n"), t.kind !== "hard", seqT[t.id] ?? 0);

    if (variant === "deadlines") continue;

    // Each milestone step as its own all-day event on its target date.
    steps.forEach((s: Task, i) => {
      const ps = a.steps[s.id];
      if (!s.milestone || !ps?.targetDate) return;
      const parts = [`No later than ${ps.wall ?? "—"}.`, `Estimate ${s.effortMinutes ?? 30} min` + (s.leadDays ? ` + ${s.leadDays} d waiting` : "")];
      if (s.needsYou) parts.push("Needs you.");
      if (ps.late) parts.push("LATE");
      parts.push(`For: ${t.title}`);
      const who = project?.name ?? t.title;
      allday(`step-${s.id}`, ps.targetDate, `${s.text} · ${i + 1} of ${n} · ${who}`, parts.join(" "), true, seqS[s.id] ?? 0);
    });
  }

  if (variant === "blocks") {
    // The planned work blocks as timed events: the calendar version of "today".
    const days = Object.keys(a.allocations).sort();
    for (const day of days) {
      const weekend = weekdayMondayFirst(day) >= 5;
      let hour = weekend ? 10 : 9;
      let minute = 0;
      for (const al of a.allocations[day]) {
        const task = taskByID.get(al.taskID);
        if (!task) continue;
        const start = hms(day, hour, minute);
        const total = hour * 60 + minute + al.minutes;
        const endHour = Math.floor(total / 60), endMinute = total % 60;
        const end = endHour >= 24 ? hms(shiftDay(day, 1), endHour - 24, endMinute) : hms(day, endHour, endMinute);
        const target = task.targetID ? ledger.targets.find((t) => t.id === task.targetID) : undefined;
        L.push(
          "BEGIN:VEVENT",
          `UID:block-${task.id}-${compactDay(day)}@${domain}`,
          `DTSTAMP:${stamp}`,
          `SEQUENCE:${seqS[task.id] ?? 0}`,
          `DTSTART;TZID=${timeZone}:${start}`,
          `DTEND;TZID=${timeZone}:${end}`,
          `SUMMARY:${escapeText(`Work: ${task.text}`)}`,
          `DESCRIPTION:${escapeText(`${al.minutes} min` + (target ? ` · ${target.title}` : ""))}`,
          "TRANSP:TRANSPARENT",
          "END:VEVENT",
        );
        const next = total + 15;
        hour = Math.floor(next / 60);
        minute = next % 60;
      }
    }
  }

  L.push("END:VCALENDAR");
  return L.map(foldLine).join("\r\n") + "\r\n";
}

/** Count VEVENTs in a rendered calendar (for tests and the health check). */
export function countEvents(ics: string): number {
  return (ics.match(/BEGIN:VEVENT/g) ?? []).length;
}

export { dayToUTC };
