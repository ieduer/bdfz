#!/usr/bin/env bash
#
# chat.sh - One-shot installer/updater for chat.bdfz.net (Anonymous Hourly-Wipe Chat)
#
# Target:
#   - Ubuntu 24.04+ (root)
#   - Domain: chat.bdfz.net
#   - HTTPS required
#   - Overwrite previous install & kill prior processes on every run
#   - Do NOT overwrite existing TLS certs (skip issuance if cert exists)
#
# Usage:
#   sudo bash chat.sh
# Optional env overrides:
#   DOMAIN=chat.bdfz.net
#   APP_PORT=8080
#   LE_EMAIL=admin@bdfz.net
#

set -euo pipefail

CHAT_VERSION="v1.0.1"

DOMAIN="${DOMAIN:-chat.bdfz.net}"
APP_PORT="${APP_PORT:-8080}"
LE_EMAIL="${LE_EMAIL:-admin@bdfz.net}"

APP_NAME="anon-hourly-chat"
APP_USER="chat"
APP_DIR="/opt/${APP_NAME}"
SERVER_DIR="${APP_DIR}/server"
PUBLIC_DIR="${SERVER_DIR}/public"

SYSTEMD_UNIT="${APP_NAME}.service"
NGINX_SITE="${DOMAIN}"
NGINX_AVAIL="/etc/nginx/sites-available/${NGINX_SITE}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${NGINX_SITE}"

LE_LIVE_DIR="/etc/letsencrypt/live/${DOMAIN}"
LE_FULLCHAIN="${LE_LIVE_DIR}/fullchain.pem"
LE_PRIVKEY="${LE_LIVE_DIR}/privkey.pem"

ACME_WEBROOT="/var/www/letsencrypt"

log()  { echo -e "[chat.sh ${CHAT_VERSION}] $*"; }
warn() { echo -e "[chat.sh ${CHAT_VERSION}] [WARN] $*" >&2; }
err()  { echo -e "[chat.sh ${CHAT_VERSION}] [ERR]  $*" >&2; }

die() { err "$*"; exit 1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Please run as root: sudo bash chat.sh"
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_pkgs() {
  log "Updating apt + installing base packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release \
    nginx redis-server \
    certbot python3-certbot-nginx \
    jq

  systemctl enable --now nginx
  systemctl enable --now redis-server
  systemctl enable --now certbot.timer || true
}

ensure_node20() {
  if have_cmd node; then
    local v
    v="$(node -v | sed 's/^v//' || true)"
    local major
    major="${v%%.*}"
    if [[ "${major}" =~ ^[0-9]+$ ]] && (( major >= 20 )); then
      log "Node.js already present (v${v})."
      return 0
    fi
    warn "Node.js present but <20 (v${v}); upgrading to Node.js 20.x via NodeSource."
  else
    log "Node.js not found; installing Node.js 20.x via NodeSource."
  fi

  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs

  if ! have_cmd node; then
    die "Node.js install failed."
  fi

  log "Node version: $(node -v)"
  log "npm  version: $(npm -v)"
}

stop_previous() {
  log "Stopping previous install (systemd + stray processes)..."

  if systemctl list-unit-files | awk '{print $1}' | grep -qx "${SYSTEMD_UNIT}"; then
    systemctl stop "${SYSTEMD_UNIT}" || true
    systemctl disable "${SYSTEMD_UNIT}" || true
  fi

  systemctl reset-failed "${SYSTEMD_UNIT}" 2>/dev/null || true

  pkill -f "${APP_DIR}/server.js" 2>/dev/null || true
  pkill -f "${SERVER_DIR}/server.js" 2>/dev/null || true
  pkill -f "${APP_NAME}" 2>/dev/null || true

  if have_cmd ss; then
    ss -ltnp | grep -q ":${APP_PORT} " && warn "Port ${APP_PORT} still appears in use; continuing (it may be nginx/other)." || true
  fi
}

create_user() {
  if id -u "${APP_USER}" >/dev/null 2>&1; then
    log "User '${APP_USER}' already exists."
  else
    log "Creating system user '${APP_USER}'..."
    useradd --system --no-create-home --shell /usr/sbin/nologin "${APP_USER}"
  fi
}

write_app_files() {
  log "Writing application files to ${APP_DIR} (full overwrite)..."

  rm -rf "${APP_DIR}"
  mkdir -p "${PUBLIC_DIR}"

  cat > "${SERVER_DIR}/package.json" <<'JSON'
{
  "name": "anon-hourly-chat",
  "version": "1.0.0",
  "private": true,
  "description": "Anonymous web chat that wipes all content every hour (Redis-backed).",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.19.2",
    "ioredis": "^5.4.1",
    "socket.io": "^4.7.5"
  }
}
JSON

  cat > "${SERVER_DIR}/server.js" <<'JS'
'use strict';

/**
 * anon-hourly-chat (server)
 * - Anonymous rooms (no login)
 * - Messages stored in Redis with a prefix
 * - Wipes ALL chat:* keys every hour at the top of the hour
 */

const path = require('path');
const http = require('http');
const express = require('express');
const { Server } = require('socket.io');
const Redis = require('ioredis');

const VERSION = 'v1.0.1';

const PORT = parseInt(process.env.PORT || '8080', 10);
const REDIS_URL = process.env.REDIS_URL || 'redis://127.0.0.1:6379';
const CHAT_KEY_PREFIX = process.env.CHAT_KEY_PREFIX || 'chat:';
const WIPE_EVERY_HOUR = (process.env.WIPE_EVERY_HOUR || '1') === '1';
const MAX_MSG_LEN = parseInt(process.env.MAX_MSG_LEN || '800', 10);

function nowIso() {
  return new Date().toISOString();
}

function clampText(s, maxLen) {
  const t = String(s || '');
  if (t.length <= maxLen) return t;
  return t.slice(0, maxLen);
}

function safeRoom(room) {
  const r = String(room || '').trim();
  if (!r) return 'lobby';
  const cleaned = r.replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 64);
  return cleaned || 'lobby';
}

