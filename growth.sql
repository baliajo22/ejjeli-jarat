-- Éjjeli Járat – egyedi nevek, meghívó jutalom, statisztika
-- Supabase: SQL Editor -> New query -> illeszd be az egészet -> Run
-- Többször is lefuttatható.

-- =====================================================================
-- 1) EGYEDI HŐSNEVEK: két hősnek nem lehet ugyanaz a neve (kis- és nagybetű mindegy)
-- =====================================================================
-- Ha már van két azonos nevű hős, a gyengébbik (alacsonyabb szintű) kap egy számot a neve végére,
-- pl. "Bence" -> "Bence 2". A játék a következő mentésnél magától átveszi az új nevet.
do $$
declare r record; n int; nm text;
begin
  for r in
    select id, name, rn from (
      select id, name, row_number() over (partition by lower(btrim(name)) order by level desc, updated_at, id) rn
      from public.characters) x
    where rn > 1
  loop
    n := r.rn;
    nm := left(btrim(r.name), 21) || ' ' || n;
    while exists (select 1 from public.characters where lower(btrim(name)) = lower(nm)) loop
      n := n + 1; nm := left(btrim(r.name), 21) || ' ' || n;
    end loop;
    update public.characters
       set name = nm,
           data = jsonb_set(jsonb_set(data, '{name}', to_jsonb(nm)), '{rev}', to_jsonb(coalesce(public.ej_num(data->'rev'), 0)::int + 1))
     where id = r.id;
    raise notice 'Átnevezve: % -> %', r.name, nm;
  end loop;
end $$;
create unique index if not exists characters_name_lower_key on public.characters (lower(btrim(name)));

-- =====================================================================
-- 2) MEGHÍVÓ JUTALOM: ha a meghívott barát eléri a 10. szintet, mindketten kapnak pogácsát
-- =====================================================================
create table if not exists public.referrals (
  id               bigint generated always as identity primary key,
  referrer_char    text not null references public.characters(id) on delete cascade,
  referrer_user    uuid not null,
  referee_char     text not null references public.characters(id) on delete cascade,
  referee_user     uuid not null unique,              -- egy fiókot csak egyszer lehet meghívni
  referee_name     text,
  status           text not null default 'pending' check (status in ('pending', 'qualified')),
  referrer_claimed boolean not null default false,
  referee_claimed  boolean not null default false,
  created_at       timestamptz not null default now(),
  qualified_at     timestamptz
);
create index if not exists referrals_referrer_idx on public.referrals(referrer_char);
alter table public.referrals enable row level security;
drop policy if exists "ref read" on public.referrals;
create policy "ref read" on public.referrals for select to authenticated using (referrer_user = auth.uid() or referee_user = auth.uid());
revoke all on public.referrals from anon, authenticated;
grant select on public.referrals to authenticated;   -- írni csak az alábbi függvények tudnak

-- új hős létrehozásakor: ki hívta meg
create or replace function public.referral_register(ref text, cid text) returns boolean
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); c public.characters; r public.characters; n int;
begin
  if me is null then return false; end if;
  select * into c from public.characters where id = cid and user_id = me;
  if c.id is null then return false; end if;
  select * into r from public.characters where id = ref;
  if r.id is null or r.user_id = me then return false; end if;     -- saját magát nem hívhatja meg
  if c.level > 4 then return false; end if;                       -- csak friss hőssel
  insert into public.referrals(referrer_char, referrer_user, referee_char, referee_user, referee_name)
  values (r.id, r.user_id, c.id, me, c.name)
  on conflict (referee_user) do nothing;
  get diagnostics n = row_count;
  return n > 0;
end $$;

-- a meghívott hős elérte a 10. szintet?
create or replace function public.referral_check() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.referrals f set status = 'qualified', qualified_at = now()
    from public.characters c
   where f.referee_user = auth.uid() and f.status = 'pending'
     and c.id = f.referee_char and c.level >= 10 and not c.suspect;
  get diagnostics n = row_count;
  return n;
end $$;

-- jutalom felvétele: hány jutalom jár most ennek a hősnek (mindegyik egyszer vehető fel)
create or replace function public.referral_claim(cid text) returns int
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); c public.characters; left_ int; a int := 0; b int := 0;
begin
  select * into c from public.characters where id = cid and user_id = me;
  if c.id is null or c.suspect then return 0; end if;
  -- meghívóként legfeljebb 20 jutalom hősönként
  select 20 - count(*) into left_ from public.referrals where referrer_char = cid and referrer_claimed;
  if left_ > 0 then
    update public.referrals set referrer_claimed = true
     where id in (select id from public.referrals
                   where referrer_char = cid and referrer_user = me and status = 'qualified' and not referrer_claimed
                   order by qualified_at limit left_);
    get diagnostics a = row_count;
  end if;
  update public.referrals set referee_claimed = true
   where referee_char = cid and referee_user = me and status = 'qualified' and not referee_claimed;
  get diagnostics b = row_count;
  return a + b;
end $$;
revoke all on function public.referral_register(text, text) from public, anon;
revoke all on function public.referral_check() from public, anon;
revoke all on function public.referral_claim(text) from public, anon;
grant execute on function public.referral_register(text, text) to authenticated;
grant execute on function public.referral_check() to authenticated;
grant execute on function public.referral_claim(text) to authenticated;

