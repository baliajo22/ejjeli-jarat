-- Éjjeli Járat – az Alapító napok meghosszabbítása november 18-ig (nov. 19. 00:00-ig)
-- Supabase: SQL Editor -> New query -> illeszd be -> Run. Csak az Alapító jutalom határidejét írja át, mást nem.
create or replace function public.founder_claim(cid text) returns boolean
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not exists (select 1 from public.characters where id = cid and user_id = auth.uid()) then return false; end if;
  if exists (select 1 from public.founders where char_id = cid) then return true; end if;
  if not exists (select 1 from public.server_meta where key = 'season' and (value->>'n')::int >= 2) then return false; end if;
  if now() < timestamptz '2026-11-11 00:00 Europe/Budapest' or now() >= timestamptz '2026-11-19 00:00 Europe/Budapest' then return false; end if;
  insert into public.founders (user_id, char_id) values (auth.uid(), cid) on conflict (user_id) do nothing;
  get diagnostics n = row_count;
  if n > 0 then insert into public.gifts (char_id, pog, gold, note) values (cid, 10, 0, 'Alapító jutalom'); end if;
  return n > 0;
end $$;
revoke all on function public.founder_claim(text) from public, anon;
grant execute on function public.founder_claim(text) to authenticated;