function kRoomMessages(room) {
  return `${CHAT_KEY_PREFIX}room:${room}:messages`;
}

function kRoomMeta(room) {
  return `${CHAT_KEY_PREFIX}room:${room}:meta`;
}

async function scanDelByPrefix(redis, prefix) {
  let cursor = '0';
  let deleted = 0;
  const pattern = `${prefix}*`;

  do {
    const res = await redis.scan(cursor, 'MATCH', pattern, 'COUNT', 1000);
    cursor = res[0];
    const keys = res[1];

    if (keys && keys.length) {
      const chunkSize = 500;
      for (let i = 0; i < keys.length; i += chunkSize) {
        const chunk = keys.slice(i, i + chunkSize);
        const n = await redis.del(...chunk);
        deleted += n;
      }
    }
  } while (cursor !== '0');

  return deleted;
}

function msUntilNextHour() {
  const now = new Date();
  const next = new Date(now);
  next.setMinutes(0, 0, 0);
  next.setHours(now.getHours() + 1);
  return next.getTime() - now.getTime();
}

async function startHourlyWipe(redis) {
  if (!WIPE_EVERY_HOUR) return;

  const schedule = async () => {
    try {
      const deleted = await scanDelByPrefix(redis, CHAT_KEY_PREFIX);
      console.log(`[${nowIso()}] wipe ok: deleted ${deleted} keys with prefix "${CHAT_KEY_PREFIX}"`);
    } catch (e) {
      console.error(`[${nowIso()}] wipe error:`, e);
    } finally {
      setTimeout(schedule, msUntilNextHour());
    }
  };

  const firstDelay = msUntilNextHour();
  console.log(`[${nowIso()}] wipe scheduled in ${firstDelay}ms (at next hour)`);
  setTimeout(schedule, firstDelay);
}

