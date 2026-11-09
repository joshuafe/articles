// The prototype seed (pm-prototype/seed.json) round-trips into a Ledger and
// the engine schedules it the way the Python prototype did — checked against
// schedule.md byte for byte. A port of SeedImporterTests.swift plus the
// full-report comparison.

import { assert, assertEquals } from "@std/assert";
import { plan } from "./engine.ts";
import { committedMinutes, tasksFor, todaysCut } from "./models.ts";
import { report } from "./report.ts";
import { parseSeed } from "./seed.ts";

const here = new URL(".", import.meta.url);
const seedURL = new URL("../../pm-prototype/seed.json", here);
const scheduleURL = new URL("../../pm-prototype/schedule.md", here);

async function loadSeed() {
  const root = JSON.parse(await Deno.readTextFile(seedURL));
  return parseSeed(root, new Date("2026-11-08T12:00:00Z"));
}

Deno.test("seed parses into a ledger", async () => {
  const { ledger, today } = await loadSeed();
  assertEquals(today, "2026-11-08");
  assertEquals(ledger.projects.length, 5);
  assertEquals(ledger.targets.length, 8);
  assertEquals(ledger.tasks.length, 27);
  assertEquals(ledger.decisions.length, 4);
  assertEquals(ledger.areas.length, 6);
  assertEquals(ledger.capacity.minutesByWeekday, [120, 120, 120, 120, 120, 300, 300]);

  const manuscript = ledger.targets.find((t) => t.title.startsWith("Submit the review manuscript"))!;
  assertEquals(manuscript.kind, "hard");
  assertEquals(manuscript.due, "2026-12-15");
  const steps = tasksFor(ledger, manuscript.id);
  assertEquals(steps[0].text, "Complete the full draft");
  assertEquals(steps[1].leadDays, 10);
  assertEquals(steps[1].dueDate, "2026-12-01");
  assertEquals(steps[1].dueKind, "hard");

  const overdue = ledger.targets.find((t) => t.title.startsWith("Overdue back assignments"))!;
  assertEquals(overdue.kind, "hard"); // D3: cutoff Friday Nov 13

  const d1 = ledger.decisions.find((d) => d.code === "D1")!;
  assert(d1.answeredAt);
  assert(d1.targetID);
});

Deno.test("engine schedules the seed like the prototype", async () => {
  const { ledger, today } = await loadSeed();
  const a = plan({ today: today!, capacity: ledger.capacity, targets: ledger.targets, tasks: ledger.tasks });

  // Today (Sun Nov 8, 300 min) opens with the presentation, as in schedule.md.
  const first = todaysCut(a)[0];
  assertEquals(ledger.tasks.find((t) => t.id === first.taskID)!.text, "Finalize the slides");
  assertEquals(committedMinutes(a, "2026-11-08"), 300);

  // The reader deadline pulls the draft's wall to Nov 21.
  const manuscript = ledger.targets.find((t) => t.title.startsWith("Submit the review manuscript"))!;
  const draft = tasksFor(ledger, manuscript.id)[0];
  assertEquals(a.steps[draft.id].wall, "2026-11-21");

  // Nothing is unreachable at this capacity; three hard targets are tight.
  assertEquals(a.raised.length, 0);
  const tight = ledger.targets.filter((t) => a.targets[t.id].state === "atRisk");
  assertEquals(tight.length, 3);
});

Deno.test("the report reproduces pm-prototype/schedule.md", async () => {
  const { ledger, today, codes } = await loadSeed();
  const a = plan({ today: today!, capacity: ledger.capacity, targets: ledger.targets, tasks: ledger.tasks });
  const expected = (await Deno.readTextFile(scheduleURL)).replace(/\n*\(feed written to [^\n]*\)\n*$/, "").trimEnd();
  const actual = report(ledger, a, codes).trimEnd();
  if (actual !== expected) {
    const el = expected.split("\n"), al = actual.split("\n");
    for (let i = 0; i < Math.max(el.length, al.length); i++) {
      if (el[i] !== al[i]) {
        throw new Error(`schedule.md differs at line ${i + 1}:\n  expected: ${el[i]}\n  actual:   ${al[i]}`);
      }
    }
  }
  assertEquals(actual, expected);
});
