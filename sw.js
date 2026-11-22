// Moe's Songbook service worker.
// App page and songs.json: network first (so updates arrive), cached copy when offline.
// Libraries, fonts, OCR data: cache first.
const CACHE='moesongbook-v9';
const SHELL=['./','index.html','manifest.json','icon.svg'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL)).then(()=>self.skipWaiting()))});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',e=>{
  const req=e.request;if(req.method!=='GET')return;
  const url=new URL(req.url),same=url.origin===location.origin;
  const netFirst=same&&(req.mode==='navigate'||/\/$|\.html$|songs\.json$|manifest\.json$/.test(url.pathname));
  if(netFirst){e.respondWith(fetch(req).then(r=>{const cp=r.clone();caches.open(CACHE).then(c=>c.put(req,cp));return r}).catch(()=>caches.match(req,{ignoreSearch:true}).then(h=>h||caches.match('index.html'))));return}
  e.respondWith(caches.match(req).then(hit=>hit||fetch(req).then(r=>{if(r.ok||r.type==='opaque'){const cp=r.clone();caches.open(CACHE).then(c=>c.put(req,cp))}return r})));
});