(async () => {
  console.log(`anon-hourly-chat ${VERSION} starting...`);
  console.log(`PORT=${PORT}`);
  console.log(`REDIS_URL=${REDIS_URL}`);
  console.log(`CHAT_KEY_PREFIX=${CHAT_KEY_PREFIX}`);
  console.log(`WIPE_EVERY_HOUR=${WIPE_EVERY_HOUR ? '1' : '0'}`);

  const redis = new Redis(REDIS_URL, {
    maxRetriesPerRequest: 2,
    enableReadyCheck: true
  });

  redis.on('error', (err) => {
    console.error(`[${nowIso()}] redis error:`, err);
  });

  await redis.ping();

  const app = express();
  const server = http.createServer(app);
  const io = new Server(server, {
    cors: { origin: false }
  });

  app.get('/healthz', (req, res) => {
    res.json({ ok: true, ts: nowIso(), version: VERSION });
  });

  app.use('/', express.static(path.join(__dirname, 'public')));

  io.on('connection', (socket) => {
    socket.on('join', async (payload) => {
      const room = safeRoom(payload && payload.room);
      const nick = clampText((payload && payload.nick) || 'anon', 24);

      socket.data.room = room;
      socket.data.nick = nick;
      socket.join(room);

      try {
        const key = kRoomMessages(room);
        const items = await redis.lrange(key, -100, -1);
        const history = items.map((s) => {
          try { return JSON.parse(s); } catch { return null; }
        }).filter(Boolean);

        socket.emit('history', { room, history });

        await redis.hset(kRoomMeta(room), 'last_active', nowIso());
        await redis.expire(kRoomMeta(room), 3600);
      } catch (e) {
        socket.emit('error_msg', { message: 'Failed to load history.' });
      }

      io.to(room).emit('system', { room, message: `${nick} joined`, ts: nowIso() });
    });

    socket.on('msg', async (payload) => {
      const room = safeRoom(socket.data.room || 'lobby');
      const nick = clampText(socket.data.nick || 'anon', 24);
      const text = clampText(payload && payload.text, MAX_MSG_LEN).trim();
      if (!text) return;

      const msg = {
        id: socket.id + ':' + Date.now(),
        nick,
        text,
        ts: nowIso()
      };

      try {
        const key = kRoomMessages(room);
        await redis.rpush(key, JSON.stringify(msg));
        await redis.ltrim(key, -500, -1);
        await redis.expire(key, 3600);
        await redis.hset(kRoomMeta(room), 'last_active', nowIso());
        await redis.expire(kRoomMeta(room), 3600);
      } catch (e) {
        console.error(`[${nowIso()}] redis write error:`, e);
      }

      io.to(room).emit('msg', { room, msg });
    });

    socket.on('clear_room', async () => {
      const room = safeRoom(socket.data.room || 'lobby');
      try {
        await redis.del(kRoomMessages(room), kRoomMeta(room));
        io.to(room).emit('system', { room, message: `Room cleared`, ts: nowIso() });
      } catch (e) {
        socket.emit('error_msg', { message: 'Failed to clear room.' });
      }
    });
  });

  await startHourlyWipe(redis);

  server.listen(PORT, () => {
    console.log(`[${nowIso()}] listening on http://127.0.0.1:${PORT}`);
  });
})().catch((e) => {
  console.error('fatal:', e);
  process.exit(1);
});
JS

  cat > "${PUBLIC_DIR}/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover" />
  <meta name="color-scheme" content="dark" />
  <title>Anon Hourly Chat</title>
  <style>
    :root{
      --bg:#05070a;
      --panel:#0b0f14;
      --panel2:#0f1720;
      --border:#1f2a37;
      --muted:rgba(230,237,243,.72);
      --text:#e6edf3;
      --green:#2ea043;
      --green2:#3ddc97;
      --warn:#f2cc60;
      --red:#ff6b6b;
      --shadow: 0 10px 30px rgba(0,0,0,.35);
      --r:14px;
      --mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
      --sans: system-ui, -apple-system, Segoe UI, Roboto, Arial;
    }

    *{ box-sizing:border-box; }
    html,body{ height:100%; }
    body{
      margin:0;
      background: radial-gradient(1100px 700px at 30% 0%, rgba(46,160,67,.12), transparent 60%),
                  radial-gradient(900px 600px at 100% 10%, rgba(61,220,151,.10), transparent 55%),
                  var(--bg);
      color:var(--text);
      font-family: var(--sans);
      -webkit-font-smoothing: antialiased;
      -moz-osx-font-smoothing: grayscale;
    }

    /* Layout */
    .app{
      height:100vh;
      height:100dvh;
      display:flex;
      flex-direction:column;
    }

    .topbar{
      position:sticky;
      top:0;
      z-index:10;
      background: linear-gradient(180deg, rgba(5,7,10,.96), rgba(5,7,10,.72));
      backdrop-filter: blur(10px);
      border-bottom: 1px solid rgba(31,42,55,.7);
    }

    .topbar-inner{
      display:flex;
      align-items:center;
      gap:10px;
      padding: 12px 14px;
      padding-top: calc(10px + env(safe-area-inset-top));
      max-width: 1100px;
      margin: 0 auto;
    }

    .brand{
      display:flex;
      align-items:baseline;
      gap:10px;
      min-width: 0;
    }

    .brand h1{
      margin:0;
      font-size: 14px;
      font-family: var(--mono);
      letter-spacing: .2px;
      white-space:nowrap;
    }

    .brand .tag{
      font-size: 12px;
      font-family: var(--mono);
      color: var(--muted);
      white-space:nowrap;
      overflow:hidden;
      text-overflow:ellipsis;
    }

    .pill{
      display:inline-flex;
      align-items:center;
      gap:8px;
      padding: 7px 10px;
      border-radius: 999px;
      border: 1px solid rgba(31,42,55,.9);
      background: rgba(11,15,20,.7);
      box-shadow: var(--shadow);
      font-family: var(--mono);
      font-size: 12px;
      color: var(--muted);
      white-space:nowrap;
    }

    .dot{
      width:8px;
      height:8px;
      border-radius:99px;
      background: rgba(255,255,255,.25);
      box-shadow: 0 0 0 2px rgba(255,255,255,.06) inset;
    }

    .dot.ok{ background: var(--green); box-shadow: 0 0 12px rgba(46,160,67,.55); }
    .dot.warn{ background: var(--warn); box-shadow: 0 0 12px rgba(242,204,96,.45); }
    .dot.bad{ background: var(--red); box-shadow: 0 0 12px rgba(255,107,107,.45); }

    .spacer{ flex:1; }

    .btn{
      appearance:none;
      border: 1px solid rgba(31,42,55,.9);
      background: rgba(15,23,32,.65);
      color: var(--text);
      border-radius: 12px;
      padding: 9px 12px;
      font-family: var(--mono);
      font-size: 12px;
      cursor:pointer;
      transition: transform .06s ease, background .15s ease, border-color .15s ease, opacity .15s ease;
      user-select:none;
      touch-action: manipulation;
    }
    .btn:hover{ background: rgba(15,23,32,.85); }
    .btn:active{ transform: translateY(1px); }
    .btn.primary{ border-color: rgba(46,160,67,.8); }
    .btn.danger{ border-color: rgba(255,107,107,.65); }

    .main{
      flex:1;
      min-height:0;
      display:flex;
      justify-content:center;
    }

    .frame{
      width: 100%;
      max-width: 1100px;
      padding: 14px;
      display:flex;
      flex-direction:column;
      gap: 12px;
    }

    .panel{
      background: rgba(11,15,20,.72);
      border: 1px solid rgba(31,42,55,.85);
      border-radius: var(--r);
      box-shadow: var(--shadow);
      overflow:hidden;
    }

    .join{
      display:flex;
      gap:10px;
      padding: 12px;
      align-items:center;
      flex-wrap: wrap;
    }

    .field{
      display:flex;
      flex-direction:column;
      gap:6px;
      min-width: 160px;
      flex: 1;
    }

    .field label{
      font-family: var(--mono);
      font-size: 11px;
      color: var(--muted);
    }

    .field input{
      width:100%;
      background: rgba(15,23,32,.85);
      color: var(--text);
      border: 1px solid rgba(35,48,65,.9);
      border-radius: 12px;
      padding: 10px 12px;
      outline: none;
      font-family: var(--mono);
      font-size: 13px;
    }

    .field input:focus{
      border-color: rgba(61,220,151,.55);
      box-shadow: 0 0 0 3px rgba(61,220,151,.15);
    }

    .hint{
      padding: 0 12px 12px 12px;
      font-family: var(--mono);
      font-size: 12px;
      color: var(--muted);
      line-height: 1.35;
    }

    /* Chat log */
    .log{
      flex:1;
      min-height: 0;
      padding: 12px;
      overflow:auto;
      scroll-behavior: smooth;
    }

    .row{ margin: 10px 0; display:flex; gap:10px; }

    .avatar{
      width: 22px;
      height: 22px;
      border-radius: 6px;
      border: 1px solid rgba(31,42,55,.9);
      background: rgba(15,23,32,.95);
      display:flex;
      align-items:center;
      justify-content:center;
      font-family: var(--mono);
      font-size: 12px;
      color: rgba(230,237,243,.85);
      flex: 0 0 auto;
    }

    .msgbox{
      flex:1;
      min-width:0;
    }

    .meta{
      font-family: var(--mono);
      font-size: 11px;
      color: var(--muted);
      margin-bottom: 6px;
      display:flex;
      gap:10px;
      flex-wrap:wrap;
    }

    .bubble{
      display:inline-block;
      padding: 10px 12px;
      border-radius: 14px;
      background: rgba(15,23,32,.85);
      border: 1px solid rgba(35,48,65,.9);
      max-width: 980px;
      white-space: pre-wrap;
      word-break: break-word;
      font-family: var(--mono);
      font-size: 13px;
      line-height: 1.35;
    }

    .sys .bubble{
      background: rgba(18,26,37,.65);
      border-style: dashed;
      color: rgba(230,237,243,.9);
    }

    .me .bubble{
      border-color: rgba(46,160,67,.8);
      box-shadow: 0 0 0 2px rgba(46,160,67,.10) inset;
    }

    /* Composer */
    .composer{
      position:sticky;
      bottom:0;
      z-index:10;
      background: linear-gradient(0deg, rgba(5,7,10,.96), rgba(5,7,10,.55));
      backdrop-filter: blur(10px);
      border-top: 1px solid rgba(31,42,55,.7);
      padding-bottom: env(safe-area-inset-bottom);
    }

    .composer-inner{
      max-width: 1100px;
      margin: 0 auto;
      padding: 12px 14px;
      display:flex;
      gap:10px;
      align-items:flex-end;
    }

    .inputwrap{ flex:1; min-width:0; }

    textarea{
      width:100%;
      resize: none;
      max-height: 160px;
      min-height: 44px;
      background: rgba(15,23,32,.92);
      color: var(--text);
      border: 1px solid rgba(35,48,65,.95);
      border-radius: 14px;
      padding: 11px 12px;
      outline:none;
      font-family: var(--mono);
      font-size: 13px;
      line-height: 1.35;
    }

    textarea:focus{
      border-color: rgba(61,220,151,.55);
      box-shadow: 0 0 0 3px rgba(61,220,151,.15);
    }

    .subhint{
      margin-top: 6px;
      font-family: var(--mono);
      font-size: 11px;
      color: rgba(230,237,243,.55);
      display:flex;
      gap:10px;
      flex-wrap:wrap;
    }

    .kbd{ border:1px solid rgba(35,48,65,.9); border-bottom-width:2px; border-radius:8px; padding:2px 6px; background: rgba(11,15,20,.65); }

    .rightbtns{ display:flex; gap:10px; }

    /* Mobile */
    @media (max-width: 720px){
      .topbar-inner{ padding-left: 12px; padding-right: 12px; }
      .frame{ padding: 10px 12px; }
      .join{ padding: 10px; }
      .field{ min-width: 0; flex: 1 1 100%; }
      .rightbtns{ width: 100%; }
      .rightbtns .btn{ flex: 1; }
      .pill{ display:none; }
      .bubble{ max-width: 100%; }
      .composer-inner{ padding-left: 12px; padding-right: 12px; }
    }

    @media (prefers-reduced-motion: reduce){
      .log{ scroll-behavior:auto; }
      .btn{ transition:none; }
    }
  </style>
