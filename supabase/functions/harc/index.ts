// @ts-nocheck
/* Éjjeli Járat – harcszerver (Supabase Edge Function, a neve: harc)
   Az arénaharcot és a céhharcot itt számolja ki a szerver, a telefon csak visszajátssza.
   A harcszabályok lent a játék kódjából vannak kimásolva (generált rész), kézzel ne írd át. */
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
const VERSION = "2026.11.03 19:03";

/* ---------- a játék kódjának szerveres helyettesítői ---------- */
let state = { cid: "\u0000szerver" };          // a szerveren nincs "saját" hős
let CHARS = {};                                // az aktuális harc szereplői az adatbázisból
function realData(cid) { return CHARS[cid] || null; }
function artOf() { return ""; }
const ENEMY_ART = {};

/* ================= A JÁTÉK HARCSZABÁLYAI (generált) ================= */
const LOOKS=Object.fromEntries(Object.entries({}).map(([k,n])=>[k,Array(n).fill(0)]));
/* generated from the game: lookCount, sexLook, CLASSES, STAT_DMG, HP_PER_CON, ENEMY_GROW, FIRST, EPI, heroFighter, rand, pick, now, MISS, maxHp, critChance, resist, armorRed, enemyLvl, genFighter, strike, simulate, SKILL_LV, SK_SCALE, S, SKILLS, FX_CAP, skillFx, enemyFx, guildChannel, MEMBER_WAIT, memberWait, mulberry, withSeed, gwSeed, gwSnap, gwHero, gwSide, gwBots, gwRelay, gwAt */
function lookCount(cls,sex){ return 1+((LOOKS[cls+':'+(sex||'m')]||[]).length); }
const sexLook=s=>!s||!s.sex?undefined:s.look?String(s.sex)[0]+(s.look<lookCount(s.cls,String(s.sex)[0])?s.look:''):String(s.sex);
const CLASSES = {
  kidobo:{name:'Kidobó', main:'str', hp:5.5, dmg:.74, crit:1, maxArmor:.45, dodge:0, block:.15, desc:'Romkocsma-ajtók őre. Sok élet, nagy ütés.', perk:'A legtöbb élet, 15% eséllyel pajzzsal hárít'},
  magus:{name:'Panelmágus', main:'int', hp:1.8, dmg:2.0, crit:1.35, maxArmor:.1, dodge:0, block:0, desc:'Tizedik emeleti varázsló egy lift nélküli panelból. Törékeny, de fáj.', perk:'Kevés élet, de a legnagyobb sebzés. Varázslata elől nem lehet kitérni, átüti a páncélt és a pajzsot'},
  futar:{name:'Tetőlövész', main:'dex', hp:4, dmg:1.1, crit:1, maxArmor:.25, dodge:.3, block:0, ranged:true, desc:'A háztetőkről vadászik csúzlival és számszeríjjal. Messziről talál, közelről elugrik.', perk:'Távolsági fegyverrel lő, 30% eséllyel kitér a támadás elől'},
  zsebmetszo:{name:'Zsebmetsző', main:'dex', hp:3.6, dmg:.65, crit:1, maxArmor:.25, dodge:.2, block:0, hits:2, desc:'A sikátorok árnya, két bicskával. Kétszer szúr, mielőtt észbe kapnál.', perk:'Körönként kétszer támad kisebb sebzéssel, 20% kitérés'}
};
const STAT_DMG=.8;
const HP_PER_CON=3;
const ENEMY_GROW=1.45;
const FIRST=['Éva','Pista','Lili','Kata','Bence','Rezső','Hanna','Tibi','Peti','Zsófi','Vilmos','Réka','Dóri','Gergő','Anna','Marci','Juli','Laci','Niki','Ernő','Bori','Csaba','Edit','Gábor'];
const EPI=['Pengés','Panel','Éjféli','Zuglói','Rúnás','Holdas','Rozsdás','Villám','Kerületi','Ködös','Csatorna','Neon','Kőbányai','Budai','Pesti','Füstös'];
function heroFighter(st){
  const s={...st.stats}; for(const it of Object.values(st.equip||{})) if(it) for(const [k,v] of Object.entries(it.bonus||{})) s[k]+=v;
  const w=st.equip&&st.equip.fegyver, armor=Object.values(st.equip||{}).reduce((a,it)=>a+(it?it.armor||0:0),0);
  const fx=skillFx(st);
  return {wpn:st.equip&&st.equip.fegyver&&st.equip.fegyver.base, name:st.name, cls:st.cls, level:st.level, stats:s, wMin:w?w.min:1, wMax:w?w.max:3, armor:Math.round(armor*(1+(fx.armor||0))), hp:Math.round(maxHp(s.con,st.level,st.cls)*(1+(fx.hp||0))), art:artOf(st.cls,sexLook(st)||'m'), sex:sexLook(st)||'m', real:true, cid:st.cid, fx};
}
const rand=(a,b)=>Math.floor(Math.random()*(b-a+1))+a;
const pick=a=>a[Math.floor(Math.random()*a.length)];
const now=()=>Date.now();
const MISS=0;
function maxHp(con,lvl,cls){return Math.round(con*HP_PER_CON*CLASSES[cls].hp)}
function critChance(f){return Math.min(FX_CAP.crit, Math.min(.5, f.stats.lck/(f.stats.lck+40+f.level*4)*CLASSES[f.cls||state.cls].crit)+((f.fx&&f.fx.crit)||0))}
function resist(s,lvl){return Math.min(.5, s/(s+15+lvl*8))}
function armorRed(f){return Math.min(CLASSES[f.cls].maxArmor, f.armor/Math.max(1,f.level*10))}
function enemyLvl(l){ return 1+(l-1)*ENEMY_GROW; }
function genFighter(name, lvl, mult, cls){
  cls = cls || pick(Object.keys(CLASSES));
  const m=CLASSES[cls].main, e=enemyLvl(lvl);
  const s={str:Math.round(3+e),dex:Math.round(3+e),int:Math.round(3+e),con:Math.round((5+e*2.5+rand(0,Math.round(e)))*mult),lck:Math.round(3+e)+rand(0,Math.round(e))};
  s[m]=Math.round((6+e*2.5+rand(0,Math.round(e)))*mult);
  const fx=enemyFx(lvl);
  return {name, cls, level:lvl, stats:s, wMin:Math.round((e*1.6+2)*mult), wMax:Math.round((e*2.4+4)*mult), armor:Math.round(e*rand(5,9)*mult), hp:Math.round(maxHp(s.con,e,cls)*(1+(fx.hp||0))), fx};
}
function strike(att, def, followUp){
  const ac=CLASSES[att.cls], dc=CLASSES[def.cls], mag=att.cls==='magus';
  if(!mag && Math.random()<MISS) return {dmg:0,miss:true};
  const af=att.fx||{}, df=def.fx||{}, dodge=Math.min(FX_CAP.dodge,(dc.dodge||0)+(df.dodge||0)), block=Math.min(FX_CAP.block,(dc.block||0)+(df.block||0)), pierce=af.pierce||0;
  if(!mag && dodge && Math.random()<dodge) return {dmg:0,dodge:true};
  if(!mag && !followUp && block && Math.random()<block) return {dmg:0,block:true}; // a quick follow-up stab slips past the shield
  const m=ac.main;
  let dmg = (rand(att.wMin, att.wMax) + att.stats[m]*STAT_DMG) * ac.dmg * (1 - resist(def.stats[m], def.level)*(1-pierce)) * (1+(af.dmg||0));
  if(att.cls!=='magus') dmg *= 1-armorRed(def)*(1-pierce);
  const crit=Math.random()<critChance(att); if(crit) dmg*=2+(af.critx||0);
  return {dmg:Math.max(1,Math.round(dmg)), crit};
}
function simulate(a,b){
  const fa=a.fx||{}, fb=b.fx||{}, mA=a.maxHp||a.hp, mB=b.maxHp||b.hp;
  let hA=a.hp, hB=b.hp, t=Math.random()<.5+(fa.first||0)-(fb.first||0)?0:1, log=[], n=0;
  while(hA>0 && hB>0 && n<300){ const att=t?b:a, def=t?a:b, af=att.fx||{}, df=def.fx||{}, hits=(CLASSES[att.cls].hits||1)+(af.extra&&Math.random()<af.extra?1:0);
    for(let h=0;h<hits&&hA>0&&hB>0;h++){ const r=strike(att, def, h>0);
      if(t) hA=Math.max(0,hA-r.dmg); else hB=Math.max(0,hB-r.dmg);
      // talents: life steal for the attacker, thorns back at them
      if(r.dmg>0&&af.leech){ const g=Math.round(r.dmg*af.leech); if(t) hB=Math.min(mB,hB+g); else hA=Math.min(mA,hA+g); r.heal=g; }
      if(r.dmg>0&&df.thorns&&(t?hA:hB)>0){ const th=Math.max(1,Math.round(r.dmg*df.thorns)); if(t) hB=Math.max(0,hB-th); else hA=Math.max(0,hA-th); r.thorns=th; }
      log.push({...r, side:t, hA, hB, extra:h>0}); n++; }
    t=1-t; }
  // a fight always ends with a knockout: if it drags on, the one in worse shape runs out of breath
  if(hA>0&&hB>0){ const aWins=hA/(a.maxHp||a.hp)>=hB/(b.maxHp||b.hp); if(aWins){ log.push({dmg:hB,side:0,hA,hB:0,finish:true}); hB=0; } else { log.push({dmg:hA,side:1,hA:0,hB,finish:true}); hA=0; } }
  return {log, win: hB<=0};
}
const SKILL_LV=[5,10,20,30,40,50,60,70,85,100];
const SK_SCALE=.5;
const S=(n,fx,d)=>({n,fx:Object.fromEntries(Object.entries(fx).map(([k,v])=>[k,+(v*SK_SCALE).toFixed(3)])),d});
const SKILLS={
 kidobo:[[S('Vastag bőr',{hp:.06},'Egy életnyi verekedés nyoma.'),S('Nehéz kéz',{dmg:.05},'Egy pofon, és vége a bulinak.')],
  [S('Pajzsfal',{block:.04},'A sörösrekesz pajzsnak is jó.'),S('Kocsmai rúgás',{crit:.04},'Pont oda, ahol fáj.')],
  [S('Ajtófélfa',{armor:.15},'Nem mozdul, ha nekimennek.'),S('Visszakézből',{thorns:.08},'Aki megüti, visszakapja.')],
  [S('Második szél',{leech:.04},'Ütés közben kifújja magát.'),S('Ököljog',{critx:.3},'A kritikus ütés még nagyobbat szól.')],
  [S('Hústorony',{hp:.08},'Ennyi embert nem lehet kidobni.'),S('Kidobás',{first:.15},'Mire észbe kapnál, már kint vagy.')],
  [S('Kemény koponya',{block:.04},'Fejjel is lehet hárítani.'),S('Bárpult-kombó',{extra:.08},'Egy jobb, egy bal, egy pult.')],
  [S('Törzsvendég',{gold:.06},'A kocsmáros mindig ad borravalót.'),S('Rendcsináló',{xp:.06},'Minden verekedésből tanul.')],
  [S('Betonfal',{armor:.2},'Az ajtó előtt áll, és az ajtó ő.'),S('Haragos',{dmg:.07},'Ma nem jó napja van.')],
  [S('Sörhas',{hp:.1},'Ez nem kövérség, hanem páncél.'),S('Üveglavina',{crit:.06},'Ami a kezébe akad, repül.')],
  [S('A kocsma ura',{hp:.06,dmg:.05},'A városban mindenki ismeri.'),S('Utolsó kör',{leech:.06,critx:.3},'Záróra után a legveszélyesebb.')]],
 magus:[[S('Lift nélküli edzés',{hp:.08},'Tíz emelet naponta kétszer.'),S('Rövidzárlat',{dmg:.05},'A villanyóra is beleremeg.')],
  [S('Távirányítás',{crit:.04},'Ránéz, és átkapcsol.'),S('Panelrezonancia',{critx:.3},'A falak felerősítik a varázst.')],
  [S('Kapualj-varázs',{dodge:.06},'Egy pillanatra eltűnik a lépcsőházban.'),S('Áramszünet',{first:.2},'Sötétben ő lát először.')],
  [S('Életerő-csapolás',{leech:.05},'A szomszéd mérőóráját is lecsapolja.'),S('Túlfeszültség',{dmg:.06},'Kicsapja a biztosítékot.')],
  [S('Védőbűbáj',{hp:.1},'Egy régi takaróba szőtt átok.'),S('Kettős varázs',{extra:.08},'Egyszerre két átkot mormol.')],
  [S('Lakógyűlés',{xp:.07},'Minden vitából tanul valamit.'),S('Közös költség',{gold:.06},'Mindenki fizet, ő is kap belőle.')],
  [S('Penészvarázs',{thorns:.06},'Aki hozzáér, megbánja.'),S('Szikrázó ész',{crit:.05},'Egy jó ötlet, egy nagy villám.')],
  [S('Tizedik emelet',{hp:.1},'Már semmi nem tudja meglepni.'),S('Villámlánc',{extra:.1},'A villám kétszer is becsap.')],
  [S('Fényszóró',{critx:.4},'Vakító, ha talál.'),S('Áramütés',{dmg:.08},'Rázós a kézfogása.')],
  [S('A panel szelleme',{hp:.08,leech:.04},'Az egész ház vele van.'),S('Tébolyult tudós',{dmg:.06,crit:.04},'Senki nem tudja, mit csinál. Ő sem.')]],
 futar:[[S('Könnyű léptek',{dodge:.03},'A cserép meg sem reccsen.'),S('Jó szem',{crit:.04},'Egy galambot is eltalál a Bazilikáról.')],
  [S('Magaslati előny',{first:.15},'Fentről mindent előbb lát.'),S('Feszes gumi',{dmg:.05},'Új csúzligumi, nagyobb csattanás.')],
  [S('Cserépvért',{armor:.15},'Ami a tetőn megvédi, rajta is.'),S('Átütő lövés',{pierce:.15},'A páncél sem állja útját.')],
  [S('Gyors töltés',{extra:.07},'Mire felnézel, már újra lőtt.'),S('Fejlövés',{critx:.3},'Ha talál, nagyon talál.')],
  [S('Szomszéd tető',{dodge:.04},'Egy ugrás, és már ott sincs.'),S('Galambetetés',{leech:.04},'A galambok hálásak, segítenek.')],
  [S('Futárpénz',{gold:.06},'Minden útért jár egy kis borravaló.'),S('Tetőtúra',{xp:.06},'Minden tetőről tanul valamit.')],
  [S('Kémény mögött',{hp:.08},'Mindig van mögé bújni.'),S('Vadász',{dmg:.07},'Tudja, hova kell célozni.')],
  [S('Szél ellen',{crit:.05},'A szelet is beleszámolja.'),S('Átütő nyíl',{pierce:.2},'Ez a nyíl a falon is átmegy.')],
  [S('Árnyék a tetőn',{dodge:.05},'Csak a sziluettje látszik.'),S('Duplázás',{extra:.1},'Két lövés egy lélegzettel.')],
  [S('A háztetők ura',{dodge:.03,dmg:.06},'A város fölött ő az úr.'),S('Mesterlövész',{crit:.05,critx:.3},'Egy lövés, egy találat.')]],
 zsebmetszo:[[S('Ügyes ujjak',{crit:.04},'Mindig a gyenge pontot találja.'),S('Hidegvér',{hp:.06},'Nem ijed meg a saját árnyékától.')],
  [S('Sikátorlépés',{dodge:.03},'Egy lépés oldalra, és már nincs ott.'),S('Hátba szúrás',{first:.15},'Mindig mögötted áll.')],
  [S('Méregpenge',{pierce:.15},'A méreg a páncélon is átjut.'),S('Tolvajszerencse',{gold:.07},'Valahogy mindig több pénz lesz nála.')],
  [S('Vérszívó',{leech:.05},'Minden vágással erősebb.'),S('Gyors kés',{extra:.07},'A harmadik vágást senki nem várja.')],
  [S('Árnyékba olvadás',{dodge:.04},'A sötét a barátja.'),S('Mély vágás',{critx:.3},'Ritkán talál nagyot, de akkor nagyon.')],
  [S('Zsebtolvaj',{gold:.06},'Az ellenfél zsebe is az övé.'),S('Tanulópénz',{xp:.07},'Minden balhéból okul.')],
  [S('Bőrdzseki',{armor:.2},'Vastag, kopott, de megvédi.'),S('Kétkezes',{dmg:.07},'Mindkét kés egyformán éles.')],
  [S('Kiszámíthatatlan',{dodge:.04},'Senki nem tudja, merre lép.'),S('Érzéki találat',{crit:.05},'Tudja, hol fáj a legjobban.')],
  [S('Hármas szúrás',{extra:.1},'Kettő kevés, legyen három.'),S('Rozsdás penge',{pierce:.2},'Ez a rozsda mindenen átmegy.')],
  [S('A sikátor ura',{dodge:.03,leech:.04},'A sikátor minden árnyéka az övé.'),S('Ezer vágás',{dmg:.06,extra:.06},'Ennyi sebet nem lehet számolni.')]]
};
const FX_CAP={dodge:.45,block:.35,crit:.6};
function skillFx(st){ const fx={}, sk=st&&st.skills||[], T=SKILLS[st&&st.cls]||[]; sk.forEach((c,i)=>{ if(c==null||!T[i]) return; for(const [k,v] of Object.entries(T[i][c].fx)) fx[k]=(fx[k]||0)+v; }); return fx; }
function enemyFx(lvl){ const n=SKILL_LV.filter(l=>l<=lvl).length; return n?{dmg:n*.02,hp:n*.02}:{}; }
function guildChannel(){ return state.guild?state.cid:state.memberOf?state.memberOf.leaderCid:null; }
const MEMBER_WAIT=12*3600*1000;
function memberWait(cid,ch,at){ cid=cid||state.cid; ch=ch||guildChannel(); at=at||now(); if(!ch||cid===ch) return 0;
  const L=ch===state.cid?state:realData(ch), m=L&&L.guild&&L.guild.members.find(x=>x.real&&x.cid===cid); if(!m) return L&&L.guild?Infinity:0; return m.since?Math.max(0,m.since+MEMBER_WAIT-at):0; }
