#!/usr/bin/env bash
set -euo pipefail

# anon-hourly-chat installer (Node + Socket.IO + Redis + Nginx)
# - Anonymous multi-room chat
# - Redis stores per-room message history (1 hour TTL)
# - Wipes ALL chat:* keys every hour at the top of the hour (server-side scheduler)
# - Nginx reverse proxy + optional TLS with certbot (webroot)
# - systemd service
#
# Usage (recommended; avoids process-substitution /dev/fd issues under sudo):
#   curl -fsSL https://raw.githubusercontent.com/ieduer/bdfz/main/chat.sh | sudo bash -s -- install --domain chat.example.com
#
# Usage:
#   sudo bash chat.sh install --domain chat.example.com
#   sudo bash chat.sh uninstall --domain chat.example.com
#   sudo bash chat.sh status
#   sudo bash chat.sh logs
#
# Notes:
# - This script will NOT overwrite existing cert files if already present.
# - Default: listens on 127.0.0.1:8080 behind Nginx.

CHAT_VERSION="v1.2.3"

APP_NAME="anon-hourly-chat"
APP_USER="anonchat"
APP_GROUP="anonchat"

BASE_DIR="/opt/${APP_NAME}"
SERVER_DIR="${BASE_DIR}/server"
PUBLIC_DIR="${SERVER_DIR}/public"

SERVICE_NAME="${APP_NAME}.service"

NGINX_SITE_AVAIL="/etc/nginx/sites-available/${APP_NAME}.conf"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/${APP_NAME}.conf"

DEFAULT_PORT="8080"
DEFAULT_DOMAIN=""

REDIS_URL_DEFAULT="redis://127.0.0.1:6379"
CHAT_KEY_PREFIX_DEFAULT="chat:"
MAX_MSG_LEN_DEFAULT="800"

PURGE_DATA_DEFAULT="1"
PURGE_USER_DEFAULT="0"
PURGE_CERT_DEFAULT="0"

usage() {
  cat <<EOF
${APP_NAME} ${CHAT_VERSION}

Commands:
  install   --domain <domain> [--port 8080] [--redis-url redis://127.0.0.1:6379] [--prefix chat:] [--max-len 800]
  uninstall --domain <domain> [--purge-data 0|1] [--purge-user 0|1] [--purge-cert 0|1]
  status
  logs

Examples:
  sudo bash chat.sh install --domain chat.example.com
  sudo bash chat.sh install --domain chat.example.com --port 8080 --prefix chat:
  sudo bash chat.sh logs

Tip (recommended):
  curl -fsSL https://raw.githubusercontent.com/ieduer/bdfz/main/chat.sh | sudo bash -s -- install --domain chat.example.com
EOF
}

log() { echo -e "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"; }
die() { echo -e "ERROR: $*" >&2; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Please run as root: sudo bash $0 ..."
  fi
}

parse_args_install() {
  DOMAIN="${DEFAULT_DOMAIN}"
  PORT="${DEFAULT_PORT}"
  REDIS_URL="${REDIS_URL_DEFAULT}"
  CHAT_KEY_PREFIX="${CHAT_KEY_PREFIX_DEFAULT}"
  MAX_MSG_LEN="${MAX_MSG_LEN_DEFAULT}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) DOMAIN="${2:-}"; shift 2 ;;
      --port) PORT="${2:-}"; shift 2 ;;
      --redis-url) REDIS_URL="${2:-}"; shift 2 ;;
      --prefix) CHAT_KEY_PREFIX="${2:-}"; shift 2 ;;
      --max-len) MAX_MSG_LEN="${2:-}"; shift 2 ;;
      *) die "Unknown arg: $1" ;;
    esac
  done

  [[ -n "${DOMAIN}" ]] || die "--domain is required"
  [[ "${PORT}" =~ ^[0-9]+$ ]] || die "--port must be numeric"
  [[ "${MAX_MSG_LEN}" =~ ^[0-9]+$ ]] || die "--max-len must be numeric"
}

parse_args_uninstall() {
  DOMAIN="${DEFAULT_DOMAIN}"
  PURGE_DATA="${PURGE_DATA_DEFAULT}"
  PURGE_USER="${PURGE_USER_DEFAULT}"
  PURGE_CERT="${PURGE_CERT_DEFAULT}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) DOMAIN="${2:-}"; shift 2 ;;
      --purge-data) PURGE_DATA="${2:-}"; shift 2 ;;
      --purge-user) PURGE_USER="${2:-}"; shift 2 ;;
      --purge-cert) PURGE_CERT="${2:-}"; shift 2 ;;
      *) die "Unknown arg: $1" ;;
    esac
  done

  [[ -n "${DOMAIN}" ]] || die "--domain is required"
  [[ "${PURGE_DATA}" == "0" || "${PURGE_DATA}" == "1" ]] || die "--purge-data must be 0 or 1"
  [[ "${PURGE_USER}" == "0" || "${PURGE_USER}" == "1" ]] || die "--purge-user must be 0 or 1"
  [[ "${PURGE_CERT}" == "0" || "${PURGE_CERT}" == "1" ]] || die "--purge-cert must be 0 or 1"
}

