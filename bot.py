#!/usr/bin/env python3
"""VPSNAT Telegram bot — UI wrapper di atas CLI `vpsnat`.

Logika utama (DB, firewall, LXD) tetap berada di CLI. Bot hanya mengatur
interaksi Telegram, validasi ringan, dan format tampilan.
Config dibaca dari /etc/vpsnat/vpsnat.conf : TG_TOKEN, TG_ADMIN.
"""
import asyncio
import html
import logging
import os
import re
import secrets
import time
from functools import wraps
from typing import Any

from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.constants import ParseMode
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

CONF = "/etc/vpsnat/vpsnat.conf"
CLI = "/usr/local/bin/vpsnat"
MAX_MSG = 3900
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")
IMAGE_RE = re.compile(r"^[A-Za-z0-9:./_-]+$")
DUR_RE = re.compile(r"^(\d+[hdwm]|\d{4}-\d{2}-\d{2}|never|0)$")
REL_DUR_RE = re.compile(r"^\d+[hdwm]$")
PORT_RE = re.compile(r"^\d{1,5}$")
OWNER_MAX = 60
STATE_TTL = 900
TOKEN_TTL = 90

logging.basicConfig(format="%(asctime)s %(levelname)s %(message)s", level=logging.INFO)
log = logging.getLogger("vpsnat-bot")


def load_conf() -> dict[str, str]:
    conf: dict[str, str] = {}
    try:
        with open(CONF, encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                conf[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return conf


CONFIG = load_conf()
TOKEN = CONFIG.get("TG_TOKEN", "")
ADMINS = {
    int(x)
    for x in CONFIG.get("TG_ADMIN", "").replace(" ", "").split(",")
    if x.lstrip("-").isdigit()
}

# Operasi berat diserialkan agar create/reinstall/backup tidak saling bertabrakan.
_op_lock = asyncio.Lock()
# token -> (chat_id, argv, env, expiry)
_pending: dict[str, tuple[int, list[str], dict[str, str], float]] = {}
# token -> (chat_id, action, data, expiry)
_ui_tokens: dict[str, tuple[int, str, dict[str, Any], float]] = {}
# user_id -> state
_user_state: dict[int, dict[str, Any]] = {}


async def run_cli(
    args: list[str],
    env_extra: dict[str, str] | None = None,
    timeout: int = 900,
    yes: bool = False,
) -> tuple[int, str]:
    """Jalankan CLI non-interaktif. Return (rc, output)."""
    env = os.environ.copy()
    env["VPSNAT_NONINTERACTIVE"] = "1"
    env["PATH"] = env.get("PATH", "") + ":/snap/bin"
    if yes:
        env["VPSNAT_YES"] = "1"
    if env_extra:
        env.update({k: str(v) for k, v in env_extra.items()})

    try:
        proc = await asyncio.create_subprocess_exec(
            CLI,
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            env=env,
        )
    except OSError as exc:
        return 127, f"CLI tidak dapat dijalankan: {exc}"

    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return 124, "Timeout: perintah dihentikan."

    return proc.returncode, out.decode(errors="replace")


def clip(text: str, limit: int = MAX_MSG) -> str:
    clean = text.strip()
    return clean if len(clean) <= limit else clean[:limit] + "\n…(dipotong)"


def esc(text: Any) -> str:
    return html.escape(str(text if text is not None else ""))


def esc_pre(text: str) -> str:
    return f"<pre>{esc(clip(text or '(kosong)'))}</pre>"


def fmt_bool_status(state: str) -> str:
    upper = (state or "?").upper()
    return {
        "RUNNING": "🟢 RUNNING",
        "STOPPED": "🔴 STOPPED",
        "SUSPEND": "🟠 SUSPENDED",
        "SUSPENDED": "🟠 SUSPENDED",
        "MISSING": "⚫ MISSING",
    }.get(upper, f"⚪ {esc(upper)}")


def valid_name(name: str) -> bool:
    return bool(NAME_RE.fullmatch(name or ""))


def cleanup_expired_memory() -> None:
    now = time.time()
    for token, item in list(_pending.items()):
        if item[3] < now:
            _pending.pop(token, None)
    for token, item in list(_ui_tokens.items()):
        if item[3] < now:
            _ui_tokens.pop(token, None)
    for uid, state in list(_user_state.items()):
        if state.get("expires", 0) < now:
            _user_state.pop(uid, None)


def set_state(user_id: int, kind: str, **data: Any) -> None:
    _user_state[user_id] = {"kind": kind, "expires": time.time() + STATE_TTL, **data}


def get_state(user_id: int) -> dict[str, Any] | None:
    state = _user_state.get(user_id)
    if not state:
        return None
    if state.get("expires", 0) < time.time():
        _user_state.pop(user_id, None)
        return None
    state["expires"] = time.time() + STATE_TTL
    return state


def clear_state(user_id: int) -> None:
    _user_state.pop(user_id, None)


def make_ui_token(chat_id: int, action: str, data: dict[str, Any]) -> str:
    cleanup_expired_memory()
    token = secrets.token_hex(4)
    _ui_tokens[token] = (chat_id, action, data, time.time() + STATE_TTL)
    return token


def take_ui_token(chat_id: int, token: str, action: str) -> dict[str, Any] | None:
    item = _ui_tokens.pop(token, None)
    if not item or item[0] != chat_id or item[1] != action or item[3] < time.time():
        return None
    return item[2]


def admin_only(fn):
    @wraps(fn)
    async def wrapper(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        uid = update.effective_user.id if update.effective_user else 0
        if uid not in ADMINS:
            log.warning("Akses ditolak uid=%s", uid)
            if update.effective_message:
                await update.effective_message.reply_text(f"⛔ Akses ditolak. ID kamu: <code>{uid}</code>", parse_mode=ParseMode.HTML)
            return
        return await fn(update, ctx)

    return wrapper


async def reply(update: Update, text: str, **kwargs: Any) -> None:
    kwargs.setdefault("parse_mode", ParseMode.HTML)
    kwargs.setdefault("disable_web_page_preview", True)
    await update.effective_message.reply_text(text, **kwargs)


async def edit(query, text: str, **kwargs: Any) -> None:
    kwargs.setdefault("parse_mode", ParseMode.HTML)
    kwargs.setdefault("disable_web_page_preview", True)
    await query.edit_message_text(text, **kwargs)


def main_keyboard() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton("🖥 VPS Saya", callback_data="menu:vps"),
                InlineKeyboardButton("➕ Buat VPS", callback_data="menu:create"),
            ],
            [
                InlineKeyboardButton("🧾 VPS Expiring", callback_data="menu:expiring"),
                InlineKeyboardButton("🖥️ Host", callback_data="menu:host"),
            ],
            [
                InlineKeyboardButton("🔄 Sync", callback_data="menu:sync"),
                InlineKeyboardButton("❓ Bantuan", callback_data="menu:help"),
            ],
        ]
    )


def back_keyboard(target: str = "menu:home") -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([[InlineKeyboardButton("⬅️ Kembali", callback_data=target)]])


def vps_action_keyboard(name: str, suspended: bool = False) -> InlineKeyboardMarkup:
    rows = [
        [
            InlineKeyboardButton("ℹ️ Detail", callback_data=f"vpsinfo:{name}"),
            InlineKeyboardButton("📊 Resource", callback_data=f"vpsstats:{name}"),
        ],
        [
            InlineKeyboardButton("▶️ Start", callback_data=f"act:start:{name}"),
            InlineKeyboardButton("⏹ Stop", callback_data=f"act:stop:{name}"),
            InlineKeyboardButton("🔄 Restart", callback_data=f"act:restart:{name}"),
        ],
        [
            InlineKeyboardButton("⏳ Renew", callback_data=f"act:renew:{name}"),
            InlineKeyboardButton("📅 Set Expire", callback_data=f"act:setexpire:{name}"),
            InlineKeyboardButton("🔑 Password", callback_data=f"act:passwd:{name}"),
        ],
        [
            InlineKeyboardButton("📐 Resize", callback_data=f"act:resize:{name}"),
            InlineKeyboardButton("🌐 Ports", callback_data=f"act:ports:{name}"),
        ],
        [
            InlineKeyboardButton("📶 Bandwidth", callback_data=f"vpsbw:{name}"),
            InlineKeyboardButton("🏷️ Tipe", callback_data=f"vpsplan:{name}"),
        ],
        [
            InlineKeyboardButton("📸 Snapshot", callback_data=f"act:snapshot:{name}"),
            InlineKeyboardButton("💾 Backup", callback_data=f"act:backup:{name}"),
        ],
        [
            InlineKeyboardButton("♻️ Reinstall", callback_data=f"act:reinstall:{name}"),
            InlineKeyboardButton("✅ Unsuspend" if suspended else "⏸ Suspend", callback_data=f"act:{'unsuspend' if suspended else 'suspend'}:{name}"),
        ],
        [
            InlineKeyboardButton("👤 Owner", callback_data=f"act:owner:{name}"),
        ],
        [InlineKeyboardButton("🗑 Hapus VPS", callback_data=f"danger:delete:{name}")],
        [InlineKeyboardButton("⬅️ Daftar VPS", callback_data="menu:vps")],
    ]
    return InlineKeyboardMarkup(rows)


async def format_vps_info(name: str, include_password: bool = False) -> tuple[int, str, str]:
    rc, out = await run_cli(["info", name])
    if rc != 0:
        return rc, f"❌ <b>Gagal mengambil detail {esc(name)}</b>\n{esc_pre(out)}", out

    values: dict[str, str] = {}
    port_lines: list[str] = []
    in_ports = False
    for raw in out.splitlines():
        line = raw.rstrip()
        if line.startswith("Port map"):
            in_ports = True
            continue
        if in_ports:
            if line.strip():
                port_lines.append(line.strip())
            continue
        match = re.match(r"^\s*([^:]+):\s*(.*)$", line)
        if match:
            values[match.group(1).strip()] = match.group(2).strip()

    status = values.get("Status", "?")
    suspended = "SUSPENDED" in status.upper()
    status_key = "SUSPENDED" if suspended else status.split(" ", 1)[0]
    body = [
        f"🖥️ <b>{esc(name)}</b>",
        fmt_bool_status(status_key),
        "",
        f"⚙️ <b>Spesifikasi</b>\n<code>{esc(values.get('Spesifikasi', values.get('Spek', '-')))}</code>",
        f"🌐 IP lokal: <code>{esc(values.get('IP Lokal', '-'))}</code>",
        f"📅 Dibuat: <code>{esc(values.get('Dibuat', '-'))}</code>",
        f"⏱ Expired: <code>{esc(values.get('Expired', '-'))}</code>",
    ]
    owner = values.get("Owner")
    if owner:
        body.append(f"👤 Owner: <code>{esc(owner)}</code>")
    body.append(f"🔐 SSH: <code>{esc(values.get('SSH', '-'))}</code>")

    if include_password:
        password = values.get("Password", "-")
        body.append(f"🔑 Password: <tg-spoiler><code>{esc(password)}</code></tg-spoiler>")

    if port_lines:
        body.extend(["", "🌐 <b>Port Forward</b>", f"<pre>{esc(chr(10).join(port_lines))}</pre>"])

    return rc, "\n".join(body), values.get("Password", "")


