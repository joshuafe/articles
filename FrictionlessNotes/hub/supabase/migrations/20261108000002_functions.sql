-- frictionless-pm · migration 2: the SQL verbs.
--
--   create_api_token(name, kind, source, trusted) → the bearer token, shown once
--   authenticate_token(token)                      → the api_tokens row (and stamps last_used_at)
--   ledger_snapshot()                              → the whole Ledger as one jsonb (what the Mac pulls)
--   apply_changes(changes, source, token_id)       → upsert rows + log one event per changed row (what the Mac pushes)
--   log_event(...)                                 → one append to the events log
--   expire_proposals()                             → pending → expired after 7 days
--
-- Everything is `security definer` and revoked from anon/authenticated: only the
-- service role (edge functions) may call them.

-- ── Tokens ───────────────────────────────────────────────────────────────────
create or replace function create_api_token(p_name text, p_kind token_kind, p_source text, p_trusted boolean default false)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
  tok text;
begin
  tok := 'fpm_' || p_source || '_' || encode(extensions.gen_random_bytes(24), 'hex');
  insert into api_tokens (name, kind, source, token_hash, trusted)
  values (p_name, p_kind, p_source, encode(extensions.digest(tok, 'sha256'), 'hex'), p_trusted);
  return tok;
end $$;

create or replace function authenticate_token(p_token text)
returns api_tokens language plpgsql security definer set search_path = public, extensions as $$
declare
  row api_tokens;
begin
  select * into row from api_tokens
   where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex') and revoked_at is null;
  if found then
    update api_tokens set last_used_at = now() where id = row.id;
    insert into cursors (token_id) values (row.id) on conflict do nothing;
  end if;
  return row;
end $$;

-- ── Events ───────────────────────────────────────────────────────────────────
create or replace function log_event(p_source text, p_token uuid, p_kind text, p_entity text, p_entity_id uuid, p_summary text, p_payload jsonb default null)
returns bigint language sql security definer set search_path = public as $$
  insert into events (source, token_id, kind, entity, entity_id, summary, payload)
  values (p_source, p_token, p_kind, p_entity, p_entity_id, p_summary, p_payload)
  returning id;
$$;

-- ── Snapshot ─────────────────────────────────────────────────────────────────
-- Column names are the wire format (snake_case); dates are 'YYYY-MM-DD',
-- timestamps ISO-8601 with offset. `version` is the latest event id, so a
-- client can tell whether anything changed since its last pull.
create or replace function ledger_snapshot()
returns jsonb language sql security definer set search_path = public stable as $$
  select jsonb_build_object(
    'version',   coalesce((select max(id) from events), 0),
    'areas',     coalesce((select jsonb_agg(to_jsonb(a) order by a.sort_order, a.name) from areas a), '[]'),
    'projects',  coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at) from projects p), '[]'),
    'targets',   coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at) from targets t), '[]'),
    'tasks',     coalesce((select jsonb_agg(to_jsonb(k) order by k.created_at) from tasks k), '[]'),
    'decisions', coalesce((select jsonb_agg(to_jsonb(d) order by d.asked_at desc) from decisions d), '[]'),
    'ideas',     coalesce((select jsonb_agg(to_jsonb(i) order by i.created_at desc) from ideas i), '[]'),
    'capacity',  (select to_jsonb(c) from capacity c where c.id = 1),
    'settings',  (select to_jsonb(s) - 'hub_url' from settings s where s.id = 1),
    'proposals', coalesce((select jsonb_agg(to_jsonb(pr) order by pr.created_at) from proposals pr where pr.status = 'pending'), '[]'),
    'assessment', (select jsonb_build_object(
        'computed_at', a.computed_at, 'today', a.today,
        'steps',     coalesce((select jsonb_agg(to_jsonb(s)) from plan_steps s), '[]'),
        'targets',   coalesce((select jsonb_agg(to_jsonb(ts)) from target_status ts), '[]'),
        'allocations', coalesce((select jsonb_agg(to_jsonb(al) order by al.day, al.position) from allocations al), '[]'))
      from assessments a order by a.id desc limit 1)
  );
$$;