ensure_packages() {
  log "Installing system packages..."
  apt-get update -y
  apt-get install -y \
    curl ca-certificates gnupg \
    nginx redis-server \
    certbot \
    jq

  systemctl enable --now redis-server >/dev/null 2>&1 || true
  systemctl enable --now nginx >/dev/null 2>&1 || true
}

ensure_node20() {
  if command -v node >/dev/null 2>&1; then
    local v
    v="$(node -v | sed 's/^v//')"
    local major="${v%%.*}"
    if [[ "${major}" -ge 20 ]]; then
      log "Node.js already present: node v${v}"
      return
    fi
  fi

  log "Installing Node.js 20 (NodeSource)..."
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
  apt-get update -y
  apt-get install -y nodejs

  node -v || die "Node install failed"
  npm -v || die "npm install failed"
}

ensure_user() {
  if id -u "${APP_USER}" >/dev/null 2>&1; then
    log "User exists: ${APP_USER}"
  else
    log "Creating user: ${APP_USER}"
    useradd --system --home-dir "${BASE_DIR}" --create-home --shell /usr/sbin/nologin "${APP_USER}"
  fi

  if getent group "${APP_GROUP}" >/dev/null 2>&1; then
    :
  else
    groupadd --system "${APP_GROUP}"
  fi

  usermod -a -G "${APP_GROUP}" "${APP_USER}" >/dev/null 2>&1 || true
}

stop_service_if_running() {
  if systemctl list-units --full -all | grep -q "^${SERVICE_NAME}"; then
    systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
    systemctl reset-failed "${SERVICE_NAME}" >/dev/null 2>&1 || true
  fi
}

