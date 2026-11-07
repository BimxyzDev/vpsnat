'use strict';
/* Halaman: detail satu server (admin) — kontrol, resource, port, danger zone. */

function infoKv(v) {
  return `<div class="kv">
    <span>Status</span><span>${stateBadge(v)}${v.suspended ? ' <span class="warnt">(' + esc(v.reason) + ')</span>' : ''}</span>
    <span>Node</span><span>${esc(v.node)} ${v.node_online ? '' : '<span class="warnt">(offline)</span>'}</span>
    <span>Tipe</span><span>${esc(v.plan)} · ${esc(v.backend)} · ${esc(v.image)}</span>
    <span>Spesifikasi</span><span>${v.cpu} CPU · ${v.ram} MB RAM · ${v.disk} GB</span>
    <span>Dibuat</span><span>${esc(v.created)}</span>
    <span>Expired</span><span>${esc(fdate(v.expires))}</span>
    <span>Owner</span><span>${esc(v.owner)}</span>
    <span>UUID</span><span><code>${esc(v.uuid)}</code></span>
  </div>${sshLine(v)}`;
}

function panelHtml(v) {
  const pct = v.bw.quota ? Math.round(v.bw.used / v.bw.quota * 100) : null;
  return `
    <div class="grid">
      <div class="card"><h2>Informasi</h2>${infoKv(v)}</div>
      <div class="card"><h2>Resource live</h2><div id="res" class="mut"><span class="spin"></span>Memuat…</div>
        <div class="mut" style="font-size:12px;margin-top:8px">Diambil langsung dari node ${esc(v.node)}.</div></div>
    </div>
    <div class="card"><h2>Kontrol</h2><div class="row">
      <button class="ok" data-a="power" data-p="start">${ic('play')} Start</button>
      <button class="warn" data-a="power" data-p="restart">${ic('rotate')} Restart</button>
      <button class="bad" data-a="power" data-p="stop">${ic('stop')} Stop</button>
      <button class="sec" data-a="power" data-p="suspend">${ic('pause')} Suspend</button>
      <button class="sec" data-a="power" data-p="unsuspend">${ic('play')} Unsuspend</button></div></div>
    <div class="grid">
      <div class="card"><h3>Resize</h3><div class="cols3">
        <div><label>CPU</label><input id="z_cpu" type="number" value="${v.cpu}"></div>
        <div><label>RAM MB</label><input id="z_ram" type="number" value="${v.ram}"></div>
        <div><label>Disk GB</label><input id="z_disk" type="number" value="${v.disk}"></div></div>
        <div style="margin-top:8px"><button data-a="resize">Terapkan</button></div></div>
      <div class="card"><h3>Expired</h3>
        <div class="cols2"><div><label>Perpanjang dari sekarang</label><input id="x_renew" placeholder="30d"></div>
        <div><label>Set expire / never</label><input id="x_exp" placeholder="2026-12-31 / never"></div></div>
        <div class="row" style="margin-top:8px"><button data-a="renew">Renew</button><button class="sec" data-a="expire">Set expire</button></div></div>
      <div class="card"><h3>Password root</h3><input id="x_pw" type="password" placeholder="kosong = random" autocomplete="new-password">
        <div style="margin-top:8px"><button data-a="passwd">Ganti password</button></div></div>
      <div class="card"><h3>Owner &amp; tipe</h3><div class="cols2">
        <input id="x_owner" value="${esc(v.owner === '-' ? '' : v.owner)}" placeholder="owner">
        <select id="x_plan"><option${v.plan === 'shared' ? ' selected' : ''}>shared</option><option${v.plan === 'dedicated' ? ' selected' : ''}>dedicated</option></select></div>
        <div class="row" style="margin-top:8px"><button data-a="owner">Simpan owner</button><button class="sec" data-a="plan">Simpan tipe</button></div></div>
      <div class="card"><h3>Bandwidth</h3><div class="cols2">
        <div><label>Kuota GB (0=∞)</label><input id="b_q" type="number" value="${v.bw.quota ? v.bw.quota / 1e9 : 0}"></div>
        <div><label>Limit Mbps (0=∞)</label><input id="b_r" type="number" value="${v.bw.rate}"></div></div>
        <div class="row" style="margin-top:8px"><button data-a="bw" data-m="set">Set</button>
        <button class="sec" data-a="bw" data-m="reset">Reset pemakaian</button></div>
        <div class="mut" style="font-size:12px;margin-top:8px">Pemakaian tercatat: ${fb(v.bw.used)}${pct == null ? '' : ' (' + pct + '% kuota)'}</div></div>
      <div class="card"><h3>Port</h3>${portsTable(v)}
        <div class="row" style="margin-top:8px"><select id="p_proto" style="width:90px"><option>tcp</option><option>udp</option><option>both</option></select>
        <input id="p_count" type="number" value="1" min="1" max="500" style="width:80px" title="Jumlah port">
        <button data-a="portadd">Tambah port</button></div>
        <div class="row" style="margin-top:8px"><select id="p_del" style="flex:1">${v.ports.filter(x => !x.ssh).map(x => `<option value="${x.public}">${x.public} → ${x.internal}</option>`).join('') || '<option value="">Tidak ada port aplikasi</option>'}</select>
        <button class="sec" data-a="portdel">Hapus port</button></div></div>
      <div class="card"><h3>Reinstall OS</h3><select id="rimg">${opts(S.meta ? S.meta.images : ['ubuntu22'], v.image)}</select>
        <div style="margin-top:8px"><button class="warn" data-a="reinstall">Reinstall</button></div></div>
      <div class="card danger"><h3>Hapus server</h3><label>Ketik <b>${esc(v.name)}</b> untuk konfirmasi</label><input id="d_conf" autocapitalize="none">
        <div class="row" style="margin-top:8px"><button class="bad" data-a="delete">${ic('trash')} Hapus permanen</button>
        <button class="sec" data-a="consolehint">Cara masuk SSH</button></div></div>
    </div>
    <pre id="joblog" class="log" hidden></pre>`;
}