</head>
<body>
  <div class="app">
    <div class="topbar">
      <div class="topbar-inner">
        <div class="brand">
          <h1>Anon Hourly Chat</h1>
          <div class="tag" id="roomTag">room:lobby</div>
        </div>

        <div class="pill" title="Connection status">
          <span class="dot" id="dot"></span>
          <span id="statusText">connecting…</span>
        </div>

        <div class="pill" title="Next wipe (client-side estimate)">
          <span>next wipe</span>
          <span id="wipeCountdown">--:--</span>
        </div>

        <div class="spacer"></div>

        <button class="btn danger" id="clear">clear room</button>
      </div>
    </div>

    <div class="main">
      <div class="frame">
        <div class="panel">
          <div class="join">
            <div class="field">
              <label for="room">room</label>
              <input id="room" autocomplete="off" spellcheck="false" placeholder="lobby / mathclub / …" />
            </div>
            <div class="field">
              <label for="nick">nickname</label>
              <input id="nick" autocomplete="off" spellcheck="false" placeholder="anon_fox" />
            </div>
            <div class="rightbtns">
              <button class="btn primary" id="join">join</button>
              <button class="btn" id="bottom">bottom</button>
            </div>
          </div>
          <div class="hint">Anonymous. No accounts. Server wipes all chat data every hour. <span style="opacity:.8">(UI inspired by terminal-ish “hacker” aesthetics — but with readable spacing.)</span></div>
        </div>

        <div class="panel" style="flex:1; min-height:0;">
          <div class="log" id="log" aria-live="polite"></div>
        </div>
      </div>
    </div>

    <div class="composer">
      <div class="composer-inner">
        <div class="inputwrap">
          <textarea id="text" placeholder="Type a message…" maxlength="800" rows="1"></textarea>
          <div class="subhint">
            <span><span class="kbd">Enter</span> send</span>
            <span><span class="kbd">Shift</span>+<span class="kbd">Enter</span> newline</span>
            <span id="len">0/800</span>
          </div>
        </div>
        <button class="btn primary" id="send" style="padding:12px 14px;">send</button>
      </div>
    </div>
  </div>

  <!-- use local socket.io client served by the same origin -->
  <script src="/socket.io/socket.io.js"></script>
  <script>
    const logEl = document.getElementById('log');
    const roomEl = document.getElementById('room');
    const nickEl = document.getElementById('nick');
    const textEl = document.getElementById('text');
    const roomTag = document.getElementById('roomTag');
    const dot = document.getElementById('dot');
    const statusText = document.getElementById('statusText');
    const wipeCountdown = document.getElementById('wipeCountdown');
    const lenEl = document.getElementById('len');

    let currentRoom = 'lobby';
    let currentNick = '';

    function nowIso(){ return new Date().toISOString(); }

    function msUntilNextHour(){
      const now = new Date();
      const next = new Date(now);
      next.setMinutes(0,0,0);
      next.setHours(now.getHours()+1);
      return next.getTime() - now.getTime();
    }

    function fmtCountdown(ms){
      const s = Math.max(0, Math.floor(ms/1000));
      const m = Math.floor(s/60);
      const r = s % 60;
      return String(m).padStart(2,'0') + ':' + String(r).padStart(2,'0');
    }

    function tickWipe(){
      wipeCountdown.textContent = fmtCountdown(msUntilNextHour());
    }

    setInterval(tickWipe, 500);
    tickWipe();

    function setStatus(kind, text){
      dot.className = 'dot ' + (kind || '');
      statusText.textContent = text;
    }

    function avatarChar(nick){
      const t = String(nick || 'a');
      const ch = (t.trim()[0] || 'a').toUpperCase();
      return ch;
    }

    function pruneDom(max=300){
      const nodes = logEl.children;
      if (nodes.length <= max) return;
      const removeCount = nodes.length - max;
      for (let i=0;i<removeCount;i++){
        logEl.removeChild(logEl.firstElementChild);
      }
    }

    function addLine(kind, nick, text, ts){
      const row = document.createElement('div');
      row.className = 'row ' + (kind || '');

      const av = document.createElement('div');
      av.className = 'avatar';
      av.textContent = kind === 'sys' ? '!' : avatarChar(nick);

      const box = document.createElement('div');
      box.className = 'msgbox';

      const meta = document.createElement('div');
      meta.className = 'meta';

      const who = document.createElement('span');
      who.textContent = kind === 'sys' ? '[system]' : (nick || 'anon');

      const when = document.createElement('span');
      when.style.opacity = '.8';
      when.textContent = ts || '';

      meta.appendChild(who);
      meta.appendChild(when);

      const bubble = document.createElement('div');
      bubble.className = 'bubble';
      bubble.textContent = text;

      box.appendChild(meta);
      box.appendChild(bubble);

      row.appendChild(av);
      row.appendChild(box);

      logEl.appendChild(row);
      pruneDom(400);
      logEl.scrollTop = logEl.scrollHeight;
    }

    function randNick(){
      const a = ['anon','quiet','wild','moss','cloud','fox','owl','cat','byte','leaf','null','root','kilo','hex'];
      const b = Math.floor(Math.random()*10000).toString().padStart(4,'0');
      return a[Math.floor(Math.random()*a.length)] + '_' + b;
    }

    function setRoomTag(r){
      roomTag.textContent = 'room:' + r;
    }

    function normalizeRoom(r){
      const t = String(r || '').trim();
      return t ? t : 'lobby';
    }

    function autoGrow(){
      textEl.style.height = 'auto';
      textEl.style.height = Math.min(textEl.scrollHeight, 160) + 'px';
    }

    function updateLen(){
      const n = (textEl.value || '').length;
      lenEl.textContent = n + '/800';
      autoGrow();
    }

    textEl.addEventListener('input', updateLen);
    updateLen();

    if (!nickEl.value) nickEl.value = randNick();
    if (!roomEl.value) roomEl.value = 'lobby';

    currentNick = nickEl.value.trim() || 'anon';
    currentRoom = normalizeRoom(roomEl.value);
    setRoomTag(currentRoom);

    const socket = io({ transports: ['websocket'] });

    socket.on('connect', () => {
      setStatus('ok', 'online');
    });

    socket.on('disconnect', (reason) => {
      setStatus('bad', 'offline');
      addLine('sys', '', 'Disconnected: ' + reason, nowIso());
    });

    socket.on('connect_error', () => {
      setStatus('warn', 'reconnecting…');
    });

    socket.on('history', (payload) => {
      logEl.innerHTML = '';
      (payload.history || []).forEach(m => {
        const k = (m.nick === currentNick) ? 'me' : 'msg';
        addLine(k, m.nick, m.text, m.ts);
      });
      addLine('sys', '', 'Joined room: ' + payload.room, nowIso());
      setRoomTag(payload.room);
      currentRoom = payload.room;
    });

    socket.on('system', (payload) => {
      addLine('sys', '', payload.message, payload.ts);
    });

    socket.on('msg', (payload) => {
      const k = (payload.msg && payload.msg.nick === currentNick) ? 'me' : 'msg';
      addLine(k, payload.msg.nick, payload.msg.text, payload.msg.ts);
    });

    socket.on('error_msg', (payload) => {
      addLine('sys', '', payload.message || 'Error', nowIso());
    });

    function doJoin(){
      currentNick = (nickEl.value || '').trim() || 'anon';
      currentRoom = normalizeRoom(roomEl.value);
      setRoomTag(currentRoom);
      socket.emit('join', { room: currentRoom, nick: currentNick });
      if (navigator.vibrate) navigator.vibrate(10);
      textEl.focus();
    }

    function doSend(){
      const t = (textEl.value || '').trim();
      if (!t) return;
      socket.emit('msg', { text: t });
      textEl.value = '';
      updateLen();
      textEl.focus();
      if (navigator.vibrate) navigator.vibrate(8);
    }

    document.getElementById('join').onclick = doJoin;
    document.getElementById('send').onclick = doSend;

    document.getElementById('clear').onclick = () => {
      socket.emit('clear_room');
      if (navigator.vibrate) navigator.vibrate([8,20,8]);
    };

    document.getElementById('bottom').onclick = () => {
      logEl.scrollTop = logEl.scrollHeight;
      textEl.focus();
    };

    textEl.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey){
        e.preventDefault();
        doSend();
      }
    });

    // initial join
    doJoin();
  </script>
