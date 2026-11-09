-- Éjjeli Járat – ÚJ SZERVER (2026. november 11.)
-- Minden hős, céh, üzenet, aréna- és főgonosz-eredmény törlődik. A fiókok (e-mail, jelszó) megmaradnak,
-- mindenki új hőst készít az 1. szintről. Aki valódi pénzért vett pogácsát, az új hőse visszakapja.
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
    update public.purchases set char_id = null where char_id is not null;   -- a régi hős már nem létezik
  end if;

  insert into public.retired_chars (id) select id from public.characters on conflict do nothing;

  foreach t in array array['arena_log','gifts','guild_donations','guild_invites','guild_raid_hits','guild_war_signups',
                           'guild_wars','messages','referrals','world_boss_hits'] loop
    if to_regclass('public.' || t) is not null then execute format('delete from public.%I', t); end if;
  end loop;
  delete from public.characters;

  insert into public.server_meta (key, value) values ('season', jsonb_build_object('n', 2, 'started', now()))
  on conflict (key) do update set value = excluded.value, updated_at = now();
  raise notice 'Kész: % hős törölve, % fiók kap vissza megvásárolt pogácsát.', n_chars, coalesce(n_grants, 0);
end $$;

-- Ellenőrzés:  select count(*) from characters;              (0 kell legyen)
--              select * from account_grants;                 (kik kapnak vissza pogácsát)
