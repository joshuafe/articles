import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import { plan } from "./engine.ts";
import { countEvents, foldLine, renderICS } from "./ics.ts";
import { parseSeed } from "./seed.ts";
import { nowText } from "./now.ts";

const seedURL = new URL("../../pm-prototype/seed.json", new URL(".", import.meta.url));

async function seeded() {
  const { ledger, today, codes } = parseSeed(JSON.parse(await Deno.readTextFile(seedURL)), new Date("2026-11-08T12:00:00Z"));
  const a = plan({ today: today!, capacity: ledger.capacity, targets: ledger.targets, tasks: ledger.tasks, now: new Date("2026-11-08T12:00:00Z") });
  return { ledger, a, codes };
}

Deno.test("feed carries deadlines and milestones on their target dates, blocks on request", async () => {
  const { ledger, a, codes } = await seeded();
  const base = { ledger, assessment: a, calendarName: "Deadlines", timeZone: "America/New_York", stamp: new Date("2026-11-08T12:00:00Z") };
  const deadlines = renderICS({ ...base, variant: "deadlines" });
  const milestones = renderICS({ ...base, variant: "milestones" });
  const blocks = renderICS({ ...base, variant: "blocks" });

  assertEquals(countEvents(deadlines), 8); // every seed target has a date
  const milestoneCount = ledger.tasks.filter((t) => t.milestone && !t.done).length; // 12
  assertEquals(countEvents(milestones), 8 + milestoneCount);
  assert(countEvents(blocks) > countEvents(milestones));

  // The manuscript draft lands on its engine-chosen target date, Nov 21, labelled with its position and project.
  const draftID = codes.byCode["T7.1"];
  assertStringIncludes(milestones, `UID:step-${draftID}@frictionless-pm`);
  const draftBlock = milestones.slice(milestones.indexOf(`UID:step-${draftID}`));
  assertStringIncludes(draftBlock.slice(0, 600), "DTSTART;VALUE=DATE:20261121");
  assertStringIncludes(draftBlock.slice(0, 600), "1 of 4");

  // Hard deadlines are opaque and say so; goals are transparent.
  assertStringIncludes(deadlines, "SUMMARY:Submit the review manuscript · hard");
  assertStringIncludes(deadlines, "SUMMARY:Final exam prep (modeling class) · goal");
  assertStringIncludes(deadlines, "BEGIN:VTIMEZONE");
  // CRLF line endings, no raw line over 75 octets.
  assert(deadlines.includes("\r\n"));
  for (const line of deadlines.split("\r\n")) assert(new TextEncoder().encode(line).length <= 75, `long line: ${line}`);
});

Deno.test("sequence numbers flow through", async () => {
  const { ledger, a } = await seeded();
  const t = ledger.targets[0];
  const ics = renderICS({ ledger, assessment: a, variant: "deadlines", calendarName: "x", timeZone: "America/New_York", sequences: { targets: { [t.id]: 7 } } });
  const block = ics.slice(ics.indexOf(`UID:target-${t.id}`));
  assertStringIncludes(block.slice(0, 300), "SEQUENCE:7");
});

Deno.test("folding splits at 75 octets and escapes text", () => {
  const long = "SUMMARY:" + "é".repeat(80);
  const folded = foldLine(long);
  for (const l of folded.split("\r\n")) assert(new TextEncoder().encode(l).length <= 75);
  assertEquals(folded.replace(/\r\n /g, ""), long); // unfold round-trips
});

Deno.test("the now text is short and names what matters", async () => {
  const { ledger, a } = await seeded();
  const text = nowText(ledger, a, [], [], new Date("2026-11-08T12:00:00Z"));
  assertStringIncludes(text, "HOSTing presentation");
  assertStringIncludes(text, "## Today (300 of 300 min)");
  assertStringIncludes(text, "Finalize the slides");
  assert(text.length < 2500, `too long: ${text.length}`);
});