async def send_vps_list(target, as_query=False) -> None:
    if as_query:
        rc, out = await run_cli(["list"])
    else:
        rc, out = await run_cli(["list"])
    if rc != 0:
        text = f"❌ <b>Gagal mengambil daftar VPS</b>\n{esc_pre(out)}"
        if as_query:
            await edit(target, text, reply_markup=back_keyboard())
        else:
            await reply(target, text)
        return

    rows: list[tuple[str, str, str, str, str, str, str, str, str, str]] = []
    for raw in out.splitlines():
        line = raw.strip()
        if not line or line.startswith("NAME ") or line.startswith("-") or line == "(kosong)":
            continue
        parts = re.split(r"\s+", line, maxsplit=9)
        if len(parts) == 10 and valid_name(parts[0]):
            rows.append(tuple(parts))
        elif len(parts) == 9 and valid_name(parts[0]):
            # Backward compatibility with a pre-3.0 installed CLI.
            rows.append((parts[0], "shared", parts[1], parts[2], parts[3], parts[4], parts[5], parts[6], parts[7], parts[8]))

    if not rows:
        text = "🖥️ <b>VPS</b>\n\nBelum ada VPS terdaftar."
        kb = InlineKeyboardMarkup(
            [
                [InlineKeyboardButton("➕ Buat VPS", callback_data="menu:create")],
                [InlineKeyboardButton("⬅️ Menu utama", callback_data="menu:home")],
            ]
        )
    else:
        buttons = []
        for name, plan, vtype, state, ip, cpu, ram, disk, ssh, bw in rows:
            icon = {"RUNNING": "🟢", "STOPPED": "🔴", "SUSPEND": "🟠", "MISSING": "⚫"}.get(state, "⚪")
            buttons.append(
                [InlineKeyboardButton(f"{icon} {name}  •  {plan}/{state}  •  {bw}", callback_data=f"vps:{name}")]
            )
        buttons.append(
            [
                InlineKeyboardButton("➕ Buat VPS", callback_data="menu:create"),
                InlineKeyboardButton("🔄 Refresh", callback_data="menu:vps"),
            ]
        )
        buttons.append([InlineKeyboardButton("⬅️ Menu utama", callback_data="menu:home")])
        text = f"🖥️ <b>VPS</b>\n\n<b>Total:</b> {len(rows)}\nPilih VPS untuk membuka kontrol."
        kb = InlineKeyboardMarkup(buttons)

    if as_query:
        await edit(target, text, reply_markup=kb)
    else:
        await reply(target, text, reply_markup=kb)


async def send_main(target, greeting: bool = False) -> None:
    title = "🛠️ <b>VPSNAT Control</b>" if greeting else "🛠️ <b>Menu Utama</b>"
    text = (
        f"{title}\n\n"
        "Kelola VPS, port, snapshot, backup, dan masa aktif tanpa perlu mengetik command manual.\n"
        "Command lama tetap tersedia sebagai fallback."
    )
    if isinstance(target, Update):
        await reply(target, text, reply_markup=main_keyboard())
    else:
        await edit(target, text, reply_markup=main_keyboard())


async def run_action(name: str, argv: list[str], label: str, env: dict[str, str] | None = None, timeout: int = 900) -> tuple[int, str]:
    async with _op_lock:
        return await run_cli(argv, env, timeout=timeout)


async def result_for_action(name: str, label: str, rc: int, out: str, include_info: bool = False) -> tuple[str, InlineKeyboardMarkup | None]:
    if rc != 0:
        return f"❌ <b>{esc(label)}</b> — <code>{esc(name)}</code>\n{esc_pre(out)}", None
    if include_info:
        info_rc, info_text, _ = await format_vps_info(name)
        if info_rc == 0:
            return f"✅ <b>{esc(label)}</b>\n\n{info_text}", vps_action_keyboard(name)
    return f"✅ <b>{esc(label)}</b> — <code>{esc(name)}</code>\n{esc_pre(out)}", vps_action_keyboard(name)


# ---------------- command fallback ----------------
HELP = """<b>VPSNAT Bot</b>\n\n<b>Menu utama</b>: /start atau /menu\n\n<b>Read-only</b>\n/list — daftar VPS\n/info &lt;n&gt; — detail\n/ports &lt;n&gt; — port\n/host — info host\n/expiring [hari] — segera expired\n\n<b>Kontrol</b>\n/start_vps &lt;n&gt;  /stop &lt;n&gt;  /restart &lt;n&gt;\n/suspend &lt;n&gt;  /unsuspend &lt;n&gt;\n/passwd &lt;n&gt; [password]\n/resize &lt;n&gt; &lt;cpu&gt; &lt;ram_mb&gt; &lt;disk_gb&gt;\n\n<b>Buat / hapus</b>\n/create &lt;n&gt; &lt;image&gt; &lt;cpu&gt; &lt;ram&gt; &lt;disk&gt; &lt;expired&gt; [owner] [shared|dedicated]\n/delete &lt;n&gt;\n/reinstall &lt;n&gt; [image]\n\n<b>Expired</b>\n/renew &lt;n&gt; &lt;durasi&gt;\n/setexpire &lt;n&gt; &lt;durasi|tanggal|never&gt;\n/owner &lt;n&gt; &lt;label&gt;\n\n<b>Port</b>\n/portadd &lt;n&gt; &lt;tcp|udp|both&gt; &lt;jumlah&gt;\n/portdel &lt;n&gt; &lt;publik&gt;\n\n<b>Data</b>\n/snapshot &lt;n&gt; &lt;create|list|restore|delete&gt; [nama]\n/backup &lt;n&gt;\n/sync\n\n/cancel — batalkan input yang sedang aktif\n"""


async def simple(update: Update, args: list[str], need_name: bool = True, label: str = "") -> None:
    if need_name and (len(args) < 2 or not valid_name(args[1])):
        await reply(update, "❌ Nama VPS tidak valid / kosong.")
        return
    async with _op_lock:
        rc, out = await run_cli(args)
    icon = "✅" if rc == 0 else "❌"
    await reply(update, f"{icon} <b>{esc(label)}</b>\n{esc_pre(out)}")


@admin_only
async def cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    clear_state(update.effective_user.id)
    await send_main(update, greeting=True)


@admin_only
async def cmd_help(update, ctx):
    await reply(update, HELP, reply_markup=back_keyboard())


@admin_only
async def cmd_cancel(update, ctx):
    clear_state(update.effective_user.id)
    await reply(update, "✅ Input dibatalkan.", reply_markup=main_keyboard())


