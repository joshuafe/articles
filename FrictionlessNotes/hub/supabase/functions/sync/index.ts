// sync — what the Mac (and later the phone) talks to with its device token.
//
//   GET  /functions/v1/sync          → the whole ledger as one JSON snapshot (ledger_snapshot)
//   POST /functions/v1/sync          body = changes (apply_changes shape) → { applied, version }
//                                     then the engine re-runs so the feed and assistants see it
//   Authorization: Bearer <trusted device token>
//
// Keeping the Mac behind an edge function means the service key never leaves
// Supabase and a device token can be revoked on its own.

import { authenticate, extractToken, json, loadState, replan, serviceClient } from "../_shared/db.ts";

const CORS = { "access-control-allow-origin": "*", "access-control-allow-methods": "GET, POST, OPTIONS", "access-control-allow-headers": "authorization, content-type" };

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  const db = serviceClient();
  const token = await authenticate(db, extractToken(req, "sync"));
  if (!token || !token.trusted || token.kind === "feed") return json({ error: "a trusted device token is required" }, 401, CORS);

  if (req.method === "GET") {
    const { data, error } = await db.rpc("ledger_snapshot");
    if (error) return json({ error: error.message }, 500, CORS);
    return json(data, 200, { ...CORS, "cache-control": "no-store" });
  }
  if (req.method !== "POST") return new Response("GET or POST", { status: 405, headers: { ...CORS, allow: "GET, POST, OPTIONS" } });

  let changes: unknown;
  try {
    changes = await req.json();
  } catch {
    return json({ error: "body must be JSON" }, 400, CORS);
  }
  const { data, error } = await db.rpc("apply_changes", { p: changes, p_source: token.source, p_token: token.id });
  if (error) return json({ error: error.message, details: error.details, hint: error.hint }, 400, CORS);
  let plan: Record<string, unknown> = {};
  try {
    const state = await loadState(db);
    const r = await replan(db, state, token.source, token.id);
    plan = { movedSteps: r.movedSteps, raisedNew: r.raisedNew, raisedCleared: r.raisedCleared, computedAt: r.assessment.computedAt };
  } catch (e) {
    console.error("replan after sync failed", e);
    plan = { error: String((e as Error)?.message ?? e) };
  }
  return json({ ...(data as Record<string, unknown>), plan }, 200, CORS);
});
