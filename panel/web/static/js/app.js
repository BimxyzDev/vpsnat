'use strict';
/* vpsnat panel — inti UI.
 *
 * Setiap halaman punya berkas HTML + JS sendiri (web/pages/*.html,
 * web/static/js/page-*.js). Berkas ini hanya menyediakan hal yang dipakai semua
 * halaman: sesi, fetch API, toast, format angka/tanggal, ikon, dan nav.
 */
const S = {
  role: null, name: null, brand: 'VPSNAT', logo: '', version: '', uiver: '',
  nodes: [], meta: null, limits: {ports_min: 2, ports_max: 50}, servers: [],
  nodeId: null, server: null, timers: [], pwa: null, offline: false,
  page: (document.body && document.body.dataset.page) || '',
};

const ICONS = {
  out:'<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/>',
  copy:'<rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
  eye:'<path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/>',
  refresh:'<polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/>',
  play:'<polygon points="5 3 19 12 5 21 5 3"/>',
  rotate:'<polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/>',
  stop:'<rect x="4" y="4" width="16" height="16" rx="2" ry="2"/>',
  pause:'<rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/>',
  trash:'<polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6m5 0V4a2 2 0 0 1 2-2h0a2 2 0 0 1 2 2v2"/>',
  plus:'<line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/>',
  server:'<rect x="2" y="2" width="20" height="8" rx="2" ry="2"/><rect x="2" y="14" width="20" height="8" rx="2" ry="2"/><line x1="6" y1="6" x2="6.01" y2="6"/><line x1="6" y1="18" x2="6.01" y2="18"/>',
  x:'<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>',
  download:'<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/>',
  inbox:'<polyline points="22 12 16 12 14 15 10 15 8 12 2 12"/><path d="M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>',
  chip:'<rect x="4" y="4" width="16" height="16" rx="2"/><rect x="9" y="9" width="6" height="6"/><path d="M9 1v3M15 1v3M9 20v3M15 20v3M1 9h3M1 15h3M20 9h3M20 15h3"/>',
  list:'<line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/>',
  cog:'<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.6 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h0a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51h0a1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v0a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>',
  book:'<path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"/>',
  user:'<path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/>',
};
const ic = n => `<svg class="ic" viewBox="0 0 24 24" aria-hidden="true">${ICONS[n] || ''}</svg>`;
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => Array.from(el.querySelectorAll(s));
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const val = id => { const e = document.getElementById(id); return e ? e.value.trim() : ''; };
const num = id => { const e = document.getElementById(id); return e ? Number(e.value) : NaN; };
const mark = () => S.logo ? `<img src="${esc(S.logo)}" alt="">` : ic('server');

/* ---------- format ---------- */
const fb = b => { b = Number(b) || 0; if (b>=1e12) return (b/1e12).toFixed(2)+' TB'; if (b>=1e9) return (b/1e9).toFixed(2)+' GB'; if (b>=1e6) return (b/1e6).toFixed(1)+' MB'; if (b>=1e3) return (b/1e3).toFixed(0)+' KB'; return b+' B'; };
const fdate = e => e ? new Date(e*1000).toLocaleString('id-ID',{dateStyle:'medium',timeStyle:'short'}) : 'Tanpa expired';
const fup = s => { s = Number(s)||0; const d = Math.floor(s/86400), h = Math.floor(s%86400/3600); return d + 'h ' + h + 'j'; };
const fmb = m => { m = Number(m)||0; return m >= 1024 ? (m/1024).toFixed(m % 1024 ? 1 : 0) + ' GB' : m + ' MB'; };
const daysLeft = e => e ? Math.ceil((e*1000 - Date.now())/864e5) : null;
const fexp = e => { if (!e) return '∞'; const d = daysLeft(e); return d < 0 ? 'Expired' : d === 0 ? 'Hari ini' : d + ' hari lagi'; };
const fago = ts => { if (!ts) return 'belum pernah'; const s = Math.max(0, Math.floor(Date.now()/1000) - ts); if (s < 90) return s + 's lalu'; if (s < 5400) return Math.floor(s/60) + 'm lalu'; if (s < 172800) return Math.floor(s/3600) + 'j lalu'; return Math.floor(s/86400) + ' hari lalu'; };
const opts = (list, sel) => list.map(x => `<option value="${esc(x)}"${x === sel ? ' selected' : ''}>${esc(x)}</option>`).join('');

/* ---------- HTTP ---------- */
async function api(method, path, body) {
  let r;
  try {
    r = await fetch(path, {method, credentials: 'same-origin',
      headers: {'Content-Type': 'application/json', 'X-Requested-With': 'vpsnat'},
      body: body === undefined ? undefined : JSON.stringify(body)});
  } catch (e) { const er = new Error('Tidak ada koneksi ke server.'); er.net = true; throw er; }
  let d = {};
  try { d = await r.json(); } catch (e) {}
  if (r.status === 401 && !path.startsWith('/api/login') && S.role) {
    const back = location.pathname;
    location.href = '/login?next=' + encodeURIComponent(back);
    throw new Error('Sesi berakhir.');
  }
  if (!r.ok || d.ok === false) throw new Error(d.error || ('HTTP ' + r.status));
  return d;
}