</body>
</html>
HTML

  pushd "${SERVER_DIR}" >/dev/null
  npm install --omit=dev
  popd >/dev/null

  chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"
}

write_systemd_unit() {
  log "Writing systemd unit: ${SYSTEMD_UNIT}"

  cat > "/etc/systemd/system/${SYSTEMD_UNIT}" <<UNIT
[Unit]
Description=Anon Hourly Chat (wipes every hour) for ${DOMAIN}
After=network-online.target redis-server.service
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${SERVER_DIR}
Environment=NODE_ENV=production
Environment=PORT=${APP_PORT}
Environment=REDIS_URL=redis://127.0.0.1:6379
Environment=CHAT_KEY_PREFIX=chat:
Environment=WIPE_EVERY_HOUR=1
Environment=MAX_MSG_LEN=800
ExecStart=/usr/bin/node ${SERVER_DIR}/server.js
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now "${SYSTEMD_UNIT}"
  systemctl restart "${SYSTEMD_UNIT}"
}

write_nginx_http_only() {
  log "Writing Nginx HTTP-only config (for first-time ACME + temporary service)..."
  mkdir -p "${ACME_WEBROOT}/.well-known/acme-challenge"

  cat > "${NGINX_AVAIL}" <<NGINX
server {
  listen 80;
  server_name ${DOMAIN};

  location ^~ /.well-known/acme-challenge/ {
    root ${ACME_WEBROOT};
    default_type text/plain;
  }

  location / {
    proxy_pass http://127.0.0.1:${APP_PORT};
    proxy_http_version 1.1;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";

    proxy_read_timeout 120s;
  }
}
NGINX

  ln -sf "${NGINX_AVAIL}" "${NGINX_ENABLED}"
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  nginx -t
  systemctl reload nginx
}