-- ── Apply a batch of changes atomically ──────────────────────────────────────
-- changes = { areas:[row…], projects:[…], targets:[…], tasks:[…], decisions:[…], ideas:[…],
--             capacity:{…}, deleted:{ areas:[id…], projects:[…], targets:[…], tasks:[…], decisions:[…], ideas:[…] } }
-- Rows are whole rows in wire format. Each row that is new or differs from the
-- stored one is upserted and logged (added / changed / done / moved / removed).
-- Returns { applied: n, version: latest event id }.
create or replace function apply_changes(p jsonb, p_source text, p_token uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  e        jsonb;
  cnt      integer := 0;
  ex_j     jsonb;
  in_j     jsonb;
  kind     text;
  r_area   areas;
  r_proj   projects;
  r_tgt    targets;
  r_task   tasks;
  r_dec    decisions;
  r_idea   ideas;
  r_cap    capacity;
  d_id     uuid;
  summary  text;
begin
  -- areas
  for e in select * from jsonb_array_elements(coalesce(p->'areas', '[]')) loop
    r_area := jsonb_populate_record(null::areas, e - 'updated_at' - 'created_at');
    select to_jsonb(a) - 'updated_at' - 'created_at' into ex_j from areas a where a.id = r_area.id;
    in_j := to_jsonb(r_area) - 'updated_at' - 'created_at';
    if ex_j is not distinct from in_j then continue; end if;
    insert into areas (id, name, colour_hex, intended_share, sort_order, created_at)
    values (r_area.id, r_area.name, r_area.colour_hex, coalesce(r_area.intended_share, 0.1), coalesce(r_area.sort_order, 0),
            coalesce((e->>'created_at')::timestamptz, now()))
    on conflict (id) do update set name = excluded.name, colour_hex = excluded.colour_hex,
      intended_share = excluded.intended_share, sort_order = excluded.sort_order;
    perform log_event(p_source, p_token, case when ex_j is null then 'added' else 'changed' end, 'area', r_area.id, r_area.name, null);
    cnt := cnt + 1;
  end loop;

  -- projects
  for e in select * from jsonb_array_elements(coalesce(p->'projects', '[]')) loop
    r_proj := jsonb_populate_record(null::projects, e - 'updated_at');
    select to_jsonb(x) - 'updated_at' into ex_j from projects x where x.id = r_proj.id;
    in_j := to_jsonb(r_proj) - 'updated_at';
    if ex_j is not null and (ex_j - 'created_at') is not distinct from (in_j - 'created_at') then continue; end if;
    insert into projects (id, name, colour_hex, goal, archived, created_at, area_id, horizon, status, narrative, people)
    values (r_proj.id, r_proj.name, coalesce(r_proj.colour_hex, 6007039), r_proj.goal, coalesce(r_proj.archived, false),
            coalesce(r_proj.created_at, now()), r_proj.area_id, coalesce(r_proj.horizon, 'month'), coalesce(r_proj.status, 'active'),
            r_proj.narrative, coalesce(r_proj.people, '{}'))
    on conflict (id) do update set name = excluded.name, colour_hex = excluded.colour_hex, goal = excluded.goal,
      archived = excluded.archived, area_id = excluded.area_id, horizon = excluded.horizon, status = excluded.status,
      narrative = excluded.narrative, people = excluded.people;
    perform log_event(p_source, p_token, case when ex_j is null then 'added' else 'changed' end, 'project', r_proj.id, r_proj.name, null);
    cnt := cnt + 1;
  end loop;

  -- targets
  for e in select * from jsonb_array_elements(coalesce(p->'targets', '[]')) loop
    r_tgt := jsonb_populate_record(null::targets, e - 'updated_at' - 'version');
    select to_jsonb(x) - 'updated_at' - 'version' into ex_j from targets x where x.id = r_tgt.id;
    in_j := to_jsonb(r_tgt) - 'updated_at' - 'version';
    if ex_j is not null and (ex_j - 'created_at') is not distinct from (in_j - 'created_at') then continue; end if;
    kind := case when ex_j is null then 'added'
                 when (ex_j->>'done')::boolean = false and r_tgt.done then 'done'
                 when ex_j->>'due' is distinct from in_j->>'due' then 'moved'
                 else 'changed' end;
    insert into targets (id, project_id, title, due, kind, why_it_matters, consequence_if_missed, done, done_at, created_at, source_capture_id)
    values (r_tgt.id, r_tgt.project_id, r_tgt.title, r_tgt.due, coalesce(r_tgt.kind, 'none'), r_tgt.why_it_matters,
            r_tgt.consequence_if_missed, coalesce(r_tgt.done, false), r_tgt.done_at, coalesce(r_tgt.created_at, now()), r_tgt.source_capture_id)
    on conflict (id) do update set project_id = excluded.project_id, title = excluded.title, due = excluded.due, kind = excluded.kind,
      why_it_matters = excluded.why_it_matters, consequence_if_missed = excluded.consequence_if_missed, done = excluded.done,
      done_at = excluded.done_at, source_capture_id = excluded.source_capture_id;
    summary := r_tgt.title || case when r_tgt.due is not null then ' · ' || r_tgt.kind || ' ' || r_tgt.due else '' end;
    perform log_event(p_source, p_token, kind, 'target', r_tgt.id, summary,
                      case when kind = 'moved' then jsonb_build_object('from', ex_j->>'due', 'to', in_j->>'due') else null end);
    cnt := cnt + 1;
  end loop;

  -- tasks
  for e in select * from jsonb_array_elements(coalesce(p->'tasks', '[]')) loop
    r_task := jsonb_populate_record(null::tasks, e - 'updated_at' - 'version');
    select to_jsonb(x) - 'updated_at' - 'version' into ex_j from tasks x where x.id = r_task.id;
    in_j := to_jsonb(r_task) - 'updated_at' - 'version';
    if ex_j is not null and (ex_j - 'created_at') is not distinct from (in_j - 'created_at') then continue; end if;
    kind := case when ex_j is null then 'added'
                 when (ex_j->>'done')::boolean = false and r_task.done then 'done'
                 when ex_j->>'due_date' is distinct from in_j->>'due_date' then 'moved'
                 else 'changed' end;
    insert into tasks (id, text, category, group_label, due_hint, done, done_at, created_at, source_capture_id, source_action_id,
                       project_id, target_id, path_order, effort_minutes, lead_days, milestone, needs_you, waiting_on,
                       due_date, due_kind, state, planned_by, actual_minutes)
    values (r_task.id, r_task.text, coalesce(r_task.category, 'todo'), r_task.group_label, r_task.due_hint, coalesce(r_task.done, false),
            r_task.done_at, coalesce(r_task.created_at, now()), r_task.source_capture_id, r_task.source_action_id,
            r_task.project_id, r_task.target_id, coalesce(r_task.path_order, 0), r_task.effort_minutes, coalesce(r_task.lead_days, 0),
            coalesce(r_task.milestone, false), coalesce(r_task.needs_you, false), r_task.waiting_on,
            r_task.due_date, r_task.due_kind, coalesce(r_task.state, case when coalesce(r_task.done, false) then 'done' else 'todo' end),
            r_task.planned_by, r_task.actual_minutes)
    on conflict (id) do update set text = excluded.text, category = excluded.category, group_label = excluded.group_label,
      due_hint = excluded.due_hint, done = excluded.done, done_at = excluded.done_at, source_capture_id = excluded.source_capture_id,
      source_action_id = excluded.source_action_id, project_id = excluded.project_id, target_id = excluded.target_id,
      path_order = excluded.path_order, effort_minutes = excluded.effort_minutes, lead_days = excluded.lead_days,
      milestone = excluded.milestone, needs_you = excluded.needs_you, waiting_on = excluded.waiting_on, due_date = excluded.due_date,
      due_kind = excluded.due_kind, state = excluded.state, planned_by = excluded.planned_by, actual_minutes = excluded.actual_minutes;
    perform log_event(p_source, p_token, kind, 'task', r_task.id, r_task.text, null);
    cnt := cnt + 1;
  end loop;

  -- decisions
  for e in select * from jsonb_array_elements(coalesce(p->'decisions', '[]')) loop
    r_dec := jsonb_populate_record(null::decisions, e - 'updated_at');
    select to_jsonb(x) - 'updated_at' into ex_j from decisions x where x.id = r_dec.id;
    in_j := to_jsonb(r_dec) - 'updated_at';
    if ex_j is not distinct from in_j then continue; end if;
    kind := case when ex_j is null then 'added'
                 when ex_j->>'answered_at' is null and r_dec.answered_at is not null then 'answered'
                 when ex_j->>'deferred_until' is distinct from in_j->>'deferred_until' and r_dec.deferred_until is not null then 'deferred'
                 else 'changed' end;
    insert into decisions (id, code, project_id, target_id, question, why_now, background, touches, options, if_unanswered,
                           raised_by, asked_at, answered_at, answer, deferred_until)
    values (r_dec.id, r_dec.code, r_dec.project_id, r_dec.target_id, r_dec.question, coalesce(r_dec.why_now, ''),
            coalesce(r_dec.background, ''), coalesce(r_dec.touches, ''), coalesce(r_dec.options, '[]'), coalesce(r_dec.if_unanswered, ''),
            coalesce(r_dec.raised_by, 'user'), coalesce(r_dec.asked_at, now()), r_dec.answered_at, r_dec.answer, r_dec.deferred_until)
    on conflict (id) do update set code = excluded.code, project_id = excluded.project_id, target_id = excluded.target_id,
      question = excluded.question, why_now = excluded.why_now, background = excluded.background, touches = excluded.touches,
      options = excluded.options, if_unanswered = excluded.if_unanswered, raised_by = excluded.raised_by, asked_at = excluded.asked_at,
      answered_at = excluded.answered_at, answer = excluded.answer, deferred_until = excluded.deferred_until;
    perform log_event(p_source, p_token, kind, 'decision', r_dec.id, r_dec.code || ' · ' || r_dec.question,
                      case when kind = 'answered' then jsonb_build_object('answer', r_dec.answer) else null end);
    cnt := cnt + 1;
  end loop;

  -- ideas
  for e in select * from jsonb_array_elements(coalesce(p->'ideas', '[]')) loop
    r_idea := jsonb_populate_record(null::ideas, e);
    select to_jsonb(x) into ex_j from ideas x where x.id = r_idea.id;
    if ex_j is not distinct from to_jsonb(r_idea) then continue; end if;
    insert into ideas (id, project_id, text, created_at, source_capture_id)
    values (r_idea.id, r_idea.project_id, r_idea.text, coalesce(r_idea.created_at, now()), r_idea.source_capture_id)
    on conflict (id) do update set project_id = excluded.project_id, text = excluded.text;
    perform log_event(p_source, p_token, case when ex_j is null then 'added' else 'changed' end, 'idea', r_idea.id, r_idea.text, null);
    cnt := cnt + 1;
  end loop;

  -- capacity (single row)
  if p ? 'capacity' and jsonb_typeof(p->'capacity') = 'object' then
    r_cap := jsonb_populate_record(null::capacity, (p->'capacity') - 'updated_at' - 'id');
    select to_jsonb(c) - 'updated_at' - 'id' into ex_j from capacity c where c.id = 1;
    in_j := jsonb_build_object('minutes_by_weekday', to_jsonb(r_cap.minutes_by_weekday), 'fixed', coalesce(r_cap.fixed, '[]'));
    if ex_j is distinct from in_j then
      update capacity set minutes_by_weekday = coalesce(r_cap.minutes_by_weekday, minutes_by_weekday), fixed = coalesce(r_cap.fixed, '[]') where id = 1;
      perform log_event(p_source, p_token, 'changed', 'capacity', null, 'capacity pattern changed', in_j);
      cnt := cnt + 1;
    end if;
  end if;

  -- deletions
  for d_id in select (x)::uuid from jsonb_array_elements_text(coalesce(p->'deleted'->'tasks', '[]')) x loop
    select text into summary from tasks where id = d_id;
    if found then
      delete from tasks where id = d_id;
      perform log_event(p_source, p_token, 'removed', 'task', d_id, summary, null); cnt := cnt + 1;
    end if;
  end loop;
  for d_id in select (x)::uuid from jsonb_array_elements_text(coalesce(p->'deleted'->'targets', '[]')) x loop
    select title into summary from targets where id = d_id;
    if found then
      delete from targets where id = d_id;
      perform log_event(p_source, p_token, 'removed', 'target', d_id, summary, null); cnt := cnt + 1;
    end if;
  end loop;
  for d_id in select (x)::uuid from jsonb_array_elements_text(coalesce(p->'deleted'->'decisions', '[]')) x loop
    select code into summary from decisions where id = d_id;
    if found then
      delete from decisions where id = d_id;
      perform log_event(p_source, p_token, 'removed', 'decision', d_id, summary, null); cnt := cnt + 1;
    end if;
  end loop;
  for d_id in select (x)::uuid from jsonb_array_elements_text(coalesce(p->'deleted'->'ideas', '[]')) x loop
    select text into summary from ideas where id = d_id;
    if found then
      delete from ideas where id = d_id;
      perform log_event(p_source, p_token, 'removed', 'idea', d_id, summary, null); cnt := cnt + 1;
    end if;
  end loop;
  for d_id in select (x)::uuid from jsonb_array_elements_text(coalesce(p->'deleted'->'projects', '[]')) x loop
    select name into summary from projects where id = d_id;
    if found then
      delete from projects where id = d_id;
      perform log_event(p_source, p_token, 'removed', 'project', d_id, summary, null); cnt := cnt + 1;
    end if;
  end loop;
  for d_id in select (x)::uuid from jsonb_array_elements_text(coalesce(p->'deleted'->'areas', '[]')) x loop
    select name into summary from areas where id = d_id;
    if found then
      delete from areas where id = d_id;
      perform log_event(p_source, p_token, 'removed', 'area', d_id, summary, null); cnt := cnt + 1;
    end if;
  end loop;

  return jsonb_build_object('applied', cnt, 'version', coalesce((select max(id) from events), 0));
end $$;

-- ── Proposals ────────────────────────────────────────────────────────────────
create or replace function expire_proposals()
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  with x as (update proposals set status = 'expired', resolved_at = now()
             where status = 'pending' and expires_at < now() returning id)
  select count(*) into n from x;
  return n;
end $$;

revoke all on function create_api_token(text, token_kind, text, boolean) from public, anon, authenticated;
revoke all on function authenticate_token(text) from public, anon, authenticated;
revoke all on function log_event(text, uuid, text, text, uuid, text, jsonb) from public, anon, authenticated;
revoke all on function ledger_snapshot() from public, anon, authenticated;
revoke all on function apply_changes(jsonb, text, uuid) from public, anon, authenticated;
revoke all on function expire_proposals() from public, anon, authenticated;