async def cmd_whoami(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    await reply(update, f"ID kamu: <code>{update.effective_user.id}</code>")


@admin_only
async def cmd_list(update, ctx):
    await send_vps_list(update)


@admin_only
async def cmd_host(update, ctx):
    rc, out = await run_cli(["host"])
    if rc != 0:
        await reply(update, f"❌ <b>Host</b>\n{esc_pre(out)}")
        return
    await reply(update, f"🖥️ <b>Host</b>\n{esc_pre(out)}", reply_markup=back_keyboard())


@admin_only
async def cmd_expiring(update, ctx):
    days = ctx.args[0] if ctx.args and ctx.args[0].isdigit() else "7"
    rc, out = await run_cli(["expiring", days])
    if rc != 0:
        await reply(update, f"❌ <b>VPS Expiring</b>\n{esc_pre(out)}", reply_markup=back_keyboard())
        return
    await reply(update, f"🧾 <b>Expired ≤ {esc(days)} hari</b>\n{esc_pre(out)}", reply_markup=back_keyboard())


@admin_only
async def cmd_info(update, ctx):
    if not ctx.args or not valid_name(ctx.args[0]):
        await reply(update, "Pakai: /info &lt;n&gt;")
        return
    rc, text, _ = await format_vps_info(ctx.args[0], include_password=True)
    await reply(update, text, reply_markup=vps_action_keyboard(ctx.args[0]) if rc == 0 else back_keyboard())


@admin_only
async def cmd_ports(update, ctx):
    if not ctx.args or not valid_name(ctx.args[0]):
        await reply(update, "Pakai: /ports &lt;n&gt;")
        return
    await show_ports(update, ctx.args[0])


@admin_only
async def cmd_start_vps(update, ctx):
    await legacy_simple_name(update, ctx, "start", "Start", True)


@admin_only
async def cmd_stop(update, ctx):
    await legacy_simple_name(update, ctx, "stop", "Stop", True)


@admin_only
async def cmd_restart(update, ctx):
    await legacy_simple_name(update, ctx, "restart", "Restart", True)


@admin_only
async def cmd_suspend(update, ctx):
    await legacy_simple_name(update, ctx, "suspend", "Suspend", True)


@admin_only
async def cmd_unsuspend(update, ctx):
    await legacy_simple_name(update, ctx, "unsuspend", "Unsuspend", True)


@admin_only
async def cmd_sync(update, ctx):
    await simple(update, ["sync"], need_name=False, label="Sync")


@admin_only
async def cmd_backup(update, ctx):
    if not ctx.args or not valid_name(ctx.args[0]):
        await reply(update, "Pakai: /backup &lt;n&gt;")
        return
    await reply(update, "⏳ Backup berjalan…")
    rc, out = await run_action(ctx.args[0], ["backup", ctx.args[0]], "backup", timeout=1800)
    text, kb = await result_for_action(ctx.args[0], "Backup", rc, out)
    await reply(update, text, reply_markup=kb or back_keyboard())


async def legacy_simple_name(update: Update, ctx, action: str, label: str, need_name: bool = True):
    if need_name and (not ctx.args or not valid_name(ctx.args[0])):
        await reply(update, f"Pakai: /{action if action != 'start' else 'start_vps'} &lt;n&gt;")
        return
    name = ctx.args[0]
    rc, out = await run_action(name, [action, name], label)
    text, kb = await result_for_action(name, label, rc, out, include_info=rc == 0)
    await reply(update, text, reply_markup=kb or back_keyboard())


@admin_only
async def cmd_renew(update, ctx):
    a = ctx.args
    if len(a) < 2 or not valid_name(a[0]) or not REL_DUR_RE.fullmatch(a[1]):
        await reply(update, "Pakai: /renew &lt;n&gt; &lt;30d|2w|1m|12h&gt;")
        return
    await handle_renew(update.effective_chat.id, update, a[0], a[1])


@admin_only
async def cmd_setexpire(update, ctx):
    a = ctx.args
    if len(a) < 2 or not valid_name(a[0]) or not DUR_RE.fullmatch(a[1]):
        await reply(update, "Pakai: /setexpire &lt;n&gt; &lt;30d|2026-12-31|never&gt;")
        return
    rc, out = await run_action(a[0], ["set-expire", a[0], a[1]], "set-expire")
    text, kb = await result_for_action(a[0], "Set expired", rc, out, include_info=rc == 0)
    await reply(update, text, reply_markup=kb or back_keyboard())


@admin_only
async def cmd_owner(update, ctx):
    if len(ctx.args) < 2 or not valid_name(ctx.args[0]):
        await reply(update, "Pakai: /owner &lt;n&gt; &lt;label&gt;")
        return
    label = " ".join(ctx.args[1:]).replace("|", "")[:OWNER_MAX]
    rc, out = await run_action(ctx.args[0], ["set-owner", ctx.args[0], label], "owner")
    text, kb = await result_for_action(ctx.args[0], "Owner", rc, out, include_info=rc == 0)
    await reply(update, text, reply_markup=kb or back_keyboard())


@admin_only
async def cmd_passwd(update, ctx):
    if not ctx.args or not valid_name(ctx.args[0]):
        await reply(update, "Pakai: /passwd &lt;n&gt; [password]")
        return
    env: dict[str, str] = {}
    if len(ctx.args) > 1:
        if "|" in ctx.args[1]:
            await reply(update, "❌ Password tidak boleh mengandung |")
            return
        env["PASS"] = ctx.args[1]
    rc, out = await run_action(ctx.args[0], ["passwd", ctx.args[0]], "passwd", env)
    if rc == 0:
        info_rc, text, _ = await format_vps_info(ctx.args[0], include_password=True)
        await reply(update, f"✅ <b>Password diperbarui</b>\n\n{text if info_rc == 0 else esc_pre(out)}", reply_markup=vps_action_keyboard(ctx.args[0]))
    else:
        await reply(update, f"❌ <b>Password</b>\n{esc_pre(out)}", reply_markup=vps_action_keyboard(ctx.args[0]))


@admin_only
async def cmd_resize(update, ctx):
    a = ctx.args
    if len(a) != 4 or not valid_name(a[0]) or not all(x.isdigit() for x in a[1:]):
        await reply(update, "Pakai: /resize &lt;n&gt; &lt;cpu&gt; &lt;ram_mb&gt; &lt;disk_gb&gt;")
        return
    await do_resize(update, a[0], a[1], a[2], a[3])


@admin_only
async def cmd_create(update, ctx):
    a = ctx.args
    if len(a) < 6:
        await reply(update, "Pakai: /create &lt;n&gt; &lt;image&gt; &lt;cpu&gt; &lt;ram&gt; &lt;disk&gt; &lt;expired&gt; [owner] [shared|dedicated]")
        return
    name, image, cpu, ram, disk, exp = a[:6]
    plan = "shared"
    owner_parts = a[6:]
    if owner_parts and owner_parts[-1] in ("shared", "dedicated"):
        plan = owner_parts.pop()
    owner = " ".join(owner_parts).replace("|", "")[:OWNER_MAX] or "-"
    if not valid_name(name) or not all(x.isdigit() for x in (cpu, ram, disk)) or not DUR_RE.fullmatch(exp) or plan not in ("shared", "dedicated"):
        await reply(update, "❌ Argumen tidak valid.")
        return
    if not IMAGE_RE.fullmatch(image):
        await reply(update, "❌ Nama image tidak valid.")
        return
    await execute_create(update, name, image, cpu, ram, disk, exp, owner, plan)


@admin_only
async def cmd_bandwidth(update, ctx):
    a = ctx.args
    if not a or not valid_name(a[0]):
        await reply(update, "Pakai: /bandwidth &lt;n&gt; [show|set|reset|limit] [quota_gb] [mbps]")
        return
    action = a[1] if len(a) > 1 else "show"
    if action not in ("show", "set", "reset", "limit"):
        await reply(update, "❌ Aksi bandwidth harus show/set/reset/limit.")
        return
    if action == "set" and (len(a) != 4 or not re.fullmatch(r"(?:[0-9]+(?:\.[0-9]+)?)", a[2]) or not re.fullmatch(r"(?:[0-9]+(?:\.[0-9]+)?)", a[3])):
        await reply(update, "Pakai: /bandwidth &lt;n&gt; set &lt;quota_gb&gt; &lt;mbps&gt;")
        return
    if action == "limit" and (len(a) != 3 or not re.fullmatch(r"(?:[0-9]+(?:\.[0-9]+)?)", a[2])):
        await reply(update, "Pakai: /bandwidth &lt;n&gt; limit &lt;mbps&gt;")
        return
    if action == "reset" and len(a) != 2:
        await reply(update, "Pakai: /bandwidth &lt;n&gt; reset")
        return
    if action == "set":
        argv = ["bandwidth", a[0], "set", a[2], a[3]]
    elif action == "limit":
        argv = ["bandwidth", a[0], "limit", a[2]]
    else:
        argv = ["bandwidth", a[0], action]
    rc, out = await run_action(a[0], argv, "bandwidth")
    text, kb = await result_for_action(a[0], "Bandwidth", rc, out, include_info=rc == 0)
    await reply(update, text, reply_markup=kb or back_keyboard(f"vps:{a[0]}"))


@admin_only
async def cmd_settings(update, ctx):
    if ctx.args:
        await reply(update, "Gunakan CLI host untuk mengubah settings: <code>vpsnat settings set &lt;key&gt; &lt;value&gt;</code>")
        return
    rc, out = await run_cli(["settings", "show"])
    await reply(update, f"{'⚙️' if rc == 0 else '❌'} <b>VPSNAT Settings</b>\n{esc_pre(out)}", reply_markup=back_keyboard())


@admin_only
async def cmd_settype(update, ctx):
    a = ctx.args
    if len(a) != 2 or not valid_name(a[0]) or a[1] not in ("shared", "dedicated"):
        await reply(update, "Pakai: /settype &lt;n&gt; &lt;shared|dedicated&gt;")
        return
    rc, out = await run_action(a[0], ["set-type", a[0], a[1]], "Tipe layanan")
    text, kb = await result_for_action(a[0], "Tipe layanan", rc, out, include_info=rc == 0)
    await reply(update, text, reply_markup=kb or back_keyboard(f"vps:{a[0]}"))

@admin_only
async def cmd_portadd(update, ctx):
    a = ctx.args
    if len(a) < 3 or not valid_name(a[0]) or a[1] not in ("tcp", "udp", "both") or not a[2].isdigit():
        await reply(update, "Pakai: /portadd &lt;n&gt; &lt;tcp|udp|both&gt; &lt;jumlah&gt;")
        return
    env = {"PROTO": a[1], "COUNT": a[2]}
    rc, out = await run_action(a[0], ["port-add", a[0]], "port-add", env)
    text, kb = await result_for_action(a[0], "Port ditambahkan", rc, out)
    await reply(update, text, reply_markup=kb or back_keyboard())


@admin_only
async def cmd_portdel(update, ctx):
    a = ctx.args
    if len(a) != 2 or not valid_name(a[0]) or not a[1].isdigit():
        await reply(update, "Pakai: /portdel &lt;n&gt; &lt;publik&gt;")
        return
    await confirm_cli(
        update,
        f"Hapus port publik <b>{esc(a[1])}</b> dari <b>{esc(a[0])}</b>?",
        ["port-del", a[0]],
        {"EXT": a[1]},
        back_to=f"vps:{a[0]}",
    )


@admin_only
async def cmd_snapshot(update, ctx):
    a = ctx.args
    if len(a) < 2 or not valid_name(a[0]) or a[1] not in ("create", "list", "restore", "delete"):
        await reply(update, "Pakai: /snapshot &lt;n&gt; &lt;create|list|restore|delete&gt; [nama]")
        return
    snap = a[2] if len(a) > 2 and re.fullmatch(r"[A-Za-z0-9._-]{1,64}", a[2]) else ""
    if a[1] in ("restore", "delete") and not snap:
        await reply(update, "Nama snapshot wajib untuk restore/delete.")
        return
    if a[1] == "restore":
        await confirm_cli(update, f"Restore <b>{esc(a[0])}</b> ke snapshot <b>{esc(snap)}</b>?", ["snapshot", a[0], "restore", snap], back_to=f"vps:{a[0]}")
        return
    rc, out = await run_action(a[0], ["snapshot", a[0], a[1], snap], "snapshot")
    await reply(update, f"{'✅' if rc == 0 else '❌'} <b>Snapshot</b>\n{esc_pre(out)}", reply_markup=back_keyboard(f"vps:{a[0]}"))


@admin_only
async def cmd_delete(update, ctx):
    if not ctx.args or not valid_name(ctx.args[0]):
        await reply(update, "Pakai: /delete &lt;n&gt;")
        return
    await confirm_cli(update, f"HAPUS permanen <b>{esc(ctx.args[0])}</b> beserta seluruh datanya?", ["delete", ctx.args[0]], back_to="menu:vps")


@admin_only
async def cmd_reinstall(update, ctx):
    if not ctx.args or not valid_name(ctx.args[0]):
        await reply(update, "Pakai: /reinstall &lt;n&gt; [image]")
        return
    image = ctx.args[1] if len(ctx.args) > 1 else "ubuntu22"
    if not IMAGE_RE.fullmatch(image):
        await reply(update, "❌ Nama image tidak valid.")
        return
    await confirm_cli(
        update,
        f"REINSTALL <b>{esc(ctx.args[0])}</b> dengan <code>{esc(image)}</code>? Data VPS akan hilang.",
        ["reinstall", ctx.args[0]],
        {"IMG_KEY": image},
        back_to=f"vps:{ctx.args[0]}",
    )


# ---------------- confirmation ----------------
async def confirm_cli(update: Update, text: str, argv: list[str], env: dict[str, str] | None = None, back_to: str = "menu:home") -> None:
    token = secrets.token_hex(4)
    _pending[token] = (update.effective_chat.id, argv, env or {}, time.time() + TOKEN_TTL)
    kb = InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton("✅ Ya, lanjut", callback_data=f"ok:{token}"),
                InlineKeyboardButton("✖ Batal", callback_data=f"no:{token}"),
            ],
            [InlineKeyboardButton("⬅️ Kembali", callback_data=back_to)],
        ]
    )
    await reply(update, f"⚠️ {text}\n\n<i>Konfirmasi berlaku {TOKEN_TTL} detik.</i>", reply_markup=kb)


# ---------------- interactive menus ----------------
async def show_vps_card(query, name: str) -> None:
    rc, text, _ = await format_vps_info(name)
    if rc != 0:
        await edit(query, text, reply_markup=back_keyboard("menu:vps"))
        return
    values = {}
    for line in text.splitlines():
        # UI keyboard hanya butuh status suspended, info detail tetap di text.
        if "SUSPENDED" in line.upper():
            values["suspended"] = True
    await edit(query, text, reply_markup=vps_action_keyboard(name, suspended=bool(values.get("suspended"))))


async def show_ports(target, name: str, query_mode: bool = False) -> None:
    rc, out = await run_cli(["port-list", name])
    if rc != 0:
        text = f"❌ <b>Port {esc(name)}</b>\n{esc_pre(out)}"
    else:
        rows = [x.strip() for x in out.splitlines() if "->" in x]
        if rows:
            text = f"🌐 <b>Port Forward — {esc(name)}</b>\n\n<pre>{esc(chr(10).join(rows))}</pre>"
        else:
            text = f"🌐 <b>Port Forward — {esc(name)}</b>\n\nTidak ada port aplikasi tambahan."
    kb = port_keyboard(name, rows if rc == 0 else [])
    if query_mode:
        await edit(target, text, reply_markup=kb)
    else:
        await reply(target, text, reply_markup=kb)


def port_keyboard(name: str, rows: list[str]) -> InlineKeyboardMarkup:
    unique: list[str] = []
    seen = set()
    for row in rows:
        match = re.search(r"(?:tcp|udp|both)[+a-z]*\s+[^:]+:(\d+)\s+->", row, flags=re.I)
        if not match:
            match = re.search(r":(\d+)\s*->", row)
        if match and match.group(1) not in seen:
            seen.add(match.group(1))
            unique.append(match.group(1))
    buttons = [[InlineKeyboardButton("➕ Tambah port", callback_data=f"portadd:{name}")]]
    if unique:
        buttons.append([InlineKeyboardButton(f"🗑 Hapus {p}", callback_data=f"portdel:{name}:{p}") for p in unique[:3]])
        for i in range(3, len(unique), 3):
            buttons.append([InlineKeyboardButton(f"🗑 Hapus {p}", callback_data=f"portdel:{name}:{p}") for p in unique[i:i + 3]])
    buttons.append([InlineKeyboardButton("⬅️ VPS", callback_data=f"vps:{name}")])
    return InlineKeyboardMarkup(buttons)


async def execute_create(update: Update, name: str, image: str, cpu: str, ram: str, disk: str, exp: str, owner: str, plan: str = "shared") -> None:
    await reply(update, f"⏳ <b>Membuat {esc(name)}</b>…\n<code>{esc(image)} • {esc(cpu)} CPU • {esc(ram)} MB • {esc(disk)} GB • {esc(exp)}</code>")
    env = {
        "NAME": name,
        "IMG_KEY": image,
        "CPU": cpu,
        "RAM": ram,
        "DISK": disk,
        "EXPIRE": exp,
        "OWNER": owner or "-",
        "PLAN_TYPE": plan,
        "NPORTS": "3",
        "NESTING": "y",
    }
    rc, out = await run_action(name, ["create", name], "create", env, timeout=1800)
    if rc != 0:
        await reply(update, f"❌ <b>Create gagal</b>\n{esc_pre(out)}", reply_markup=back_keyboard("menu:create"))
        return
    info_rc, info_text, _ = await format_vps_info(name)
    if info_rc == 0:
        await reply(update, f"✅ <b>VPS berhasil dibuat</b>\n\n{info_text}", reply_markup=vps_action_keyboard(name))
    else:
        await reply(update, f"✅ <b>VPS {esc(name)} berhasil dibuat</b>\n{esc_pre(out)}", reply_markup=vps_action_keyboard(name))


