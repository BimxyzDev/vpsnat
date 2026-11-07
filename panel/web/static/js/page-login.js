'use strict';
/* Halaman: login (admin & client). */

let mode = 'user';

function render() {
  const brand = window.__brand || 'VPSNAT';
  document.title = brand + ' — Masuk';
  document.getElementById('app').innerHTML = `<div class="auth">
    <div class="hero"><div class="mk">${window.__logo ? `<img src="${esc(window.__logo)}" alt="">` : ic('server')}</div>
      <h1>${esc(brand)}</h1><p>Panel manajemen VPS</p></div>
    <div class="card">
      <div class="row" style="gap:4px;flex-wrap:nowrap">
        <button style="flex:1" class="${mode === 'user' ? '' : 'sec'}" data-a="mode" data-m="user">Login client</button>
        <button style="flex:1" class="${mode === 'admin' ? '' : 'sec'}" data-a="mode" data-m="admin">Admin</button></div>
      ${mode === 'user'
        ? `<label>Nama server atau port SSH</label><input id="l1" autocomplete="username" autocapitalize="none" placeholder="mis. web-01 atau 20010">
           <label>Password root server</label><input id="l2" type="password" autocomplete="current-password">`
        : `<label>Username admin</label><input id="l1" autocomplete="username" autocapitalize="none">
           <label>Password admin</label><input id="l2" type="password" autocomplete="current-password">`}
      <div style="margin-top:16px"><button data-a="login" style="width:100%">Masuk</button></div>
      <div id="lerr" class="err" style="margin-top:10px"></div>
    </div>
    <div class="foot">Gunakan nama server atau port SSH + password root server.
      <div class="pwa-hint">${installBtnJs()}<span data-ioshint hidden>Di iPhone/iPad: ketuk Bagikan lalu <b>Tambahkan ke Layar Utama</b>.</span></div></div></div>`;
  const go = e => { if (e.key === 'Enter') document.querySelector('[data-a=login]').click(); };
  document.getElementById('l1').addEventListener('keydown', go);
  document.getElementById('l2').addEventListener('keydown', go);
  syncInstall();
}

const installBtnJs = () => '<button class="sec sm" data-a="install" data-install hidden>Pasang aplikasi</button>';

async function doLogin(btn) {
  btn.disabled = true;
  $('#lerr').textContent = '';
  try {
    const body = mode === 'user'
      ? {identifier: val('l1'), password: $('#l2').value}
      : {username: val('l1'), password: $('#l2').value};
    const d = await api('POST', '/api/login/' + mode, body);
    const next = new URLSearchParams(location.search).get('next');
    const dest = d.role === 'admin' ? (next && next.startsWith('/') ? next : '/') : '/account';
    location.href = dest;
  } catch (e) {
    $('#lerr').textContent = e.message;
    btn.disabled = false;
  }
}

async function pageInit() {
  setNav();
  try {
    const d = await api('GET', '/api/panel');
    window.__brand = d.brand; window.__logo = d.logo;
    if (d.role === 'admin') { location.href = '/'; return; }
    if (d.role === 'user') { location.href = '/account'; return; }
  } catch (e) {}
  render();
}

window.PAGE_ACTIONS = {
  mode: b => { mode = b.dataset.m; render(); },
  login: b => doLogin(b),
};