write_nginx_https_force() {
  log "Writing Nginx HTTPS config (force HTTPS; keep ACME path on 80)..."
  mkdir -p "${ACME_WEBROOT}/.well-known/acme-challenge"

  cat > "${NGINX_AVAIL}" <<NGINX
server {
  listen 80;
  server_name ${DOMAIN};

  location ^~ /.well-known/acme-challenge/ {
    root ${ACME_WEBROOT};
    default_type text/plain;
  }

  location / {
    return 301 https://\$host\$request_uri;
  }
}

server {
  listen 443 ssl http2;
  server_name ${DOMAIN};

  ssl_certificate     ${LE_FULLCHAIN};
  ssl_certificate_key ${LE_PRIVKEY};

  ssl_session_timeout 1d;
  ssl_session_cache shared:SSL:10m;
  ssl_session_tickets off;

  add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

  location / {
    proxy_pass http://127.0.0.1:${APP_PORT};
    proxy_http_version 1.1;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";

    proxy_read_timeout 120s;
  }
}
NGINX

  ln -sf "${NGINX_AVAIL}" "${NGINX_ENABLED}"
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  nginx -t
  systemctl reload nginx
}

obtain_cert_if_needed() {
  if [[ -f "${LE_FULLCHAIN}" && -f "${LE_PRIVKEY}" ]]; then
    log "Existing cert found at ${LE_LIVE_DIR}; NOT overwriting."
    return 0
  fi

  log "No existing cert found. Obtaining Let's Encrypt cert for ${DOMAIN} (webroot)..."
  mkdir -p "${ACME_WEBROOT}/.well-known/acme-challenge"

  write_nginx_http_only

  certbot certonly \
    --non-interactive --agree-tos \
    --email "${LE_EMAIL}" \
    --webroot -w "${ACME_WEBROOT}" \
    -d "${DOMAIN}" \
    --keep-until-expiring

  if [[ ! -f "${LE_FULLCHAIN}" || ! -f "${LE_PRIVKEY}" ]]; then
    die "Cert issuance did not produce expected files under ${LE_LIVE_DIR}."
  fi

  log "Cert obtained: ${LE_FULLCHAIN}"
}