write_app_files() {
  log "Writing app files to ${SERVER_DIR} ..."

  mkdir -p "${PUBLIC_DIR}"
  chown -R "${APP_USER}:${APP_GROUP}" "${BASE_DIR}" || true
  chmod 755 "${BASE_DIR}" "${SERVER_DIR}" "${PUBLIC_DIR}" || true

  cat > "${SERVER_DIR}/package.json" <<'JSON'
{
  "name": "anon-hourly-chat",
  "version": "1.2.3",
  "private": true,
  "type": "commonjs",
  "main": "server.js",
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
 * - Presence: room online counts + top rooms
 * - /me action messages
 * - client_id support for optimistic UI de-dup on client
 */

const path = require('path');
const http = require('http');
const express = require('express');
const { Server } = require('socket.io');
const Redis = require('ioredis');

const VERSION = 'v1.2.3';

const PORT = parseInt(process.env.PORT || '8080', 10);
const REDIS_URL = process.env.REDIS_URL || 'redis://127.0.0.1:6379';
const CHAT_KEY_PREFIX = process.env.CHAT_KEY_PREFIX || 'chat:';
const WIPE_EVERY_HOUR = (process.env.WIPE_EVERY_HOUR || '1') === '1';
const MAX_MSG_LEN = parseInt(process.env.MAX_MSG_LEN || '800', 10);
const PRESENCE_DEBOUNCE_MS = parseInt(process.env.PRESENCE_DEBOUNCE_MS || '350', 10);

function nowIso() {
  return new Date().toISOString();
}

function clampText(s, maxLen) {
  const t = String(s || '');
  if (t.length <= maxLen) return t;
  return t.slice(0, maxLen);
}

function safeNick(nick) {
  const t = String(nick || '').trim();
  if (!t) return 'anon';
  const cleaned = t.replace(/[^a-zA-Z0-9_.-]/g, '').slice(0, 24);
  return cleaned || 'anon';
}

function safeRoom(room) {
  const r = String(room || '').trim();
  if (!r) return 'lobby';
  const cleaned = r.replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 64);
  return cleaned || 'lobby';
}

function safeClientId(x) {
  const t = String(x || '').trim();
  if (!t) return '';
  const cleaned = t.replace(/[^a-zA-Z0-9_.:-]/g, '').slice(0, 80);
  return cleaned;
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

function listPublicRooms(io) {
  const rooms = [];
  const adapter = io.sockets.adapter;
  for (const [name, sockets] of adapter.rooms) {
    if (adapter.sids && adapter.sids.has(name)) continue;
    const online = sockets ? sockets.size : 0;
    if (online <= 0) continue;
    rooms.push({ room: name, online });
  }
  rooms.sort((a, b) => (b.online - a.online) || a.room.localeCompare(b.room));
  return rooms;
}

function buildPresencePayload(io) {
  return {
    ts: nowIso(),
    rooms: listPublicRooms(io).slice(0, 30)
  };
}

function mkPresenceBroadcaster(io) {
  let timer = null;
  let lastSentAt = 0;

  const flush = () => {
    timer = null;
    lastSentAt = Date.now();
    io.emit('presence', buildPresencePayload(io));
  };

  return () => {
    if (timer) return;
    const elapsed = Date.now() - lastSentAt;
    const delay = Math.max(0, PRESENCE_DEBOUNCE_MS - elapsed);
    timer = setTimeout(flush, delay);
  };
}

function parseMessageText(raw) {
  const t = clampText(raw, MAX_MSG_LEN).trim();
  if (!t) return null;

  if (t.startsWith('/me ')) {
    const action = t.slice(4).trim();
    if (!action) return null;
    return { type: 'action', text: action };
  }

  if (t === '/me') return null;

  return { type: 'text', text: t };
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
    cors: { origin: false },
    transports: ['websocket']
  });

  const broadcastPresence = mkPresenceBroadcaster(io);

  app.get('/healthz', (req, res) => {
    res.json({ ok: true, ts: nowIso(), version: VERSION });
  });

  app.use('/', express.static(path.join(__dirname, 'public')));

  io.on('connection', (socket) => {
    socket.emit('presence', buildPresencePayload(io));
    broadcastPresence();

    socket.on('join', async (payload) => {
      const nextRoom = safeRoom(payload && payload.room);
      const nick = safeNick((payload && payload.nick) || 'anon');

      const prevRoomRaw = socket.data.room || '';
      const prevRoom = prevRoomRaw ? safeRoom(prevRoomRaw) : '';

      if (prevRoom && prevRoom !== nextRoom) {
        socket.leave(prevRoom);
      }

      socket.data.room = nextRoom;
      socket.data.nick = nick;
      socket.join(nextRoom);

      try {
        const key = kRoomMessages(nextRoom);
        const items = await redis.lrange(key, -100, -1);
        const history = items
          .map((s) => {
            try { return JSON.parse(s); } catch { return null; }
          })
          .filter(Boolean);

        socket.emit('history', { room: nextRoom, history });

        await redis.hset(kRoomMeta(nextRoom), 'last_active', nowIso());
        await redis.expire(kRoomMeta(nextRoom), 3600);
      } catch (e) {
        socket.emit('error_msg', { message: 'Failed to load history.' });
      }

      io.to(nextRoom).emit('system', { room: nextRoom, message: `${nick} joined`, ts: nowIso() });
      broadcastPresence();
    });

    socket.on('msg', async (payload) => {
      const room = safeRoom(socket.data.room || 'lobby');
      const nick = safeNick(socket.data.nick || 'anon');

      const parsed = parseMessageText(payload && payload.text);
      if (!parsed) return;

      const client_id = safeClientId(payload && payload.client_id);

      const msg = {
        id: socket.id + ':' + Date.now(),
        client_id,
        nick,
        text: parsed.text,
        type: parsed.type,
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

    socket.on('disconnect', () => {
      broadcastPresence();
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
      --shadow: 0 10px 30px rgba(0,0,0,.35);
      --r:14px;
      --mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
      --sans: system-ui, -apple-system, Segoe UI, Roboto, Arial;

      --accent: hsl(150 72% 52%);
      --accent2: hsl(150 72% 60%);
      --accentSoft: hsla(150, 72%, 52%, .16);

      --warn:#f2cc60;
      --red:#ff6b6b;

      --composerH: 44px;
    }

    *{ box-sizing:border-box; }
    html,body{ height:100%; }
    body{
      margin:0;
      background:
        radial-gradient(1100px 700px at 30% 0%, var(--accentSoft), transparent 60%),
        radial-gradient(900px 600px at 100% 10%, hsla(190, 72%, 52%, .10), transparent 55%),
        var(--bg);
      color:var(--text);
      font-family: var(--sans);
      -webkit-font-smoothing: antialiased;
      -moz-osx-font-smoothing: grayscale;
    }

    .app{ height:100vh; height:100dvh; display:flex; flex-direction:column; }

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

    .brand{ display:flex; align-items:baseline; gap:10px; min-width: 0; }

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
      width:8px; height:8px; border-radius:99px;
      background: rgba(255,255,255,.25);
      box-shadow: 0 0 0 2px rgba(255,255,255,.06) inset;
    }
    .dot.ok{ background: var(--accent); box-shadow: 0 0 14px var(--accentSoft); }
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
    .btn.primary{ border-color: color-mix(in srgb, var(--accent) 65%, rgba(31,42,55,.9)); }

    .tabs-wrap{ max-width: 1100px; margin: 0 auto; padding: 0 14px 10px 14px; }

    .tabs{
      display:flex; gap:8px; overflow:auto; padding-bottom: 2px;
      scrollbar-width: none;
    }
    .tabs::-webkit-scrollbar{ display:none; }

    .tab{
      display:inline-flex;
      align-items:center;
      gap:8px;
      padding: 8px 10px;
      border-radius: 999px;
      border: 1px solid rgba(31,42,55,.88);
      background: rgba(11,15,20,.62);
      font-family: var(--mono);
      font-size: 12px;
      color: rgba(230,237,243,.86);
      white-space:nowrap;
      cursor:pointer;
      user-select:none;
      transition: transform .06s ease, background .15s ease, border-color .15s ease;
    }

    .tab:hover{ background: rgba(15,23,32,.78); }
    .tab:active{ transform: translateY(1px); }

    .tab .badge{
      padding: 2px 7px;
      border-radius: 999px;
      border: 1px solid rgba(35,48,65,.9);
      background: rgba(15,23,32,.78);
      color: rgba(230,237,243,.78);
      font-size: 11px;
      line-height: 1.2;
    }

    .tab .badge.unread{
      border-color: color-mix(in srgb, var(--accent) 70%, rgba(35,48,65,.9));
      color: rgba(230,237,243,.92);
      box-shadow: 0 0 0 2px var(--accentSoft) inset;
    }

    .tab.active{
      border-color: color-mix(in srgb, var(--accent) 70%, rgba(31,42,55,.88));
      box-shadow: 0 0 0 2px var(--accentSoft) inset;
    }

    .main{ flex:1; min-height:0; display:flex; justify-content:center; }

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

    .field{ display:flex; flex-direction:column; gap:6px; min-width: 160px; flex: 1; }
    .field label{ font-family: var(--mono); font-size: 11px; color: var(--muted); }

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
      border-color: color-mix(in srgb, var(--accent) 60%, rgba(35,48,65,.9));
      box-shadow: 0 0 0 3px var(--accentSoft);
    }

    .hint{
      padding: 0 12px 12px 12px;
      font-family: var(--mono);
      font-size: 12px;
      color: var(--muted);
      line-height: 1.35;
    }

    .log{ flex:1; min-height: 0; padding: 12px; overflow:auto; scroll-behavior: smooth; }

    .row{ margin: 10px 0; display:flex; gap:10px; }

    .avatar{
      width: 22px; height: 22px;
      border-radius: 6px;
      border: 1px solid rgba(31,42,55,.9);
      background: rgba(15,23,32,.95);
      display:flex; align-items:center; justify-content:center;
      font-family: var(--mono);
      font-size: 12px;
      color: rgba(230,237,243,.85);
      flex: 0 0 auto;
    }

    .msgbox{ flex:1; min-width:0; }

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
      border-color: color-mix(in srgb, var(--accent) 70%, rgba(35,48,65,.9));
      box-shadow: 0 0 0 2px var(--accentSoft) inset;
    }

    .action .bubble{
      background: rgba(11,15,20,.55);
      border-color: color-mix(in srgb, var(--accent) 60%, rgba(35,48,65,.9));
      font-style: italic;
    }

    .pending .bubble{
      opacity: .78;
      border-style: dashed;
    }

    .mention{
      padding: 1px 4px;
      border-radius: 8px;
      border: 1px solid rgba(35,48,65,.9);
      background: rgba(11,15,20,.55);
      color: rgba(230,237,243,.92);
    }

    .mention.self{
      border-color: color-mix(in srgb, var(--accent) 80%, rgba(35,48,65,.9));
      box-shadow: 0 0 0 2px var(--accentSoft) inset;
    }

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
      align-items: stretch;
    }

    .inputwrap{ flex:1; min-width:0; }

    textarea{
      width:100%;
      resize: none;
      height: var(--composerH);
      min-height: var(--composerH);
      max-height: var(--composerH);
      background: rgba(15,23,32,.92);
      color: var(--text);
      border: 1px solid rgba(35,48,65,.95);
      border-radius: 14px;
      padding: 11px 12px;
      outline:none;
      font-family: var(--mono);
      font-size: 13px;
      line-height: 1.35;
      overflow: hidden;
    }

    textarea:focus{
      border-color: color-mix(in srgb, var(--accent) 60%, rgba(35,48,65,.95));
      box-shadow: 0 0 0 3px var(--accentSoft);
    }

    #send{
      height: var(--composerH);
      min-height: var(--composerH);
      padding: 10px 14px;
      align-self: stretch;
      display:flex;
      align-items:center;
      justify-content:center;
    }

    @media (max-width: 720px){
      .topbar-inner{ padding-left: 12px; padding-right: 12px; }
      .tabs-wrap{ padding-left: 12px; padding-right: 12px; }
      .frame{ padding: 10px 12px; }
      .join{ padding: 10px; }
      .field{ min-width: 0; flex: 1 1 100%; }
      .pill{ display:none; }
      .bubble{ max-width: 100%; }
      .composer-inner{ padding-left: 12px; padding-right: 12px; }
    }

    @media (prefers-reduced-motion: reduce){
      .log{ scroll-behavior:auto; }
      .btn{ transition:none; }
      .tab{ transition:none; }
    }
  </style>
</head>
<body>
  <div class="app">
    <div class="topbar">
      <div class="topbar-inner">
        <div class="brand">
          <h1>Anon Hourly Chat</h1>
          <div class="tag" id="roomTag">room:lobby • online:0</div>
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

        <button class="btn" id="bottom">bottom</button>
      </div>

      <div class="tabs-wrap">
        <div class="tabs" id="tabs" aria-label="rooms"></div>
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
            <button class="btn primary" id="join">join</button>
          </div>
          <div class="hint">Anonymous. No accounts. Server wipes all chat data every hour. <span style="opacity:.8">Tips: use <b>/me</b> for actions; ping with <b>@nick</b>.</span></div>
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
        </div>
        <button class="btn primary" id="send">send</button>
      </div>
    </div>
  </div>

  <script src="/socket.io/socket.io.js"></script>
  <script>
    const logEl = document.getElementById('log');
    const tabsEl = document.getElementById('tabs');
    const roomEl = document.getElementById('room');
    const nickEl = document.getElementById('nick');
    const textEl = document.getElementById('text');
    const roomTag = document.getElementById('roomTag');
    const dot = document.getElementById('dot');
    const statusText = document.getElementById('statusText');
    const wipeCountdown = document.getElementById('wipeCountdown');

    let currentRoom = 'lobby';
    let currentNick = '';
    let currentOnline = 0;

    const roomLogs = new Map();      // room -> [{...}]
    const roomUnread = new Map();    // room -> unread
    let lastPresenceRooms = [];

    const visitedRooms = new Map();  // room -> ts
    const pendingByClientId = new Map(); // client_id -> { room, idx }

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

    function tickWipe(){ wipeCountdown.textContent = fmtCountdown(msUntilNextHour()); }
    setInterval(tickWipe, 500);
    tickWipe();

    function setStatus(kind, text){
      dot.className = 'dot ' + (kind || '');
      statusText.textContent = text;
    }

    function safeRoomName(r){
      const t = String(r || '').trim();
      if (!t) return 'lobby';
      const cleaned = t.replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 64);
      return cleaned || 'lobby';
    }

    function safeNickName(n){
      const t = String(n || '').trim();
      if (!t) return 'anon';
      const cleaned = t.replace(/[^a-zA-Z0-9_.-]/g, '').slice(0, 24);
      return cleaned || 'anon';
    }

    function normalizeRoom(r){ return safeRoomName(r); }

    function avatarChar(nick){
      const t = String(nick || 'a');
      const ch = (t.trim()[0] || 'a').toUpperCase();
      return ch;
    }

    function hashHue(str){
      const s = String(str || 'lobby');
      let h = 0;
      for (let i=0;i<s.length;i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
      return h % 360;
    }

    function applyRoomTheme(room){
      const hue = hashHue(room);
      const root = document.documentElement;
      root.style.setProperty('--accent', `hsl(${hue} 72% 52%)`);
      root.style.setProperty('--accent2', `hsl(${hue} 72% 60%)`);
      root.style.setProperty('--accentSoft', `hsla(${hue}, 72%, 52%, .16)`);
    }

    function setRoomTag(r){
      roomTag.textContent = `room:${r} • online:${currentOnline}`;
    }

    function randNick(){
      const a = ['anon','quiet','wild','moss','cloud','fox','owl','cat','byte','leaf','null','root','kilo','hex'];
      const b = Math.floor(Math.random()*10000).toString().padStart(4,'0');
      return a[Math.floor(Math.random()*a.length)] + '_' + b;
    }

    function getRoomLog(room){
      const r = normalizeRoom(room);
      if (!roomLogs.has(r)) roomLogs.set(r, []);
      return roomLogs.get(r);
    }

    function setRoomLog(room, entries){
      const r = normalizeRoom(room);
      roomLogs.set(r, Array.isArray(entries) ? entries.slice() : []);
    }

    function bumpUnread(room, n){
      const r = normalizeRoom(room);
      const cur = roomUnread.get(r) || 0;
      roomUnread.set(r, Math.max(0, cur + (n || 0)));
    }

    function clearUnread(room){
      const r = normalizeRoom(room);
      roomUnread.set(r, 0);
    }

    function getUnread(room){
      const r = normalizeRoom(room);
      return roomUnread.get(r) || 0;
    }

    function pruneRoomLog(room, max=420){
      const arr = getRoomLog(room);
      if (arr.length <= max) return;
      arr.splice(0, arr.length - max);
    }

    function renderEntry(entry){
      const kind = entry.kind || 'msg';
      const nick = entry.nick || '';
      const text = entry.text || '';
      const ts = entry.ts || '';
      const msgType = entry.msgType || 'text';
      const pending = !!entry.pending;

      const row = document.createElement('div');
      row.className = 'row ' + (kind || '') + (pending ? ' pending' : '');
      if (entry.client_id) row.dataset.clientId = entry.client_id;

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

      if (msgType === 'action') {
        bubble.textContent = `* ${nick || 'anon'} ${text}`;
      } else {
        const parts = String(text || '').split(/(@[a-zA-Z0-9_.-]{1,24})/g);
        for (const p of parts) {
          if (p && p.startsWith('@') && p.length > 1) {
            const span = document.createElement('span');
            span.className = 'mention';
            const target = p.slice(1);
            if (currentNick && target.toLowerCase() === currentNick.toLowerCase()) {
              span.classList.add('self');
            }
            span.textContent = p;
            bubble.appendChild(span);
          } else {
            bubble.appendChild(document.createTextNode(p));
          }
        }
      }

      box.appendChild(meta);
      box.appendChild(bubble);

      row.appendChild(av);
      row.appendChild(box);

      logEl.appendChild(row);

      const maxDom = 420;
      while (logEl.children.length > maxDom) {
        logEl.removeChild(logEl.firstElementChild);
      }

      logEl.scrollTop = logEl.scrollHeight;

      if (kind !== 'sys' && msgType !== 'action' && currentNick) {
        const escaped = currentNick.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
        const re = new RegExp('(^|\\s)@' + escaped + '(\\b)', 'i');
        if (re.test(String(text || '')) && navigator.vibrate) navigator.vibrate([12, 30, 12]);
      }
    }

    function pushEntry(room, entry){
      const r = normalizeRoom(room);
      const arr = getRoomLog(r);
      arr.push(entry);
      pruneRoomLog(r, 420);
      return arr.length - 1;
    }

    function renderRoom(room){
      const r = normalizeRoom(room);
      logEl.innerHTML = '';
      const arr = getRoomLog(r);
      for (const e of arr) renderEntry(e);
      logEl.scrollTop = logEl.scrollHeight;
    }

    function updateTabs(rooms){
      const list = Array.isArray(rooms) ? rooms.slice() : [];

      const merged = new Map();
      for (const r of list) merged.set(r.room, r.online);
      for (const [r, _ts] of visitedRooms.entries()) {
        if (!merged.has(r)) merged.set(r, 0);
      }

      const items = Array.from(merged.entries()).map(([room, online]) => ({ room, online }));

      items.sort((a, b) => {
        if (a.room === currentRoom) return -1;
        if (b.room === currentRoom) return 1;
        if (b.online !== a.online) return b.online - a.online;
        const at = visitedRooms.get(a.room) || 0;
        const bt = visitedRooms.get(b.room) || 0;
        return bt - at;
      });

      tabsEl.innerHTML = '';
      items.slice(0, 16).forEach(({room, online}) => {
        const t = document.createElement('div');
        t.className = 'tab' + (room === currentRoom ? ' active' : '');

        const name = document.createElement('span');
        name.textContent = room;

        const badgeOnline = document.createElement('span');
        badgeOnline.className = 'badge';
        badgeOnline.textContent = String(online);

        t.appendChild(name);
        t.appendChild(badgeOnline);

        const unread = getUnread(room);
        if (unread > 0 && room !== currentRoom) {
          const badgeUnread = document.createElement('span');
          badgeUnread.className = 'badge unread';
          badgeUnread.textContent = '+' + String(Math.min(unread, 99));
          t.appendChild(badgeUnread);
        }

        t.onclick = () => {
          roomEl.value = room;
          doJoin();
        };

        tabsEl.appendChild(t);
      });
    }

    function genClientId(){
      const r = Math.random().toString(16).slice(2, 10);
      return 'c:' + Date.now().toString(16) + ':' + r;
    }

    if (!nickEl.value) nickEl.value = randNick();
    if (!roomEl.value) roomEl.value = 'lobby';

    currentNick = safeNickName(nickEl.value);
    currentRoom = safeRoomName(roomEl.value);
    nickEl.value = currentNick;
    roomEl.value = currentRoom;

    visitedRooms.set(currentRoom, Date.now());
    applyRoomTheme(currentRoom);
    clearUnread(currentRoom);

    const socket = io({ transports: ['websocket'] });

    socket.on('connect', () => { setStatus('ok', 'online'); });
    socket.on('disconnect', (reason) => {
      setStatus('bad', 'offline');
      pushEntry(currentRoom, { kind: 'sys', nick: '', text: 'Disconnected: ' + reason, ts: nowIso(), msgType: 'text' });
      renderRoom(currentRoom);
    });
    socket.on('connect_error', () => { setStatus('warn', 'reconnecting…'); });

    socket.on('presence', (payload) => {
      lastPresenceRooms = (payload && payload.rooms) || [];
      const hit = lastPresenceRooms.find(r => r.room === currentRoom);
      currentOnline = hit ? hit.online : currentOnline;
      setRoomTag(currentRoom);
      updateTabs(lastPresenceRooms);
    });

    socket.on('history', (payload) => {
      const room = safeRoomName(payload && payload.room);
      const history = (payload && payload.history) || [];

      const entries = [];
      for (const m of history) {
        const me = (m.nick === currentNick);
        const kind = (m.type === 'action') ? 'action' : (me ? 'me' : 'msg');
        entries.push({
          kind,
          nick: m.nick,
          text: m.text,
          ts: m.ts,
          msgType: m.type || 'text',
          client_id: m.client_id || ''
        });
      }
      entries.push({ kind: 'sys', nick: '', text: 'Joined room: ' + room, ts: nowIso(), msgType: 'text' });

      setRoomLog(room, entries);

      currentRoom = room;
      roomEl.value = room;
      visitedRooms.set(currentRoom, Date.now());
      applyRoomTheme(currentRoom);
      clearUnread(currentRoom);

      const hit = lastPresenceRooms.find(r => r.room === currentRoom);
      if (hit) currentOnline = hit.online;

      setRoomTag(currentRoom);
      renderRoom(currentRoom);
      updateTabs(lastPresenceRooms);
      textEl.focus();
    });

    socket.on('system', (payload) => {
      const room = safeRoomName(payload && payload.room);
      pushEntry(room, { kind: 'sys', nick: '', text: (payload && payload.message) || 'system', ts: (payload && payload.ts) || nowIso(), msgType: 'text' });

      if (room === currentRoom) {
        renderRoom(currentRoom);
      } else {
        bumpUnread(room, 1);
        updateTabs(lastPresenceRooms);
      }
    });

    socket.on('msg', (payload) => {
      const room = safeRoomName(payload && payload.room);
      const msg = payload && payload.msg;
      if (!msg) return;

      // de-dup optimistic message
      const cid = String(msg.client_id || '').trim();
      if (cid && pendingByClientId.has(cid)) {
        const ref = pendingByClientId.get(cid);
        pendingByClientId.delete(cid);

        // update in-memory buffer
        const arr = getRoomLog(ref.room);
        const e = arr[ref.idx];
        if (e) {
          e.pending = false;
          e.ts = msg.ts || e.ts;
          e.msgType = msg.type || e.msgType;
          e.text = msg.text || e.text;
          e.nick = msg.nick || e.nick;
          e.kind = (msg.type === 'action') ? 'action' : ((msg.nick === currentNick) ? 'me' : 'msg');
          e.client_id = cid;
        }

        // best-effort: remove dashed style in DOM if this room is current
        if (ref.room === currentRoom) {
          const node = logEl.querySelector('[data-client-id="' + cid.replace(/"/g,'') + '"]');
          if (node) node.classList.remove('pending');
        }
        return;
      }

      const me = (msg.nick === currentNick);
      const kind = (msg.type === 'action') ? 'action' : (me ? 'me' : 'msg');

      const entry = { kind, nick: msg.nick, text: msg.text, ts: msg.ts, msgType: msg.type || 'text', client_id: cid, pending: false };
      pushEntry(room, entry);

      if (room === currentRoom) {
        // append-only for real-time feel
        renderEntry(entry);
      } else {
        bumpUnread(room, 1);
        updateTabs(lastPresenceRooms);
      }
    });

    socket.on('error_msg', (payload) => {
      const entry = { kind: 'sys', nick: '', text: (payload && payload.message) || 'Error', ts: nowIso(), msgType: 'text' };
      pushEntry(currentRoom, entry);
      renderEntry(entry);
    });

    function doJoin(){
      currentNick = safeNickName(nickEl.value || 'anon');
      const nextRoom = safeRoomName(roomEl.value);

      nickEl.value = currentNick;
      roomEl.value = nextRoom;

      // UI switches immediately (isolate view)
      currentRoom = nextRoom;
      visitedRooms.set(currentRoom, Date.now());
      applyRoomTheme(currentRoom);
      clearUnread(currentRoom);

      const hit = lastPresenceRooms.find(r => r.room === currentRoom);
      if (hit) currentOnline = hit.online;

      setRoomTag(currentRoom);
      renderRoom(currentRoom);
      updateTabs(lastPresenceRooms);

      socket.emit('join', { room: currentRoom, nick: currentNick });
      if (navigator.vibrate) navigator.vibrate(10);
      textEl.focus();
    }

    function doSend(){
      const t = (textEl.value || '');
      const trimmed = t.trim();
      if (!trimmed) return;

      const cid = genClientId();

      // optimistic append so user always sees it immediately
      const action = trimmed.startsWith('/me ') ? true : false;
      const entry = {
        kind: action ? 'action' : 'me',
        nick: currentNick || safeNickName(nickEl.value || 'anon'),
        text: action ? trimmed.slice(4).trim() : trimmed,
        ts: nowIso(),
        msgType: action ? 'action' : 'text',
        client_id: cid,
        pending: true
      };

      const idx = pushEntry(currentRoom, entry);
      pendingByClientId.set(cid, { room: currentRoom, idx });

      renderEntry(entry);

      socket.emit('msg', { text: trimmed, client_id: cid });

      textEl.value = '';
      textEl.focus();
      if (navigator.vibrate) navigator.vibrate(8);
    }

    document.getElementById('join').onclick = doJoin;
    document.getElementById('send').onclick = doSend;

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

  chown -R "${APP_USER}:${APP_GROUP}" "${BASE_DIR}" || true

  log "Installing npm deps..."
  pushd "${SERVER_DIR}" >/dev/null
  mkdir -p "${SERVER_DIR}/.npm-cache"
  chown -R "${APP_USER}:${APP_GROUP}" "${SERVER_DIR}/.npm-cache" || true
  sudo -u "${APP_USER}" -g "${APP_GROUP}" env NPM_CONFIG_CACHE="${SERVER_DIR}/.npm-cache" npm install --omit=dev
  popd >/dev/null
}

write_systemd_unit() {
  log "Writing systemd unit: ${SERVICE_NAME}"
  cat > "/etc/systemd/system/${SERVICE_NAME}" <<EOF
[Unit]
Description=Anon Hourly Chat (${APP_NAME})
After=network.target redis-server.service
Wants=redis-server.service

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${SERVER_DIR}
Environment=PORT=${PORT}
Environment=REDIS_URL=${REDIS_URL}
Environment=CHAT_KEY_PREFIX=${CHAT_KEY_PREFIX}
Environment=WIPE_EVERY_HOUR=1
Environment=MAX_MSG_LEN=${MAX_MSG_LEN}
Environment=PRESENCE_DEBOUNCE_MS=350

ExecStart=/usr/bin/node ${SERVER_DIR}/server.js
Restart=always
RestartSec=2

NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || systemctl start "${SERVICE_NAME}" >/dev/null 2>&1 || true
}

write_nginx_conf() {
  local domain="$1"
  log "Writing Nginx site config for ${domain} ..."

  cat > "${NGINX_SITE_AVAIL}" <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name ${domain};

  location ^~ /.well-known/acme-challenge/ {
    root /var/www/html;
    allow all;
  }

  location / {
    proxy_pass http://127.0.0.1:${PORT};
    proxy_http_version 1.1;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";

    proxy_read_timeout 60s;
    proxy_send_timeout 60s;
  }
}
EOF

  ln -sf "${NGINX_SITE_AVAIL}" "${NGINX_SITE_ENABLED}"

  nginx -t
  systemctl reload nginx
}

obtain_certificate_if_needed() {
  local domain="$1"
  local cert_dir="/etc/letsencrypt/live/${domain}"

  if [[ -d "${cert_dir}" ]] && [[ -s "${cert_dir}/fullchain.pem" ]] && [[ -s "${cert_dir}/privkey.pem" ]]; then
    log "Cert already exists for ${domain}, skipping certbot."
    return
  fi

  log "Obtaining TLS certificate via certbot (webroot) for ${domain} ..."
  mkdir -p /var/www/html
  certbot certonly --webroot -w /var/www/html -d "${domain}" --agree-tos --register-unsafely-without-email --non-interactive || die "certbot failed"

  log "Updating Nginx config to enable TLS..."
  cat > "${NGINX_SITE_AVAIL}" <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name ${domain};

  location ^~ /.well-known/acme-challenge/ {
    root /var/www/html;
    allow all;
  }

  location / {
    return 301 https://\$host\$request_uri;
  }
}

server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name ${domain};

  ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;

  ssl_session_timeout 1d;
  ssl_session_cache shared:SSL:10m;
  ssl_session_tickets off;

  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers off;

  add_header Strict-Transport-Security "max-age=31536000" always;

  location / {
    proxy_pass http://127.0.0.1:${PORT};
    proxy_http_version 1.1;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";

    proxy_read_timeout 60s;
    proxy_send_timeout 60s;
  }
}
EOF

  ln -sf "${NGINX_SITE_AVAIL}" "${NGINX_SITE_ENABLED}"
  nginx -t
  systemctl reload nginx
}

