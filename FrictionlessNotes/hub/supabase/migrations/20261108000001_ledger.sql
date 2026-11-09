-- frictionless-pm · hub schema, migration 1: the ledger.
--
-- Mirrors PlanCore/Ledger.swift exactly (areas, projects, targets, tasks,
-- decisions, ideas, capacity) plus what the hub adds on top (DESIGN-PM.md §9):
-- api_tokens (one per assistant / device / feed), cursors (what each assistant
-- has already seen), events (append-only log every write goes through, so a
-- cursor can replay), proposals (assistants propose, Joshua accepts), and the
-- stored assessment the server-side engine writes (plan_steps, target_status,
-- allocations) so the feed and the MCP `now` resource read the same numbers.
--
-- Single-user design: row-level security is ON for every table with no
-- policies, so only the service role (edge functions) can read or write.
-- Clients never talk to PostgREST directly; they hold an api_token and go
-- through the edge functions, which check the token and use the service key.

create extension if not exists pgcrypto with schema extensions;

-- ── Enumerations (PlanModels.swift) ──────────────────────────────────────────
create type deadline_kind  as enum ('hard', 'goal', 'none');
create type task_state     as enum ('todo', 'doing', 'waiting', 'done');
create type note_category  as enum ('todo', 'shopping', 'idea', 'note', 'journal', 'reference');
create type horizon        as enum ('week', 'month', 'quarter', 'year', 'someday');
create type project_status as enum ('active', 'waiting', 'paused', 'done');
create type target_state   as enum ('onTrack', 'atRisk', 'willMiss', 'slipping', 'done', 'backlog');
create type proposal_status as enum ('pending', 'accepted', 'rejected', 'expired');
create type token_kind     as enum ('assistant', 'device', 'feed');

-- ── Ledger tables ────────────────────────────────────────────────────────────
create table areas (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  colour_hex     integer not null default 6007039,          -- 0x5BA8FF
  intended_share double precision not null default 0.1,     -- 0…1 of weekly capacity
  sort_order     integer not null default 0,
  created_at     timestamptz(3) not null default now(),
  updated_at     timestamptz(3) not null default now()
);

create table projects (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  colour_hex integer not null default 6007039,
  goal       text,
  archived   boolean not null default false,
  created_at timestamptz(3) not null default now(),
  area_id    uuid references areas (id) on delete set null,
  horizon    horizon not null default 'month',
  status     project_status not null default 'active',
  narrative  text,
  people     text[] not null default '{}',
  updated_at timestamptz(3) not null default now()
);

create table targets (
  id                    uuid primary key default gen_random_uuid(),
  project_id            uuid references projects (id) on delete set null,
  title                 text not null,
  due                   date,                               -- start of day in settings.timezone
  kind                  deadline_kind not null default 'none',
  why_it_matters        text,
  consequence_if_missed text,
  done                  boolean not null default false,
  done_at               timestamptz(3),
  created_at            timestamptz(3) not null default now(),
  source_capture_id     uuid,
  version               integer not null default 1,        -- feeds the VEVENT SEQUENCE
  updated_at            timestamptz(3) not null default now()
);
create index targets_due_idx on targets (due) where not done;

create table tasks (
  id                uuid primary key default gen_random_uuid(),
  text              text not null,
  category          note_category not null default 'todo',
  group_label       text,                                   -- Swift `group`
  due_hint          text,                                   -- Swift `due` (spoken hint, display only)
  done              boolean not null default false,
  done_at           timestamptz(3),
  created_at        timestamptz(3) not null default now(),
  source_capture_id uuid,
  source_action_id  uuid,
  project_id        uuid references projects (id) on delete set null,
  target_id         uuid references targets (id) on delete set null,
  path_order        integer not null default 0,
  effort_minutes    integer,                                -- null = unestimated (engine assumes 30)
  lead_days         integer not null default 0,
  milestone         boolean not null default false,
  needs_you         boolean not null default false,
  waiting_on        text,
  due_date          date,
  due_kind          deadline_kind,
  state             task_state not null default 'todo',
  planned_by        text,
  actual_minutes    integer,
  version           integer not null default 1,
  updated_at        timestamptz(3) not null default now()
);
create index tasks_target_idx on tasks (target_id, path_order);
create index tasks_open_idx on tasks (done) where not done;

create table decisions (
  id             uuid primary key default gen_random_uuid(),
  code           text not null,                             -- "D3", "E-1A2B"
  project_id     uuid references projects (id) on delete set null,
  target_id      uuid references targets (id) on delete set null,
  question       text not null,
  why_now        text not null default '',
  background     text not null default '',
  touches        text not null default '',
  options        jsonb not null default '[]',               -- [{label, does}]
  if_unanswered  text not null default '',
  raised_by      text not null default 'user',              -- engine | planner | user
  asked_at       timestamptz(3) not null default now(),
  answered_at    timestamptz(3),
  answer         text,
  deferred_until timestamptz(3),
  updated_at     timestamptz(3) not null default now()
);
create index decisions_open_idx on decisions (asked_at desc) where answered_at is null;

create table ideas (
  id                uuid primary key default gen_random_uuid(),
  project_id        uuid references projects (id) on delete set null,
  text              text not null,
  created_at        timestamptz(3) not null default now(),
  source_capture_id uuid
);