-- =====================================================================
-- 3) STATISZTIKA: a játék eseményeket küld (belépés, küldetés, szintlépés, harc...)
-- =====================================================================
create table if not exists public.events (
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid(),
  char_id    text,
  kind       text not null check (char_length(kind) between 1 and 40),
  v          jsonb check (v is null or pg_column_size(v) < 2000),
  created_at timestamptz not null default now()
);
create index if not exists events_time_idx on public.events(created_at);
create index if not exists events_user_idx on public.events(user_id, created_at);
create index if not exists events_kind_idx on public.events(kind, created_at);
alter table public.events enable row level security;
drop policy if exists "ev insert" on public.events;
create policy "ev insert" on public.events for insert to authenticated with check (user_id = auth.uid());
revoke all on public.events from anon, authenticated;
grant insert on public.events to authenticated;      -- a játékosok csak írni tudnak, olvasni nem

-- elárasztás ellen: óránként legfeljebb 600 esemény egy fiókból
create or replace function public.ej_event_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.events where user_id = new.user_id and created_at > now() - interval '1 hour') >= 600 then
    return null;   -- csendben eldobjuk
  end if;
  new.created_at := now();
  return new;
end $$;
drop trigger if exists ej_event_limit on public.events;
create trigger ej_event_limit before insert on public.events for each row execute function public.ej_event_limit();

-- ===== a kimutatások egy külön "stats" sémában: a játékból nem érhetők el, csak innen, az SQL Editorból =====
create schema if not exists stats;
revoke all on schema stats from public, anon, authenticated;

-- napi forgalom
create or replace view stats.napi as
select (created_at at time zone 'Europe/Budapest')::date                         as nap,
       count(distinct user_id)                                                 as aktiv_jatekos,
       count(*) filter (where kind = 'signup')                                 as regisztracio,
       count(*) filter (where kind = 'char_new')                               as uj_hos,
       count(*) filter (where kind = 'ping') * 5                               as jatekperc_osszesen,
       round(count(*) filter (where kind = 'ping') * 5.0 / nullif(count(distinct user_id), 0), 1) as perc_per_jatekos
  from public.events
 where created_at > now() - interval '90 days'
 group by 1 order by 1 desc;

-- megtartás: az adott napon kezdők közül hányan jöttek vissza
create or replace view stats.megtartas as
with d as (select user_id, (created_at at time zone 'Europe/Budapest')::date nap from public.events group by 1, 2),
     f as (select user_id, min(nap) elso from d group by 1)
select f.elso                                                                                    as kezdes_napja,
       count(*)                                                                                  as uj_jatekos,
       round(100.0 * count(*) filter (where exists (select 1 from d where d.user_id = f.user_id and d.nap = f.elso + 1)) / count(*), 1)              as masnap_vissza_szazalek,
       round(100.0 * count(*) filter (where exists (select 1 from d where d.user_id = f.user_id and d.nap between f.elso + 6 and f.elso + 8)) / count(*), 1)  as het_mulva_szazalek,
       round(100.0 * count(*) filter (where exists (select 1 from d where d.user_id = f.user_id and d.nap between f.elso + 27 and f.elso + 33)) / count(*), 1) as honap_mulva_szazalek
  from f group by 1 order by 1 desc;

-- tölcsér: a játékosok hányad része jutott el egy-egy pontig (hol morzsolódnak le)
create or replace view stats.tolcser as
with u as (select distinct user_id from public.events),
     c as (select user_id, max(level) lvl, bool_or(data->'guild' is not null and jsonb_typeof(data->'guild') = 'object' or data->'memberOf' is not null and jsonb_typeof(data->'memberOf') = 'object') ceh
             from public.characters group by 1)
select count(*)                                                                                             as jatekos,
       count(*) filter (where exists (select 1 from public.events e where e.user_id = u.user_id and e.kind = 'quest'))    as volt_kuldetesen,
       count(*) filter (where c.lvl >= 5)                                                                   as elerte_5_szintet,
       count(*) filter (where c.lvl >= 10)                                                                  as elerte_10_szintet,
       count(*) filter (where exists (select 1 from public.events e where e.user_id = u.user_id and e.kind = 'dungeon'))  as volt_kazamataban,
       count(*) filter (where exists (select 1 from public.events e where e.user_id = u.user_id and e.kind = 'arena'))    as harcolt_arenaban,
       count(*) filter (where c.ceh)                                                                        as cehben_van,
       count(*) filter (where c.lvl >= 30)                                                                  as elerte_30_szintet,
       count(*) filter (where exists (select 1 from public.referrals r where r.referrer_user = u.user_id))  as hivott_meg_barátot
  from u left join c using (user_id);

-- mit csinálnak a játékosok (utolsó 7 nap)
create or replace view stats.esemenyek as
select kind as esemeny, count(*) as darab, count(distinct user_id) as jatekos
  from public.events where created_at > now() - interval '7 days'
 group by 1 order by 2 desc;

-- hősök szint szerint
create or replace view stats.szintek as
select (level / 10) * 10 || '–' || ((level / 10) * 10 + 9) as szint, count(*) as hos
  from public.characters group by level / 10 order by level / 10;

-- meghívások
drop view if exists stats.meghivok;
create view stats.meghivok as
select c.name as meghivo, count(*) as meghivott, count(*) filter (where r.status = 'qualified') as elerte_10_szintet
  from public.referrals r join public.characters c on c.id = r.referrer_char
 group by 1 order by 2 desc;

-- Használat (SQL Editorban):
--   select * from stats.napi;          napi aktív játékosok, regisztrációk, játékidő
--   select * from stats.megtartas;     hányan jönnek vissza másnap / egy hét / egy hónap múlva
--   select * from stats.tolcser;       hol morzsolódnak le a játékosok
--   select * from stats.esemenyek;     mit csinálnak a játékban
--   select * from stats.szintek;       hősök szintek szerint
--   select * from stats.meghivok;      ki hány barátot hozott
-- Régi események törlése (ha nagyon megnőne az adatbázis):
--   delete from public.events where created_at < now() - interval '120 days';
