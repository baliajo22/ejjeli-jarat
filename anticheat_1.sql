-- Éjjeli Járat – csalásvédelem, 1. rész: hihetőségi ellenőrzés
-- Supabase: SQL Editor -> New query -> illeszd be az egészet -> Run
-- Többször is lefuttatható, nem töröl adatot.
--
-- Mit csinál:
--  * minden mentésnél összeveti a régi és az új hőst; ha valami lehetetlen (túl gyors szintlépés,
--    a semmiből jött pénz, a szintnél erősebb tárgy), a hőst "gyanús"-nak jelöli (suspect = true).
--    A mentést NEM dobja el, így egy tévedés miatt senki nem veszít haladást.
--  * a gyanús hős nem látszik a ranglistán, nem lehet vele harcolni az arénában,
--    nem jelentkezhet céhharcra, nem üthet főgonoszt és nem fizethet be a céhkasszába.
--  * a főgonosz-csapásokat és a céhharc-hadüzenetet a szerver is ellenőrzi.
--
-- Ha egy hőst tévesen jelölt meg: Table Editor -> characters -> a hős sorában
-- a suspect oszlopot állítsd false-ra (a flags oszlopban látod, miért jelölte meg).

-- ===== új oszlopok: ezeket a játék nem írhatja, csak a szerver =====
alter table public.characters add column if not exists suspect    boolean     not null default false;
alter table public.characters add column if not exists flags      jsonb       not null default '[]'::jsonb;
alter table public.characters add column if not exists checked_at timestamptz not null default now();