-- One row. minutes_by_weekday is Monday-first, as in CapacityModel.
create table capacity (
  id                 smallint primary key default 1 check (id = 1),
  minutes_by_weekday integer[] not null default '{120,120,120,120,120,300,300}',
  fixed              jsonb not null default '[]',           -- [{day: 'YYYY-MM-DD', minutes, why}]
  updated_at         timestamptz(3) not null default now()
);
insert into capacity (id) values (1);

create table settings (
  id            smallint primary key default 1 check (id = 1),
  timezone      text not null default 'America/New_York',
  horizon_days  integer not null default 120,
  calendar_name text not null default 'Deadlines (FrictionlessNotes)',
  hub_url       text,                                       -- https://<ref>.supabase.co, set after creation
  updated_at    timestamptz(3) not null default now()
);
insert into settings (id) values (1);

-- ── Hub tables ───────────────────────────────────────────────────────────────
create table api_tokens (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  kind         token_kind not null,
  source       text not null,                               -- claude | chatgpt | gemini | mac | phone | feed | cron
  token_hash   text not null unique,                        -- sha256 hex of the bearer token
  trusted      boolean not null default false,              -- trusted tokens write directly; others propose
  created_at   timestamptz(3) not null default now(),
  last_used_at timestamptz(3),
  revoked_at   timestamptz(3)
);

create table events (
  id        bigserial primary key,
  at        timestamptz(3) not null default now(),
  source    text not null,
  token_id  uuid references api_tokens (id) on delete set null,
  kind      text not null,        -- added | changed | done | moved | removed | captured | proposed | accepted | rejected | answered | deferred | replanned
  entity    text not null,        -- area | project | target | task | decision | idea | capacity | proposal | plan
  entity_id uuid,
  summary   text not null,
  payload   jsonb
);

create table cursors (
  token_id      uuid primary key references api_tokens (id) on delete cascade,
  last_event_id bigint not null default 0,
  last_read_at  timestamptz(3)
);

create table proposals (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null,      -- add_target | add_steps | update_step | move_due | change_kind | change | …
  target_id   uuid references targets (id) on delete cascade,
  task_id     uuid references tasks (id) on delete cascade,
  change      jsonb not null,
  evidence    text,
  source      text not null,
  token_id    uuid references api_tokens (id) on delete set null,
  status      proposal_status not null default 'pending',
  created_at  timestamptz(3) not null default now(),
  expires_at  timestamptz(3) not null default now() + interval '7 days',
  resolved_at timestamptz(3),
  note        text
);
create index proposals_pending_idx on proposals (created_at) where status = 'pending';

-- ── Stored assessment (PlanAssessment, written by the replan function) ───────
create table assessments (
  id          bigserial primary key,
  computed_at timestamptz(3) not null default now(),
  today       date not null,
  source      text not null default 'engine',
  step_count  integer not null default 0,
  raised      integer not null default 0
);

create table plan_steps (
  task_id       uuid primary key references tasks (id) on delete cascade,
  target_id     uuid references targets (id) on delete cascade,
  idx           integer not null,
  wall          date,
  latest_start  date,
  planned_start date,
  planned_end   date,
  target_date   date,
  late          boolean not null default false,
  minutes_left  integer not null default 0,
  sequence      integer not null default 0,                 -- bumps when target_date moves (VEVENT SEQUENCE)
  computed_at   timestamptz(3) not null default now()
);

create table target_status (
  target_id         uuid primary key references targets (id) on delete cascade,
  state             target_state not null,
  slack_days        integer,
  late_task_ids     uuid[] not null default '{}',
  remaining_minutes integer not null default 0,
  computed_at       timestamptz(3) not null default now()
);

create table allocations (
  day      date not null,
  position integer not null,
  task_id  uuid not null references tasks (id) on delete cascade,
  minutes  integer not null,
  primary key (day, position)
);

-- ── Housekeeping triggers ────────────────────────────────────────────────────
create or replace function set_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create or replace function bump_version() returns trigger language plpgsql as $$
begin
  if to_jsonb(new) - 'updated_at' - 'version' is distinct from to_jsonb(old) - 'updated_at' - 'version' then
    new.version := old.version + 1;
  end if;
  new.updated_at := now();
  return new;
end $$;

create trigger areas_updated     before update on areas     for each row execute function set_updated_at();
create trigger projects_updated  before update on projects  for each row execute function set_updated_at();
create trigger decisions_updated before update on decisions for each row execute function set_updated_at();
create trigger capacity_updated  before update on capacity  for each row execute function set_updated_at();
create trigger settings_updated  before update on settings  for each row execute function set_updated_at();
create trigger targets_version   before update on targets   for each row execute function bump_version();
create trigger tasks_version     before update on tasks     for each row execute function bump_version();

-- ── Row-level security: on everywhere, no policies → service role only ───────
alter table areas         enable row level security;
alter table projects      enable row level security;
alter table targets       enable row level security;
alter table tasks         enable row level security;
alter table decisions     enable row level security;
alter table ideas         enable row level security;
alter table capacity      enable row level security;
alter table settings      enable row level security;
alter table api_tokens    enable row level security;
alter table events        enable row level security;
alter table cursors       enable row level security;
alter table proposals     enable row level security;
alter table assessments   enable row level security;
alter table plan_steps    enable row level security;
alter table target_status enable row level security;
alter table allocations   enable row level security;

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;
