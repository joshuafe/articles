-- frictionless-pm · first-run setup, run once after the migrations are applied
-- and the edge functions are deployed. Replace <ref> with the project ref.
--
-- 1. Where the functions live (pg_cron reads this to call `replan`).
update settings set hub_url = 'https://zxslnlhnfsaglobsfodn.supabase.co' where id = 1;

-- 2. The cron token: a trusted device token the scheduled job presents to `replan`.
--    Stored in Vault; never shown again.
do $$
declare tok text;
begin
  if not exists (select 1 from vault.secrets where name = 'hub_cron_token') then
    tok := create_api_token('pg_cron replan', 'device', 'cron', true);
    perform vault.create_secret(tok, 'hub_cron_token', 'bearer token pg_cron uses to call the replan edge function');
  end if;
end $$;

-- 3. The tokens Joshua holds. Each line returns the bearer token ONCE; copy it
--    into hub.json (mac), the connector URL (assistants) or the calendar app (feed).
select 'mac'     as who, create_api_token('FrictionlessMac', 'device', 'mac', true)        as token
union all
select 'feed',            create_api_token('Calendar feed', 'feed', 'feed', false)
union all
select 'claude',          create_api_token('Claude', 'assistant', 'claude', false)
union all
select 'chatgpt',         create_api_token('ChatGPT', 'assistant', 'chatgpt', false)
union all
select 'gemini',          create_api_token('Gemini', 'assistant', 'gemini', false);

-- To revoke one later:   update api_tokens set revoked_at = now() where name = 'ChatGPT';
-- To trust an assistant: update api_tokens set trusted = true where name = 'Claude';
