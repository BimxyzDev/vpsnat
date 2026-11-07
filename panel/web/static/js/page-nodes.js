'use strict';
/* Halaman: nodes — registry node (tambah/hapus/ping/token/maintenance/port pool). */

function nodeCard(n) {
  const sys = n.system || {}, ram = sys.ram || {}, disk = sys.disk || {};
  const ramPct = ram.total ? Math.round((ram.total - (ram.avail || 0)) / ram.total * 100) : null;
  const diskPct = disk.total ? Math.round((disk.used || 0) / disk.total * 100) : null;
  return `<div class="vc" id="node-${n.id}">
    <div class="vh"><b>${esc(n.name)}</b><span class="badge b-${esc(n.online ? 'online' : (n.status || 'offline'))}">${esc(n.online ? 'ONLINE' : (n.status || 'offline').toUpperCase())}</span></div>
    <div class="vs">${esc(n.wan_ip)} · <code>${esc(n.url)}</code></div>
    <div class="chips">
      <span class="chip">${n.ports_free}/${n.ports_total} port kosong</span>
      <span class="chip">pool ${n.port_min}-${n.port_max}</span>
      ${sys.vps ? `<span class="chip">${sys.vps.total} server</span>` : ''}
      ${n.maintenance ? '<span class="chip">maintenance</span>' : ''}
    </div>
    ${ramPct == null ? `<div class="mh"><span>Host</span><span class="mut">data belum ada · ${esc(fago(n.last_seen))}</span></div>`
      : bar('RAM host', ramPct, fb(ram.total - (ram.avail || 0)) + ' / ' + fb(ram.total))}
    ${diskPct == null ? '' : bar('Disk host', diskPct, fb(disk.used) + ' / ' + fb(disk.total))}
    <div class="vf"><span>sync ${esc(fago(n.last_seen))}${sys.cores ? ' · ' + sys.cores + ' core' : ''}${sys.uptime ? ' · up ' + fup(sys.uptime) : ''}</span>
      <span>${sys.lxd_version ? esc(String(sys.lxd_version).slice(0, 22)) : ''}</span></div>
    ${n.error ? `<div class="warnt" style="font-size:12px;margin-top:6px">${esc(n.error)}</div>` : ''}
    <div class="row" style="margin-top:10px">
      <button class="sm sec" data-a="ping" data-id="${n.id}">${ic('refresh')} Ping</button>
      <button class="sm sec" data-a="token" data-id="${n.id}">${ic('key') || ic('book')} Token</button>
      <button class="sm sec" data-a="maint" data-id="${n.id}">${n.maintenance ? 'Akhiri maintenance' : 'Maintenance'}</button>
      <button class="sm sec" data-a="ports" data-id="${n.id}" data-min="${n.port_min}" data-max="${n.port_max}">Perluas port</button>
      <button class="sm bad" data-a="del" data-id="${n.id}" data-n="${esc(n.name)}">${ic('trash')} Hapus</button>
    </div></div>`;
}

async function load() {
  try {
    const d = await api('GET', '/api/admin/nodes');
    S.nodes = d.nodes || [];
    $('#nlist').innerHTML = S.nodes.length ? S.nodes.map(nodeCard).join('')
      : `<div class="empty" style="grid-column:1/-1">${ic('chip')}<h2>Belum ada node</h2><p>Pasang node (<code>vpsnat install-node</code>), lalu daftarkan di sini.</p></div>`;
  } catch (e) { toast(e.message, true); }
}

function showToken(tok) {
  const el = $('#tokout');
  el.hidden = false;
  el.innerHTML = `<h3>Token node (untuk vpsnat node attach)</h3>
    <div class="row"><input id="tokval" value="${esc(tok)}" readonly style="flex:1">
    <button class="sm sec" data-a="copytok">${ic('copy')} Salin</button></div>
    <p class="mut" style="font-size:12px">Tempel di node: <code>vpsnat node attach &lt;token&gt;</code>, lalu restart agent: <code>systemctl restart vpsnat-node</code>.</p>`;
  const v = $('#tokval'); if (v) v.select();
  window.__tok = tok;
}

function actRefresh() { return load(); }

