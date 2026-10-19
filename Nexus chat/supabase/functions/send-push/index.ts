// Supabase Edge Function: sends Web Push when a message or an incoming call is created.
// Triggered by two Database Webhooks (messages INSERT, call_signals INSERT). See SETUP.md.
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com",
  Deno.env.get("VAPID_PUBLIC_KEY")!,
  Deno.env.get("VAPID_PRIVATE_KEY")!,
);

const LABEL: Record<string, string> = {
  image: "📷 Photo", video: "🎥 Video", audio: "🎤 Voice message", sticker: "🙂 Sticker", file: "📄 File",
};

Deno.serve(async (req) => {
  if (req.headers.get("x-webhook-secret") !== Deno.env.get("WEBHOOK_SECRET")) {
    return new Response("forbidden", { status: 401 });
  }
  let body: any;
  try { body = await req.json(); } catch { return new Response("bad json", { status: 400 }); }
  if (body.type !== "INSERT" || !body.record) return Response.json({ skipped: "not insert" });

  const rec = body.record;
  let toId: string, fromId: string, text: string, kind = "message";

  if (body.table === "messages") {
    if (rec.type === "call" || rec.deleted) return Response.json({ skipped: "call row" });
    toId = rec.recipient_id; fromId = rec.sender_id;
    text = rec.type === "text" ? String(rec.text ?? "").slice(0, 140) : (LABEL[rec.type] ?? "New message");
  } else if (body.table === "call_signals") {
    if (rec.kind !== "offer") return Response.json({ skipped: "not offer" });
    toId = rec.to_id; fromId = rec.from_id; kind = "call";
    text = rec.payload?.video ? "📹 Incoming video call" : "📞 Incoming voice call";
  } else {
    return Response.json({ skipped: "unknown table" });
  }

  const [{ data: sender }, { data: subs }] = await Promise.all([
    supabase.from("profiles").select("first_name,last_name,email").eq("id", fromId).maybeSingle(),
    supabase.from("push_subscriptions").select("id,endpoint,p256dh,auth").eq("user_id", toId),
  ]);
  const name = [sender?.first_name, sender?.last_name].filter(Boolean).join(" ") || sender?.email || "NEXUS CHAT";
  const payload = JSON.stringify({ title: name, body: text, peer: fromId, kind, tag: `${kind}-${fromId}` });

  let sent = 0;
  const dead: string[] = [];
  await Promise.all((subs ?? []).map(async (s) => {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        payload,
        { TTL: kind === "call" ? 30 : 86400, urgency: kind === "call" ? "high" : "normal" },
      );
      sent++;
    } catch (e: any) {
      if (e?.statusCode === 404 || e?.statusCode === 410) dead.push(s.id);
      else console.error("push failed", e?.statusCode, e?.body);
    }
  }));
  if (dead.length) await supabase.from("push_subscriptions").delete().in("id", dead);
  return Response.json({ sent, removed: dead.length });
});
