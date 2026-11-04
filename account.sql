-- Éjjeli Járat – fióktörlés, saját adatok letöltése, statisztika megőrzési ideje
-- Supabase: SQL Editor -> New query -> illeszd be az egészet -> Run   (többször is lefuttatható)

-- ===== 1) Fióktörlés: a játékos a játékból törölheti a fiókját és minden adatát =====
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
  foreach t in array q loop
    if to_regclass(split_part(split_part(t, 'from ', 2), ' ', 1)) is not null then execute t using me; end if;
  end loop;
  delete from auth.users where id = me;      -- a bejelentkezés (e-mail, jelszó) is törlődik
  return true;
end $$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- ===== 2) Saját adatok letöltése: a játékstatisztikát a játékos maga nem olvashatja, ezért ez adja ki =====
create or replace function public.my_events() returns json
language plpgsql security definer set search_path = public as $$
declare r json;
begin
  if auth.uid() is null or to_regclass('public.events') is null then return '[]'::json; end if;
  execute 'select coalesce(json_agg(json_build_object(''kind'', kind, ''v'', v, ''char_id'', char_id, ''at'', created_at) order by created_at), ''[]''::json)
             from (select * from public.events where user_id = $1 order by created_at desc limit 5000) e' into r using auth.uid();
  return r;
end $$;
revoke all on function public.my_events() from public, anon;
grant execute on function public.my_events() to authenticated;

-- ===== 3) A játékstatisztika legfeljebb 120 napig marad meg (ahogy az adatkezelési tájékoztató írja) =====
create or replace function public.ej_event_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.events where user_id = new.user_id and created_at > now() - interval '1 hour') >= 600 then
    return null;   -- elárasztás ellen: óránként legfeljebb 600 esemény egy fiókból
  end if;
  if random() < 0.002 then
    delete from public.events where created_at < now() - interval '120 days';   -- időnként kitakarítja a régieket
  end if;
  new.created_at := now();
  return new;
end $$;
