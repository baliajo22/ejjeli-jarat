# Éjjeli Járat – online tesztverzió

Böngészős RPG modern városi fantasy világban. Ez a változat Supabase-t használ a fiókokhoz, a hősök mentéséhez és az online arénához.

## Fájlok

- `index.html` – maga a játék
- `config.js` – a Supabase projekt címe és nyilvános (anon) kulcsa
- `schema.sql` – az adatbázis táblái és jogosultságai
- `anticheat_1.sql`, `anticheat_2.sql` – csalásvédelem (lásd lent)
- `supabase/functions/harc/index.ts` – a harcszerver: itt dől el az aréna és a céhharc

## Beállítás

1. **Supabase projekt:** supabase.com → New project (régió: Central EU / Frankfurt).
2. **Adatbázis:** SQL Editor → New query → másold be a `schema.sql` teljes tartalmát → Run.
3. **E-mail megerősítés kikapcsolása (teszthez ajánlott):** Authentication → Sign In / Providers → Email → kapcsold ki a „Confirm email” opciót → Save. Így a barátaid regisztráció után azonnal játszhatnak.
4. **Kulcsok:** Project Settings → API → másold a `Project URL`-t és az `anon public` kulcsot a `config.js`-be.
5. **Feltöltés:** a három fájlt tedd fel egy GitHub repóba, majd Settings → Pages → Branch: `main`, mappa: `/ (root)` → Save. Pár perc múlva elérhető: `https://FELHASZNALO.github.io/REPO/`.

## Tudnivalók

- A `service_role` kulcsot soha ne tedd a játékba vagy a repóba.
- A rangpontot és a harcok eredményét a kliens nem írhatja át közvetlenül.

## Csalásvédelem

1. **Hihetőségi ellenőrzés:** SQL Editor → futtasd az `anticheat_1.sql`-t. Minden mentésnél ellenőrzi a hőst (szint, pénz, tárgyak, statok); a lehetetlen változást mutató hőst `suspect`-nek jelöli. A gyanús hős nem látszik a ranglistán, nem harcolhat, nem üthet főgonoszt. Téves jelölésnél a Table Editorban a `characters` táblában állítsd a `suspect` oszlopot `false`-ra (az okot a `flags` oszlop mutatja).
2. **Harcszerver:** Edge Functions → Deploy a new function → Via Editor → a neve legyen pontosan `harc` → a kódot cseréld le a `supabase/functions/harc/index.ts` tartalmára → Deploy. Ettől kezdve az arénát és a céhharcot a szerver számolja.
3. **Régi utak lezárása:** ha a harcszerver működik (az arénában a harc után megjelenik a rangpont), futtasd az `anticheat_2.sql`-t.

A harcszerver kódját a `build_harc.py` állítja elő a játék kódjából, így a szabályok mindig egyeznek; a játék harcszabályainak módosítása után újra kell telepíteni.
