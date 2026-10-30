# Éjjeli Járat – online tesztverzió

Böngészős RPG modern városi fantasy világban. Ez a változat Supabase-t használ a fiókokhoz, a hősök mentéséhez és az online arénához.

## Fájlok

- `index.html` – maga a játék
- `config.js` – a Supabase projekt címe és nyilvános (anon) kulcsa
- `schema.sql` – az adatbázis táblái és jogosultságai

## Beállítás

1. **Supabase projekt:** supabase.com → New project (régió: Central EU / Frankfurt).
2. **Adatbázis:** SQL Editor → New query → másold be a `schema.sql` teljes tartalmát → Run.
3. **E-mail megerősítés kikapcsolása (teszthez ajánlott):** Authentication → Sign In / Providers → Email → kapcsold ki a „Confirm email” opciót → Save. Így a barátaid regisztráció után azonnal játszhatnak.
4. **Kulcsok:** Project Settings → API → másold a `Project URL`-t és az `anon public` kulcsot a `config.js`-be.
5. **Feltöltés:** a három fájlt tedd fel egy GitHub repóba, majd Settings → Pages → Branch: `main`, mappa: `/ (root)` → Save. Pár perc múlva elérhető: `https://FELHASZNALO.github.io/REPO/`.

## Tudnivalók

- A `service_role` kulcsot soha ne tedd a játékba vagy a repóba.
- A játék logikája a böngészőben fut, így egy ügyes játékos csalhatna. Baráti teszthez ez rendben van; nyilvános megjelenés előtt a harcot és a jutalmakat szerveroldalra kell vinni.
- A rangpontot csak az `arena_result` adatbázis-függvény változtathatja, a kliens nem írhatja át közvetlenül.