async def do_resize(update_or_query, name: str, cpu: str, ram: str, disk: str, query_mode: bool = False) -> None:
    rc, out = await run_action(name, ["resize", name], "resize", {"CPU": cpu, "RAM": ram, "DISK": disk})
    if rc == 0:
        info_rc, info_text, _ = await format_vps_info(name)
        text = f"✅ <b>Resize berhasil</b>\n\n{info_text}" if info_rc == 0 else f"✅ <b>Resize berhasil</b>\n{esc_pre(out)}"
    else:
        text = f"❌ <b>Resize gagal</b>\n{esc_pre(out)}"
    kb = vps_action_keyboard(name) if rc == 0 else back_keyboard(f"vps:{name}")
    if query_mode:
        await edit(update_or_query, text, reply_markup=kb)
    else:
        await reply(update_or_query, text, reply_markup=kb)


async def handle_renew(chat_id: int, target, name: str, duration: str, query_mode: bool = False) -> None:
    rc, out = await run_action(name, ["renew", name, duration], "renew")
    text, kb = await result_for_action(name, f"Renew {duration}", rc, out, include_info=rc == 0)
    kb = kb or back_keyboard(f"vps:{name}")
    if query_mode:
        await edit(target, text, reply_markup=kb)
    else:
        await reply(target, text, reply_markup=kb)


async def show_renew_menu(query, name: str) -> None:
    kb = InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton("+7 hari", callback_data=f"renew:{name}:7d"),
                InlineKeyboardButton("+30 hari", callback_data=f"renew:{name}:30d"),
            ],
            [
                InlineKeyboardButton("+60 hari", callback_data=f"renew:{name}:60d"),
                InlineKeyboardButton("+90 hari", callback_data=f"renew:{name}:90d"),
            ],
            [InlineKeyboardButton("⌨️ Durasi custom", callback_data=f"custom:renew:{name}")],
            [InlineKeyboardButton("⬅️ VPS", callback_data=f"vps:{name}")],
        ]
    )
    await edit(query, f"⏳ <b>Renew {esc(name)}</b>\n\nPilih tambahan masa aktif:", reply_markup=kb)


async def show_resize_menu(query, name: str) -> None:
    set_state(query.from_user.id, "resize_cpu", name=name)
    kb = InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton("1 CPU", callback_data=f"resizecpu:{name}:1"),
                InlineKeyboardButton("2 CPU", callback_data=f"resizecpu:{name}:2"),
                InlineKeyboardButton("4 CPU", callback_data=f"resizecpu:{name}:4"),
            ],
            [
                InlineKeyboardButton("8 CPU", callback_data=f"resizecpu:{name}:8"),
                InlineKeyboardButton("⌨️ Custom", callback_data=f"custom:resizecpu:{name}"),
            ],
            [InlineKeyboardButton("⬅️ VPS", callback_data=f"vps:{name}")],
        ]
    )
    await edit(query, f"📐 <b>Resize {esc(name)}</b>\n\n1/3: pilih CPU", reply_markup=kb)


async def show_passwd_menu(query, name: str) -> None:
    kb = InlineKeyboardMarkup(
        [
            [InlineKeyboardButton("🎲 Generate random", callback_data=f"passwdgen:{name}")],
            [InlineKeyboardButton("⌨️ Password custom", callback_data=f"custom:passwd:{name}")],
            [InlineKeyboardButton("⬅️ VPS", callback_data=f"vps:{name}")],
        ]
    )
    await edit(query, f"🔑 <b>Password {esc(name)}</b>\n\nPilih cara mengganti password:", reply_markup=kb)


async def show_owner_menu(query, name: str) -> None:
    kb = InlineKeyboardMarkup(
        [
            [InlineKeyboardButton("👤 Hapus owner", callback_data=f"owner:{name}:clear")],
            [InlineKeyboardButton("⌨️ Isi owner / label", callback_data=f"custom:owner:{name}")],
            [InlineKeyboardButton("⬅️ VPS", callback_data=f"vps:{name}")],
        ]
    )
    await edit(query, f"👤 <b>Owner {esc(name)}</b>\n\nPilih aksi:", reply_markup=kb)


async def show_portadd_menu(query, name: str) -> None:
    kb = InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton("TCP", callback_data=f"portproto:{name}:tcp"),
                InlineKeyboardButton("UDP", callback_data=f"portproto:{name}:udp"),
                InlineKeyboardButton("TCP + UDP", callback_data=f"portproto:{name}:both"),
            ],
            [InlineKeyboardButton("⬅️ Ports", callback_data=f"ports:{name}")],
        ]
    )
    await edit(query, f"➕ <b>Tambah Port — {esc(name)}</b>\n\n1/2: pilih protokol", reply_markup=kb)


async def show_bandwidth_menu(query, name: str) -> None:
    rc, out = await run_cli(["bandwidth", name, "show"])
    if rc != 0:
        await edit(query, f"❌ <b>Bandwidth {esc(name)}</b>\n{esc_pre(out)}", reply_markup=back_keyboard(f"vps:{name}"))
        return
    kb = InlineKeyboardMarkup([
        [InlineKeyboardButton("100 GB / 50 Mbps", callback_data=f"bwpreset:{name}:100:50"), InlineKeyboardButton("500 GB / 100 Mbps", callback_data=f"bwpreset:{name}:500:100")],
        [InlineKeyboardButton("1 TB / 200 Mbps", callback_data=f"bwpreset:{name}:1000:200"), InlineKeyboardButton("∞ / 100 Mbps", callback_data=f"bwpreset:{name}:0:100")],
        [InlineKeyboardButton("⌨️ Custom quota + speed", callback_data=f"custom:bw:{name}")],
        [InlineKeyboardButton("♻️ Reset pemakaian", callback_data=f"bwreset:{name}")],
        [InlineKeyboardButton("⬅️ VPS", callback_data=f"vps:{name}")],
    ])
    await edit(query, f"📶 <b>Bandwidth — {esc(name)}</b>\n\n{esc_pre(out)}\nPilih preset atau masukkan <code>quota_gb speed_mbps</code> untuk custom.", reply_markup=kb)


async def show_plan_menu(query, name: str) -> None:
    current = "shared"
    rc, out = await run_cli(["info", name])
    if rc == 0:
        match = re.search(r"^Tipe layanan\s*:\s*(shared|dedicated)", out, re.M)
        if match:
            current = match.group(1)
    kb = InlineKeyboardMarkup([
        [InlineKeyboardButton("✅ Shared" if current == "shared" else "Shared", callback_data=f"setplan:{name}:shared"), InlineKeyboardButton("✅ Dedicated" if current == "dedicated" else "Dedicated", callback_data=f"setplan:{name}:dedicated")],
        [InlineKeyboardButton("⬅️ VPS", callback_data=f"vps:{name}")],
    ])
    await edit(query, f"🏷️ <b>Tipe layanan — {esc(name)}</b>\n\nSaat ini: <b>{esc(current)}</b>", reply_markup=kb)


async def show_snapshot_menu(query, name: str) -> None:
    rc, out = await run_cli(["snapshot", name, "list", ""])
    snapshots = parse_snapshots(out) if rc == 0 else []
    buttons = [
        [InlineKeyboardButton("➕ Buat snapshot", callback_data=f"snapcreate:{name}")],
    ]
    if snapshots:
        buttons.append([InlineKeyboardButton("♻️ Restore snapshot", callback_data=f"snaprestore:{name}")])
        buttons.append([InlineKeyboardButton("🗑 Hapus snapshot", callback_data=f"snapdelete:{name}")])
        text = f"📸 <b>Snapshot — {esc(name)}</b>\n\n" + "\n".join(f"• <code>{esc(s)}</code>" for s in snapshots)
    else:
        text = f"📸 <b>Snapshot — {esc(name)}</b>\n\nBelum ada snapshot."
    buttons.append([InlineKeyboardButton("⬅️ VPS", callback_data=f"vps:{name}")])
    await edit(query, text, reply_markup=InlineKeyboardMarkup(buttons))


def parse_snapshots(out: str) -> list[str]:
    found: list[str] = []
    in_section = False
    for raw in out.splitlines():
        line = raw.strip()
        if line.lower().startswith("snapshots:"):
            in_section = True
            continue
        if not in_section:
            continue
        if not line:
            continue
        match = re.match(r"^[|\-_*\s]*([A-Za-z0-9][A-Za-z0-9._-]{0,63})(?:\s|$)", line)
        if match and match.group(1).lower() not in {"snapshot", "name", "snapshots"}:
            found.append(match.group(1))
    return list(dict.fromkeys(found))


async def show_snapshot_picker(query, name: str, mode: str) -> None:
    rc, out = await run_cli(["snapshot", name, "list", ""])
    snapshots = parse_snapshots(out) if rc == 0 else []
    if not snapshots:
        await edit(query, f"📸 Tidak ada snapshot untuk <b>{esc(name)}</b>.", reply_markup=back_keyboard(f"vps:{name}"))
        return
    buttons = []
    for snap in snapshots:
        token = make_ui_token(query.message.chat_id, f"snapshot:{mode}", {"name": name, "snapshot": snap})
        buttons.append([InlineKeyboardButton(snap, callback_data=f"snap:{mode}:{token}")])
    buttons.append([InlineKeyboardButton("⬅️ Snapshot", callback_data=f"snapshot:{name}")])
    action_text = "restore" if mode == "restore" else "hapus"
    await edit(query, f"📸 Pilih snapshot untuk <b>{action_text}</b>:", reply_markup=InlineKeyboardMarkup(buttons))


async def execute_snapshot_token(query, mode: str, token: str) -> None:
    data = take_ui_token(query.message.chat_id, token, f"snapshot:{mode}")
    if not data:
        await edit(query, "❌ Pilihan snapshot sudah kedaluwarsa. Buka menu snapshot lagi.", reply_markup=back_keyboard("menu:vps"))
        return
    name = data["name"]
    snap = data["snapshot"]
    if mode == "restore":
        await query.answer()
        await ask_confirm_query(query, f"Restore <b>{esc(name)}</b> ke <b>{esc(snap)}</b>?", ["snapshot", name, "restore", snap], f"vps:{name}")
        return
    rc, out = await run_action(name, ["snapshot", name, "delete", snap], "snapshot-delete")
    text = f"{'✅' if rc == 0 else '❌'} <b>Hapus snapshot</b>\n{esc_pre(out)}"
    await edit(query, text, reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("📸 Snapshot", callback_data=f"snapshot:{name}")], [InlineKeyboardButton("⬅️ VPS", callback_data=f"vps:{name}")]]))


async def ask_confirm_query(query, text: str, argv: list[str], back_to: str, env: dict[str, str] | None = None) -> None:
    token = secrets.token_hex(4)
    _pending[token] = (query.message.chat_id, argv, env or {}, time.time() + TOKEN_TTL)
    kb = InlineKeyboardMarkup(
        [
            [InlineKeyboardButton("✅ Ya, lanjut", callback_data=f"ok:{token}"), InlineKeyboardButton("✖ Batal", callback_data=f"no:{token}")],
            [InlineKeyboardButton("⬅️ Kembali", callback_data=back_to)],
        ]
    )
    await edit(query, f"⚠️ {text}\n\n<i>Konfirmasi berlaku {TOKEN_TTL} detik.</i>", reply_markup=kb)


