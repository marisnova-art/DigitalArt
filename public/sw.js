/* =====================================================================
   MarisNova — Service Worker
   · 배포 시 sw.js 내용을 바꿨다면 VERSION 을 올리세요 → 사용자에게 "새 버전" 배너가 뜹니다.
   · index.html 자체는 네트워크 우선이라 VERSION 을 올리지 않아도 온라인 사용자에게 바로 반영됩니다.
   ===================================================================== */
const VERSION = 'mn-2026-10-01.1';
const SHELL = `${VERSION}-shell`;      // 앱 셸 (index, offline, manifest, icons)
const STATIC = `${VERSION}-static`;    // 폰트·라이브러리·동일 출처 정적 파일
const MEDIA = 'mn-media';              // 공개 작품 이미지 (버전 간 유지)
const MEDIA_MAX = 300;                 // 이미지 캐시 최대 개수
const STATIC_MAX = 80;
const NAV_TIMEOUT = 4000;              // 느린 네트워크에서 캐시된 셸로 전환하기까지 대기(ms)

const SHELL_URL = '/';
const OFFLINE_URL = '/offline.html';
const PRECACHE = [
  SHELL_URL, OFFLINE_URL, '/manifest.webmanifest',
  '/icons/icon-192.png', '/icons/icon-512.png', '/icons/maskable-512.png', '/icons/apple-touch-icon.png', '/icons/favicon-32.png'
];
// 실패해도 설치를 막지 않는 워밍 대상 (외부)
const WARM = [
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js',
  'https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=Space+Grotesk:wght@500;600;700&display=swap'
];

/* Cloudflare Pages 의 pretty URL(/offline.html → /offline) 같은 리다이렉트 응답은
   내비게이션 응답으로 재사용할 수 없으므로 본문만 복사해 깨끗한 Response 로 저장 */
async function clean(res) {
  if (!res || !res.redirected) return res;
  const body = await res.blob();
  return new Response(body, { status: res.status, statusText: res.statusText, headers: res.headers });
}

/* no-cors 로 요청된 외부 리소스(<img>, <link>, <script>)를 CORS 로 다시 받아
   opaque 응답(용량 패딩·상태 확인 불가) 캐싱을 피함. 실패 시 원 요청으로 폴백 */
async function corsFetch(req) {
  if (req.mode === 'no-cors') {
    try { return await fetch(req.url, { mode: 'cors', credentials: 'omit', referrerPolicy: req.referrerPolicy }); }
    catch { /* CORS 미지원 → 원 요청 */ }
  }
  return fetch(req);
}
const cacheable = res => res && res.ok && (res.type === 'basic' || res.type === 'cors' || res.type === 'default');

async function trim(name, max) {
  const c = await caches.open(name); const keys = await c.keys();
  for (let i = 0; i < keys.length - max; i++) await c.delete(keys[i]);
}

self.addEventListener('install', e => {
  e.waitUntil((async () => {
    const c = await caches.open(SHELL);
    await Promise.all(PRECACHE.map(async u => {
      const res = await fetch(u, { cache: 'reload' });
      if (!res.ok) throw new Error(`precache ${u}: ${res.status}`);
      await c.put(u, await clean(res));
    }));
    const s = await caches.open(STATIC);
    await Promise.all(WARM.map(async u => { try { const r = await fetch(u, { mode: 'cors', credentials: 'omit' }); if (cacheable(r)) await s.put(u, r); } catch { /* 선택 사항 */ } }));
    // 첫 설치는 즉시 활성화, 업데이트는 사용자가 "새로고침"을 누를 때까지 대기
    if (!self.registration.active) await self.skipWaiting();
  })());
});

self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    const keep = new Set([SHELL, STATIC, MEDIA]);
    await Promise.all((await caches.keys()).filter(k => k.startsWith('mn-') && !keep.has(k)).map(k => caches.delete(k)));
    if (self.registration.navigationPreload) { try { await self.registration.navigationPreload.enable(); } catch { /* noop */ } }
    await self.clients.claim();
  })());
});

self.addEventListener('message', e => {
  if (e.data?.type === 'SKIP_WAITING') self.skipWaiting();
  if (e.data?.type === 'GET_VERSION') e.ports?.[0]?.postMessage(VERSION);
  if (e.data?.type === 'CLEAR_MEDIA') e.waitUntil(caches.delete(MEDIA));
});