async function act(btn, fn) {
  if (btn) btn.disabled = true;
  try { return await fn(); }
  catch (e) { toast(e.message, true); }
  finally { if (btn) btn.disabled = false; }
}

function toast(msg, bad) {
  const t = document.createElement('div');
  t.className = 'toast' + (bad ? ' e' : '');
  t.setAttribute('role', bad ? 'alert' : 'status');
  t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), bad ? 6000 : 3200);
}

async function copyText(t) {
  if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(t);
  const ta = document.createElement('textarea');
  ta.value = t; ta.setAttribute('readonly', ''); ta.style.cssText = 'position:fixed;top:0;left:0;opacity:0';
  document.body.appendChild(ta); ta.select();
  let ok = false;
  try { ok = document.execCommand('copy'); } catch (e) {}
  ta.remove();
  if (!ok) throw new Error('copy gagal');
}

/* ---------- nav ---------- */
const NAV = {
  admin: [['/', 'Dashboard', 'chip'], ['/servers', 'Server', 'server'], ['/jobs', 'Job', 'list'], ['/settings', 'Setting', 'cog'], ['/api-docs', 'API', 'book']],
  user: [['/account', 'Server saya', 'server']],
};
function setNav(right) {
  const items = NAV[S.role] || [];
  const here = location.pathname;
  const links = items.map(([href, label, icon]) => {
    const on = href === '/' ? here === '/' : here.startsWith(href);
    return `<a href="${href}" class="${on ? 'on' : ''}">${ic(icon)} ${esc(label)}</a>`;
  }).join('');
  $('#nav').innerHTML = `<div class="nav"><div class="in">
    <a class="logo" href="/" style="text-decoration:none;color:inherit"><span class="mk">${mark()}</span>
      <span>${esc(S.brand)}${S.role ? ` <small>${S.role === 'admin' ? 'Panel' : 'Client'}</small>` : ''}</span></a>
    <div class="row"><div class="menu">${links}</div>${installBtn()}
      ${S.role ? `<button class="sec sm" data-a="logout">${ic('out')} Keluar</button>` : ''}</div>
  </div></div>`;
  syncInstall();
}
const installBtn = () => `<button class="sec sm" data-a="install" data-install hidden>${ic('download')} Pasang</button>`;

/* ---------- job tracking ---------- */
function track(jobId, logSel, done) {
  const log = logSel ? $(logSel) : null;
  const tick = async () => {
    try {
      const {job} = await api('GET', '/api/jobs/' + jobId);
      if (log) { log.hidden = false; log.textContent = `[${job.kind} ${job.name}] ${job.status.toUpperCase()}\n` + (job.output || ''); }
      if (job.status === 'running') return setTimeout(tick, 3000);
      toast(`${job.kind} ${job.name}: ${job.status}`, job.status !== 'done');
      if (done) done(job);
    } catch (e) {
      if (e.net) return setTimeout(tick, 5000);
      toast(e.message, true);
    }
  };
  setTimeout(tick, 1500);
}

/* ---------- komponen ---------- */
function bar(label, pct, sub) {
  const p = pct == null ? 0 : Math.max(0, Math.min(100, pct));
  return `<div class="m"><div class="mh"><span>${esc(label)}</span><span>${esc(sub)}</span></div><div class="bar"><i class="${p>=90?'hi':p>=70?'md':''}" style="width:${p}%"></i></div></div>`;
}

function resHtml(r) {
  const bw = (r && r.bw) || {};
  const bwBar = bw.quota > 0
    ? bar('Bandwidth', bw.used / bw.quota * 100, fb(bw.used) + ' / ' + fb(bw.quota) + (bw.exhausted ? ' · HABIS' : ''))
    : `<div class="m"><div class="mh"><span>Bandwidth</span><span>${fb(bw.used)} · unlimited</span></div></div>`;
  return bar('CPU', r.cpu.pct, r.cpu.pct == null ? 'mengukur…' : r.cpu.pct + '% · ' + r.cpu.cores + ' core')
    + bar('RAM', r.ram.pct, fb(r.ram.used) + ' / ' + fb(r.ram.limit))
    + bar('Disk', r.disk.pct, r.disk.used == null ? 'n/a' : fb(r.disk.used) + ' / ' + fb(r.disk.limit))
    + bwBar
    + `<div class="mut" style="font-size:12px">Network: ↓ ${fb(r.net.rx)} · ↑ ${fb(r.net.tx)} · Proses: ${r.procs}` + (bw.rate > 0 ? ` · Limit ${bw.rate} Mbps` : '') + `</div>`;
}

const stateBadge = v => `<span class="badge b-${esc(v.suspended ? 'SUSPEND' : (v.state || 'unknown'))}">${esc(v.suspended ? 'SUSPEND' : (v.state || '?'))}</span>`;

