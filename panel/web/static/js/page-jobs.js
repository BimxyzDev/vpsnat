'use strict';
/* Halaman: job — riwayat operasi panjang (create/delete/reinstall). */

const KINDS = {create: 'Buat server', delete: 'Hapus server', reinstall: 'Reinstall OS'};

function statusBadge(j) {
  const cls = j.status === 'done' ? 'RUNNING' : (j.status === 'running' ? 'CREATING' : 'STOPPED');
  return `<span class="badge b-${cls}">${esc(j.status.toUpperCase())}</span>`;
}

function jobsTable(items) {
  if (!items.length) return `<div class="empty">${ic('inbox')}Belum ada job.</div>`;
  return `<div class="tw"><table><tr><th>Waktu</th><th>Operasi</th><th>Target</th><th>Status</th><th>Hasil</th><th></th></tr>`
    + items.map(j => `<tr class="click" data-a="detail" data-id="${j.id}">
        <td>${esc(fdate(j.started))}</td><td>${esc(KINDS[j.kind] || j.kind)}</td><td>${esc(j.target || '-')}</td>
        <td>${statusBadge(j)}</td><td>${j.rc == null ? '-' : j.rc}</td>
        <td><button class="sm sec" data-a="detail" data-id="${j.id}">Detail</button></td></tr>`).join('') + '</table></div>';
}

async function load() {
  try {
    const d = await api('GET', '/api/admin/jobs');
    S.jobs = d.jobs || [];
    $('#jobs').innerHTML = jobsTable(S.jobs);
  } catch (e) { toast(e.message, true); }
}

async function detail(id) {
  const d = await api('GET', '/api/admin/jobs/' + id);
  const j = d.job;
  $('#detail').hidden = false;
  $('#detail').innerHTML = `<div class="row" style="justify-content:space-between">
      <h2 style="margin:0">Job ${esc(j.id)} ${statusBadge(j)}</h2>
      <button class="sec sm" data-a="closedetail">${ic('x')} Tutup</button></div>
    <div class="kv" style="margin-top:10px">
      <span>Operasi</span><span>${esc(KINDS[j.kind] || j.kind)}</span>
      <span>Target</span><span>${esc(j.name || '-')}</span>
      <span>Mulai</span><span>${esc(fdate(j.started))}</span>
      <span>Selesai</span><span>${j.finished ? esc(fdate(j.finished)) : '-'}</span>
      <span>Exit code</span><span>${j.rc == null ? '-' : j.rc}</span></div>
    <pre class="log">${esc(j.output || '(belum ada output)')}</pre>`;
  if (j.status === 'running') S.timers.push(setInterval(() => detail(id).catch(() => {}), 3000));
}

async function pageInit() {
  setNav();
  if (S.role !== 'admin') { location.href = '/account'; return; }
  $('#app').innerHTML = `
    <div class="top"><h1>Job</h1><button class="sec" data-a="refresh">${ic('refresh')} Refresh</button></div>
    <p class="lead">Operasi panjang (buat/hapus/reinstall) berjalan sebagai job di node. Halaman ini menampilkan 30 job terbaru.</p>
    <div class="card"><div id="jobs"><div class="skel"></div></div></div>
    <div class="card" id="detail" hidden></div>
    <div class="foot">${esc(S.brand)} · VPSNAT ${esc(S.version || '')} Panel</div>`;
  await load();
  S.timers.push(setInterval(load, 10000));
}

window.PAGE_ACTIONS = {
  refresh: () => load(),
  detail: el => detail(el.dataset.id),
  closedetail: () => { $('#detail').hidden = true; },
};