function mulberry(a){ return function(){ a|=0; a=a+0x6D2B79F5|0; let t=Math.imul(a^a>>>15,1|a); t=t+Math.imul(t^t>>>7,61|t)^t; return ((t^t>>>14)>>>0)/4294967296; }; }
function withSeed(seed,fn){ const r=Math.random; Math.random=mulberry(seed); try{ return fn(); } finally{ Math.random=r; } }
const gwSeed=w=>{ const s=String(w.id); let h=2166136261; for(let i=0;i<s.length;i++){ h^=s.charCodeAt(i); h=Math.imul(h,16777619); } return h>>>0; };
function gwSnap(f){ const {art,...o}=f; return JSON.parse(JSON.stringify(o)); }
function gwHero(cid){ const d=cid===state.cid?state:realData(cid); if(!d||!d.stats) return null; const f=heroFighter(d); f.name=d.name; f.cid=cid; f.artKey=d.cls+':'+(sexLook(d)||'m'); return f; }
function gwSide(ch,signCids,leaderSigned){ // real members who signed up + every bot member of that guild
  const L=ch===state.cid?state:realData(ch), g=L&&L.guild; const out=[];
  const cids=[...new Set(signCids)].filter(c=>memberWait(c,ch,gwAt||now())===0); for(const c of cids){ const f=gwHero(c); if(f) out.push(f); }
  if(g) for(const m of g.members.filter(m=>!m.real)){ const f=genFighter(m.name,Math.max(1,(L.level||1)+(m.off||0)),.95,m.cls); f.artKey=m.cls; out.push(f); }
  const boost=1+.02*(((g||{}).upg||{}).fegyver||0); out.forEach(f=>{ f.wMin=Math.round(f.wMin*boost); f.wMax=Math.round(f.wMax*boost); });
  return out.sort((a,b)=>a.level-b.level); }
