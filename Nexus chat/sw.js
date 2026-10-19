/* NEXUS CHAT service worker: push notifications + installable app shell */
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));

self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { title: "NEXUS CHAT", body: e.data ? e.data.text() : "" }; }
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    // the open, focused app already shows the message itself
    if (wins.some(w => w.visibilityState === "visible" && w.focused)) return;
    await self.registration.showNotification(d.title || "NEXUS CHAT", {
      body: d.body || "",
      icon: "icon-192.png",
      badge: "icon-192.png",
      tag: d.tag || "nexus",
      renotify: true,
      data: { peer: d.peer || null, kind: d.kind || "message" },
      vibrate: d.kind === "call" ? [300, 150, 300, 150, 300] : [120]
    });
  })());
});

self.addEventListener("notificationclick", e => {
  e.notification.close();
  const peer = e.notification.data && e.notification.data.peer;
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    if (wins.length) {
      const w = wins[0];
      await w.focus();
      if (peer) w.postMessage({ type: "open-chat", peer });
      return;
    }
    await self.clients.openWindow("./" + (peer ? "?chat=" + encodeURIComponent(peer) : ""));
  })());
});
