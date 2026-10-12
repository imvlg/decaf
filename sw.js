const VERSION = "decaf-v1";
const SHELL_CACHE = VERSION + "-shell";
const RUNTIME_CACHE = VERSION + "-runtime";
const TILE_CACHE = "decaf-tiles-v1";
const TILE_LIMIT = 600;

const SHELL = [
  "./",
  "./index.html",
  "./manifest.webmanifest",
  "./supabase-config.js",
  "./de-caf-logo.png",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./assets/drinks/filter.svg",
  "./assets/drinks/latte.png",
  "./assets/drinks/cappuccino.png",
  "./assets/drinks/flat-white.png",
  "./assets/drinks/americano.png",
  "./assets/drinks/espresso.png"
];

const CDN_HOSTS = ["cdn.jsdelivr.net", "fonts.googleapis.com", "fonts.gstatic.com"];
const TILE_HOST = "tile.openstreetmap.org";

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(SHELL_CACHE)
      .then((cache) => Promise.all(SHELL.map((url) => cache.add(url).catch(() => {}))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys
        .filter((key) => key.startsWith("decaf-") && key !== SHELL_CACHE && key !== RUNTIME_CACHE && key !== TILE_CACHE)
        .map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

const cacheable = (response) => response && (response.ok || response.type === "opaque");

async function networkFirst(request, cacheName, fallbackUrl) {
  const cache = await caches.open(cacheName);
  try {
    const response = await fetch(request);
    if (response.ok) cache.put(fallbackUrl || request, response.clone());
    return response;
  } catch (error) {
    const cached = await cache.match(fallbackUrl || request, { ignoreSearch: true }) ||
      await caches.match(fallbackUrl || request, { ignoreSearch: true });
    if (cached) return cached;
    throw error;
  }
}

async function staleWhileRevalidate(event, cacheName) {
  const { request } = event;
  const cache = await caches.open(cacheName);
  const cached = await cache.match(request) || await caches.match(request);
  const network = fetch(request)
    .then((response) => {
      if (cacheable(response)) cache.put(request, response.clone());
      return response;
    })
    .catch(() => cached);
  if (cached) {
    event.waitUntil(network);
    return cached;
  }
  return network;
}

let trimming = false;
async function trimTiles() {
  if (trimming) return;
  trimming = true;
  try {
    const cache = await caches.open(TILE_CACHE);
    const keys = await cache.keys();
    const extra = keys.length - TILE_LIMIT;
    for (let i = 0; i < extra; i += 1) await cache.delete(keys[i]);
  } finally {
    trimming = false;
  }
}

async function tileFirst(event) {
  const { request } = event;
  const cache = await caches.open(TILE_CACHE);
  const cached = await cache.match(request);
  if (cached) return cached;
  const response = await fetch(request);
  if (response.ok) {
    event.waitUntil(cache.put(request, response.clone()).then(trimTiles));
  }
  return response;
}

self.addEventListener("fetch", (event) => {
  const { request } = event;
  if (request.method !== "GET") return;
  const url = new URL(request.url);

  if (request.mode === "navigate" && url.origin === self.location.origin) {
    event.respondWith(networkFirst(request, SHELL_CACHE, "./index.html"));
    return;
  }

  if (url.origin === self.location.origin) {
    if (url.pathname.endsWith("/supabase-config.js") || url.pathname.endsWith("/sw.js")) {
      event.respondWith(networkFirst(request, SHELL_CACHE));
    } else {
      event.respondWith(staleWhileRevalidate(event, SHELL_CACHE));
    }
    return;
  }

  if (url.hostname.endsWith(TILE_HOST)) {
    event.respondWith(tileFirst(event));
    return;
  }

  if (CDN_HOSTS.includes(url.hostname)) {
    event.respondWith(staleWhileRevalidate(event, RUNTIME_CACHE));
  }
  // Supabase, Overpass and everything else go straight to the network.
});