function gwBots(bot){ return Array.from({length:bot.size},()=>{ const c=pick(Object.keys(CLASSES)), f=genFighter(`${pick(EPI)} ${pick(FIRST)}`,Math.max(1,bot.lvl+bot.off+rand(-2,1)),.95,c); f.artKey=c; return f; }).sort((a,b)=>a.level-b.level); }
function gwRelay(A,D){ const duels=[]; if(!A.length||!D.length) return duels; let i=0,j=0,ha=A[0].hp,hb=D[0].hp;
  while(i<A.length&&j<D.length){ const a=A[i], b=D[j], r=simulate({...a,hp:ha,maxHp:a.hp},{...b,hp:hb,maxHp:b.hp}), last=r.log[r.log.length-1]||{hA:ha,hB:hb};
    const ea=r.win?Math.max(1,last.hA):0, eb=r.win?0:Math.max(1,last.hB); duels.push({a,b,win:r.win,aFrom:ha,aTo:ea,bFrom:hb,bTo:eb,res:r});
    if(r.win){ ha=ea; j++; hb=D[j]?D[j].hp:0; } else { hb=eb; i++; ha=A[i]?A[i].hp:0; } }
  return duels; }
let gwAt=0;

/* ================= vége a generált résznek ================= */

const ARENA_MIN_MS = 10000;     // két arénatámadás között legalább ennyi idő (a játékban 15 mp a várakozás)
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const J = (o, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const admin = createClient(
  Deno.env.get("SUPABASE_URL"),
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("SUPABASE_SECRET_KEY"),
  { auth: { persistSession: false, autoRefreshToken: false } },
);
const toChar = (r) => ({ ...(r.data || {}), cid: r.id, name: r.name, cls: r.cls, level: r.level });
async function loadChars(ids) {
  const { data, error } = await admin.from("characters").select("id,user_id,name,cls,level,rating,data,suspect").in("id", ids);
  if (error) throw error;
  return data || [];
}

/* ---------- aréna: a szerver dobja a kockát ---------- */
async function arena(user, b) {
  const rows = await loadChars([String(b.attacker || ""), String(b.defender || "")]);
  const a = rows.find((r) => r.id === b.attacker), d = rows.find((r) => r.id === b.defender);
  if (!a || !d) return J({ error: "Ismeretlen hős." }, 404);
  if (a.user_id !== user.id) return J({ error: "Ez nem a te hősöd." }, 403);
  if (a.id === d.id) return J({ error: "Magad ellen nem harcolhatsz." }, 400);
  if (a.suspect) return J({ error: "A hősödet a szerver ellenőrzésre jelölte, ezért most nem harcolhat az arénában." }, 403);
  if (d.suspect || !d.data || !d.data.stats) return J({ error: "Ez a játékos most nem támadható." }, 409);
  if (!a.data || !a.data.stats) return J({ error: "A hősöd mentése még nem érkezett meg, próbáld újra." }, 409);
  const { data: last } = await admin.from("arena_log").select("created_at").eq("attacker_id", a.id).order("created_at", { ascending: false }).limit(1);
  if (last && last[0] && Date.now() - Date.parse(last[0].created_at) < ARENA_MIN_MS) return J({ error: "Túl gyorsan: várj pár másodpercet." }, 429);
  CHARS = {};
  const A = heroFighter(toChar(a)), D = heroFighter(toChar(d));
  A.name = a.name; D.name = d.name;
  const res = simulate(A, D);
  const { data: delta, error } = await admin.rpc("arena_apply", { attacker: a.id, defender: d.id, won: res.win });
  if (error) throw error;
  return J({ win: res.win, log: res.log, delta, a: gwSnap(A), d: gwSnap(D), v: VERSION });
}

/* ---------- céhharc: ugyanaz a menet, mint a játékban, csak itt dől el ---------- */
function resolveWar(w) {
  const S = w.signups || [], seed = gwSeed(w);
  gwAt = w.starts;
  try {
    const r = withSeed(seed, () => {
      const A = gwSide(w.atk.ch, [w.atk.ch, ...S.filter((s) => s.side === "a").map((s) => s.cid)]);
      const D = w.def.bot ? gwBots(w.def.bot) : gwSide(w.def.ch, S.filter((s) => s.side === "d").map((s) => s.cid));
      return { A: A.map(gwSnap), D: D.map(gwSnap) };
    });
    const duels = withSeed(seed + 1, () => gwRelay(r.A, r.D));
    const atkWon = !r.D.length ? r.A.length > 0 : duels.length ? duels[duels.length - 1].win && duels.filter((d) => d.win).length >= r.D.length : false;
    return { ...r, atkWon, w: duels.filter((d) => d.win).length, l: duels.filter((d) => !d.win).length, empty: !r.D.length, srv: VERSION };
  } finally { gwAt = 0; }
}
async function gwar(user, b) {
  const { data: w, error } = await admin.from("guild_wars").select("*").eq("id", b.war).maybeSingle();
  if (error) throw error;
  if (!w) return J({ error: "Nincs ilyen céhharc." }, 404);
  if (w.status === "done") return J({ result: w.result });
  if (Date.parse(w.starts_at) > Date.now()) return J({ error: "Ez a céhharc még nem kezdődött el." }, 409);
  const { data: S, error: se } = await admin.from("guild_war_signups").select("char_id,side").eq("war_id", w.id);
  if (se) throw se;
  const ids = [...new Set([w.atk_ch, w.def_ch, ...(S || []).map((s) => s.char_id)].filter(Boolean))];
  CHARS = {};
  for (const r of await loadChars(ids)) if (!r.suspect && r.data) CHARS[r.id] = toChar(r);
  const W = { id: w.id, atk: { ch: w.atk_ch }, def: { ch: w.def_ch, bot: w.def_bot || null }, starts: Date.parse(w.starts_at),
    signups: (S || []).map((s) => ({ cid: s.char_id, side: s.side })) };
  const result = resolveWar(W);
  const { data: up, error: ue } = await admin.from("guild_wars").update({ status: "done", result }).eq("id", w.id).eq("status", "pending").select("result");
  if (ue) throw ue;
  if (!up || !up.length) { const { data: again } = await admin.from("guild_wars").select("result").eq("id", w.id).maybeSingle(); return J({ result: again && again.result }); }
  return J({ result });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: ud, error: ae } = await admin.auth.getUser(token);
    const user = ud && ud.user;
    if (ae || !user) return J({ error: "Jelentkezz be újra." }, 401);
    const b = await req.json().catch(() => ({}));
    if (b.action === "arena") return await arena(user, b);
    if (b.action === "gwar") return await gwar(user, b);
    if (b.action === "ping") return J({ ok: true, v: VERSION });
    return J({ error: "Ismeretlen kérés." }, 400);
  } catch (e) {
    console.error(e);
    return J({ error: "Szerverhiba, próbáld újra." }, 500);
  }
});
