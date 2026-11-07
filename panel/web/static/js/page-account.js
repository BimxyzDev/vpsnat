'use strict';
/* Halaman: akun client (user) — hanya servernya sendiri. */

function panelHtml(v) {
  return `
    <div class="grid">
      <div class="card"><h2>Informasi</h2>
        <div class="kv">
          <span>Status</span><span>${stateBadge(v)}${v.suspended ? ' <span class="warnt">(' + esc(v.reason) + ')</span>' : ''}</span>
          <span>Tipe</span><span>${esc(v.plan)} · ${esc(v.backend)}</span>
          <span>Spesifikasi</span><span>${v.cpu} CPU · ${v.ram} MB RAM · ${v.disk} GB</span>
          <span>Expired</span><span>${esc(fdate(v.expires))}</span>
        </div>${sshLine(v)}</div>
      <div class="card"><h2>Resource</h2><div id="res" class="mut"><span class="spin"></span>Memuat…</div></div>
    </div>
    <div class="card"><h2>Port</h2>${portsTable(v)}</div>
    <div class="grid">
      <div class="card"><h2>Kontrol</h2>
        <div class="row"><button class="ok" data-a="power" data-p="start">${ic('play')} Start</button>
        <button class="warn" data-a="power" data-p="restart">${ic('rotate')} Restart</button>
        <button class="bad" data-a="power" data-p="stop">${ic('stop')} Stop</button></div>
        <h3 style="margin-top:16px">Ganti password root</h3>
        <input id="newpw" type="password" placeholder="Kosongkan untuk random" autocomplete="new-password">
        <div style="margin-top:8px"><button data-a="passwd">Ganti password</button></div>
        <div class="mut" style="font-size:12px;margin-top:8px">Mengganti password akan mengakhiri sesi login lain di panel.</div></div>
      <div class="card"><h2>Bantuan</h2>
        <p class="lead">Hubungi admin bila perlu ubah OS, resource, atau masa aktif. Ubah OS oleh client dinonaktifkan.</p>
        <pre class="log">ssh root@${esc(v.host)} -p ${v.ssh}</pre></div>
    </div>
    <pre id="joblog" class="log" hidden></pre>`;
}

let me = null;

async function load() {
  try {
    const d = await api('GET', '/api/me');
    me = d.server || d.vps;
  } catch (e) { return toast(e.message, true); }
  $('#app').innerHTML = `<div class="top"><h1>${esc(me.name)} ${stateBadge(me)}</h1>
    <button class="sec sm" data-a="refresh">${ic('refresh')} Refresh</button></div>${panelHtml(me)}`;
}

async function pollRes() {
  if (!me) return;
  try {
    const d = await api('GET', '/api/me/resources');
    const e = $('#res'); if (e) e.innerHTML = resHtml(d.res);
  } catch (e) {
    const el = $('#res'); if (el) el.innerHTML = '<div class="warnt">' + esc(e.message) + '</div>';
  }
}

async function pageInit() {
  setNav();
  if (S.role === 'admin') { location.href = '/'; return; }
  if (S.role !== 'user') { location.href = '/login'; return; }
  window.PAGE_ACTIONS = {
    refresh: () => load().then(pollRes),
    power: b => act(b, async () => { await api('POST', '/api/me/action', {action: b.dataset.p}); toast(b.dataset.p + ' OK'); setTimeout(() => load().then(pollRes), 800); }),
    passwd: b => act(b, async () => {
      const d = await api('POST', '/api/me/passwd', {password: val('newpw') || undefined});
      toast('Password baru: ' + d.password);
      await load();
    }),
  };
  await load();
  await pollRes();
  S.timers.push(setInterval(pollRes, 5000));
}
