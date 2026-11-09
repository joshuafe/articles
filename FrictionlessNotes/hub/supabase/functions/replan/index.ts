// replan — run the urgency engine over the ledger and store the assessment
// (plan_steps, target_status, allocations) plus any newly raised "what gives?"
// decisions. Called by pg_cron every 30 minutes (migration 3), by the Mac after
// a push, and by anyone holding a trusted token who wants the plan now.
//
//   POST /functions/v1/replan        Authorization: Bearer <trusted token>
//   → { ok, today, steps, movedSteps, raisedNew, raisedCleared, computedAt }

import { authenticate, extractToken, json, loadState, replan, serviceClient } from "../_shared/db.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204 });
  const db = serviceClient();
  const token = await authenticate(db, extractToken(req, "replan"));
  if (!token || !token.trusted) return json({ error: "a trusted token is required" }, 401);
  let source = token.source;
  try {
    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
    if (typeof body?.source === "string" && body.source) source = body.source;
  } catch { /* no body */ }
  try {
    const state = await loadState(db);
    const r = await replan(db, state, source, token.id);
    return json({
      ok: true,
      today: r.assessment.today,
      computedAt: r.assessment.computedAt,
      steps: Object.keys(r.assessment.steps).length,
      targets: Object.keys(r.assessment.targets).length,
      movedSteps: r.movedSteps,
      raisedNew: r.raisedNew,
      raisedCleared: r.raisedCleared,
    });
  } catch (e) {
    console.error("replan failed", e);
    return json({ ok: false, error: String((e as Error)?.message ?? e) }, 500);
  }
});
