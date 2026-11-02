-- Éjjeli Járat – online adatbázis
-- Supabase: SQL Editor -> New query -> illeszd be az egészet -> Run

-- Hősök: minden játékos karaktere, a teljes mentéssel együtt
create table if not exists public.characters (
  id          text primary key,
  user_id     uuid not null references auth.users(id) on delete cascade default auth.uid(),
  name        text not null check (char_length(name) between 1 and 24),
  cls         text not null,
  level       int  not null default 1,
  rating      int  not null default 1000,
  data        jsonb not null,
  updated_at  timestamptz not null default now()
);
create index if not exists characters_user_idx   on public.characters(user_id);
create index if not exists characters_rating_idx on public.characters(rating desc);

-- Arénanapló: ki kit támadott meg, és ki nyert
create table if not exists public.arena_log (
  id            bigint generated always as identity primary key,
  attacker_id   text not null references public.characters(id) on delete cascade,
  defender_id   text not null references public.characters(id) on delete cascade,
  attacker_name text not null,
  defender_name text not null,
  attacker_won  boolean not null,
  rating_change int not null,
  created_at    timestamptz not null default now()
);
create index if not exists arena_log_def_idx on public.arena_log(defender_id, created_at desc);

alter table public.characters enable row level security;
alter table public.arena_log  enable row level security;

-- Mindenki látja a többi hőst (kell az arénához), de csak a sajátját írhatja
drop policy if exists "chars read"   on public.characters;
drop policy if exists "chars insert" on public.characters;
drop policy if exists "chars update" on public.characters;
drop policy if exists "chars delete" on public.characters;
create policy "chars read"   on public.characters for select to authenticated using (true);
create policy "chars insert" on public.characters for insert to authenticated with check (user_id = auth.uid());
create policy "chars update" on public.characters for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "chars delete" on public.characters for delete to authenticated using (user_id = auth.uid());

-- Alap jogok (akkor is kellenek, ha az "Automatically expose new tables" ki van kapcsolva)
grant usage on schema public to authenticated;
grant select, delete on public.characters to authenticated;
grant select on public.arena_log to authenticated;

-- A rangpontot (rating) kliensből nem lehet átírni, csak az arena_result függvény változtatja
revoke insert, update on public.characters from authenticated;
grant  insert (id, user_id, name, cls, level, data, updated_at) on public.characters to authenticated;
grant  update (name, cls, level, data, updated_at) on public.characters to authenticated;

-- A naplót a résztvevők olvashatják, írni csak a függvény tud
drop policy if exists "log read" on public.arena_log;
create policy "log read" on public.arena_log for select to authenticated using (
  exists (select 1 from public.characters c where c.user_id = auth.uid() and (c.id = attacker_id or c.id = defender_id))
);

-- Arénaharc eredménye: rangpontok frissítése és naplózás egy lépésben
create or replace function public.arena_result(attacker text, defender text, won boolean)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.characters;
  d public.characters;
  delta int;
begin
  select * into a from public.characters where id = attacker;
  select * into d from public.characters where id = defender;
  if a.id is null or d.id is null then raise exception 'Ismeretlen hős'; end if;
  if a.user_id <> auth.uid() then raise exception 'Ez nem a te hősöd'; end if;
  if a.id = d.id then raise exception 'Magad ellen nem harcolhatsz'; end if;

  -- erősebb ellenfél legyőzése többet ér (egyszerű Elo-szerű számítás)
  delta := greatest(5, least(40, round(20 + (d.rating - a.rating) / 20.0)::int));
  if won then
    update public.characters set rating = rating + delta where id = a.id;
    update public.characters set rating = greatest(0, rating - delta / 2) where id = d.id;
  else
    delta := greatest(5, least(30, round(15 - (d.rating - a.rating) / 25.0)::int));
    update public.characters set rating = greatest(0, rating - delta) where id = a.id;
    update public.characters set rating = rating + delta / 2 where id = d.id;
  end if;

  insert into public.arena_log(attacker_id, defender_id, attacker_name, defender_name, attacker_won, rating_change)
  values (a.id, d.id, a.name, d.name, won, case when won then delta else -delta end);
  return case when won then delta else -delta end;
end;
$$;
revoke all on function public.arena_result(text, text, boolean) from public;
grant execute on function public.arena_result(text, text, boolean) to authenticated;

-- ===== Céhmeghívók valódi játékosoknak =====
-- (ha a fenti rész már lefutott korábban, elég csak ezt a blokkot futtatni)
create table if not exists public.guild_invites (
  id           bigint generated always as identity primary key,
  from_char    text not null references public.characters(id) on delete cascade,
  from_user    uuid not null default auth.uid(),
  to_char      text not null references public.characters(id) on delete cascade,
  to_user      uuid not null,
  guild_name   text not null,
  guild_emblem text,
  leader_name  text,
  to_name      text,
  status       text not null default 'pending' check (status in ('pending','accepted','joined','declined','left')),
  created_at   timestamptz not null default now(),
  unique (from_char, to_char)
);
alter table public.guild_invites enable row level security;
drop policy if exists "gi read"   on public.guild_invites;
drop policy if exists "gi insert" on public.guild_invites;
drop policy if exists "gi update" on public.guild_invites;
drop policy if exists "gi delete" on public.guild_invites;
create policy "gi read"   on public.guild_invites for select to authenticated using (from_user = auth.uid() or to_user = auth.uid());
create policy "gi insert" on public.guild_invites for insert to authenticated with check (
  from_user = auth.uid() and exists (select 1 from public.characters c where c.id = from_char and c.user_id = auth.uid()));
