-- Éjjeli Járat – ajándék a játékosoknak (pogácsa, forint)
-- Supabase: SQL Editor -> New query -> illeszd be az egészet -> Run   (egyszer kell, utána lent a "HOGYAN ADJ AJÁNDÉKOT")
-- Az ajándékot a játék a következő belépéskor (vagy 2 percen belül) adja oda, egy értesítéssel.

create table if not exists public.gifts (
  id         bigint generated always as identity primary key,
  char_id    text not null references public.characters(id) on delete cascade,
  pog        int  not null default 0 check (pog between 0 and 10000),
  gold       int  not null default 0 check (gold between 0 and 100000000),
  note       text,
  created_at timestamptz not null default now(),
  claimed_at timestamptz
);
create index if not exists gifts_char_idx on public.gifts(char_id) where claimed_at is null;
alter table public.gifts enable row level security;
revoke all on public.gifts from anon, authenticated;       -- a játékosok nem látják és nem írhatják, csak felvehetik

-- a játék ezzel veszi fel a hőshöz tartozó ajándékokat (mindegyiket csak egyszer)
create or replace function public.gift_claim(cid text) returns json
language plpgsql security definer set search_path = public as $$
declare r json;
begin
  if not exists (select 1 from public.characters where id = cid and user_id = auth.uid()) then return null; end if;
  with u as (update public.gifts set claimed_at = now() where char_id = cid and claimed_at is null returning pog, gold, note)
  select json_build_object('pog', coalesce(sum(pog), 0), 'gold', coalesce(sum(gold), 0), 'note', string_agg(note, ' · ')) into r from u;
  return r;
end $$;
revoke all on function public.gift_claim(text) from public, anon;
grant execute on function public.gift_claim(text) to authenticated;

-- a mentés-ellenőrzés tudjon az ajándékról (különben a +pogácsát gyanúsnak jelölné)
create or replace function public.ej_check_character() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  probs text[]; dt numeric; lv int; od jsonb; gp numeric := 0; gg numeric := 0;
begin
  lv := coalesce(public.ej_num(new.data->'level'), new.level)::int;
  new.level := lv;                                    -- a ranglista mindig a mentés szerinti szintet mutatja
  if tg_op = 'INSERT' then
    new.suspect := false; new.flags := '[]'::jsonb;  -- a játék nem állíthatja be saját magának
    probs := public.ej_char_problems(new.data, lv, null, null, 0);
  else
    new.suspect := old.suspect; new.flags := old.flags;
    dt := greatest(1, extract(epoch from (now() - old.checked_at)));
    od := old.data;
    -- a játék gazdájától kapott ajándék (gifts tábla) nem számít gyanúsnak
    if to_regclass('public.gifts') is not null then
      execute 'select coalesce(sum(pog),0), coalesce(sum(gold),0) from public.gifts where char_id = $1 and claimed_at >= $2 - interval ''10 minutes'''
        into gp, gg using new.id, old.checked_at;
      if gp > 0 or gg > 0 then
        od := jsonb_set(jsonb_set(od, '{pog}', to_jsonb(coalesce(public.ej_num(od->'pog'), 0) + gp)), '{gold}', to_jsonb(coalesce(public.ej_num(od->'gold'), 0) + gg));
      end if;
    end if;
    probs := public.ej_char_problems(new.data, lv, od, old.level, dt);
  end if;
  new.checked_at := now();
  if array_length(probs, 1) > 0 then
    new.suspect := true;
    new.flags := (select coalesce(jsonb_agg(e), '[]'::jsonb) from (
      select e from jsonb_array_elements(coalesce(new.flags, '[]'::jsonb) || jsonb_build_array(jsonb_build_object('at', now(), 'why', to_jsonb(probs)))) e
      offset greatest(0, jsonb_array_length(coalesce(new.flags, '[]'::jsonb)) + 1 - 20)) x);
  end if;
  return new;
end $$;

-- =====================================================================
-- HOGYAN ADJ AJÁNDÉKOT (ezt a részt bármikor újra lefuttathatod, csak a nevet és a számot írd át)
-- =====================================================================
insert into public.gifts (char_id, pog, gold, note)
select id, 200, 0, 'Ajándék a játék gazdájától'
  from public.characters where lower(btrim(name)) = lower('Fredi')
returning (select name from public.characters c where c.id = char_id) as hos, pog, gold;
-- Ha nem ír ki semmit, nincs ilyen nevű hős. Így kereshetsz rá:
--   select name, level from public.characters where name ilike '%fredi%';
-- Kiosztott és még fel nem vett ajándékok:
--   select c.name, g.pog, g.gold, g.created_at, g.claimed_at from public.gifts g join public.characters c on c.id = g.char_id order by g.created_at desc;