post_checks() {
  local domain="$1"
  log "Post-checks..."
  systemctl --no-pager status "${SERVICE_NAME}" || true

  log "Health check (local):"
  curl -fsS "http://127.0.0.1:${PORT}/healthz" | jq . || true

  log "Nginx test:"
  curl -I "http://${domain}/" --connect-timeout 5 || true
  curl -Ik "https://${domain}/" --connect-timeout 5 || true

  log "App files sanity:"
  ls -la "${SERVER_DIR}" || true
  ls -la "${PUBLIC_DIR}" | head -n 50 || true

  log "Done."
}

install() {
  require_root
  parse_args_install "$@"

  log "${APP_NAME} ${CHAT_VERSION} install begin"
  log "DOMAIN=${DOMAIN}"
  log "PORT=${PORT}"
  log "REDIS_URL=${REDIS_URL}"
  log "CHAT_KEY_PREFIX=${CHAT_KEY_PREFIX}"
  log "MAX_MSG_LEN=${MAX_MSG_LEN}"

  ensure_packages
  ensure_node20
  ensure_user

  mkdir -p "${BASE_DIR}"
  chown -R "${APP_USER}:${APP_GROUP}" "${BASE_DIR}" || true

  stop_service_if_running
  write_app_files
  write_systemd_unit
  write_nginx_conf "${DOMAIN}"
  obtain_certificate_if_needed "${DOMAIN}"
  post_checks "${DOMAIN}"
}