post_checks() {
  log "Post-checks..."
  systemctl --no-pager --full status "${SYSTEMD_UNIT}" || true
  nginx -t

  log "Local health check (HTTP to localhost):"
  curl -fsS "http://127.0.0.1:${APP_PORT}/healthz" | jq . || true

  if [[ -f "${LE_FULLCHAIN}" && -f "${LE_PRIVKEY}" ]]; then
    log "Nginx HTTPS endpoint check (SNI to localhost):"
    curl -kfsS "https://127.0.0.1/healthz" -H "Host: ${DOMAIN}" | jq . || true
  else
    warn "No cert detected yet; HTTPS check skipped."
  fi

  log "Done. Open: https://${DOMAIN}/"
  log "Logs: journalctl -u ${SYSTEMD_UNIT} -f --no-pager"
}

main() {
  need_root
  log "Installing ${APP_NAME} on ${DOMAIN} (HTTPS required)"

  ensure_pkgs
  ensure_node20

  stop_previous
  create_user
  write_app_files
  write_systemd_unit

  obtain_cert_if_needed

  if [[ -f "${LE_FULLCHAIN}" && -f "${LE_PRIVKEY}" ]]; then
    write_nginx_https_force
  else
    die "HTTPS is required but no cert exists. Fix DNS/80 reachability and rerun."
  fi

  post_checks
}

main "$@"