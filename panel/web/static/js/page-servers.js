'use strict';
/* Halaman: server (daftar + buat) — admin. */

function serverCard(v) {
  const bw = v.bw || {}, p = bw.quota > 0 ? Math.min(100, bw.used / bw.quota * 100) : null;
  const d = daysLeft(v.expires), ecls = v.expires && d <= 7 ? 'warnt' : '';
  return `<div class="vc" data-a="open" data-n="${esc(v.name)}" tabindex="0" role="button" aria-label="Buka ${esc(v.name)}">
    <div class="vh"><b>${esc(v.name)}</b>${stateBadge(v)}</div>
    <div class="vs">${esc(v.node)}${v.node_online ? '' : ' · node offline'} · ${esc(v.plan)} · ${esc(v.backend)}${v.owner && v.owner !== '-' ? ' · ' + esc(v.owner) : ''}</div>
    <div class="chips"><span class="chip">${v.cpu} CPU</span><span class="chip">${fmb(v.ram)}</span><span class="chip">${v.disk} GB</span><span class="chip">${v.ports.length} port</span></div>
    ${p == null ? `<div class="mh"><span>Bandwidth</span><span>${fb(bw.used)} · ∞</span></div>` : bar('Bandwidth', p, fb(bw.used) + ' / ' + fb(bw.quota))}
    <div class="vf"><span>SSH ${esc(v.host)}:${v.ssh}${bw.rate > 0 ? ' · ' + bw.rate + ' Mbps' : ''}</span><span class="${ecls}">${v.expires ? esc(fexp(v.expires)) : 'Tanpa expired'}</span></div></div>`;
}

function vlist() {
  const q = (S.q || '').toLowerCase(), f = S.f || 'all', el = $('#vlist');
  if (!el) return;
  const list = (S.servers || []).filter(v => (!q || v.name.toLowerCase().includes(q) || String(v.owner).toLowerCase().includes(q) || String(v.ssh).includes(q))
    && (f === 'all' || (f === 'RUNNING' && v.state === 'RUNNING' && !v.suspended) || (f === 'STOPPED' && v.state !== 'RUNNING' && !v.suspended)
      || (f === 'SUSPEND' && v.suspended) || (f === 'EXP' && v.expires && daysLeft(v.expires) <= 7)));
  el.innerHTML = list.length ? list.map(serverCard).join('')
    : `<div class="empty" style="grid-column:1/-1">${ic('inbox')}${(S.servers || []).length ? 'Tidak ada server yang cocok dengan filter.' : 'Belum ada server. Tambahkan lewat form di atas.'}</div>`;
}

function vstats(l) {
  const sum = f => l.reduce((t, v) => t + (f(v) || 0), 0);
  const run = l.filter(v => v.state === 'RUNNING' && !v.suspended).length, sus = l.filter(v => v.suspended).length;
  const soon = l.filter(v => v.expires && daysLeft(v.expires) <= 7).length;
  const c = (cls, n, lbl, sm) => `<div class="stat ${cls}"><b>${n}</b><span>${lbl}</span>${sm ? `<small>${sm}</small>` : ''}</div>`;
  return c('', l.length, 'Total server', sum(v => v.ports.length) + ' port aktif')
    + c('ok', run, 'Running') + c(l.length - run - sus ? 'bad' : '', l.length - run - sus, 'Stopped')
    + c(sus ? 'warn' : '', sus, 'Suspend') + c(soon ? 'warn' : '', soon, 'Expired ≤ 7 hari')
    + c('', sum(v => v.cpu) + ' CPU', 'Alokasi CPU', fmb(sum(v => v.ram)) + ' RAM · ' + sum(v => v.disk) + ' GB disk');
}

async function load() {
  try {
    const d = await api('GET', '/api/admin/servers');
    S.servers = d.servers || []; S.limits = d.limits || S.limits;
  } catch (e) { return toast(e.message, true); }
  const f = S.f || 'all';
  const fo = [['all', 'Semua'], ['RUNNING', 'Running'], ['STOPPED', 'Stopped'], ['SUSPEND', 'Suspend'], ['EXP', 'Segera expired']];
  $('#stats').innerHTML = vstats(S.servers);
  $('#count').textContent = S.servers.length + ' server';
  $('#vfilter').innerHTML = fo.map(([k, n]) => `<option value="${k}"${f === k ? ' selected' : ''}>${n}</option>`).join('');
  $('#vq').value = S.q || '';
  vlist();
}

function nodeOptions() {
  const online = (S.nodes || []).filter(n => n.online && !n.maintenance);
  if (!online.length) return '<option value="">(tidak ada node online)</option>';
  return online.map(n => `<option value="${n.id}">${esc(n.name)} · ${esc(n.wan_ip)}</option>`).join('');
}