uninstall() {
  require_root
  parse_args_uninstall "$@"

  log "${APP_NAME} ${CHAT_VERSION} uninstall begin"
  log "DOMAIN=${DOMAIN}"
  log "PURGE_DATA=${PURGE_DATA} PURGE_USER=${PURGE_USER} PURGE_CERT=${PURGE_CERT}"

  systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl reset-failed "${SERVICE_NAME}" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}"
  systemctl daemon-reload >/dev/null 2>&1 || true

  rm -f "${NGINX_SITE_ENABLED}" || true
  rm -f "${NGINX_SITE_AVAIL}" || true
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true

  if [[ "${PURGE_DATA}" == "1" ]]; then
    rm -rf "${BASE_DIR}" || true
  fi

  if [[ "${PURGE_CERT}" == "1" ]]; then
    rm -rf "/etc/letsencrypt/live/${DOMAIN}" "/etc/letsencrypt/archive/${DOMAIN}" "/etc/letsencrypt/renewal/${DOMAIN}.conf" || true
  fi

  if [[ "${PURGE_USER}" == "1" ]]; then
    userdel "${APP_USER}" >/dev/null 2>&1 || true
    groupdel "${APP_GROUP}" >/dev/null 2>&1 || true
  fi

  log "Uninstall done."
}

status_cmd() {
  echo "${APP_NAME} ${CHAT_VERSION}"
  echo
  systemctl --no-pager status "${SERVICE_NAME}" || true
  echo
  echo "Listening ports:";
  ss -ltnp | grep -E ":(${DEFAULT_PORT})\s" || true
  echo
  echo "Local health:";
  curl -fsS "http://127.0.0.1:${DEFAULT_PORT}/healthz" | jq . || true
}

logs_cmd() {
  echo "${APP_NAME} ${CHAT_VERSION}"
  echo
  journalctl -u "${SERVICE_NAME}" -n 250 --no-pager || true
}

main() {
  local cmd="${1:-}"
  shift || true

  echo "${APP_NAME} ${CHAT_VERSION}"

  case "${cmd}" in
    install) install "$@" ;;
    uninstall) uninstall "$@" ;;
    status) status_cmd ;;
    logs) logs_cmd ;;
    -h|--help|help|"") usage ;;
    *) die "Unknown command: ${cmd}" ;;
  esac
}

main "$@"