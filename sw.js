// Service worker : coquille hors-ligne. Les appels API (relay.php) ne sont
// JAMAIS mis en cache. La navigation est "réseau d'abord" pour récupérer
// les mises à jour de la PWA immédiatement.
const CACHE = "cockpit-shell-v5";
const SHELL = ["./", "index.html", "manifest.webmanifest",
               "icons/icon-192.png", "icons/icon-512.png", "icons/apple-touch-icon.png"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys =>
    Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
  ).then(() => self.clients.claim()));
});

self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET") return;                 // POST relay.php → réseau direct
  if (url.searchParams.has("f")) return;                   // GET relay.php?f=… → réseau direct
  if (url.searchParams.has("auth")) return;                // flux Google → réseau direct
  if (url.pathname.endsWith("version.json")) return;       // vérif de version (cockpit + prisme) → réseau direct
  if (url.pathname.endsWith(".dmg")) return;               // téléchargements → réseau direct

  // Navigation / HTML : réseau d'abord, cache en secours.
  if (e.request.mode === "navigate" || url.pathname.endsWith("index.html") || url.pathname.endsWith("/")) {
    e.respondWith(
      fetch(e.request).then(res => {
        if (res.ok && url.origin === location.origin) {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put("index.html", copy));
        }
        return res;
      }).catch(() => caches.match("index.html"))
    );
    return;
  }

  // Autres ressources (icônes, manifest) : cache d'abord.
  e.respondWith(
    caches.match(e.request).then(hit => hit || fetch(e.request).then(res => {
      if (res.ok && url.origin === location.origin) {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(e.request, copy));
      }
      return res;
    }).catch(() => caches.match("index.html")))
  );
});
