// Éjjeli Járat service worker: the game always tries the network first, so updates arrive at once;
// the cached copy is only used when the phone is offline.
const CACHE='ejjeli-20261102-1709';
const SHELL=['./','./index.html','./config.js','./manifest.webmanifest','./icon-192.png','./icon-512.png',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js'];
self.addEventListener('install',e=>{ self.skipWaiting(); e.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL).catch(()=>{}))); });
self.addEventListener('activate',e=>{ e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())); });
self.addEventListener('fetch',e=>{
  const r=e.request, u=new URL(r.url);
  if(r.method!=='GET'||u.hostname.endsWith('supabase.co')) return;   // game data always live
  e.respondWith(fetch(r).then(res=>{ if(res.ok&&(u.origin===location.origin||u.hostname==='cdn.jsdelivr.net')){ const c=res.clone(); caches.open(CACHE).then(x=>x.put(r,c)); } return res; })
    .catch(()=>caches.match(r).then(m=>m||(r.mode==='navigate'?caches.match('./index.html'):undefined))));
});
