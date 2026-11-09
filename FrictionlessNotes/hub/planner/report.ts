// Reproduces pm-prototype/engine.py's report() — the markdown in schedule.md —
// from a Ledger and a PlanAssessment, so the port can be checked byte for byte
// against the prototype's output. Not used by the hub at run time.

import { type Day, formatAbd, shiftDay } from "./dates.ts";
import { capacityMinutes, type Ledger, type PlanAssessment, type Target, type TargetState } from "./models.ts";
import type { SeedCodes } from "./seed.ts";
import { tasksFor } from "./models.ts";

const none = (v: unknown) => (v === null || v === undefined ? "None" : String(v));

export function report(ledger: Ledger, a: PlanAssessment, codes: SeedCodes): string {
  const out: string[] = [];
  const P = (s: string) => out.push(s);
  const today = a.today;
  const cap = (d: Day) => capacityMinutes(ledger.capacity, d);
  const taskByID = new Map(ledger.tasks.map((t) => [t.id, t]));
  const targetByID = new Map(ledger.targets.map((t) => [t.id, t]));
  const projectByID = new Map(ledger.projects.map((p) => [p.id, p]));
  void projectByID;
  const targetOf = (taskID: string): Target | undefined => {
    const t = taskByID.get(taskID);
    return t?.targetID ? targetByID.get(t.targetID) : undefined;
  };
  const openSteps = (t: Target) => tasksFor(ledger, t.id).filter((s) => !s.done);

  P(`# Schedule as of ${formatAbd(today)} ${today.slice(0, 4)}\n`);
  const keys = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
  P("Capacity (min/day): " + keys.map((k, i) => `${k} ${ledger.capacity.minutesByWeekday[i]}`).join(", ") +
    "; minus fixed events; EDF across all targets.\n");

  const mark: Record<string, string> = { willMiss: "RED", atRisk: "amber", onTrack: "ok" };
  const hard = ledger.targets.filter((t) => t.kind === "hard").sort((x, y) => (x.due ?? "9999") < (y.due ?? "9999") ? -1 : (x.due ?? "9999") > (y.due ?? "9999") ? 1 : 0);
  P("## Now strip\n");
  P("**Due (hard, by date)**\n");
  for (const t of hard) {
    const st = a.targets[t.id];
    P(`- ${t.due} · ${t.title} · ${mark[st.state] ?? st.state} · slack ${st.slackDays ?? "?"} d`);
  }
  P("\n**At risk / slipping**\n");
  const atRisk = ledger.targets.filter((t) => (["willMiss", "atRisk", "slipping"] as TargetState[]).includes(a.targets[t.id]?.state));
  for (const t of atRisk) {
    const st = a.targets[t.id];
    let why: string;
    if (st.lateTaskIDs.length > 0) {
      const s = taskByID.get(st.lateTaskIDs[0])!;
      const ps = a.steps[s.id];
      why = `${s.text} planned to end ${none(ps.plannedEnd)}, wall ${none(ps.wall)}`;
    } else {
      why = `slack ${none(st.slackDays)} d`;
    }
    P(`- ${t.title} · ${st.state} · ${why}`);
  }
  if (atRisk.length === 0) P("- nothing");
  P("\n**Today**\n");
  const todayAlloc = a.allocations[today] ?? [];
  for (const al of todayAlloc) {
    P(`- ${al.minutes} min · ${taskByID.get(al.taskID)!.text} (${targetOf(al.taskID)?.title})`);
  }
  if (todayAlloc.length === 0) P("- nothing scheduled");

  P("\n## Next 10 days\n");
  for (let i = 0; i < 10; i++) {
    const day = shiftDay(today, i);
    const items = a.allocations[day] ?? [];
    const text = items.map((al) => `${al.minutes}′ ${taskByID.get(al.taskID)!.text} [${codes.targets[targetOf(al.taskID)!.id]}]`).join("; ");
    P(`- **${formatAbd(day)}** (${cap(day)} min): ` + (text || "free"));
  }

  P("\n## Targets and paths\n");
  const sorted = [...ledger.targets].sort((x, y) => (x.due ?? "9999") < (y.due ?? "9999") ? -1 : (x.due ?? "9999") > (y.due ?? "9999") ? 1 : 0);
  for (const t of sorted) {
    const st = a.targets[t.id];
    P(`### ${codes.targets[t.id]} · ${t.title} · ${t.kind} ${none(t.due)} · ${st.state} (slack ${none(st.slackDays)} d)`);
    if (t.whyItMatters) P(`_${t.whyItMatters}_`);
    P("");
    P("| step | effort | lead | wall | planned | target date | note |");
    P("|---|---|---|---|---|---|---|");
    for (const s of openSteps(t)) {
      const ps = a.steps[s.id];
      const flags = [s.milestone ? "MILESTONE" : "", s.needsYou ? "YOU" : "", ps.late ? "LATE" : ""].filter(Boolean).join(" ");
      P(`| ${s.text} | ${s.effortMinutes ?? 30}′ | ${s.leadDays} d | ${none(ps.wall)} | ${none(ps.plannedStart)} → ${none(ps.plannedEnd)} | **${none(ps.targetDate)}** | ${flags} |`);
    }
    P("");
  }
  P("## Decisions for you\n");
  for (const dc of [...ledger.decisions, ...a.raised]) {
    P(`**${codes.decisions[dc.id] ?? dc.code} · ${dc.question}**  `);
    P(`Why now: ${dc.whyNow}  `);
    P(`Background: ${dc.background}  `);
    P(`Touches: ${dc.touches}  `);
    for (const o of dc.options) P(`- [${o.label}] → ${o.does}`);
    P(`If you don't answer: ${dc.ifUnanswered}\n`);
  }
  return out.join("\n");
}
