'use strict';
/* Halaman: dokumentasi API — dibaca dari /api/openapi (selalu sinkron dengan router). */

function curlOf(e) {
  const base = location.origin;
  const path = e.path.replace(/\{[^}]+\}/g, 'CONTOH');
  const pub = /^\/api\/(login|logout|session|panel|openapi)/.test(e.path);
  const me = e.path.startsWith('/api/me');
  const auth = pub ? "-c cookie.txt -b cookie.txt -H 'X-Requested-With: vpsnat'"
    : me ? "-b cookie.txt -H 'X-Requested-With: vpsnat'"
    : '-H "Authorization: Bearer $KEY"';
  const body = e.example ? ` -H 'Content-Type: application/json' -d '${e.example}'` : '';
  return `curl${e.method === 'GET' ? '' : ' -X ' + e.method} ${auth}${body} ${base}${path}`;
}

function epHtml(e) {
  const curl = curlOf(e);
  const search = (e.method + ' ' + e.path + ' ' + e.summary).toLowerCase();
  return `<details class="ep" data-s="${esc(search)}"><summary>
      <span class="mth m-${e.method}">${e.method}</span><span class="pth">${esc(e.path)}</span>
      <span class="sd">${esc(e.summary)}</span></summary><div class="bd">
    <p>${esc(e.summary)}</p>
    <p class="mut" style="font-size:12px">Akses: <b>${esc(e.role)}</b>${e.undocumented ? ' · <span class="warnt">belum ada deskripsi rinci</span>' : ''}</p>
    ${e.fields && e.fields.length ? `<div class="tw"><table><tr><th>Field</th><th>Tipe</th><th>Wajib</th><th>Keterangan</th></tr>${
      e.fields.map(f => `<tr><td><code>${esc(f[0])}</code></td><td>${esc(f[1])}</td><td>${esc(f[2])}</td><td class="wrap">${esc(f[3])}</td></tr>`).join('')
    }</table></div>` : ''}
    <button class="sm sec cp" data-a="copy" data-t="${esc(curl)}">${ic('copy')} Salin curl</button>
    <pre>${esc(curl)}</pre>
    ${e.note ? `<p class="mut" style="margin:8px 0 0">${esc(e.note)}</p>` : ''}</div></details>`;
}

function render(d) {
  const auth = Object.entries(d.auth);
  const codes = Object.entries(d.codes);
  $('#app').innerHTML = `
    <div class="top"><h1>API</h1><button class="sec" data-a="refresh">${ic('refresh')} Refresh</button></div>
    <div class="card">
      <h2>Dasar</h2>
      <p class="lead">Semua endpoint di bawah <code>/api/</code>. Panel ini mendokumentasikan ${d.counts.routes} endpoint dan ${d.counts.pages} halaman.</p>
      <div class="kv">${auth.map(([k, v]) => `<span>${esc(k)}</span><span>${esc(v).replace(/`([^`]+)`/g, '<code>$1</code>')}</span>`).join('')}</div>
      <h3 style="margin-top:16px">Kode status</h3>
      <div class="tw"><table style="min-width:420px"><tr><th>Kode</th><th>Arti</th></tr>${
        codes.map(([c, v]) => `<tr><td><code>${esc(c)}</code></td><td class="wrap">${esc(v)}</td></tr>`).join('')}</table></div>
      <h3 style="margin-top:16px">Mulai cepat</h3>
      <pre>export KEY=&lt;WEB_API_KEY&gt;   # ambil dengan: vpsnat web key
curl -H "Authorization: Bearer $KEY" ${esc(location.origin)}/api/admin/dashboard
curl -H "Authorization: Bearer $KEY" ${esc(location.origin)}/api/admin/servers</pre>
      <div class="row" style="margin-top:10px"><button class="sec" data-a="flow">${ic('book')} Alur lengkap buat server</button></div>
      <pre id="flow" hidden></pre>
    </div>
    <div class="card"><input id="apiq" class="apisrch" type="search" placeholder="Cari endpoint… (mis. bandwidth, node, delete)" autocomplete="off" aria-label="Cari endpoint">
      <div id="eps">${d.endpoints.map(epHtml).join('')}</div></div>
    <div class="foot">${esc(S.brand)} · VPSNAT ${esc(S.version || '')} Panel · API v${esc(d.version || '')}</div>`;
}

async function load() {
  try { render(await api('GET', '/api/openapi')); }
  catch (e) { toast(e.message, true); }
}

async function pageInit() {
  setNav();
  if (S.role !== 'admin') { location.href = S.role === 'user' ? '/account' : '/login'; return; }
  await load();
}

window.PAGE_ACTIONS = {
  refresh: () => load(),
  flow: b => act(b, async () => {
    const d = await api('POST', '/api/openapi/example', {});
    const el = $('#flow'); el.hidden = false; el.textContent = d.example;
  }),
};
window.PAGE_INPUT = e => {
  if (e.target.id !== 'apiq') return;
  const q = e.target.value.trim().toLowerCase();
  $$('.ep').forEach(el => { el.hidden = !!q && !el.dataset.s.includes(q); });
};
