-- frictionless-pm · migration 3: the 30-minute replan (DESIGN-PM.md §9.2,
-- "scheduled passes run server-side").
--
-- pg_cron calls the `replan` edge function through pg_net. The function is
-- deployed with JWT verification off and authenticates its own bearer token,
-- so the job needs (a) settings.hub_url and (b) a trusted device token stored
-- in Vault under the name 'hub_cron_token'. hub/scripts/setup.sql creates both
-- after the project exists; until then the job runs and does nothing.

create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
create extension if not exists pg_net with schema extensions;

create or replace function trigger_replan(p_source text default 'cron')
returns bigint language plpgsql security definer set search_path = public, extensions, vault as $$
declare
  url text;
  tok text;
begin
  select hub_url into url from settings where id = 1;
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'hub_cron_token' limit 1;
  if url is null or tok is null then
    return null;
  end if;
  return net.http_post(
    url     := url || '/functions/v1/replan',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || tok),
    body    := jsonb_build_object('source', p_source),
    timeout_milliseconds := 20000
  );
end $$;
revoke all on function trigger_replan(text) from public, anon, authenticated;

select cron.schedule('frictionless-replan', '*/30 * * * *', $$ select public.trigger_replan('cron'); $$);
select cron.schedule('frictionless-expire-proposals', '5 * * * *', $$ select public.expire_proposals(); $$);
