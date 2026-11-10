-- Éjjeli Járat – ÚJ SZERVER (2026. november 11.)
-- A hősök megmaradnak (név, kaszt, kinézet), de mindenki visszakerül az 1. szintre: felszerelés, forint, pogácsa,
-- céhek, üzenetek, aréna- és főgonosz-eredmények az elejéről indulnak. A fiókok (e-mail, jelszó) maradnak.
-- Aki valódi pénzért vett pogácsát, az visszakapja.
-- Supabase: SQL Editor -> New query -> illeszd be az egészet -> Run.   NEM LEHET VISSZACSINÁLNI.
-- Ha véletlenül másodszor is lefuttatod, nem csinál semmit (kiírja, hogy már lefutott).

-- ===== 1) amit a reset után is használunk =====
create table if not exists public.server_meta (key text primary key, value jsonb, updated_at timestamptz not null default now());
alter table public.server_meta enable row level security;
revoke all on public.server_meta from anon, authenticated;

-- a régi hősök azonosítói: egy még nyitva hagyott régi játék ne tudja visszatölteni őket
create table if not exists public.retired_chars (id text primary key, retired_at timestamptz not null default now());
alter table public.retired_chars enable row level security;
revoke all on public.retired_chars from anon, authenticated;

-- fiókhoz kötött jóváírás (pl. a megvett pogácsa), amit az első új hős kap meg
create table if not exists public.account_grants (
  id           bigint generated always as identity primary key,
  user_id      uuid not null,
  pog          int  not null default 0 check (pog between 0 and 100000),
  note         text,
  created_at   timestamptz not null default now(),
  claimed_at   timestamptz,
  claimed_char text
);
create index if not exists account_grants_user_idx on public.account_grants(user_id) where claimed_at is null;
alter table public.account_grants enable row level security;
revoke all on public.account_grants from anon, authenticated;

create or replace function public.ej_block_retired() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.retired_chars where id = new.id) then
    raise exception 'EJ_RETIRED: ez a hős a régi szerveren maradt';
  end if;
  return new;
end $$;
drop trigger if exists ej_block_retired on public.characters;
create trigger ej_block_retired before insert on public.characters for each row execute function public.ej_block_retired();


-- az új szerveres hőst egy régi, még nyitva hagyott játék nem írhatja felül a régi állapotával
create or replace function public.ej_season_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce((old.data->>'season')::int, 0) >= 2 and coalesce((new.data->>'season')::int, 0) < 2 then
    raise exception 'EJ_RETIRED: ez a mentés még a régi szerverről való';
  end if;
  return new;
end $$;
drop trigger if exists ej_season_guard on public.characters;
create trigger ej_season_guard before update on public.characters for each row execute function public.ej_season_guard();

-- az ajándékfelvétel előbb a fiókhoz kötött jóváírásokat is a hőshöz rakja
create or replace function public.gift_claim(cid text) returns json
language plpgsql security definer set search_path = public as $$
declare r json;
begin
  if not exists (select 1 from public.characters where id = cid and user_id = auth.uid()) then return null; end if;
  with g as (update public.account_grants set claimed_at = now(), claimed_char = cid
              where user_id = auth.uid() and claimed_at is null returning pog, note)
  insert into public.gifts (char_id, pog, gold, note) select cid, pog, 0, note from g where pog > 0;
  with u as (update public.gifts set claimed_at = now() where char_id = cid and claimed_at is null returning pog, gold, note)
  select json_build_object('pog', coalesce(sum(pog), 0), 'gold', coalesce(sum(gold), 0), 'note', string_agg(note, ' · ')) into r from u;
  return r;
end $$;
revoke all on function public.gift_claim(text) from public, anon;
grant execute on function public.gift_claim(text) to authenticated;


-- ALAPÍTÓK: aki az új szerver első 3 napjában (nov. 11–13.) készít hőst, Alapító jelvényt és 10 pogácsát kap (fiókonként egyszer)
create table if not exists public.founders (user_id uuid primary key, char_id text not null, created_at timestamptz not null default now());
alter table public.founders enable row level security;
revoke all on public.founders from anon, authenticated;
create or replace function public.founder_claim(cid text) returns boolean
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not exists (select 1 from public.characters where id = cid and user_id = auth.uid()) then return false; end if;
  if exists (select 1 from public.founders where char_id = cid) then return true; end if;
  if not exists (select 1 from public.server_meta where key = 'season' and (value->>'n')::int >= 2) then return false; end if;   -- csak az új szerveren
  if now() < timestamptz '2026-11-11 00:00 Europe/Budapest' or now() >= timestamptz '2026-11-14 00:00 Europe/Budapest' then return false; end if;
  insert into public.founders (user_id, char_id) values (auth.uid(), cid) on conflict (user_id) do nothing;
  get diagnostics n = row_count;
  if n > 0 then insert into public.gifts (char_id, pog, gold, note) values (cid, 10, 0, 'Alapító jutalom'); end if;
  return n > 0;
