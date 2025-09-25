// sw.js - simple but robust service worker for DriftThreads
const CACHE_VERSION = 'v1.2025.09';
const PRECACHE = `driftthreads-precache-${CACHE_VERSION}`;
const RUNTIME = `driftthreads-runtime-${CACHE_VERSION}`;

// Files to precache (app shell) - edit these to match your site files
const PRECACHE_URLS = [
  '/',
  '/index.html',
  '/home',             // if you use a route '/home' ensure it's an HTML file uploaded or redirected to
  '/styles.css',
  '/main.js',
  '/manifest.json',
  '/icons/icon-192.png',
  '/icons/icon-512.png',
  '/offline.html'
];

// Limits for runtime caches
const IMAGE_CACHE = 'images-cache';
const IMAGE_MAX_ENTRIES = 60;
const IMAGE_MAX_AGE = 30 * 24 * 60 * 60 * 1000; // 30 days

// Install: pre-cache app shell + offline page
self.addEventListener('install', event => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(PRECACHE).then(cache => cache.addAll(PRECACHE_URLS))
  );
});

// Activate: clean up old caches
self.addEventListener('activate', event => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(
        keys
          .filter(key => key !== PRECACHE && key !== RUNTIME && !key.startsWith('images-cache'))
          .map(key => caches.delete(key))
      );
      await self.clients.claim();
    })()
  );
});

// Helper: limit cache size (LRU-ish)
async function trimCache(cacheName, maxEntries) {
  const cache = await caches.open(cacheName);
  const requests = await cache.keys();
  if (requests.length > maxEntries) {
    const deleteCount = requests.length - maxEntries;
    for (let i = 0; i < deleteCount; i++) {
      await cache.delete(requests[i]);
    }
  }
}

// Fetch handler
self.addEventListener('fetch', event => {
  const { request } = event;

  // Only handle GET requests
  if (request.method !== 'GET') return;

  const url = new URL(request.url);

  // Bypass cross-origin requests for most caching decisions (except images we might cache)
  const isSameOrigin = url.origin === self.location.origin;

  // 1) Navigation requests (HTML) -> Network-first, fallback to cache/offline page
  if (request.mode === 'navigate') {
    event.respondWith(
      (async () => {
        try {
          const networkResponse = await fetch(request);
          // Update runtime cache with the fresh HTML for future offline navigation
          const cache = await caches.open(RUNTIME);
          cache.put(request, networkResponse.clone());
          return networkResponse;
        } catch (err) {
          const cache = await caches.match(request);
          if (cache) return cache;
          const fallback = await caches.match('/offline.html');
          return fallback || Response.error();
        }
      })()
    );
    return;
  }

  // 2) Static resources (CSS/JS) -> Cache-first (precache has most)
  if (request.destination === 'style' || request.destination === 'script' || request.destination === 'worker') {
    event.respondWith(
      caches.match(request).then(cached => cached || fetch(request).then(res => {
        return caches.open(RUNTIME).then(cache => { cache.put(request, res.clone()); return res; });
      }))
    );
    return;
  }

  // 3) Images -> Cache-first with LRU limit
  if (request.destination === 'image' || /\.(png|jpg|jpeg|webp|avif|gif|svg)$/.test(url.pathname)) {
    event.respondWith(
      caches.match(request).then(cached => {
        if (cached) return cached;
        return fetch(request).then(res => {
          // Only cache successful responses
          if (!res || res.status !== 200 || res.type !== 'basic') return res;
          return caches.open(IMAGE_CACHE).then(async cache => {
            cache.put(request, res.clone());
            // trim cache size (non-strict LRU)
            trimCache(IMAGE_CACHE, IMAGE_MAX_ENTRIES);
            return res;
          });
        }).catch(() => {
          // optionally return a placeholder image from cache
          return caches.match('/icons/icon-192.png');
        });
      })
    );
    return;
  }

  // 4) Other requests: network-first, fallback to cache
  event.respondWith(
    fetch(request)
      .then(res => {
        // Put a copy in the runtime cache
        if (isSameOrigin && res && res.status === 200) {
          const copy = res.clone();
          caches.open(RUNTIME).then(cache => cache.put(request, copy));
        }
        return res;
      })
      .catch(() => caches.match(request))
  );
});