function portsTable(v) {
  if (!v.ports || !v.ports.length) return '<div class="mut">Tidak ada port.</div>';
  const app = v.ports.filter(p => !p.ssh).length;
  return `<div class="mut" style="font-size:12px;margin-bottom:6px">${v.ports.length} port · 1 SSH · ${app} aplikasi</div><div class="tw"><table style="min-width:320px"><tr><th>Publik</th><th>Internal</th><th>Proto</th><th></th></tr>`
    + v.ports.map(p => `<tr><td>${esc(v.host)}:${p.public}</td><td>${p.internal}</td><td>${esc(p.proto)}${p.ssh ? ' · <b>SSH</b>' : ''}</td><td><button class="sm sec" data-a="copy" data-t="${esc(v.host + ':' + p.public)}" title="Salin">${ic('copy')}</button></td></tr>`).join('')
    + '</table></div>';
}

function sshLine(v) {
  return `<div class="kv">
    <span>SSH</span><span><code>ssh root@${esc(v.host)} -p ${v.ssh}</code> <button class="sm sec" data-a="copy" data-t="ssh root@${esc(v.host)} -p ${v.ssh}">${ic('copy')} Salin</button></span>
    <span>Password</span><span><code class="pw" data-pw="${esc(v.password)}">••••••••</code> <button class="sm sec" data-a="reveal">${ic('eye')} Tampilkan</button> <button class="sm sec" data-a="copy" data-t="${esc(v.password)}">${ic('copy')} Salin</button></span></div>`;
}

/* ---------- boot ---------- */
function clearTimers() { S.timers.forEach(clearInterval); S.timers = []; }

async function boot() {
  try {
    const d = await api('GET', '/api/session');
    S.role = d.role; S.name = d.name || null; S.brand = d.brand || S.brand; S.logo = d.logo || '';
  } catch (e) {
    if (e.net) { S.offline = true; }
  }
  S.version = $('#meta')?.dataset.version || '';
  if (!S.role) {
    const here = location.pathname;
    if (here !== '/login') { location.href = '/login?next=' + encodeURIComponent(here); return; }
  }
  clearTimers();
  if (typeof pageInit === 'function') await pageInit();
  else setNav();
}
window.vpsnat = {S, api, act, toast, copyText, setNav, track, bar, resHtml, stateBadge, portsTable, sshLine, opts, esc, val, num, fb, fdate, fup, fmb, daysLeft, fexp, fago, ic, $, $$, clearTimers, boot};

/* ---------- PWA ---------- */
const standalone = () => (window.matchMedia && matchMedia('(display-mode: standalone)').matches) || navigator.standalone === true;
function syncInstall() {
  $$('[data-install]').forEach(b => { b.hidden = !S.pwa; });
  const ios = /iphone|ipad|ipod/i.test(navigator.userAgent) && !standalone();
  $$('[data-ioshint]').forEach(b => { b.hidden = !ios; });
}
function netState() { const n = $('#net'); if (n) n.hidden = navigator.onLine; }
window.addEventListener('beforeinstallprompt', e => { e.preventDefault(); S.pwa = e; syncInstall(); });
window.addEventListener('appinstalled', () => { S.pwa = null; syncInstall(); toast('Aplikasi terpasang'); });
window.addEventListener('online', () => { netState(); toast('Kembali online'); });
window.addEventListener('offline', netState);
if ('serviceWorker' in navigator && window.isSecureContext) {
  navigator.serviceWorker.register('/sw.js').then(reg => {
    reg.addEventListener('updatefound', () => {
      const w = reg.installing;
      if (w) w.addEventListener('statechange', () => {
        if (w.state === 'installed' && navigator.serviceWorker.controller) toast('Versi panel baru tersedia. Muat ulang halaman untuk memakainya.');
      });
    });
  }).catch(() => {});
}

/* ---------- delegasi event global ---------- */
const GLOBAL = {
  install: async () => { const e = S.pwa; if (!e) return; S.pwa = null; syncInstall(); e.prompt(); try { await e.userChoice; } catch (_) {} },
  logout: async () => { try { await api('POST', '/api/logout', {}); } catch (e) {} location.href = '/login'; },
  copy: b => copyText(b.dataset.t).then(() => toast('Disalin')).catch(() => toast('Gagal menyalin', true)),
  reveal: b => { const e = $('#pw') || $('.pw'); if (!e) return; const hid = e.textContent.startsWith('•'); e.textContent = hid ? e.dataset.pw : '••••••••'; const lbl = b.lastChild; if (lbl) lbl.textContent = hid ? ' Sembunyikan' : ' Tampilkan'; },
};
document.addEventListener('click', e => {
  const el = e.target.closest('[data-a]');
  if (!el) return;
  const fn = (window.PAGE_ACTIONS && window.PAGE_ACTIONS[el.dataset.a]) || GLOBAL[el.dataset.a];
  if (fn) { e.preventDefault(); fn(el); }
});
document.addEventListener('input', e => { if (window.PAGE_INPUT) window.PAGE_INPUT(e); });
document.addEventListener('keydown', e => { if (window.PAGE_KEYDOWN) window.PAGE_KEYDOWN(e); });

netState();
boot();