end $$;
revoke all on function public.founder_claim(text) from public, anon;
grant execute on function public.founder_claim(text) to authenticated;

-- ===== 2) maga a reset (csak egyszer fut le) =====
do $$
declare t text; n_chars int; n_grants int;
begin
  if exists (select 1 from public.server_meta where key = 'season' and (value->>'n')::int >= 2) then
    raise notice 'Az új szerver már elindult korábban, nem töröltem semmit.';
    return;
  end if;
  select count(*) into n_chars from public.characters;

  -- a valódi pénzért vett pogácsa visszajár (fiókonként összeadva)
  if to_regclass('public.purchases') is not null then
    insert into public.account_grants (user_id, pog, note)
    select user_id, sum(pog), 'Új szerver: visszakaptad a megvásárolt ' || sum(pog) || ' pogácsádat'
      from public.purchases
     where status = 'paid' and coalesce(livemode, true) and user_id is not null
     group by user_id;
    get diagnostics n_grants = row_count;
  end if;

  foreach t in array array['arena_log','gifts','guild_donations','guild_invites','guild_raid_hits','guild_war_signups',
                           'guild_wars','messages','referrals','world_boss_hits'] loop
    if to_regclass('public.' || t) is not null then execute format('delete from public.%I', t); end if;
  end loop;

  -- minden hős az 1. szintre: név, kaszt, nem, kinézet marad; a többi egy friss kezdő hős
  -- (a játék az első belépéskor ebből teljes, új hőst épít: küldetések, bolt, ranglétra)
  alter table public.characters disable trigger user;
  update public.characters c set
    level = 1, rating = 1000, suspect = false, flags = '[]'::jsonb, updated_at = now(), checked_at = now(),
    data = jsonb_build_object(
      'cid', c.id, 'name', c.name, 'cls', c.cls, 'sex', coalesce(c.data->'sex', '"m"'::jsonb), 'look', c.data->'look',
      'level', 1, 'xp', 0, 'gold', 40, 'energy', 100, 'lastTick', (extract(epoch from now()) * 1000)::bigint, 'pog', 25,
      'stats', jsonb_build_object('str', case when c.cls = 'kidobo' then 10 else 5 end, 'dex', case when c.cls in ('futar','zsebmetszo') then 10 else 5 end,
                                  'int', case when c.cls = 'magus' then 10 else 5 end, 'con', 8, 'lck', 5),
      'bought', jsonb_build_object('str',0,'dex',0,'int',0,'con',0,'lck',0),
      'equip', jsonb_build_object('fegyver', jsonb_build_object('id', 'w' || c.id, 'slot', 'fegyver', 'rar', 0, 'lvl', 1,
                 'base', w.n, 'name', w.n, 'min', 3, 'max', 6, 'armor', 0, 'bonus', '{}'::jsonb, 'price', 10),
                 'fej', null, 'nyaklanc', null, 'test', null, 'gyuru', null, 'kesztyu', null, 'ov', null, 'cipo', null, 'kabala', null),
      'inv', '[]'::jsonb, 'fame', 0, 'wins', 0, 'losses', 0, 'guild', null, 'memberOf', null,
      'season', 2, 'reset2', true, 'rev', coalesce((c.data->>'rev')::int, 0) + 1, 'savedAt', (extract(epoch from now()) * 1000)::bigint)
  from (values ('kidobo','Sörösrekesz'),('magus','Lejárt bérlet'),('futar','Csúzli'),('zsebmetszo','Bicskapár')) w(cls, n)
  where w.cls = c.cls;
  alter table public.characters enable trigger user;

  insert into public.server_meta (key, value) values ('season', jsonb_build_object('n', 2, 'started', now()))
  on conflict (key) do update set value = excluded.value, updated_at = now();
  raise notice 'Kész: % hős visszakerült az 1. szintre, % fiók kap vissza megvásárolt pogácsát.', n_chars, coalesce(n_grants, 0);
end $$;

-- Ellenőrzés:  select name, level from characters;           (mindenki 1. szintű)
--              select * from account_grants;                 (kik kapnak vissza pogácsát)
