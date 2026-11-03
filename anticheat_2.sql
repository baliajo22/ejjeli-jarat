-- Éjjeli Járat – csalásvédelem, 2. rész: a régi, kijátszható utak lezárása
-- CSAK AKKOR futtasd, ha a "harc" szerverprogram (Edge Function) már működik!
-- Supabase: SQL Editor -> New query -> illeszd be az egészet -> Run
--
-- Ezután az aréna és a céhharc eredményét csak a szerver számolhatja és írhatja be:
--  * a régi arena_result függvényt (ahol a telefon mondta meg, ki nyert) már nem lehet hívni,
--  * a céhharc eredményét a telefon már nem írhatja be.

revoke execute on function public.arena_result(text, text, boolean) from public;
revoke execute on function public.arena_result(text, text, boolean) from anon;
revoke execute on function public.arena_result(text, text, boolean) from authenticated;

drop policy if exists "gw finish" on public.guild_wars;
revoke update on public.guild_wars from authenticated;
revoke update on public.guild_wars from anon;
