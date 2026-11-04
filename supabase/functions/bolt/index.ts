// @ts-nocheck
/* Éjjeli Járat – pogácsabolt (Supabase Edge Function, a neve: bolt)
   1) A játék innen kér egy Stripe fizetési oldalt (bejelentkezett játékos, kiválasztott csomag).
   2) A Stripe ide szól vissza (webhook), ha a fizetés sikerült: ekkor kapja meg a hős a pogácsát.
   Titkos kulcsok (Supabase -> Edge Functions -> Secrets): STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET
   Telepítéskor a "Verify JWT" legyen KIKAPCSOLVA, mert a Stripe nem tud bejelentkezni; a játékost itt ellenőrizzük. */
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

// a csomagok árát csak itt lehet megadni (a játék nem küldhet saját árat)
export const PACKS = {
  p10:  { pog: 10,  huf: 990 },
  p30:  { pog: 30,  huf: 2490 },
  p80:  { pog: 80,  huf: 5990 },
  p200: { pog: 200, huf: 12990 },
};
const SITE = Deno.env.get("SITE_URL") || "https://nightlinebudapest.com/";
const TAX_CODE = Deno.env.get("STRIPE_TAX_CODE") || "txcd_10000000";   // elektronikusan nyújtott szolgáltatás
const MAX_OPEN_PER_HOUR = 10;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const J = (o, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
let _admin = null;
const admin = () => _admin || (_admin = createClient(
  Deno.env.get("SUPABASE_URL"),
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("SUPABASE_SECRET_KEY"),
  { auth: { persistSession: false, autoRefreshToken: false } },
));

/* ---------- Stripe hívás, SDK nélkül ---------- */
export function form(obj, pre = "", out = []) {
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined || v === null) continue;
    const key = pre ? `${pre}[${k}]` : k;
    if (typeof v === "object") form(v, key, out);
    else out.push(encodeURIComponent(key) + "=" + encodeURIComponent(String(v)));
  }
  return out.join("&");
}
async function stripe(path, body) {
  const key = Deno.env.get("STRIPE_SECRET_KEY");
  if (!key) throw new Error("STRIPE_SECRET_KEY hiányzik");
  const r = await fetch("https://api.stripe.com/v1/" + path, {
    method: "POST",
    headers: { Authorization: "Bearer " + key, "Content-Type": "application/x-www-form-urlencoded", "Stripe-Version": "2025-03-31.basil" },
    body: form(body),
  });
  const j = await r.json();
  if (!r.ok) throw new Error((j.error && j.error.message) || "Stripe hiba " + r.status);
  return j;
}