async def execute_button_action(query, action: str, name: str) -> None:
    if action in {"start", "stop", "restart", "suspend", "unsuspend"}:
        await edit(query, f"⏳ <b>{esc(action.title())} {esc(name)}</b>…")
        rc, out = await run_action(name, [action, name], action)
        text, kb = await result_for_action(name, action.title(), rc, out, include_info=rc == 0)
        await edit(query, text, reply_markup=kb or back_keyboard(f"vps:{name}"))
        return
    if action == "backup":
        await edit(query, f"⏳ <b>Backup {esc(name)}</b>…")
        rc, out = await run_action(name, ["backup", name], "backup", timeout=1800)
        text, kb = await result_for_action(name, "Backup", rc, out)
        await edit(query, text, reply_markup=kb or back_keyboard(f"vps:{name}"))
        return
    if action == "ports":
        await show_ports(query, name, query_mode=True)
        return
    if action == "renew":
        await show_renew_menu(query, name)
        return
    if action == "setexpire":
        await show_setexpire_menu(query, name)
        return
    if action == "resize":
        await show_resize_menu(query, name)
        return
    if action == "passwd":
        await show_passwd_menu(query, name)
        return
    if action == "owner":
        await show_owner_menu(query, name)
        return
    if action == "snapshot":
        await show_snapshot_menu(query, name)
        return
    if action == "reinstall":
        await show_reinstall_menu(query, name)
        return
    if action == "stats":
        rc, out = await run_cli(["stats", name])
        text = f"📊 <b>Resource — {esc(name)}</b>\n{esc_pre(out)}"
        await edit(query, text, reply_markup=back_keyboard(f"vps:{name}"))
        return



async def show_setexpire_menu(query, name: str) -> None:
    kb = InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton("30 hari", callback_data=f"setexpire:{name}:30d"),
                InlineKeyboardButton("60 hari", callback_data=f"setexpire:{name}:60d"),
            ],
            [
                InlineKeyboardButton("90 hari", callback_data=f"setexpire:{name}:90d"),
                InlineKeyboardButton("Tanpa expired", callback_data=f"setexpire:{name}:0"),
            ],
            [InlineKeyboardButton("⌨️ Tanggal custom", callback_data=f"custom:setexpire:{name}")],
            [InlineKeyboardButton("⬅️ VPS", callback_data=f"vps:{name}")],
        ]
    )
    await edit(query, f"📅 <b>Set Expire — {esc(name)}</b>\n\nPilih masa aktif baru:", reply_markup=kb)


async def show_reinstall_menu(query, name: str) -> None:
    images = [
        ("Ubuntu 22", "ubuntu22"),
        ("Ubuntu 24", "ubuntu24"),
        ("Debian 12", "debian12"),
        ("Debian 11", "debian11"),
        ("Alpine", "alpine"),
    ]
    buttons = [[InlineKeyboardButton(label, callback_data=f"reinstall:{name}:{image}") for label, image in images[:2]]]
    buttons += [[InlineKeyboardButton(label, callback_data=f"reinstall:{name}:{image}") for label, image in images[2:4]]]
    buttons += [[InlineKeyboardButton(images[4][0], callback_data=f"reinstall:{name}:{images[4][1]}")]]
    buttons += [[InlineKeyboardButton("⌨️ Custom image", callback_data=f"custom:reinstall:{name}")]]
    buttons += [[InlineKeyboardButton("⬅️ VPS", callback_data=f"vps:{name}")]]
    await edit(query, f"♻️ <b>Reinstall {esc(name)}</b>\n\nPilih image:", reply_markup=InlineKeyboardMarkup(buttons))


async def execute_reinstall(query, name: str, image: str) -> None:
    await ask_confirm_query(
        query,
        f"REINSTALL <b>{esc(name)}</b> dengan <code>{esc(image)}</code>? Semua data akan hilang.",
        ["reinstall", name],
        f"vps:{name}",
        {"IMG_KEY": image},
    )


async def start_create_wizard(query) -> None:
    clear_state(query.from_user.id)
    set_state(query.from_user.id, "create_name", create={})
    await edit(
        query,
        "➕ <b>Buat VPS</b>\n\n1/7: kirim <b>nama VPS</b> (contoh: <code>web1</code>).\n\nInput manual hanya diperlukan untuk nama; parameter lain tersedia sebagai button.",
        reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("❌ Batal", callback_data="menu:home")]]),
    )


async def finish_create_summary(query, state: dict[str, Any]) -> None:
    data = state["create"]
    text = (
        "🧾 <b>Konfirmasi pembuatan VPS</b>\n\n"
        f"• Nama: <code>{esc(data['name'])}</code>\n"
        f"• Image: <code>{esc(data['image'])}</code>\n"
        f"• CPU: <code>{esc(data['cpu'])}</code> core\n"
        f"• RAM: <code>{esc(data['ram'])}</code> MB\n"
        f"• Disk: <code>{esc(data['disk'])}</code> GB\n"
        f"• Tipe layanan: <code>{esc(data.get('plan', 'shared'))}</code>\n"
        f"• Expired: <code>{esc(data['expire'])}</code>\n"
        f"• Owner: <code>{esc(data['owner'])}</code>\n"
        "• Port: <code>3</code> (default)\n"
        "• Nesting: <code>yes</code> (default)\n"
        "• Password: <code>random</code> (default)"
    )
    kb = InlineKeyboardMarkup(
        [
            [InlineKeyboardButton("✅ Buat sekarang", callback_data="create:confirm"), InlineKeyboardButton("✖ Batal", callback_data="menu:home")],
            [InlineKeyboardButton("🔧 Ubah parameter", callback_data="create:edit")],
        ]
    )
    await edit(query, text, reply_markup=kb)


