/* Dark Store CRM — Service Worker
   - ملفات التطبيق (HTML وغيره): من النت الأول، ومن الكاش لو مفيش نت  => أي نسخة جديدة بتظهر فورًا
   - مكتبات CDN (React/Babel/XLSX/Supabase): من الكاش وبتتحدّث في الخلفية => فتح أسرع
   - Supabase (البيانات): دايمًا من النت ومبنخزنش منها أي حاجة */
const VERSION = 'dark-store-crm-v1';
const SHELL = ['./', 'index.html', 'manifest.webmanifest', 'icon-192.png', 'icon-512.png'];
const CDN_HOSTS = ['cdnjs.cloudflare.com', 'cdn.jsdelivr.net'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  if (url.hostname.endsWith('supabase.co')) return;           // البيانات: النت بس

  if (url.origin === location.origin) {                        // ملفات التطبيق: النت الأول
    e.respondWith(
      fetch(req, { cache: 'no-cache' })
        .then(res => {
          if (res.ok) { const copy = res.clone(); caches.open(VERSION).then(c => c.put(req, copy)); }
          return res;
        })
        .catch(() => caches.match(req).then(hit => hit || caches.match('index.html')))
    );
    return;
  }

  if (CDN_HOSTS.includes(url.hostname)) {                      // المكتبات: كاش + تحديث بالخلفية
    e.respondWith(
      caches.match(req).then(hit => {
        const net = fetch(req).then(res => {
          if (res.ok) { const copy = res.clone(); caches.open(VERSION).then(c => c.put(req, copy)); }
          return res;
        }).catch(() => hit);
        return hit || net;
      })
    );
  }
});