/* ---------- webhook aláírás ellenőrzése (Stripe-Signature: t=...,v1=...) ---------- */
const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
export async function verifySig(raw, header, secret, nowSec = Math.floor(Date.now() / 1000), tol = 300) {
  if (!header || !secret) return false;
  let t = null; const v1 = [];
  for (const p of header.split(",")) { const [k, v] = p.split("="); if (k === "t") t = v; if (k === "v1") v1.push(v); }
  if (!t || !v1.length || Math.abs(nowSec - Number(t)) > tol) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = hex(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${t}.${raw}`)));
  return v1.some((s) => s.length === sig.length && [...s].reduce((a, c, i) => a | (c.charCodeAt(0) ^ sig.charCodeAt(i)), 0) === 0);
}

/* ---------- 1) fizetési oldal kérése a játékból ---------- */
async function checkout(req) {
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: ud, error: ae } = await admin().auth.getUser(token);
  const user = ud && ud.user;
  if (ae || !user) return J({ error: "Jelentkezz be újra." }, 401);
  const b = await req.json().catch(() => ({}));
  if (b.action === "ping") return J({ ok: true, packs: PACKS });
  if (b.action !== "checkout") return J({ error: "Ismeretlen kérés." }, 400);
  // tesztüzemben (sk_test_ kulcs) csak a STRIPE_TEST_USERS listában lévő e-mail-címek vásárolhatnak,
  // különben bárki ingyen pogácsát szerezhetne a Stripe tesztkártyájával
  const key = Deno.env.get("STRIPE_SECRET_KEY") || "";
  if (!key) return J({ error: "A pogácsabolt hamarosan nyílik." }, 503);
  if (key.startsWith("sk_test_") || key.startsWith("rk_test_")) {
    const allow = (Deno.env.get("STRIPE_TEST_USERS") || "").toLowerCase().split(",").map((x) => x.trim()).filter(Boolean);
    if (!allow.includes(String(user.email || "").toLowerCase())) return J({ error: "A pogácsabolt hamarosan nyílik." }, 403);
  }
  const pk = PACKS[b.pack];
  if (!pk) return J({ error: "Nincs ilyen csomag." }, 400);
  if (b.consent !== true) return J({ error: "A vásárláshoz el kell fogadnod a feltételeket." }, 400);
  const { data: ch } = await admin().from("characters").select("id,name,user_id,suspect").eq("id", String(b.char || "")).maybeSingle();
  if (!ch || ch.user_id !== user.id) return J({ error: "Ez a hős nem a tiéd." }, 403);
  const { count } = await admin().from("purchases").select("id", { count: "exact", head: true })
    .eq("user_id", user.id).gte("created_at", new Date(Date.now() - 3600e3).toISOString());
  if ((count || 0) >= MAX_OPEN_PER_HOUR) return J({ error: "Túl sok próbálkozás, próbáld újra egy óra múlva." }, 429);
  const en = b.lang === "en";
  const name = en ? `${pk.pog} magic scones` : `${pk.pog} bűvös pogácsa`;
  const s = await stripe("checkout/sessions", {
    mode: "payment",
    managed_payments: { enabled: true },
    customer_email: user.email || undefined,
    client_reference_id: user.id,
    locale: en ? "en" : "hu",
    line_items: { 0: { quantity: 1, price_data: {
      currency: "huf", unit_amount: pk.huf * 100, tax_behavior: "inclusive",   // a forintot a Stripe fillérben kéri
      product_data: { name, description: en ? `For your hero ${ch.name} in Night Line: Budapest` : `${ch.name} nevű hősödnek az Éjjeli Járatban`, tax_code: TAX_CODE },
    } } },
    metadata: { user_id: user.id, char_id: ch.id, pack: b.pack, pog: pk.pog },
    payment_intent_data: { metadata: { user_id: user.id, char_id: ch.id, pack: b.pack } },
    success_url: SITE + "?fizetes=ok",
    cancel_url: SITE + "?fizetes=megse",
  });
  const { error: ie } = await admin().from("purchases").insert({
    session_id: s.id, user_id: user.id, char_id: ch.id, char_name: ch.name, pack: b.pack, pog: pk.pog, amount: pk.huf, currency: "huf", livemode: !!s.livemode,
  });
  if (ie) throw ie;
  return J({ ok: true, url: s.url });
}

/* ---------- 2) a Stripe értesítése ---------- */
async function webhook(req) {
  const raw = await req.text();
  const ok = await verifySig(raw, req.headers.get("Stripe-Signature"), Deno.env.get("STRIPE_WEBHOOK_SECRET"));
  if (!ok) return J({ error: "bad signature" }, 400);
  const ev = JSON.parse(raw);
  const o = ev.data && ev.data.object || {};
  const t = ev.type;
  if ((t === "checkout.session.completed" && o.payment_status === "paid") || t === "checkout.session.async_payment_succeeded") {
    const { data, error } = await admin().rpc("purchase_fulfill", { sid: o.id, pi: o.payment_intent || null, live: !!ev.livemode });
    if (error) throw error;
    return J({ received: true, ...data });
  }
  if (t === "checkout.session.expired" || t === "checkout.session.async_payment_failed") {
    await admin().from("purchases").update({ status: "expired" }).eq("session_id", o.id).eq("status", "open");
    return J({ received: true });
  }
  if (t === "charge.refunded" || t === "charge.dispute.created") {
    const pi = o.payment_intent;
    if (pi) { const { error } = await admin().rpc("purchase_reverse", { pi, st: t === "charge.refunded" ? "refunded" : "disputed" }); if (error) throw error; }
    return J({ received: true });
  }
  return J({ received: true, ignored: t });
}

if (typeof Deno !== "undefined" && Deno.serve) Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    if (req.headers.get("Stripe-Signature")) return await webhook(req);
    return await checkout(req);
  } catch (e) {
    console.error(e);
    return J({ error: "Szerverhiba, próbáld újra." }, 500);
  }
});