# ---------------- button dispatcher ----------------
async def on_button(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    uid = query.from_user.id if query.from_user else 0
    if uid not in ADMINS:
        await query.answer("Akses ditolak.", show_alert=True)
        return
    await query.answer()
    cleanup_expired_memory()
    data = query.data or ""

    try:
        if data.startswith("create:"):
            handled = await on_create_button(query, data.split(":") )
            if handled:
                return

        if data == "menu:home":
            clear_state(uid)
            await send_main(query)
            return
        if data == "menu:vps":
            clear_state(uid)
            await send_vps_list(query, as_query=True)
            return
        if data == "menu:create":
            await start_create_wizard(query)
            return
        if data == "menu:host":
            rc, out = await run_cli(["host"])
            text = f"🖥️ <b>Host</b>\n{esc_pre(out)}" if rc == 0 else f"❌ <b>Host</b>\n{esc_pre(out)}"
            await edit(query, text, reply_markup=back_keyboard())
            return
        if data == "menu:expiring":
            rc, out = await run_cli(["expiring", "7"])
            text = f"🧾 <b>Expired ≤ 7 hari</b>\n{esc_pre(out)}" if rc == 0 else f"❌ <b>Expiring</b>\n{esc_pre(out)}"
            await edit(query, text, reply_markup=back_keyboard())
            return
        if data == "menu:sync":
            await edit(query, "⏳ <b>Sync sedang berjalan…</b>")
            rc, out = await run_action("__host__", ["sync"], "sync")
            text = f"✅ <b>Sync selesai</b>\n{esc_pre(out)}" if rc == 0 else f"❌ <b>Sync gagal</b>\n{esc_pre(out)}"
            await edit(query, text, reply_markup=back_keyboard())
            return
        if data == "menu:help":
            await edit(query, HELP, reply_markup=back_keyboard())
            return

        if data.startswith("vps:"):
            name = data.split(":", 1)[1]
            if not valid_name(name):
                await edit(query, "❌ Nama VPS tidak valid.", reply_markup=back_keyboard("menu:vps"))
                return
            await show_vps_card(query, name)
            return
        if data.startswith("vpsinfo:"):
            name = data.split(":", 1)[1]
            rc, text, _ = await format_vps_info(name, include_password=True)
            await edit(query, text, reply_markup=vps_action_keyboard(name) if rc == 0 else back_keyboard("menu:vps"))
            return
        if data.startswith("vpsstats:"):
            name = data.split(":", 1)[1]
            await execute_button_action(query, "stats", name)
            return
        if data.startswith("act:"):
            _, action, name = data.split(":", 2)
            await execute_button_action(query, action, name)
            return
        if data.startswith("danger:"):
            _, action, name = data.split(":", 2)
            if action == "delete":
                await ask_confirm_query(query, f"HAPUS permanen <b>{esc(name)}</b> beserta seluruh datanya?", ["delete", name], "menu:vps")
            return
        if data.startswith("renew:"):
            _, name, duration = data.split(":", 2)
            await handle_renew(query.message.chat_id, query, name, duration, query_mode=True)
            return
        if data.startswith("resizecpu:"):
            _, name, cpu = data.split(":", 2)
            state = get_state(uid) or {"kind": "resize_cpu"}
            state["kind"] = "resize_ram"
            state["name"] = name
            state["cpu"] = cpu
            _user_state[uid] = state
            kb = InlineKeyboardMarkup(
                [
                    [
                        InlineKeyboardButton("1 GB", callback_data=f"resizeram:{name}:{cpu}:1024"),
                        InlineKeyboardButton("2 GB", callback_data=f"resizeram:{name}:{cpu}:2048"),
                    ],
                    [
                        InlineKeyboardButton("4 GB", callback_data=f"resizeram:{name}:{cpu}:4096"),
                        InlineKeyboardButton("8 GB", callback_data=f"resizeram:{name}:{cpu}:8192"),
                    ],
                    [InlineKeyboardButton("⌨️ Custom MB", callback_data=f"custom:resizeram:{name}:{cpu}")],
                    [InlineKeyboardButton("⬅️ CPU", callback_data=f"act:resize:{name}")],
                ]
            )
            await edit(query, f"📐 <b>Resize {esc(name)}</b>\n\n2/3: pilih RAM", reply_markup=kb)
            return
        if data.startswith("resizeram:"):
            _, name, cpu, ram = data.split(":", 3)
            set_state(uid, "resize_disk", name=name, cpu=cpu, ram=ram)
            kb = InlineKeyboardMarkup(
                [
                    [
                        InlineKeyboardButton("10 GB", callback_data=f"resizedisk:{name}:{cpu}:{ram}:10"),
                        InlineKeyboardButton("20 GB", callback_data=f"resizedisk:{name}:{cpu}:{ram}:20"),
                    ],
                    [
                        InlineKeyboardButton("40 GB", callback_data=f"resizedisk:{name}:{cpu}:{ram}:40"),
                        InlineKeyboardButton("80 GB", callback_data=f"resizedisk:{name}:{cpu}:{ram}:80"),
                    ],
                    [InlineKeyboardButton("⌨️ Custom GB", callback_data=f"custom:resizedisk:{name}:{cpu}:{ram}")],
                    [InlineKeyboardButton("⬅️ RAM", callback_data=f"act:resize:{name}")],
                ]
            )
            await edit(query, f"📐 <b>Resize {esc(name)}</b>\n\n3/3: pilih Disk", reply_markup=kb)
            return
        if data.startswith("resizedisk:"):
            _, name, cpu, ram, disk = data.split(":", 4)
            clear_state(uid)
            await do_resize(query, name, cpu, ram, disk, query_mode=True)
            return
        if data.startswith("passwdgen:"):
            name = data.split(":", 1)[1]
            rc, out = await run_action(name, ["passwd", name], "passwd")
            if rc == 0:
                info_rc, text, _ = await format_vps_info(name, include_password=True)
                await edit(query, f"✅ <b>Password diperbarui</b>\n\n{text if info_rc == 0 else esc_pre(out)}", reply_markup=vps_action_keyboard(name))
            else:
                await edit(query, f"❌ <b>Password</b>\n{esc_pre(out)}", reply_markup=vps_action_keyboard(name))
            return
        if data.startswith("owner:"):
            _, name, mode = data.split(":", 2)
            if mode == "clear":
                rc, out = await run_action(name, ["set-owner", name, "-"], "owner")
                text, kb = await result_for_action(name, "Owner dihapus", rc, out, include_info=rc == 0)
                await edit(query, text, reply_markup=kb or back_keyboard(f"vps:{name}"))
            return
        if data.startswith("vpsbw:"):
            name = data.split(":", 1)[1]
            await show_bandwidth_menu(query, name)
            return
        if data.startswith("vpsplan:"):
            name = data.split(":", 1)[1]
            await show_plan_menu(query, name)
            return
        if data.startswith("bwpreset:"):
            _, name, quota, rate = data.split(":", 3)
            rc, out = await run_action(name, ["bandwidth", name, "set", quota, rate], "bandwidth")
            if rc == 0:
                await show_bandwidth_menu(query, name)
            else:
                text, kb = await result_for_action(name, "Bandwidth", rc, out, include_info=False)
                await edit(query, text, reply_markup=kb or back_keyboard(f"vps:{name}"))
            return
        if data.startswith("bwreset:"):
            name = data.split(":", 1)[1]
            rc, out = await run_action(name, ["bandwidth", name, "reset"], "bandwidth reset")
            await edit(query, f"{'✅' if rc == 0 else '❌'} <b>Reset bandwidth</b>\n{esc_pre(out)}", reply_markup=vps_action_keyboard(name) if rc == 0 else back_keyboard(f"vps:{name}"))
            return
        if data.startswith("setplan:"):
            _, name, plan = data.split(":", 2)
            if plan not in ("shared", "dedicated"):
                await edit(query, "❌ Tipe layanan tidak valid.", reply_markup=back_keyboard(f"vps:{name}"))
                return
            rc, out = await run_action(name, ["set-type", name, plan], "set type")
            text, kb = await result_for_action(name, "Tipe layanan", rc, out, include_info=rc == 0)
            await edit(query, text, reply_markup=kb or back_keyboard(f"vps:{name}"))
            return
        if data.startswith("portadd:"):
            name = data.split(":", 1)[1]
            await show_portadd_menu(query, name)
            return
        if data.startswith("portproto:"):
            _, name, proto = data.split(":", 2)
            set_state(uid, "port_count", name=name, proto=proto)
            await edit(
                query,
                f"➕ <b>Tambah Port — {esc(name)}</b>\n\n2/2: kirim <b>jumlah port</b> (1–500).\nPublic port akan dialokasikan otomatis secara kontigu; port internal disamakan.",
                reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("❌ Batal", callback_data=f"ports:{name}")]]),
            )
            return
        if data.startswith("portdel:"):
            _, name, ext = data.split(":", 2)
            await ask_confirm_query(query, f"Hapus port publik <b>{esc(ext)}</b> dari <b>{esc(name)}</b>?", ["port-del", name], f"ports:{name}", {"EXT": ext})
            return
        if data.startswith("ports:"):
            name = data.split(":", 1)[1]
            await show_ports(query, name, query_mode=True)
            return
        if data.startswith("snapshot:"):
            name = data.split(":", 1)[1]
            await show_snapshot_menu(query, name)
            return
        if data.startswith("snapcreate:"):
            name = data.split(":", 1)[1]
            rc, out = await run_action(name, ["snapshot", name, "create", ""], "snapshot-create")
            await edit(query, f"{'✅' if rc == 0 else '❌'} <b>Snapshot</b>\n{esc_pre(out)}", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("📸 Snapshot", callback_data=f"snapshot:{name}")], [InlineKeyboardButton("⬅️ VPS", callback_data=f"vps:{name}")]]))
            return
        if data.startswith("snaprestore:"):
            name = data.split(":", 1)[1]
            await show_snapshot_picker(query, name, "restore")
            return
        if data.startswith("snapdelete:"):
            name = data.split(":", 1)[1]
            await show_snapshot_picker(query, name, "delete")
            return
        if data.startswith("snap:"):
            _, mode, token = data.split(":", 2)
            await execute_snapshot_token(query, mode, token)
            return
        if data.startswith("setexpire:"):
            _, name, duration = data.split(":", 2)
            if duration == "0" or DUR_RE.fullmatch(duration):
                rc, out = await run_action(name, ["set-expire", name, duration], "set-expire")
                text, kb = await result_for_action(name, "Set expired", rc, out, include_info=rc == 0)
                await edit(query, text, reply_markup=kb or back_keyboard(f"vps:{name}"))
            else:
                await edit(query, "❌ Durasi tidak valid.", reply_markup=back_keyboard(f"vps:{name}"))
            return
        if data.startswith("reinstall:"):
            _, name, image = data.split(":", 2)
            await execute_reinstall(query, name, image)
            return
        if data == "create:edit":
            state = get_state(uid)
            if not state or state.get("kind") != "create_confirm":
                await start_create_wizard(query)
                return
            await start_create_wizard(query)
            return
        if data == "create:confirm":
            state = get_state(uid)
            if not state or state.get("kind") != "create_confirm":
                await edit(query, "❌ Draft pembuatan sudah kedaluwarsa.", reply_markup=main_keyboard())
                return
            clear_state(uid)
            d = state["create"]
            await edit(query, f"⏳ <b>Membuat {esc(d['name'])}</b>…")
            env = {
                "NAME": d["name"],
                "IMG_KEY": d["image"],
                "CPU": d["cpu"],
                "RAM": d["ram"],
                "DISK": d["disk"],
                "EXPIRE": d["expire"],
                "OWNER": d["owner"],
                "PLAN_TYPE": d.get("plan", "shared"),
                "NPORTS": "3",
                "NESTING": "y",
            }
            rc, out = await run_action(d["name"], ["create", d["name"]], "create", env, timeout=1800)
            if rc == 0:
                info_rc, info_text, _ = await format_vps_info(d["name"])
                text = f"✅ <b>VPS berhasil dibuat</b>\n\n{info_text}" if info_rc == 0 else f"✅ <b>VPS berhasil dibuat</b>\n{esc_pre(out)}"
                await edit(query, text, reply_markup=vps_action_keyboard(d["name"]))
            else:
                await edit(query, f"❌ <b>Create gagal</b>\n{esc_pre(out)}", reply_markup=back_keyboard("menu:create"))
            return
        if data.startswith("custom:"):
            _, kind, *rest = data.split(":")
            await begin_custom_input(query, kind, rest)
            return
        if data.startswith("ok:") or data.startswith("no:"):
            await handle_confirmation(query, data[:2], data[3:])
            return

        await edit(query, "❓ Aksi tidak dikenali. Buka menu utama lagi.", reply_markup=main_keyboard())
    except Exception:
        log.exception("Button handler gagal: %s", data)
        await edit(query, "❌ Terjadi error pada bot. Coba ulangi dari menu.", reply_markup=main_keyboard())


async def handle_confirmation(query, action: str, token: str) -> None:
    item = _pending.pop(token, None)
    if not item or item[3] < time.time() or item[0] != query.message.chat_id:
        await edit(query, "❌ Konfirmasi kedaluwarsa / tidak valid.", reply_markup=main_keyboard())
        return
    if action == "no":
        await edit(query, "✅ Dibatalkan.", reply_markup=main_keyboard())
        return
    _, argv, env, _ = item
    await edit(query, "⏳ <b>Memproses…</b>")
    async with _op_lock:
        rc, out = await run_cli(argv, env, yes=True, timeout=1800 if argv[0] in {"delete", "reinstall", "backup"} else 900)
    name = argv[1] if len(argv) > 1 else ""
    if rc == 0 and name and valid_name(name) and argv[0] not in {"delete"}:
        info_rc, info_text, _ = await format_vps_info(name)
        if info_rc == 0:
            await edit(query, f"✅ <b>{esc(argv[0].title())} selesai</b>\n\n{info_text}", reply_markup=vps_action_keyboard(name))
            return
    kb = main_keyboard() if argv[0] == "delete" else (back_keyboard(f"vps:{name}") if valid_name(name) else main_keyboard())
    await edit(query, f"{'✅' if rc == 0 else '❌'} <b>{esc(argv[0].title())}</b>\n{esc_pre(out)}", reply_markup=kb)


async def begin_custom_input(query, kind: str, rest: list[str]) -> None:
    uid = query.from_user.id
    if kind == "renew" and rest:
        name = rest[0]
        set_state(uid, "custom_renew", name=name)
        await edit(query, f"⌨️ <b>Durasi renew — {esc(name)}</b>\n\nKirim durasi, contoh: <code>45d</code>, <code>2w</code>, <code>1m</code>.", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("❌ Batal", callback_data=f"vps:{name}")]]))
        return
    if kind == "passwd" and rest:
        name = rest[0]
        set_state(uid, "custom_passwd", name=name)
        await edit(query, f"⌨️ <b>Password baru — {esc(name)}</b>\n\nKirim password. Karakter <code>|</code> tidak diperbolehkan.", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("❌ Batal", callback_data=f"vps:{name}")]]))
        return
    if kind == "owner" and rest:
        name = rest[0]
        set_state(uid, "custom_owner", name=name)
        await edit(query, f"⌨️ <b>Owner / label — {esc(name)}</b>\n\nKirim label maksimal {OWNER_MAX} karakter.", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("❌ Batal", callback_data=f"vps:{name}")]]))
        return
    if kind == "bw" and rest:
        name = rest[0]
        set_state(uid, "custom_bandwidth", name=name)
        await edit(query, f"⌨️ <b>Bandwidth custom — {esc(name)}</b>\n\nKirim <code>quota_gb speed_mbps</code>. Contoh <code>500 100</code>. Gunakan quota <code>0</code> untuk unlimited.", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("❌ Batal", callback_data=f"vpsbw:{name}")]]))
        return
    if kind == "setexpire" and rest:
        name = rest[0]
        set_state(uid, "custom_setexpire", name=name)
        await edit(query, f"⌨️ <b>Expired custom — {esc(name)}</b>\n\nKirim durasi atau tanggal, contoh: <code>45d</code>, <code>2w</code>, <code>2026-12-31</code>, <code>never</code>.", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("❌ Batal", callback_data=f"vps:{name}")]]))
        return
    if kind == "reinstall" and rest:
        name = rest[0]
        set_state(uid, "custom_reinstall", name=name)
        await edit(query, f"⌨️ <b>Custom image — {esc(name)}</b>\n\nKirim image key yang didukung VPSNAT.", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("❌ Batal", callback_data=f"vps:{name}")]]))
        return
    if kind == "resizecpu" and rest:
        name = rest[0]
        set_state(uid, "custom_resize_cpu", name=name)
        await edit(query, f"⌨️ <b>CPU custom — {esc(name)}</b>\n\nKirim jumlah CPU core (angka ≥ 1).", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("❌ Batal", callback_data=f"vps:{name}")]]))
        return
    if kind == "resizeram" and len(rest) >= 2:
        name, cpu = rest[:2]
        set_state(uid, "custom_resize_ram", name=name, cpu=cpu)
        await edit(query, f"⌨️ <b>RAM custom — {esc(name)}</b>\n\nKirim RAM dalam MB (≥ 128).", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("❌ Batal", callback_data=f"vps:{name}")]]))
        return
    if kind == "resizedisk" and len(rest) >= 2:
        name, cpu = rest[0], rest[1]
        ram = rest[2] if len(rest) > 2 else ""
        set_state(uid, "custom_resize_disk", name=name, cpu=cpu, ram=ram)
        await edit(query, f"⌨️ <b>Disk custom — {esc(name)}</b>\n\nKirim ukuran disk dalam GB (≥ 1).", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("❌ Batal", callback_data=f"vps:{name}")]]))
        return