-- ===== segédfüggvények =====
create or replace function public.ej_num(j jsonb) returns numeric
language sql immutable as $$
  select case when j is null or jsonb_typeof(j) = 'null' then 0
              when jsonb_typeof(j) = 'number' then (j #>> '{}')::numeric
              else null end
$$;

-- egy tárgy: a szintjéhez és ritkaságához képest nem lehet erősebb, mint amit a játék valaha generálhat
create or replace function public.ej_item_problem(it jsonb, maxlvl numeric) returns text
language plpgsql immutable as $$
declare
  r int; l numeric; rm numeric; sm numeric; slot text; aw numeric; k text; v jsonb; n int := 0;
  tol constant numeric := 1.25;
begin
  if it is null or jsonb_typeof(it) <> 'object' then return null; end if;
  if public.ej_num(it->'rar') is null then return 'tárgy: hibás ritkaság'; end if;
  r := coalesce(public.ej_num(it->'rar'), 0)::int;
  if r < 0 or r > 4 then return 'tárgy: lehetetlen ritkaság ' || r; end if;
  l := least(greatest(coalesce(public.ej_num(it->'lvl'), 1), 1), maxlvl);
  rm := (array[.8, 1, 1.15, 1.25, 1.4])[r + 1];
  sm := (array[.8, 1, 1.15, 1.2, 1.35])[r + 1];
  slot := it->>'slot';
  if slot = 'fegyver' then
    if public.ej_num(it->'max') is null or public.ej_num(it->'min') is null then return 'fegyver: hibás sebzés'; end if;
    if public.ej_num(it->'max') > ((l * 2.4 + 4) * rm + 1) * tol + 2
       or public.ej_num(it->'min') > ((l * 1.6 + 2) * rm) * tol + 2 then
      return format('fegyver túl erős: %s–%s (%s. szint)', it->>'min', it->>'max', round(l));
    end if;
  end if;
  aw := case slot when 'fej' then 5 when 'test' then 6 when 'kesztyu' then 3 when 'cipo' then 4 when 'ov' then 2 else 0 end;
  if public.ej_num(it->'armor') is null then return 'tárgy: hibás páncél'; end if;
  if public.ej_num(it->'armor') > ((l * greatest(aw, 1) + 2) * rm + 1) * tol + 2 then
    return format('páncél túl nagy: %s (%s. szint)', it->>'armor', round(l));
  end if;
  if it->'bonus' is not null and jsonb_typeof(it->'bonus') = 'object' then
    for k, v in select * from jsonb_each(it->'bonus') loop
      n := n + 1;
      if k not in ('str', 'dex', 'int', 'con', 'lck') then return 'tárgy: ismeretlen tulajdonság ' || k; end if;
      if public.ej_num(v) is null or public.ej_num(v) > ((1.6 + l * .7) * sm + 1) * tol + 2 then
        return format('tárgy tulajdonsága túl nagy: %s +%s (%s. szint)', k, v #>> '{}', round(l));
      end if;
    end loop;
    if n > 3 then return 'tárgy: túl sok tulajdonság'; end if;
  end if;
  return null;
end $$;

-- az egész hős: abszolút korlátok (minden mentésnél) + a változás sebessége (a régi mentéshez képest)
create or replace function public.ej_char_problems(d jsonb, lvl int, old_d jsonb, old_lvl int, dt numeric) returns text[]
language plpgsql immutable as $$
declare
  out text[] := '{}'; k text; v jsonb; p text; cap numeric; maxl numeric;
  g numeric; og numeric; pg numeric; opg numeric;
begin
  if d is null or jsonb_typeof(d) <> 'object' then return out; end if;
  if lvl < 1 or lvl > 150 then out := out || format('lehetetlen szint: %s', lvl); end if;
  -- alap tulajdonságok: szintlépésből + edzésből sem lehet ennél több
  cap := 20 + 8 * lvl;
  if d->'stats' is not null and jsonb_typeof(d->'stats') = 'object' then
    for k, v in select * from jsonb_each(d->'stats') loop
      if public.ej_num(v) is null or public.ej_num(v) > cap then out := out || format('túl nagy alap %s: %s (max %s)', k, v #>> '{}', cap); end if;
    end loop;
  end if;
  -- felszerelés és táska
  maxl := lvl + 8;
  if d->'equip' is not null and jsonb_typeof(d->'equip') = 'object' then
    for k, v in select * from jsonb_each(d->'equip') loop
      p := public.ej_item_problem(v, maxl); if p is not null then out := out || ('viselt ' || p); end if;
    end loop;
  end if;
  if d->'inv' is not null and jsonb_typeof(d->'inv') = 'array' then
    for v in select * from jsonb_array_elements(d->'inv') loop
      p := public.ej_item_problem(v, maxl); if p is not null then out := out || ('táska: ' || p); end if;
    end loop;
  end if;
  -- céhfejlesztések
  if d #> '{guild,upg}' is not null and jsonb_typeof(d #> '{guild,upg}') = 'object' then
    for k, v in select * from jsonb_each(d #> '{guild,upg}') loop
      if public.ej_num(v) is null or public.ej_num(v) > 30 then out := out || format('céhfejlesztés túl magas: %s %s', k, v #>> '{}'); end if;
    end loop;
  end if;
  g := public.ej_num(d->'gold'); pg := public.ej_num(d->'pog');
  if g is null or pg is null then out := out || 'hibás pénz'::text; return out; end if;
  if old_d is null then
    -- első feltöltés: nincs mihez hasonlítani, csak durva felső korlát
    if g > 50000 + 400 * lvl * lvl then out := out || format('túl sok pénz: %s', g); end if;
    if pg > 300 + 10 * lvl then out := out || format('túl sok pogácsa: %s', pg); end if;
  else
    og := coalesce(public.ej_num(old_d->'gold'), 0); opg := coalesce(public.ej_num(old_d->'pog'), 0);
    if lvl - old_lvl > 2 + dt / 60 then out := out || format('túl gyors szintlépés: %s -> %s, %s mp alatt', old_lvl, lvl, round(dt)); end if;
    if g - og > 10000 + 800 * lvl + dt * (5 + 2 * lvl) then out := out || format('túl gyorsan jött pénz: +%s, %s mp alatt', g - og, round(dt)); end if;
    if pg - opg > 40 + dt / 60 then out := out || format('túl gyorsan jött pogácsa: +%s, %s mp alatt', pg - opg, round(dt)); end if;
    if coalesce(old_d->>'cls', '') <> '' and coalesce(d->>'cls', '') <> coalesce(old_d->>'cls', '') then out := out || 'kaszt megváltozott'::text; end if;
  end if;
  return out;
end $$;

-- minden mentésnél lefut; a jelölést és az ellenőrzés idejét csak ez írhatja
create or replace function public.ej_check_character() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  probs text[]; dt numeric; lv int;
begin
  lv := coalesce(public.ej_num(new.data->'level'), new.level)::int;
  new.level := lv;                                    -- a ranglista mindig a mentés szerinti szintet mutatja
  if tg_op = 'INSERT' then
    new.suspect := false; new.flags := '[]'::jsonb;  -- a játék nem állíthatja be saját magának
    probs := public.ej_char_problems(new.data, lv, null, null, 0);
  else
    new.suspect := old.suspect; new.flags := old.flags;
    dt := greatest(1, extract(epoch from (now() - old.checked_at)));
    probs := public.ej_char_problems(new.data, lv, old.data, old.level, dt);
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
drop trigger if exists ej_check_character on public.characters;
create trigger ej_check_character before insert or update of data, level, cls, name on public.characters
  for each row execute function public.ej_check_character();

-- ===== főgonosz-csapások: sebzés a hős szintjéhez mérve, napi darabszám =====
create or replace function public.ej_check_hit() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  c public.characters; n int; day_start timestamptz; lim int;
begin
  select * into c from public.characters where id = new.char_id;
  if c.id is null then raise exception 'Ismeretlen hős'; end if;
  if c.suspect then raise exception 'A hősöd ellenőrzés alatt áll, most nem üthet.'; end if;
  if new.dmg > 5000 + 250 * c.level * c.level then raise exception 'Túl nagy sebzés ehhez a szinthez.'; end if;
  day_start := date_trunc('day', now() at time zone 'Europe/Budapest') at time zone 'Europe/Budapest';
  if tg_table_name = 'world_boss_hits' then
    select count(*) into n from public.world_boss_hits where char_id = new.char_id and created_at >= day_start; lim := 10;   -- játékban 3 ingyen + 5 pogácsáért
    new.level := c.level;
  else
    select count(*) into n from public.guild_raid_hits where char_id = new.char_id and created_at >= day_start; lim := 7;    -- játékban 2 ingyen + 3 pogácsáért
  end if;
  if n >= lim then raise exception 'Mára elfogytak a csapások.'; end if;
  new.name := c.name; new.cls := c.cls;
  return new;
end $$;
drop trigger if exists ej_check_hit on public.world_boss_hits;
create trigger ej_check_hit before insert on public.world_boss_hits for each row execute function public.ej_check_hit();
drop trigger if exists ej_check_hit on public.guild_raid_hits;
create trigger ej_check_hit before insert on public.guild_raid_hits for each row execute function public.ej_check_hit();

-- ===== gyanús hős nem fizethet be, nem jelentkezhet céhharcra, nem üzenhet hadat =====
create or replace function public.ej_block_suspect() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  cid text; s boolean;
begin
  cid := case tg_table_name when 'guild_donations' then new.from_char when 'guild_war_signups' then new.char_id else new.atk_ch end;
  select suspect into s from public.characters where id = cid;
  if coalesce(s, false) then raise exception 'A hősöd ellenőrzés alatt áll, ezt most nem teheted meg.'; end if;
  return new;
end $$;
drop trigger if exists ej_block_suspect on public.guild_donations;
create trigger ej_block_suspect before insert on public.guild_donations for each row execute function public.ej_block_suspect();
drop trigger if exists ej_block_suspect on public.guild_war_signups;
create trigger ej_block_suspect before insert on public.guild_war_signups for each row execute function public.ej_block_suspect();

-- hadüzenet gépi céhnek: a gépi céh méretét és erejét nem lehet "kedvezőre" állítani
create or replace function public.ej_check_war() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  c public.characters;
begin
  select * into c from public.characters where id = new.atk_ch;
  if c.id is null then raise exception 'Ismeretlen hős'; end if;
  if c.suspect then raise exception 'A hősöd ellenőrzés alatt áll, most nem üzenhetsz hadat.'; end if;
  if new.def_bot is not null and jsonb_typeof(new.def_bot) = 'object' then
    new.def_bot := new.def_bot
      || jsonb_build_object('lvl', c.level)
      || jsonb_build_object('size', least(12, greatest(4, coalesce(public.ej_num(new.def_bot->'size'), 4)))::int)
      || jsonb_build_object('off', least(6, greatest(-3, coalesce(public.ej_num(new.def_bot->'off'), 0)))::int);
  end if;
  new.status := 'pending'; new.result := null;
  return new;
end $$;
drop trigger if exists ej_check_war on public.guild_wars;
create trigger ej_check_war before insert on public.guild_wars for each row execute function public.ej_check_war();

-- ===== aréna: ezt a függvényt csak a harcszerver hívhatja (2. lépés) =====
create or replace function public.arena_apply(attacker text, defender text, won boolean)
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
  if a.id = d.id then raise exception 'Magad ellen nem harcolhatsz'; end if;
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
revoke all on function public.arena_apply(text, text, boolean) from public;
revoke all on function public.arena_apply(text, text, boolean) from anon;
revoke all on function public.arena_apply(text, text, boolean) from authenticated;
grant execute on function public.arena_apply(text, text, boolean) to service_role;

-- a gyanús hősök listája (csak ránézésre): select id, name, level, flags from public.characters where suspect;
