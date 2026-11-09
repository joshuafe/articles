// feed — the live calendar subscription (DESIGN-PM.md §9.1).
//
//   GET /functions/v1/feed?t=<feed token>            deadlines + milestone steps (default)
//   GET /functions/v1/feed?t=<feed token>&m=0        deadlines only
//   GET /functions/v1/feed?t=<feed token>&blocks=1   deadlines + milestones + planned work blocks
//
// Renders the current ledger on every request as text/calendar: one all-day
// VEVENT per dated target (hard ones say so in the title), one all-day VEVENT
// per milestone step on the date the engine chose for it, timed VEVENTs for the
// planned blocks on request. UIDs are stable and SEQUENCE rises when a date
// moves, so Outlook, Google and Apple Calendar update in place on re-poll.
// Deployed with JWT verification off: the feed token is the credential.

import { renderICS, type FeedVariant } from "../../../planner/ics.ts";
import { authenticate, currentPlan, extractToken, serviceClient } from "../_shared/db.ts";

async function etagOf(body: string): Promise<string> {
  const h = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body));
  return `"${Array.from(new Uint8Array(h)).slice(0, 16).map((b) => b.toString(16).padStart(2, "0")).join("")}"`;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response("GET only", { status: 405, headers: { allow: "GET, HEAD" } });
  }
  const db = serviceClient();
  const token = await authenticate(db, extractToken(req, "feed"));
  if (!token || token.kind !== "feed") {
    return new Response("unknown feed token", { status: 401, headers: { "cache-control": "no-store" } });
  }
  const url = new URL(req.url);
  const variant: FeedVariant = url.searchParams.get("blocks") === "1" ? "blocks" : url.searchParams.get("m") === "0" ? "deadlines" : "milestones";

  const { state, assessment, sequences } = await currentPlan(db, "feed");
  const body = renderICS({
    ledger: state.ledger,
    assessment,
    variant,
    calendarName: state.settings.calendarName,
    timeZone: state.settings.timezone,
    sequences,
    refreshMinutes: 60,
  });
  const etag = await etagOf(body);
  const headers: Record<string, string> = {
    "content-type": "text/calendar; charset=utf-8",
    "content-disposition": 'inline; filename="deadlines.ics"',
    // Google polls every 12–24 h regardless; Outlook ~3 h; Apple as configured. A short
    // shared max-age keeps a burst of pollers from re-planning, must-revalidate keeps it honest.
    "cache-control": "public, max-age=300, must-revalidate",
    "etag": etag,
    "last-modified": new Date(assessment.computedAt).toUTCString(),
    "x-frictionless-events": String((body.match(/BEGIN:VEVENT/g) ?? []).length),
    "access-control-allow-origin": "*",
  };
  if (req.headers.get("if-none-match") === etag) return new Response(null, { status: 304, headers });
  return new Response(req.method === "HEAD" ? null : body, { status: 200, headers });
});