async def handle_text(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id if update.effective_user else 0
    if uid not in ADMINS:
        return
    state = get_state(uid)
    if not state:
        await reply(update, "Gunakan /start untuk membuka menu.")
        return
    value = (update.message.text or "").strip()
    kind = state.get("kind")

    try:
        if kind == "create_imagecustom":
            if await text_handler_create_imagecustom(update, state, value):
                return
        if kind == "create_name":
            if not valid_name(value):
                await reply(update, "❌ Nama harus a-z, 0-9, dan '-' (maks. 31 karakter). Contoh: <code>web1</code>")
                return
            state["create"]["name"] = value
            state["kind"] = "create_plan"
            await show_create_plan(update)
            return
        if kind == "custom_renew":
            name = state["name"]
            if not REL_DUR_RE.fullmatch(value):
                await reply(update, "❌ Durasi harus seperti <code>30d</code>, <code>2w</code>, <code>1m</code>, atau <code>12h</code>.")
                return
            clear_state(uid)
            await handle_renew(update.effective_chat.id, update, name, value)
            return
        if kind == "custom_passwd":
            name = state["name"]
            if not value or "|" in value:
                await reply(update, "❌ Password kosong atau mengandung karakter <code>|</code>.")
                return
            clear_state(uid)
            rc, out = await run_action(name, ["passwd", name], "passwd", {"PASS": value})
            info_rc, text, _ = await format_vps_info(name, include_password=True)
            await reply(update, f"✅ <b>Password diperbarui</b>\n\n{text if rc == 0 and info_rc == 0 else esc_pre(out)}", reply_markup=vps_action_keyboard(name))
            return
        if kind == "custom_owner":
            name = state["name"]
            label = value.replace("|", "")[:OWNER_MAX]
            clear_state(uid)
            rc, out = await run_action(name, ["set-owner", name, label or "-"], "owner")
            text, kb = await result_for_action(name, "Owner", rc, out, include_info=rc == 0)
            await reply(update, text, reply_markup=kb or back_keyboard(f"vps:{name}"))
            return
        if kind == "port_count":
            name, proto = state["name"], state["proto"]
            if not value.isdigit() or not 1 <= int(value) <= 500:
                await reply(update, "❌ Jumlah port harus 1–500.")
                return
            clear_state(uid)
            env = {"PROTO": proto, "COUNT": value}
            rc, out = await run_action(name, ["port-add", name], "port-add", env)
            text, kb = await result_for_action(name, "Port ditambahkan", rc, out)
            await reply(update, text, reply_markup=kb or back_keyboard(f"vps:{name}"))
            return
        if kind == "custom_resize_ram":
            name, cpu = state["name"], state["cpu"]
            if not value.isdigit() or int(value) < 128:
                await reply(update, "❌ RAM harus angka ≥ 128 MB.")
                return
            state["kind"] = "resize_disk"
            state["ram"] = value
            await reply(update, f"✅ RAM: <code>{esc(value)} MB</code>\n\n3/3: pilih disk.", reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton("10 GB", callback_data=f"resizedisk:{name}:{cpu}:{value}:10"), InlineKeyboardButton("20 GB", callback_data=f"resizedisk:{name}:{cpu}:{value}:20")],
                [InlineKeyboardButton("40 GB", callback_data=f"resizedisk:{name}:{cpu}:{value}:40"), InlineKeyboardButton("80 GB", callback_data=f"resizedisk:{name}:{cpu}:{value}:80")],
                [InlineKeyboardButton("120 GB", callback_data=f"resizedisk:{name}:{cpu}:{value}:120"), InlineKeyboardButton("⌨️ Custom GB", callback_data=f"custom:resizedisk:{name}:{cpu}:{value}")],
                [InlineKeyboardButton("⬅️ VPS", callback_data=f"vps:{name}")],
            ]))
            return
        if kind == "custom_resize_disk":
            name, cpu, ram = state["name"], state["cpu"], state["ram"]
            if not value.isdigit() or int(value) < 1:
                await reply(update, "❌ Disk harus angka ≥ 1 GB.")
                return
            clear_state(uid)
            await do_resize(update, name, cpu, ram, value)
            return
        if kind == "custom_bandwidth":
            name = state["name"]
            parts = value.split()
            if len(parts) != 2 or not all(re.fullmatch(r"\d+(?:\.\d+)?", x) for x in parts):
                await reply(update, "❌ Format harus <code>quota_gb speed_mbps</code>, contoh <code>500 100</code>.")
                return
            clear_state(uid)
            rc, out = await run_action(name, ["bandwidth", name, "set", parts[0], parts[1]], "bandwidth")
            text, kb = await result_for_action(name, "Bandwidth", rc, out, include_info=rc == 0)
            await reply(update, text, reply_markup=kb or back_keyboard(f"vps:{name}"))
            return
        if kind == "custom_setexpire":
            name = state["name"]
            if not DUR_RE.fullmatch(value):
                await reply(update, "❌ Format expired tidak valid. Contoh: <code>45d</code>, <code>2026-12-31</code>, <code>never</code>.")
                return
            clear_state(uid)
            rc, out = await run_action(name, ["set-expire", name, value], "set-expire")
            text, kb = await result_for_action(name, "Set expired", rc, out, include_info=rc == 0)
            await reply(update, text, reply_markup=kb or back_keyboard(f"vps:{name}"))
            return
        if kind == "custom_reinstall":
            name = state["name"]
            if not IMAGE_RE.fullmatch(value):
                await reply(update, "❌ Format image tidak valid.")
                return
            clear_state(uid)
            token = secrets.token_hex(4)
            _pending[token] = (update.effective_chat.id, ["reinstall", name], {"IMG_KEY": value}, time.time() + TOKEN_TTL)
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton("✅ Ya, reinstall", callback_data=f"ok:{token}"), InlineKeyboardButton("✖ Batal", callback_data=f"no:{token}")],
                [InlineKeyboardButton("⬅️ VPS", callback_data=f"vps:{name}")],
            ])
            await reply(update, f"⚠️ Reinstall <b>{esc(name)}</b> dengan <code>{esc(value)}</code>? Semua data akan hilang.", reply_markup=kb)
            return
        if kind == "custom_resize_cpu":
            name = state["name"]
            if not value.isdigit() or int(value) < 1:
                await reply(update, "❌ CPU harus angka ≥ 1.")
                return
            state["kind"] = "custom_resize_ram_after_cpu"
            state["cpu"] = value
            await reply(update, f"✅ CPU: <code>{esc(value)}</code>\n\nSekarang kirim RAM dalam MB (≥ 128).")
            return
        if kind == "custom_resize_ram_after_cpu":
            name, cpu = state["name"], state["cpu"]
            if not value.isdigit() or int(value) < 128:
                await reply(update, "❌ RAM harus angka ≥ 128 MB.")
                return
            state["kind"] = "custom_resize_disk_after_ram"
            state["ram"] = value
            await reply(update, f"✅ RAM: <code>{esc(value)} MB</code>\n\nSekarang kirim disk dalam GB (≥ 1).")
            return
        if kind == "custom_resize_disk_after_ram":
            name, cpu, ram = state["name"], state["cpu"], state["ram"]
            if not value.isdigit() or int(value) < 1:
                await reply(update, "❌ Disk harus angka ≥ 1 GB.")
                return
            clear_state(uid)
            await do_resize(update, name, cpu, ram, value)
            return
        if kind == "create_custom_cpu":
            if not value.isdigit() or int(value) < 1:
                await reply(update, "❌ CPU harus angka ≥ 1.")
                return
            state["create"]["cpu"] = value
            state["kind"] = "create_ram"
            await show_create_ram(update)
            return
        if kind == "create_custom_ram":
            if not value.isdigit() or int(value) < 128:
                await reply(update, "❌ RAM harus angka ≥ 128 MB.")
                return
            state["create"]["ram"] = value
            state["kind"] = "create_disk"
            await show_create_disk(update)
            return
        if kind == "create_custom_disk":
            if not value.isdigit() or int(value) < 1:
                await reply(update, "❌ Disk harus angka ≥ 1 GB.")
                return
            state["create"]["disk"] = value
            state["kind"] = "create_expire"
            await show_create_expire(update)
            return
        if kind == "create_custom_expire":
            if not DUR_RE.fullmatch(value):
                await reply(update, "❌ Expired harus seperti <code>30d</code>, <code>2w</code>, <code>1m</code>, <code>2026-12-31</code>, atau <code>never</code>.")
                return
            state["create"]["expire"] = value
            state["kind"] = "create_owner"
            await show_create_owner(update)
            return
        if kind == "create_owner_custom":
            state["create"]["owner"] = value.replace("|", "")[:OWNER_MAX] or "-"
            state["kind"] = "create_confirm"
            dummy = DummyQuery(update, uid)
            await finish_create_summary(dummy, state)
            return
        await reply(update, "❓ Input tidak sesuai tahap aktif. Tekan /cancel lalu buka menu lagi.")
    except Exception:
        log.exception("Text handler gagal")
        await reply(update, "❌ Input gagal diproses. Gunakan /cancel lalu coba lagi.")


class DummyQuery:
    def __init__(self, update: Update, user_id: int):
        self._update = update
        self.from_user = update.effective_user
        self.message = update.message
        self._chat_id = update.effective_chat.id

    async def edit_message_text(self, *args, **kwargs):
        return await self._update.message.reply_text(*args, **kwargs)


async def show_create_plan(update: Update) -> None:
    kb = InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton("🔗 Shared", callback_data="create:plan:shared"),
                InlineKeyboardButton("⚡ Dedicated", callback_data="create:plan:dedicated"),
            ],
            [InlineKeyboardButton("❌ Batal", callback_data="menu:home")],
        ]
    )
    await reply(update, "2/7: pilih <b>tipe layanan</b>. Shared akan dipantau untuk auto-suspend CPU/RAM; Dedicated tidak.", reply_markup=kb)


async def show_create_image(update: Update) -> None:
    kb = InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton("Ubuntu 22", callback_data="create:image:ubuntu22"),
                InlineKeyboardButton("Ubuntu 24", callback_data="create:image:ubuntu24"),
            ],
            [
                InlineKeyboardButton("Debian 12", callback_data="create:image:debian12"),
                InlineKeyboardButton("Debian 11", callback_data="create:image:debian11"),
            ],
            [
                InlineKeyboardButton("Alma 9", callback_data="create:image:alma9"),
                InlineKeyboardButton("Rocky 9", callback_data="create:image:rocky9"),
            ],
            [InlineKeyboardButton("Alpine", callback_data="create:image:alpine"), InlineKeyboardButton("⌨️ Custom image", callback_data="create:imagecustom")],
            [InlineKeyboardButton("❌ Batal", callback_data="menu:home")],
        ]
    )
    await reply(update, "3/7: pilih <b>image</b>.", reply_markup=kb)


async def show_create_cpu(update: Update) -> None:
    kb = InlineKeyboardMarkup(
        [
            [InlineKeyboardButton("1 CPU", callback_data="create:cpu:1"), InlineKeyboardButton("2 CPU", callback_data="create:cpu:2")],
            [InlineKeyboardButton("4 CPU", callback_data="create:cpu:4"), InlineKeyboardButton("8 CPU", callback_data="create:cpu:8")],
            [InlineKeyboardButton("⌨️ Custom", callback_data="create:cpucustom")],
        ]
    )
    if update.message:
        await reply(update, "4/7: pilih <b>CPU</b>.", reply_markup=kb)


async def show_create_ram(update: Update) -> None:
    kb = InlineKeyboardMarkup(
        [
            [InlineKeyboardButton("1 GB", callback_data="create:ram:1024"), InlineKeyboardButton("2 GB", callback_data="create:ram:2048")],
            [InlineKeyboardButton("4 GB", callback_data="create:ram:4096"), InlineKeyboardButton("8 GB", callback_data="create:ram:8192")],
            [InlineKeyboardButton("16 GB", callback_data="create:ram:16384"), InlineKeyboardButton("⌨️ Custom", callback_data="create:ramcustom")],
        ]
    )
    await reply(update, "5/7: pilih <b>RAM</b>.", reply_markup=kb)


