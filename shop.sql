-- Éjjeli Járat – pogácsavásárlás (Stripe)
-- Supabase: SQL Editor -> New query -> illeszd be az egészet -> Run   (többször is lefuttatható)
-- Előfeltétel: a gifts.sql már le van futtatva (a megvett pogácsát ajándékként kapja meg a hős).

create table if not exists public.purchases (
  id             bigint generated always as identity primary key,
  session_id     text unique,                         -- a Stripe fizetési oldal azonosítója
  user_id        uuid,                                -- fióktörléskor kiürül, a vásárlás könyvelési nyoma megmarad
  char_id        text,
  char_name      text,
  pack           text not null,
  pog            int  not null check (pog between 1 and 10000),
  amount         int  not null,                       -- forintban, áfával
  currency       text not null default 'huf',
  status         text not null default 'open' check (status in ('open', 'paid', 'refunded', 'disputed', 'expired')),
  payment_intent text,
  gift_id        bigint,
  livemode       boolean,
  created_at     timestamptz not null default now(),
  paid_at        timestamptz
);
create index if not exists purchases_user_idx on public.purchases(user_id, created_at);
create index if not exists purchases_pi_idx on public.purchases(payment_intent);
alter table public.purchases enable row level security;
drop policy if exists "own purchases" on public.purchases;
create policy "own purchases" on public.purchases for select to authenticated using (user_id = auth.uid());
revoke all on public.purchases from anon, authenticated;
grant select on public.purchases to authenticated;       -- a játékos csak a saját vásárlásait látja, írni csak a szerver tud

-- fizetés sikerült: egyszer és csak egyszer adja oda a pogácsát (a Stripe többször is szólhat ugyanarról)
create or replace function public.purchase_fulfill(sid text, pi text, live boolean) returns json
language plpgsql security definer set search_path = public as $$
declare p public.purchases; g bigint;
begin
  update public.purchases set status = 'paid', paid_at = now(), payment_intent = coalesce(pi, payment_intent), livemode = live
   where session_id = sid and status in ('open', 'expired')
   returning * into p;
  if p.id is null then return json_build_object('ok', true, 'already', true); end if;
  if p.char_id is not null and exists (select 1 from public.characters where id = p.char_id) then
    insert into public.gifts (char_id, pog, gold, note) values (p.char_id, p.pog, 0, 'Vásárlás: ' || p.pog || ' pogácsa')
    returning id into g;
    update public.purchases set gift_id = g where id = p.id;
  end if;
  return json_build_object('ok', true, 'pog', p.pog, 'gift', g);
end $$;

-- visszatérítés vagy vitatott fizetés: ha még nem vette fel, a pogácsa nem jár
create or replace function public.purchase_reverse(pi text, st text) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from public.gifts g using public.purchases p
   where p.payment_intent = pi and g.id = p.gift_id and g.claimed_at is null;
  update public.purchases set status = st where payment_intent = pi and status = 'paid';
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.purchase_fulfill(text, text, boolean) from public, anon, authenticated;
revoke all on function public.purchase_reverse(text, text) from public, anon, authenticated;
grant execute on function public.purchase_fulfill(text, text, boolean) to service_role;
grant execute on function public.purchase_reverse(text, text) to service_role;

-- fióktörlés: a vásárlások könyvelési nyoma megmarad, de már nem köthető a játékoshoz
create or replace function public.delete_my_account() returns boolean
language plpgsql security definer set search_path = public, auth as $$
declare
  me uuid := auth.uid();
  t text;
  q text[] := array[
    'delete from public.events where user_id = $1',
    'delete from public.referrals where referee_user = $1 or referrer_user = $1',
    'delete from public.messages where from_user = $1 or to_user = $1',
    'delete from public.guild_invites where from_user = $1 or to_user = $1',
    'delete from public.guild_war_signups where user_id = $1',
    'delete from public.world_boss_hits where user_id = $1',
    'delete from public.guild_raid_hits where user_id = $1',
    'delete from public.guild_donations where from_user = $1 or leader_user = $1',
    'delete from public.characters where user_id = $1'];
begin
  if me is null then return false; end if;
  if to_regclass('public.purchases') is not null then
    execute 'update public.purchases set user_id = null, char_id = null, char_name = null where user_id = $1' using me;
  end if;
  foreach t in array q loop
    if to_regclass(split_part(split_part(t, 'from ', 2), ' ', 1)) is not null then execute t using me; end if;
  end loop;
  delete from auth.users where id = me;
  return true;
end $$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- ===== kimutatás (csak az SQL Editorból) =====
create schema if not exists stats;
create or replace view stats.bevetel as
select (paid_at at time zone 'Europe/Budapest')::date as nap,
       count(*)                                        as vasarlas,
       sum(amount)                                     as brutto_ft,
       sum(pog)                                        as eladott_pogacsa,
       count(distinct user_id)                         as vasarlo
  from public.purchases where status = 'paid' and livemode
 group by 1 order by 1 desc;
-- Használat:  select * from stats.bevetel;
--             select char_name, pack, amount, status, created_at from public.purchases order by created_at desc limit 50;