/* ---------- 전략 ---------- */
// 내비게이션(SPA 라우트 전부): 네트워크 우선 → 타임아웃/오프라인 시 캐시된 셸 → offline.html
async function handleNav(e) {
  const c = await caches.open(SHELL);
  const network = (async () => {
    const pre = await e.preloadResponse;
    const res = pre || await fetch(e.request);
    // 같은 index.html 이 모든 라우트에 서빙되므로 HTML 200 응답을 셸로 갱신
    if (res.ok && (res.headers.get('content-type') || '').includes('text/html')) {
      c.put(SHELL_URL, await clean(res.clone())).catch(() => {});
    }
    return res;
  })();
  e.waitUntil(network.then(() => {}, () => {}));
  const timeout = new Promise(r => setTimeout(() => r(null), NAV_TIMEOUT));
  try {
    const first = await Promise.race([network, timeout]);
    if (first) return first;
    const cached = await c.match(SHELL_URL);
    if (cached) return cached;
    return await network;
  } catch {
    return (await c.match(SHELL_URL)) || (await c.match(OFFLINE_URL)) ||
      new Response('Offline', { status: 503, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
  }
}

// 캐시 우선 + 백그라운드 갱신 (stale-while-revalidate)
async function swr(e, name, max, fetcher = corsFetch) {
  const c = await caches.open(name);
  const key = e.request.url;
  const cached = await c.match(key);
  const update = fetcher(e.request).then(async res => {
    if (cacheable(res)) { await c.put(key, res.clone()); if (max) trim(name, max); }
    return res;
  });
  if (cached) { e.waitUntil(update.catch(() => {})); return cached; }
  try { return await update; }
  catch { return cached || Response.error(); }
}

// 공개 미디어: 캐시 우선 (URL 이 바뀌면 새 파일이므로 갱신 불필요)
async function cacheFirst(e, name, max) {
  const c = await caches.open(name);
  const cached = await c.match(e.request.url);
  if (cached) return cached;
  const res = await corsFetch(e.request);
  if (cacheable(res)) { e.waitUntil(c.put(e.request.url, res.clone()).then(() => trim(name, max))); }
  return res;
}

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;                 // 업로드·RPC·인증 POST 는 건드리지 않음
  if (req.headers.has('range')) return;             // 영상 부분 요청은 브라우저 기본 처리
  const url = new URL(req.url);
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return;

  // Supabase: 인증·DB·서명 URL·비공개 원본은 절대 캐시하지 않음
  if (url.hostname.endsWith('.supabase.co') || url.pathname.startsWith('/storage/v1/') || url.pathname.startsWith('/rest/v1/') || url.pathname.startsWith('/auth/v1/')) {
    const pub = /^\/storage\/v1\/(object|render\/image)\/public\//.test(url.pathname);
    if (pub && req.destination === 'image') e.respondWith(cacheFirst(e, MEDIA, MEDIA_MAX));
    return;
  }

  if (req.mode === 'navigate') { e.respondWith(handleNav(e)); return; }

  if (url.origin === self.location.origin) {
    if (url.pathname === '/sw.js') return;
    // OAuth 콜백 등 쿼리 붙은 동일 출처 정적 파일은 캐시 키 오염 방지
    if (/\.(png|jpe?g|webp|avif|gif|svg|ico|css|js|woff2?|webmanifest|json)$/i.test(url.pathname)) {
      e.respondWith(swr(e, url.pathname.startsWith('/icons/') || url.pathname === '/manifest.webmanifest' ? SHELL : STATIC, STATIC_MAX, r => fetch(r)));
    }
    return;
  }

  // 폰트 · CDN 라이브러리
  if (url.hostname === 'fonts.googleapis.com' || url.hostname === 'cdn.jsdelivr.net') { e.respondWith(swr(e, STATIC, STATIC_MAX)); return; }
  if (url.hostname === 'fonts.gstatic.com') { e.respondWith(cacheFirst(e, STATIC, STATIC_MAX)); return; }
  // 그 외 외부(유튜브 임베드, 후원 링크 등)는 브라우저 기본 처리
});