async def show_create_disk(update: Update) -> None:
    kb = InlineKeyboardMarkup(
        [
            [InlineKeyboardButton("10 GB", callback_data="create:disk:10"), InlineKeyboardButton("20 GB", callback_data="create:disk:20")],
            [InlineKeyboardButton("40 GB", callback_data="create:disk:40"), InlineKeyboardButton("80 GB", callback_data="create:disk:80")],
            [InlineKeyboardButton("120 GB", callback_data="create:disk:120"), InlineKeyboardButton("⌨️ Custom", callback_data="create:diskcustom")],
        ]
    )
    await reply(update, "6/7: pilih <b>Disk</b>.", reply_markup=kb)


async def show_create_expire(update: Update) -> None:
    kb = InlineKeyboardMarkup(
        [
            [InlineKeyboardButton("30 hari", callback_data="create:expire:30d"), InlineKeyboardButton("60 hari", callback_data="create:expire:60d")],
            [InlineKeyboardButton("90 hari", callback_data="create:expire:90d"), InlineKeyboardButton("Tanpa expired", callback_data="create:expire:0")],
            [InlineKeyboardButton("⌨️ Custom", callback_data="create:expirecustom")],
        ]
    )
    await reply(update, "7/7: pilih <b>masa aktif</b>.", reply_markup=kb)


async def show_create_owner(update: Update) -> None:
    kb = InlineKeyboardMarkup(
        [
            [InlineKeyboardButton("Tanpa owner", callback_data="create:owner:-")],
            [InlineKeyboardButton("⌨️ Isi owner / label", callback_data="create:ownercustom")],
        ]
    )
    await reply(update, "👤 <b>Owner</b> (opsional).", reply_markup=kb)


async def on_create_button(query, parts: list[str]) -> bool:
    uid = query.from_user.id
    if len(parts) < 2:
        return False
    action = parts[1]
    state = get_state(uid)
    if action == "plan" and len(parts) == 3:
        if not state or state.get("kind") != "create_plan":
            await edit(query, "❌ Wizard create sudah kedaluwarsa.", reply_markup=main_keyboard())
            return True
        if parts[2] not in ("shared", "dedicated"):
            await edit(query, "❌ Tipe layanan tidak valid.", reply_markup=main_keyboard())
            return True
        state["create"]["plan"] = parts[2]
        state["kind"] = "create_image"
        await edit(query, f"✅ Tipe: <code>{esc(parts[2])}</code>\n\n3/7: pilih <b>image</b>.", reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("Ubuntu 22", callback_data="create:image:ubuntu22"), InlineKeyboardButton("Ubuntu 24", callback_data="create:image:ubuntu24")],
            [InlineKeyboardButton("Debian 12", callback_data="create:image:debian12"), InlineKeyboardButton("Debian 11", callback_data="create:image:debian11")],
            [InlineKeyboardButton("Alma 9", callback_data="create:image:alma9"), InlineKeyboardButton("Rocky 9", callback_data="create:image:rocky9")],
            [InlineKeyboardButton("Alpine", callback_data="create:image:alpine"), InlineKeyboardButton("⌨️ Custom image", callback_data="create:imagecustom")],
            [InlineKeyboardButton("⬅️ Tipe", callback_data="menu:create")],
        ]))
        return True
    if action == "image" and len(parts) == 3:
        if not state or state.get("kind") != "create_image":
            await edit(query, "❌ Wizard create sudah kedaluwarsa.", reply_markup=main_keyboard())
            return True
        state["create"]["image"] = parts[2]
        state["kind"] = "create_cpu"
        await edit(query, f"✅ Image: <code>{esc(parts[2])}</code>\n\n4/7: pilih <b>CPU</b>.", reply_markup=InlineKeyboardMarkup([
            [InlineKeyboardButton("1 CPU", callback_data="create:cpu:1"), InlineKeyboardButton("2 CPU", callback_data="create:cpu:2")],
            [InlineKeyboardButton("4 CPU", callback_data="create:cpu:4"), InlineKeyboardButton("8 CPU", callback_data="create:cpu:8")],
            [InlineKeyboardButton("⌨️ Custom", callback_data="create:cpucustom")],
        ]))
        return True
    if action == "imagecustom":
        if state:
            state["kind"] = "create_imagecustom"
        await edit(query, "⌨️ <b>Custom image</b>\n\nKirim image key sesuai dukungan VPSNAT, misalnya <code>ubuntu22</code>.", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("❌ Batal", callback_data="menu:home")]]))
        return True
    if action == "cpu" and len(parts) == 3:
        if state:
            state["create"]["cpu"] = parts[2]
            state["kind"] = "create_ram"
            await edit(query, f"✅ CPU: <code>{esc(parts[2])}</code>\n\n5/7: pilih <b>RAM</b>.", reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton("1 GB", callback_data="create:ram:1024"), InlineKeyboardButton("2 GB", callback_data="create:ram:2048")],
                [InlineKeyboardButton("4 GB", callback_data="create:ram:4096"), InlineKeyboardButton("8 GB", callback_data="create:ram:8192")],
                [InlineKeyboardButton("16 GB", callback_data="create:ram:16384"), InlineKeyboardButton("⌨️ Custom", callback_data="create:ramcustom")],
            ]))
        return True
    if action == "cpucustom":
        if state:
            state["kind"] = "create_custom_cpu"
        await edit(query, "⌨️ <b>CPU custom</b>\n\nKirim jumlah core, minimal 1.", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("❌ Batal", callback_data="menu:home")]]))
        return True
    if action == "ram" and len(parts) == 3:
        if state:
            state["create"]["ram"] = parts[2]
            state["kind"] = "create_disk"
            await edit(query, f"✅ RAM: <code>{esc(parts[2])} MB</code>\n\n6/7: pilih <b>Disk</b>.", reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton("10 GB", callback_data="create:disk:10"), InlineKeyboardButton("20 GB", callback_data="create:disk:20")],
                [InlineKeyboardButton("40 GB", callback_data="create:disk:40"), InlineKeyboardButton("80 GB", callback_data="create:disk:80")],
                [InlineKeyboardButton("120 GB", callback_data="create:disk:120"), InlineKeyboardButton("⌨️ Custom", callback_data="create:diskcustom")],
            ]))
        return True
    if action == "ramcustom":
        if state:
            state["kind"] = "create_custom_ram"
        await edit(query, "⌨️ <b>RAM custom</b>\n\nKirim RAM dalam MB, minimal 128.", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("❌ Batal", callback_data="menu:home")]]))
        return True
    if action == "disk" and len(parts) == 3:
        if state:
            state["create"]["disk"] = parts[2]
            state["kind"] = "create_expire"
            await edit(query, f"✅ Disk: <code>{esc(parts[2])} GB</code>\n\n7/7: pilih <b>masa aktif</b>.", reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton("30 hari", callback_data="create:expire:30d"), InlineKeyboardButton("60 hari", callback_data="create:expire:60d")],
                [InlineKeyboardButton("90 hari", callback_data="create:expire:90d"), InlineKeyboardButton("Tanpa expired", callback_data="create:expire:0")],
                [InlineKeyboardButton("⌨️ Custom", callback_data="create:expirecustom")],
            ]))
        return True
    if action == "diskcustom":
        if state:
            state["kind"] = "create_custom_disk"
        await edit(query, "⌨️ <b>Disk custom</b>\n\nKirim ukuran disk dalam GB, minimal 1.", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("❌ Batal", callback_data="menu:home")]]))
        return True
    if action == "expire" and len(parts) == 3:
        if state:
            state["create"]["expire"] = parts[2]
            state["kind"] = "create_owner"
            await edit(query, f"✅ Expired: <code>{esc(parts[2])}</code>\n\n👤 <b>Owner</b> (opsional).", reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton("Tanpa owner", callback_data="create:owner:-")],
                [InlineKeyboardButton("⌨️ Isi owner / label", callback_data="create:ownercustom")],
            ]))
        return True
    if action == "expirecustom":
        if state:
            state["kind"] = "create_custom_expire"
        await edit(query, "⌨️ <b>Masa aktif custom</b>\n\nContoh: <code>45d</code>, <code>2w</code>, <code>1m</code>, <code>2026-12-31</code>, <code>never</code>.", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("❌ Batal", callback_data="menu:home")]]))
        return True
    if action == "owner" and len(parts) == 3 and state:
        state["create"]["owner"] = parts[2]
        state["kind"] = "create_confirm"
        await finish_create_summary(query, state)
        return True
    if action == "ownercustom":
        if state:
            state["kind"] = "create_owner_custom"
        await edit(query, f"⌨️ <b>Owner / label</b>\n\nKirim label maksimal {OWNER_MAX} karakter.", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("❌ Batal", callback_data="menu:home")]]))
        return True
    return False


async def text_handler_create_imagecustom(update: Update, state: dict[str, Any], value: str) -> bool:
    if state.get("kind") != "create_imagecustom":
        return False
    if not IMAGE_RE.fullmatch(value):
        await reply(update, "❌ Format image tidak valid.")
        return True
    state["create"]["image"] = value
    state["kind"] = "create_cpu"
    await show_create_cpu(update)
    return True


async def post_init(application: Application) -> None:
    commands = [
        ("start", "Buka menu utama"),
        ("list", "Daftar VPS"),
        ("create", "Buat VPS"),
        ("info", "Detail VPS"),
        ("ports", "Port VPS"),
        ("host", "Info host"),
        ("expiring", "VPS segera expired"),
        ("sync", "Sinkronisasi"),
        ("settings", "Lihat konfigurasi monitor"),
        ("help", "Bantuan"),
        ("cancel", "Batalkan input"),
    ]
    try:
        await application.bot.set_my_commands(commands)
    except Exception:
        log.exception("Gagal memasang command menu Telegram")


async def on_error(update: object, ctx: ContextTypes.DEFAULT_TYPE):
    log.exception("Handler error", exc_info=ctx.error)


def main() -> None:
    if not TOKEN or not ADMINS:
        raise SystemExit(f"TG_TOKEN / TG_ADMIN belum diset di {CONF}  (jalankan: vpsnat bot-setup)")

    app = Application.builder().token(TOKEN).post_init(post_init).build()

    handlers = {
        "start": cmd_start,
        "menu": cmd_start,
        "help": cmd_help,
        "whoami": cmd_whoami,
        "cancel": cmd_cancel,
        "list": cmd_list,
        "host": cmd_host,
        "expiring": cmd_expiring,
        "info": cmd_info,
        "ports": cmd_ports,
        "bandwidth": cmd_bandwidth,
        "settype": cmd_settype,
        "settings": cmd_settings,
        "start_vps": cmd_start_vps,
        "stop": cmd_stop,
        "restart": cmd_restart,
        "suspend": cmd_suspend,
        "unsuspend": cmd_unsuspend,
        "sync": cmd_sync,
        "backup": cmd_backup,
        "renew": cmd_renew,
        "setexpire": cmd_setexpire,
        "owner": cmd_owner,
        "passwd": cmd_passwd,
        "resize": cmd_resize,
        "create": cmd_create,
        "portadd": cmd_portadd,
        "portdel": cmd_portdel,
        "snapshot": cmd_snapshot,
        "delete": cmd_delete,
        "reinstall": cmd_reinstall,
    }
    for name, fn in handlers.items():
        app.add_handler(CommandHandler(name, fn))
    app.add_handler(CallbackQueryHandler(on_button, pattern=r"^(?:menu|create|vps|vpsinfo|vpsstats|vpsbw|vpsplan|bwpreset|bwreset|setplan|act|danger|renew|resizecpu|resizeram|resizedisk|passwdgen|owner|portadd|portproto|portdel|ports|snapshot|snapcreate|snaprestore|snapdelete|snap|setexpire|reinstall|custom|ok|no):"))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text), group=2)
    app.add_error_handler(on_error)

    log.info("Bot jalan. Admin: %s", sorted(ADMINS))
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()