create policy "gi update" on public.guild_invites for update to authenticated using (from_user = auth.uid() or to_user = auth.uid());
create policy "gi delete" on public.guild_invites for delete to authenticated using (from_user = auth.uid() or to_user = auth.uid());
grant select, insert, update, delete on public.guild_invites to authenticated;

-- ===== Céhtagok befizetései a vezető kasszájába =====
create table if not exists public.guild_donations (
  id           bigint generated always as identity primary key,
  from_char    text not null references public.characters(id) on delete cascade,
  from_user    uuid not null default auth.uid(),
  from_name    text,
  leader_char  text not null references public.characters(id) on delete cascade,
  leader_user  uuid not null,
  amount       int  not null check (amount > 0 and amount <= 100000),
  created_at   timestamptz not null default now()
);
alter table public.guild_donations enable row level security;
drop policy if exists "gd read"   on public.guild_donations;
drop policy if exists "gd insert" on public.guild_donations;
drop policy if exists "gd delete" on public.guild_donations;
create policy "gd read"   on public.guild_donations for select to authenticated using (from_user = auth.uid() or leader_user = auth.uid());
create policy "gd insert" on public.guild_donations for insert to authenticated with check (
  from_user = auth.uid() and exists (select 1 from public.characters c where c.id = from_char and c.user_id = auth.uid()));
create policy "gd delete" on public.guild_donations for delete to authenticated using (leader_user = auth.uid());
grant select, insert, delete on public.guild_donations to authenticated;

-- ===== Városi főgonosz: minden csapás egy sor, a heti összeg a közös életerőből fogy =====
create table if not exists public.world_boss_hits (
  id         bigint generated always as identity primary key,
  week       text not null,
  char_id    text not null references public.characters(id) on delete cascade,
  user_id    uuid not null default auth.uid(),
  name       text,
  cls        text,
  level      int,
  dmg        int not null check (dmg >= 0 and dmg <= 1000000),
  created_at timestamptz not null default now()
);
create index if not exists world_boss_week_idx on public.world_boss_hits(week);
alter table public.world_boss_hits enable row level security;
drop policy if exists "wb read"   on public.world_boss_hits;
drop policy if exists "wb insert" on public.world_boss_hits;
create policy "wb read"   on public.world_boss_hits for select to authenticated using (true);
create policy "wb insert" on public.world_boss_hits for insert to authenticated with check (
  user_id = auth.uid() and exists (select 1 from public.characters c where c.id = char_id and c.user_id = auth.uid()));
grant select, insert on public.world_boss_hits to authenticated;

-- ===== Üzenetek: privát üzenet, barátjelölés, céhes chat =====
create table if not exists public.messages (
  id         bigint generated always as identity primary key,
  kind       text not null check (kind in ('dm','friend','guild')),
  channel    text,
  from_char  text not null references public.characters(id) on delete cascade,
  from_user  uuid not null default auth.uid(),
  from_name  text,
  from_cls   text,
  to_char    text references public.characters(id) on delete cascade,
  to_user    uuid,
  to_name    text,
  body       text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);
create index if not exists messages_to_idx      on public.messages(to_user, created_at desc);
create index if not exists messages_channel_idx on public.messages(channel, created_at desc);
alter table public.messages enable row level security;
drop policy if exists "msg read"   on public.messages;
drop policy if exists "msg insert" on public.messages;
drop policy if exists "msg delete" on public.messages;
create policy "msg read"   on public.messages for select to authenticated using (kind = 'guild' or from_user = auth.uid() or to_user = auth.uid());
create policy "msg insert" on public.messages for insert to authenticated with check (
  from_user = auth.uid() and exists (select 1 from public.characters c where c.id = from_char and c.user_id = auth.uid()));
create policy "msg delete" on public.messages for delete to authenticated using (from_user = auth.uid() or to_user = auth.uid());
grant select, insert, delete on public.messages to authenticated;

-- ===== Céhes rajtaütés: a céh tagjainak csapásai a céhes főgonoszra =====
create table if not exists public.guild_raid_hits (
  id         bigint generated always as identity primary key,
  channel    text not null,
  char_id    text not null references public.characters(id) on delete cascade,
  user_id    uuid not null default auth.uid(),
  name       text,
  cls        text,
  dmg        int not null check (dmg >= 0 and dmg <= 1000000),
  created_at timestamptz not null default now()
);
create index if not exists guild_raid_channel_idx on public.guild_raid_hits(channel);
alter table public.guild_raid_hits enable row level security;
drop policy if exists "gr read"   on public.guild_raid_hits;
drop policy if exists "gr insert" on public.guild_raid_hits;
create policy "gr read"   on public.guild_raid_hits for select to authenticated using (true);
create policy "gr insert" on public.guild_raid_hits for insert to authenticated with check (
  user_id = auth.uid() and exists (select 1 from public.characters c where c.id = char_id and c.user_id = auth.uid()));
grant select, insert on public.guild_raid_hits to authenticated;

-- ===== Pogácsa befizetése a céh kasszájába =====
alter table public.guild_donations add column if not exists currency text not null default 'ft';
alter table public.guild_donations drop constraint if exists guild_donations_currency_check;
alter table public.guild_donations add constraint guild_donations_currency_check check (currency in ('ft','pog'));
