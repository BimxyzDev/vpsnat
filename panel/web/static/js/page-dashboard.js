'use strict';
/* Halaman: dashboard admin — ringkasan panel, node, dan server. */

function statCards(s) {
  const c = (cls, n, lbl, sm) => `<div class="stat ${cls}"><b>${n}</b><span>${lbl}</span>${sm ? `<small>${sm}</small>` : ''}</div>`;
  return c('', s.servers, 'Total server', s.ports_free + ' port kosong')
    + c('ok', s.running, 'Running')
    + c(s.suspended ? 'warn' : '', s.suspended, 'Suspend')
    + c(s.nodes_online === s.nodes ? '' : 'warn', s.nodes_online + '/' + s.nodes, 'Node online')
    + c('', s.cpu + ' CPU', 'Alokasi CPU', fmb(s.ram) + ' RAM · ' + s.disk + ' GB disk')
    + c('', fb(s.bw), 'Bandwidth terpakai');
}

function nodeCard(n) {
  const sys = n.system || {};
  const ram = sys.ram || {}, disk = sys.disk || {};
  const ramPct = ram.total ? Math.round((ram.total - (ram.avail || 0)) / ram.total * 100) : null;
  const diskPct = disk.total ? Math.round((disk.used || 0) / disk.total * 100) : null;
  const used = n.ports_total - n.ports_free;
  return `<div class="vc" data-a="nodeopen" data-id="${n.id}">
    <div class="vh"><b>${esc(n.name)}</b><span class="badge b-${esc(n.online ? 'online' : (n.status || 'offline'))}">${esc(n.online ? 'ONLINE' : (n.status || 'offline').toUpperCase())}</span></div>
    <div class="vs">${esc(n.wan_ip)} · ${esc(n.url)}</div>
    <div class="chips">
      <span class="chip">${n.ports_free}/${n.ports_total} port kosong</span>
      <span class="chip">${sys.vps ? (sys.vps.total + ' server') : 'n/a'}</span>
      ${n.maintenance ? '<span class="chip">maintenance</span>' : ''}
    </div>
    ${ramPct == null ? '<div class="mh"><span>Host</span><span class="mut">data belum ada</span></div>' : bar('RAM host', ramPct, fb(ram.total - (ram.avail || 0)) + ' / ' + fb(ram.total))}
    ${diskPct == null ? '' : bar('Disk host', diskPct, fb(disk.used) + ' / ' + fb(disk.total))}
    <div class="vf"><span>${used} port terpakai · sync ${esc(fago(n.last_seen))}</span><span>${sys.cores ? sys.cores + ' core' : ''}</span></div>
    ${n.error ? `<div class="warnt" style="font-size:12px;margin-top:6px">${esc(n.error)}</div>` : ''}
  </div>`;
}

function render(d) {
  const s = d.summary;
  $('#stats').innerHTML = statCards(s);
  $('#nodes').innerHTML = d.nodes.length
    ? d.nodes.map(nodeCard).join('')
    : `<div class="empty" style="grid-column:1/-1">${ic('chip')}<h2>Belum ada node</h2><p>Daftarkan node lebih dahulu, lalu buat server di atasnya.</p><a href="/nodes"><button>${ic('plus')} Kelola node</button></a></div>`;
  const log = $('#joblog');
  if (log && !log.textContent) log.hidden = true;
}

async function load() {
  try {
    const d = await api('GET', '/api/admin/dashboard');
    window.__dash = d;
    render(d);
  } catch (e) { toast(e.message, true); }
}

async function pageInit() {
  setNav();
  if (S.role !== 'admin') { location.href = '/account'; return; }
  $('#app').innerHTML = `
    <div class="top"><h1>Dashboard</h1>
      <div class="row"><a href="/servers"><button>${ic('server')} Kelola server</button></a>
      <button class="sec" data-a="refresh">${ic('refresh')} Refresh</button></div></div>
    <div class="stats" id="stats"><div class="skel"></div></div>
    <div class="row" style="justify-content:space-between;margin:6px 0 10px">
      <h2 style="margin:0">Node</h2><a href="/nodes" class="mut" style="font-size:13px">Kelola node →</a></div>
    <div class="vgrid" id="nodes"><div class="skel"></div></div>
    <pre id="joblog" class="log" hidden></pre>
    <div class="foot">${esc(S.brand)} · VPSNAT ${esc(S.version || '')} Panel</div>`;
  await load();
  S.timers.push(setInterval(load, 15000));
}

window.PAGE_ACTIONS = {
  refresh: () => load(),
  nodeopen: el => { location.href = '/nodes#' + el.dataset.id; },
};