async function loadMeta() {
  try {
    const m = await api('GET', '/api/meta');
    S.meta = m; S.nodes = m.nodes || [];
  } catch (e) {}
  $('#c_node').innerHTML = nodeOptions();
  $('#c_image').innerHTML = opts(S.meta ? S.meta.images : ['ubuntu22']);
  const portDefault = (S.meta && S.meta.defaults && S.meta.defaults.ports) || 3;
  $('#c_ports').value = portDefault;
}

async function create(btn) {
  const body = {
    name: val('c_name'), node_id: $('#c_node').value ? Number($('#c_node').value) : null,
    image: val('c_image'), cpu: num('c_cpu'), ram: num('c_ram'), disk: num('c_disk'),
    plan: val('c_plan'), backend: val('c_backend'), ports: num('c_ports'),
    expire: val('c_expire') || '0', owner: val('c_owner') || '-',
    nesting: $('#c_nest').checked, password: val('c_pass') || undefined,
    bw_quota_gb: val('c_bwq') || undefined, bw_rate_mbit: val('c_bwr') || undefined,
  };
  if (!/^[a-z0-9][a-z0-9-]{0,30}$/.test(body.name)) { toast('Nama: a-z, 0-9, dan - (maks 31).', true); return; }
  await act(btn, async () => {
    const d = await api('POST', '/api/admin/servers', body);
    toast('Pembuatan server dimulai (job ' + d.job + ')');
    $('#joblog').hidden = false;
    track(d.job, '#joblog', () => load());
    await load();
  });
}

function pageActions() {
  return {
    refresh: () => load(),
    open: el => { location.href = '/servers/' + encodeURIComponent(el.dataset.n); },
    newserver: () => { $('#newwrap').hidden = !$('#newwrap').hidden; },
    create: b => create(b),
    sync: b => act(b, async () => { const d = await api('POST', '/api/sync', {}); toast('Sync: ' + (d.servers_synced ?? 0) + ' server, ' + (d.nodes_online ?? 0) + ' node online'); await load(); }),
  };
}

async function pageInit() {
  setNav();
  if (S.role !== 'admin') { location.href = '/account'; return; }
  $('#app').innerHTML = `
    <div class="top"><h1 id="count">Server</h1>
      <div class="row"><button data-a="newserver">${ic('plus')} Server baru</button>
      <button class="sec" data-a="sync">${ic('refresh')} Sync dari node</button></div></div>
    <div id="newwrap" hidden>
      <div class="card"><h2>Buat server client</h2>
        <div class="cols2"><div><label>Nama (a-z, 0-9, -)</label><input id="c_name" autocapitalize="none"></div>
          <div><label>Node</label><select id="c_node"></select></div></div>
        <div class="cols3"><div><label>Image</label><select id="c_image"></select></div>
          <div><label>Plan</label><select id="c_plan"><option>shared</option><option>dedicated</option></select></div>
          <div><label>Backend</label><select id="c_backend"><option>container</option><option>vm</option></select></div></div>
        <div class="cols3"><div><label>CPU</label><input id="c_cpu" type="number" value="1" min="1"></div>
          <div><label>RAM (MB)</label><input id="c_ram" type="number" value="1024" min="128"></div>
          <div><label>Disk (GB)</label><input id="c_disk" type="number" value="10" min="1"></div></div>
        <div class="cols3"><div><label>Jumlah port total (termasuk 1 SSH)</label><input id="c_ports" type="number" value="3" min="2" max="50"></div>
          <div><label>Expired (30d / 2026-12-31)</label><input id="c_expire" placeholder="kosong = tanpa"></div>
          <div><label>Owner / label</label><input id="c_owner"></div></div>
        <div class="cols3"><div><label>Kuota BW (GB)</label><input id="c_bwq" type="number" min="0" placeholder="default"></div>
          <div><label>Limit (Mbps)</label><input id="c_bwr" type="number" min="0" placeholder="default"></div>
          <div><label>Password root (kosong = random)</label><input id="c_pass" type="password" autocomplete="new-password"></div></div>
        <label style="display:flex;gap:8px;align-items:center"><input id="c_nest" type="checkbox" checked style="width:auto"> Nesting (Docker di dalam server, container saja)</label>
        <div style="margin-top:12px"><button data-a="create">${ic('plus')} Buat server</button></div></div>
    </div>
    <div class="stats" id="stats"><div class="skel"></div></div>
    <div class="fbar"><input id="vq" type="search" placeholder="Cari nama / owner / port SSH…" autocomplete="off"><select id="vfilter"></select></div>
    <div class="vgrid" id="vlist"><div class="skel"></div><div class="skel"></div></div>
    <pre id="joblog" class="log" hidden></pre>
    <div class="foot">${esc(S.brand)} · VPSNAT ${esc(S.version || '')} Panel</div>`;
  window.PAGE_ACTIONS = pageActions();
  window.PAGE_INPUT = e => {
    if (e.target.id === 'vq') { S.q = e.target.value; vlist(); }
    else if (e.target.id === 'vfilter') { S.f = e.target.value; vlist(); }
  };
  await loadMeta();
  await load();
  S.timers.push(setInterval(load, 20000));
}
