'use strict';
/* Halaman: settings panel + audit trail. */

const LABEL = {
  brand: 'Nama panel (brand)',
  node_sync_seconds: 'Interval sync node (detik)',
  job_timeout: 'Batas waktu job (detik)',
  grace_days: 'Grace period expiry (hari)',
  default_ports: 'Jumlah port default saat buat server',
  ports_min: 'Minimum port per server',
  ports_max: 'Maksimum port per server',
  default_quota_gb: 'Kuota bandwidth default (GB)',
  default_rate_mbit: 'Limit bandwidth default (Mbps)',
  allow_user_reinstall: 'Izinkan client reinstall OS sendiri (0/1)',
};

const KEYMAP = {
  brand: 'brand', node_sync_seconds: 'node-sync-seconds', job_timeout: 'job-timeout',
  grace_days: 'grace-days', default_ports: 'default-ports', ports_min: 'ports-min',
  ports_max: 'ports-max', default_quota_gb: 'default-quota-gb',
  default_rate_mbit: 'default-rate-mbit', allow_user_reinstall: 'allow-user-reinstall',
};

async function load() {
  try {
    const [s, a] = await Promise.all([api('GET', '/api/admin/settings'), api('GET', '/api/admin/audit')]);
    renderSettings(s.settings);
    renderAudit(a.audit || []);
  } catch (e) { toast(e.message, true); }
}

function renderSettings(vals) {
  $('#settings').innerHTML = Object.entries(vals).filter(([k]) => k in LABEL).map(([k, v]) =>
    `<div class="cols2" style="align-items:end">
       <div><label>${esc(LABEL[k])} <code>${esc(k)}</code></label><input data-k="${esc(k)}" value="${esc(v)}"></div>
       <div style="padding-bottom:4px"><button class="sm sec" data-a="save" data-k="${esc(k)}">Simpan</button></div>
     </div>`).join('') + `<div style="margin-top:14px"><button data-a="saveall">Simpan semua perubahan</button></div>`;
}

function renderAudit(rows) {
  if (!rows.length) { $('#audit').innerHTML = '<div class="empty">Belum ada catatan audit.</div>'; return; }
  $('#audit').innerHTML = `<div class="tw"><table><tr><th>Waktu</th><th>Aktor</th><th>Aksi</th><th>Target</th><th>Hasil</th><th>Detail</th></tr>`
    + rows.map(r => `<tr><td>${esc(fdate(r.ts))}</td><td>${esc(r.actor)}</td><td>${esc(r.action)}</td>
        <td>${esc(r.target)}</td><td>${esc(r.result)}</td><td class="wrap">${esc(r.detail)}</td></tr>`).join('') + '</table></div>';
}

function inputs() { return Array.from(document.querySelectorAll('#settings input[data-k]')); }

async function save(key, value) {
  const api_key = KEYMAP[key] || key;
  await api('POST', '/api/admin/settings', {key: api_key, value});
}

async function pageInit() {
  setNav();
  if (S.role !== 'admin') { location.href = '/account'; return; }
  $('#app').innerHTML = `
    <div class="top"><h1>Setting</h1><button class="sec" data-a="refresh">${ic('refresh')} Refresh</button></div>
    <div class="grid">
      <div class="card"><h2>Panel</h2>
        <p class="lead">Nilai ini disimpan di panel DB dan dipakai form/worker panel. Setting node (auto-suspend, hardening, dsb.) diatur di node lewat <code>vpsnat settings</code>.</p>
        <div id="settings"><div class="skel"></div></div></div>
      <div class="card"><h2>Node</h2>
        <p class="lead">Resource host dan status agent tiap node diperbarui otomatis oleh worker.</p>
        <div id="nsummary" class="mut">Memuat…</div>
        <div class="row" style="margin-top:10px"><button class="sec" data-a="syncnow">${ic('refresh')} Sync sekarang</button></div></div>
    </div>
    <div class="card"><div class="row" style="justify-content:space-between"><h2 style="margin:0">Audit trail</h2>
      <span class="mut" style="font-size:12px">100 kejadian terakhir</span></div>
      <div id="audit" style="margin-top:10px"><div class="skel"></div></div></div>
    <div class="foot">${esc(S.brand)} · VPSNAT ${esc(S.version || '')} Panel</div>`;
  await load();
  try {
    const d = await api('GET', '/api/admin/nodes');
    $('#nsummary').innerHTML = d.nodes.length
      ? d.nodes.map(n => `<div class="kv" style="margin-bottom:6px"><span>${esc(n.name)}</span><span>${n.online ? '<span class="badge b-online">ONLINE</span>' : '<span class="badge b-offline">OFFLINE</span>'} ${n.ports_free}/${n.ports_total} port · sync ${esc(fago(n.last_seen))}</span></div>`).join('')
      : '<span class="warnt">Belum ada node terdaftar.</span>';
  } catch (e) {}
}

window.PAGE_ACTIONS = {
  refresh: () => load(),
  save: b => act(b, async () => {
    const el = inputs().find(i => i.dataset.k === b.dataset.k);
    await save(b.dataset.k, el ? el.value : '');
    toast(b.dataset.k + ' disimpan');
    await load();
  }),
  saveall: b => act(b, async () => {
    for (const el of inputs()) await save(el.dataset.k, el.value);
    toast('Semua setting disimpan');
    await load();
  }),
  syncnow: b => act(b, async () => {
    const d = await api('POST', '/api/sync', {});
    toast('Sync: ' + (d.servers_synced ?? 0) + ' server, ' + (d.nodes_online ?? 0) + ' node online');
    await load();
  }),
};