async function load() {
  try {
    const d = await api('GET', '/api/admin/servers/' + encodeURIComponent(S.server));
    window.__v = d.server;
  } catch (e) {
    if (/tidak ditemukan/i.test(e.message)) { location.href = '/servers'; return; }
    return toast(e.message, true);
  }
  $('#app').innerHTML = `<div class="top"><h1>${esc(window.__v.name)} ${stateBadge(window.__v)}</h1>
    <div class="row"><a href="/servers"><button class="sec sm">${ic('x')} Kembali</button></a>
    <button class="sec sm" data-a="refresh">${ic('refresh')} Refresh</button></div></div>${panelHtml(window.__v)}`;
}

async function pollRes() {
  if (S.role !== 'admin' || !window.__v) return;
  if (!window.__v.node_online) { const e = $('#res'); if (e) e.innerHTML = '<div class="warnt">Node offline — resource live tidak tersedia.</div>'; return; }
  try {
    const d = await api('GET', '/api/admin/servers/' + encodeURIComponent(S.server) + '/resources');
    const e = $('#res'); if (e) e.innerHTML = resHtml(d.res);
  } catch (e) {}
}

function vpath(p) { return '/api/admin/servers/' + encodeURIComponent(S.server) + (p || ''); }

function actions() {
  const after = () => { load().then(pollRes); };
  return {
    refresh: () => after(),
    power: b => act(b, async () => { await api('POST', vpath('/power'), {action: b.dataset.p}); toast(b.dataset.p + ' OK'); setTimeout(after, 800); }),
    resize: b => act(b, async () => { await api('POST', vpath('/resize'), {cpu: num('z_cpu'), ram: num('z_ram'), disk: num('z_disk')}); toast('Resource diperbarui'); after(); }),
    renew: b => act(b, async () => { await api('POST', vpath('/expire'), {value: val('x_renew'), relative: true}); toast('Diperpanjang'); after(); }),
    expire: b => act(b, async () => { await api('POST', vpath('/expire'), {value: val('x_exp')}); toast('Expire diubah'); after(); }),
    passwd: b => act(b, async () => { const d = await api('POST', vpath('/password'), {password: val('x_pw') || undefined}); toast('Password baru: ' + d.password); after(); }),
    owner: b => act(b, async () => { await api('POST', vpath('/owner'), {owner: val('x_owner')}); toast('Owner disimpan'); after(); }),
    plan: b => act(b, async () => { await api('POST', vpath('/plan'), {plan: val('x_plan')}); toast('Tipe disimpan'); after(); }),
    bw: b => act(b, async () => { await api('POST', vpath('/bandwidth'), {action: b.dataset.m, quota_gb: val('b_q') || 0, rate_mbit: val('b_r') || 0}); toast('Bandwidth diperbarui'); after(); }),
    portadd: b => act(b, async () => { const n = num('p_count'); if (!Number.isInteger(n) || n < 1 || n > 500) throw new Error('Jumlah port 1-500.'); await api('POST', vpath('/ports'), {proto: val('p_proto'), count: n}); toast(n + ' port ditambah'); after(); }),
    portdel: b => act(b, async () => { const p = val('p_del'); if (!/^\d{1,5}$/.test(p)) throw new Error('Pilih port yang akan dihapus.'); await api('DELETE', vpath('/ports/' + p)); toast('Port ' + p + ' dihapus'); after(); }),
    reinstall: b => act(b, async () => {
      if (!confirm('Reinstall ' + S.server + '? Semua data di dalam server hilang.')) return;
      const d = await api('POST', vpath('/reinstall'), {image: val('rimg')});
      const log = $('#joblog'); log.hidden = false;
      track(d.job, '#joblog', () => after());
    }),
    delete: b => act(b, async () => {
      if (val('d_conf') !== S.server) throw new Error('Nama konfirmasi tidak cocok.');
      if (!confirm('Hapus ' + S.server + ' beserta seluruh datanya? Tindakan ini permanen.')) return;
      const d = await api('DELETE', vpath());
      location.href = '/servers';
      toast('Penghapusan dimulai (job ' + d.job + ')');
    }),
    consolehint: () => {
      const v = window.__v;
      alert('SSH ke server ini:\n\nssh root@' + v.host + ' -p ' + v.ssh + '\n\nPort lain yang bisa dipakai client:\n' + v.ports.filter(p => !p.ssh).map(p => '  ' + v.host + ':' + p.public).join('\n'));
    },
  };
}

async function pageInit() {
  setNav();
  if (S.role !== 'admin') { location.href = '/account'; return; }
  const m = location.pathname.split('/').filter(Boolean);
  S.server = decodeURIComponent(m[1] || '');
  try { S.meta = await api('GET', '/api/meta'); S.nodes = S.meta.nodes || []; } catch (e) {}
  window.PAGE_ACTIONS = actions();
  await load();
  await pollRes();
  S.timers.push(setInterval(pollRes, 5000));
}
