/*
 * sw.js: offline cache for Daily Expenses.
 * Bump CACHE whenever you change ANY file. The app then shows "A new version is ready"
 * and switches over only when you tap Update now, so an entry in progress is never lost.
 * If you add a file, add it to ASSETS too.
 */
const CACHE = 'daily-expenses-v2';
const ASSETS = [
  './',
  './index.html',
  './styles.css',
  './core.js',
  './store.js',
  './app.js',
  './manifest.webmanifest',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/icon-maskable-512.png',
  './icons/apple-touch-icon.png'
];

self.addEventListener('install', (event) => {
  // cache: 'reload' skips the HTTP cache so a new version never caches stale files.
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(ASSETS.map((url) => new Request(url, { cache: 'reload' }))))
  );
});

self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k.startsWith('daily-expenses-') && k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  // App shell: cache first, so the app opens instantly and offline.
  if (req.mode === 'navigate') {
    event.respondWith(caches.match('./index.html').then((cached) => cached || fetch(req)));
    return;
  }
  event.respondWith(caches.match(req, { ignoreSearch: true }).then((cached) => cached || fetch(req)));
});
