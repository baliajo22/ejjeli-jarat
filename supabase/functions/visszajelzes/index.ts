// Éjjeli Járat – e-mail értesítés új játékos-visszajelzésről
// A Supabase "Database Webhook" hívja meg, amikor új sor kerül a public.feedback táblába.
// Titkok (Edge Functions → Secrets):
//   RESEND_API_KEY        – a Resend API-kulcs (ugyanaz, mint amivel a regisztrációs leveleket küldöd)
//   FEEDBACK_HOOK_SECRET  – egy általad kitalált hosszú, véletlen szöveg; a webhook ugyanezt küldi az x-hook-secret fejlécben
//   FEEDBACK_FROM         – feladó, pl. "Éjjeli Járat <noreply@nightlinebudapest.com>" (a Resendben igazolt domainről)
//   FEEDBACK_TO           – (nem kötelező) címzett; alapból ejjelijarat.support@gmail.com
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const TO = Deno.env.get("FEEDBACK_TO") || "ejjelijarat.support@gmail.com";
const FROM = Deno.env.get("FEEDBACK_FROM") || "Éjjeli Járat <noreply@nightlinebudapest.com>";
const KIND: Record<string, string> = { hiba: "🐞 Hiba", otlet: "💡 Ötlet", egyeb: "💬 Egyéb" };

const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method", { status: 405 });
  const secret = Deno.env.get("FEEDBACK_HOOK_SECRET");
  if (!secret || req.headers.get("x-hook-secret") !== secret) return new Response("forbidden", { status: 403 });

  let body: any;
  try { body = await req.json(); } catch { return new Response("bad json", { status: 400 }); }
  const r = body?.record;
  if (body?.type !== "INSERT" || body?.table !== "feedback" || !r) return new Response("ignored", { status: 200 });

  // a játékos e-mail-címe, hogy válaszolni tudj neki (csak a levélbe kerül, sehova máshova)
  let replyTo: string | undefined;
  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data } = await admin.auth.admin.getUserById(r.user_id);
    const em = data?.user?.email;
    if (em && !em.endsWith(".invalid")) replyTo = em;
  } catch (_) { /* nem baj, ha nincs meg */ }

  const kind = KIND[r.kind] || r.kind;
  const when = new Date(r.created_at || Date.now()).toLocaleString("hu-HU", { timeZone: "Europe/Budapest" });
  const html = `<div style="font-family:system-ui,Arial,sans-serif;max-width:560px">
  <h2 style="margin:0 0 8px">${esc(kind)} – új visszajelzés</h2>
  <p style="margin:0 0 12px;color:#555">${esc(when)} · Hős: <b>${esc(r.char_name || "–")}</b>${r.char_level ? ` (${esc(r.char_level)}. szint)` : ""} · #${esc(r.id)}</p>
  <div style="white-space:pre-wrap;background:#f4f4f7;border-radius:8px;padding:12px 14px;font-size:15px;line-height:1.45">${esc(r.body)}</div>
  <p style="margin:12px 0 0;color:#777;font-size:12px">Eszköz: ${esc(r.device || "–")}<br>Verzió: ${esc(r.build || "–")}</p>
  ${replyTo ? `<p style="margin:12px 0 0;font-size:13px">Erre a levélre válaszolva a játékosnak írsz.</p>` : ""}
  <p style="margin:12px 0 0;color:#999;font-size:12px">Elintézve jelölés: <code>update feedback set done = true where id = ${esc(r.id)};</code></p></div>`;

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { "Authorization": `Bearer ${Deno.env.get("RESEND_API_KEY")}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: FROM, to: [TO], ...(replyTo ? { reply_to: replyTo } : {}),
      subject: `${kind}: ${String(r.body || "").slice(0, 60).replace(/\s+/g, " ")}${String(r.body || "").length > 60 ? "…" : ""}`,
      html,
    }),
  });
  if (!res.ok) { console.error("resend", res.status, await res.text()); return new Response("mail failed", { status: 502 }); }
  return new Response("ok", { status: 200 });
});