async function pageInit() {
  setNav();
  if (S.role !== 'admin') { location.href = '/account'; return; }
  $('#app').innerHTML = `
    <div class="top"><h1>Node</h1>
      <div class="row"><button data-a="newnode">${ic('plus')} Daftarkan node</button>
      <button class="sec" data-a="refresh">${ic('refresh')} Refresh</button></div></div>
    <div id="newwrap" hidden><div class="card"><h2>Daftarkan node baru</h2>
      <p class="lead">Di node: <code>vpsnat install-node</code>, lalu <code>vpsnat node init</code> untuk melihat token.
      Daftarkan di panel dengan token itu, atau biarkan kosong untuk membuat token baru (tambahkan di node lewat <code>vpsnat node attach</code>).</p>
      <div class="cols2"><div><label>Nama node (a-z0-9-)</label><input id="n_name" autocapitalize="none"></div>
        <div><label>WAN IP node (IP untuk SSH client)</label><input id="n_wan" placeholder="203.0.113.10"></div></div>
      <div class="cols2"><div><label>URL agent node</label><input id="n_url" placeholder="http://203.0.113.10:8788"></div>
        <div><label>Token dari node (opsional)</label><input id="n_tok" placeholder="kosong = buat baru"></div></div>
      <div class="cols2"><div><label>Port pool — mulai</label><input id="n_pmin" type="number" value="20000"></div>
        <div><label>Port pool — akhir</label><input id="n_pmax" type="number" value="24999"></div></div>
      <label>Keterangan (opsional)</label><input id="n_desc">
      <div style="margin-top:12px"><button data-a="addnode">${ic('plus')} Tambahkan</button></div></div></div>
    <div id="tokout" class="card" hidden></div>
    <div class="vgrid" id="nlist"><div class="skel"></div></div>
    <div class="foot">${esc(S.brand)} · VPSNAT ${esc(S.version || '')} Panel</div>`;
  await load();
  S.timers.push(setInterval(load, 20000));
}

window.PAGE_ACTIONS = {
  refresh: actRefresh,
  newnode: () => { $('#newwrap').hidden = !$('#newwrap').hidden; },
  copytok: () => copyText(window.__tok || '').then(() => toast('Token disalin')).catch(() => toast('Gagal menyalin', true)),
  addnode: b => act(b, async () => {
    const body = {name: val('n_name'), wan_ip: val('n_wan'), url: val('n_url'),
      token: val('n_tok') || undefined, port_min: num('n_pmin'), port_max: num('n_pmax'), description: val('n_desc')};
    if (!body.url) body.url = 'http://' + body.wan_ip + ':8788';
    const d = await api('POST', '/api/admin/nodes', body);
    toast('Node ' + d.node.name + ' ditambahkan');
    $('#newwrap').hidden = true;
    showToken(d.token);
    await load();
  }),
  ping: b => act(b, async () => {
    const d = await api('POST', '/api/admin/nodes/' + b.dataset.id + '/ping', {});
    toast(d.online ? 'Node online' : ('Node tidak merespons: ' + (d.error || '?')), !d.online);
    await load();
  }),
  token: b => act(b, async () => {
    if (!confirm('Buat token baru? Token lama langsung tidak berlaku, dan node perlu attach ulang.')) return;
    const d = await api('POST', '/api/admin/nodes/' + b.dataset.id + '/token', {});
    showToken(d.token);
  }),
  maint: b => act(b, async () => {
    const d = await api('POST', '/api/admin/nodes/' + b.dataset.id + '/maintenance', {});
    toast('Maintenance: ' + (d.maintenance ? 'aktif' : 'nonaktif'));
    await load();
  }),
  ports: b => act(b, async () => {
    const lo = prompt('Port pool mulai:', b.dataset.min);
    if (lo === null) return;
    const hi = prompt('Port pool akhir:', b.dataset.max);
    if (hi === null) return;
    const d = await api('POST', '/api/admin/nodes/' + b.dataset.id + '/ports', {port_min: Number(lo), port_max: Number(hi)});
    toast('Pool port: ' + d.port_min + '-' + d.port_max);
    await load();
  }),
  del: b => act(b, async () => {
    if (!confirm('Hapus node ' + b.dataset.n + ' dari panel? Server di node itu TIDAK dihapus.')) return;
    await api('DELETE', '/api/admin/nodes/' + b.dataset.id);
    toast('Node dihapus');
    await load();
  }),
};
