

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

CHAT_VERSION="v1.0.0"

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
  # certbot.timer handles renewals
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

  # NodeSource setup for Ubuntu
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

  # Stop systemd unit if exists
  if systemctl list-unit-files | awk '{print $1}' | grep -qx "${SYSTEMD_UNIT}"; then
    systemctl stop "${SYSTEMD_UNIT}" || true
    systemctl disable "${SYSTEMD_UNIT}" || true
  fi

  # Kill any stray node processes pointing at our app dir
  pkill -f "${APP_DIR}/server.js" 2>/dev/null || true
  pkill -f "${SERVER_DIR}/server.js" 2>/dev/null || true
  pkill -f "${APP_NAME}" 2>/dev/null || true

  # Ensure port is free
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

const VERSION = 'v1.0.0';

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
  // letters, numbers, dash, underscore
  const r = String(room || '').trim();
  if (!r) return 'lobby';
  const cleaned = r.replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 64);
  return cleaned || 'lobby';
}

function kRoomMessages(room) {
  return `${CHAT_KEY_PREFIX}room:${room}:messages`; // Redis list
}

function kRoomMeta(room) {
  return `${CHAT_KEY_PREFIX}room:${room}:meta`; // hash
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
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Anon Hourly Chat</title>
  <style>
    body { font-family: system-ui, -apple-system, Segoe UI, Roboto, Arial; margin: 0; background: #0b0f14; color: #e6edf3; }
    header { padding: 12px 14px; border-bottom: 1px solid #1f2a37; display:flex; gap:10px; align-items:center; flex-wrap:wrap;}
    header input { background:#0f1720; color:#e6edf3; border:1px solid #233041; border-radius:10px; padding:10px 12px; outline:none; }
    header button { background:#1f6feb; color:white; border:none; border-radius:10px; padding:10px 12px; cursor:pointer; }
    header button:hover { opacity: .9; }
    .hint { opacity:.8; font-size: 12px; }
    #wrap { display:flex; flex-direction:column; height: calc(100vh - 64px); }
    #log { flex:1; overflow:auto; padding: 14px; }
    .msg { margin: 10px 0; }
    .meta { opacity:.75; font-size: 12px; }
    .bubble { display:inline-block; padding: 10px 12px; border-radius: 14px; background:#0f1720; border:1px solid #233041; max-width: 900px; white-space:pre-wrap; word-break:break-word; }
    .sys .bubble { background:#121a25; border-style:dashed; }
    footer { border-top: 1px solid #1f2a37; padding: 12px 14px; display:flex; gap:10px; }
    footer input { flex:1; background:#0f1720; color:#e6edf3; border:1px solid #233041; border-radius:12px; padding:12px; outline:none; }
    footer button { background:#2ea043; color:white; border:none; border-radius:12px; padding:12px 14px; cursor:pointer; }
    footer button:hover { opacity:.9; }
  </style>
</head>
<body>
  <header>
    <strong>Anon Hourly Chat</strong>
    <input id="room" placeholder="room (e.g. mathclub)" />
    <input id="nick" placeholder="nickname (e.g. anon_fox)" />
    <button id="join">Join</button>
    <button id="clear">Clear room</button>
    <div class="hint">All content auto-wipes every hour (server-side).</div>
  </header>

  <div id="wrap">
    <div id="log"></div>
    <footer>
      <input id="text" placeholder="Type a message…" maxlength="800" />
      <button id="send">Send</button>
    </footer>
  </div>

  <script src="https://cdn.socket.io/4.7.5/socket.io.min.js"></script>
  <script>
    const log = document.getElementById('log');
    const roomEl = document.getElementById('room');
    const nickEl = document.getElementById('nick');
    const textEl = document.getElementById('text');

    function addLine(kind, nick, text, ts) {
      const div = document.createElement('div');
      div.className = 'msg ' + (kind === 'sys' ? 'sys' : '');
      const meta = document.createElement('div');
      meta.className = 'meta';
      meta.textContent = kind === 'sys'
        ? `[system] ${ts || ''}`
        : `${nick || 'anon'} · ${ts || ''}`;
      const bubble = document.createElement('div');
      bubble.className = 'bubble';
      bubble.textContent = text;
      div.appendChild(meta);
      div.appendChild(bubble);
      log.appendChild(div);
      log.scrollTop = log.scrollHeight;
    }

    function randNick() {
      const a = ['anon','quiet','wild','moss','cloud','fox','owl','cat','byte','leaf'];
      const b = Math.floor(Math.random()*10000).toString().padStart(4,'0');
      return a[Math.floor(Math.random()*a.length)] + '_' + b;
    }

    if (!nickEl.value) nickEl.value = randNick();
    if (!roomEl.value) roomEl.value = 'lobby';

    const socket = io({ transports: ['websocket'] });

    socket.on('history', (payload) => {
      log.innerHTML = '';
      (payload.history || []).forEach(m => addLine('msg', m.nick, m.text, m.ts));
      addLine('sys', '', `Joined room: ${payload.room}`, new Date().toISOString());
    });

    socket.on('system', (payload) => {
      addLine('sys', '', payload.message, payload.ts);
    });

    socket.on('msg', (payload) => {
      addLine('msg', payload.msg.nick, payload.msg.text, payload.msg.ts);
    });

    socket.on('error_msg', (payload) => {
      addLine('sys', '', payload.message || 'Error', new Date().toISOString());
    });

    document.getElementById('join').onclick = () => {
      socket.emit('join', { room: roomEl.value, nick: nickEl.value });
    };

    document.getElementById('send').onclick = () => {
      const t = textEl.value.trim();
      if (!t) return;
      socket.emit('msg', { text: t });
      textEl.value = '';
      textEl.focus();
    };

    document.getElementById('clear').onclick = () => {
      socket.emit('clear_room');
    };

    textEl.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') document.getElementById('send').click();
    });

    // auto-join
    socket.emit('join', { room: roomEl.value, nick: nickEl.value });
  </script>
</body>
</html>
HTML

  # install deps
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

# Hardening (kept minimal to avoid surprises)
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

  # Temporary: serve app over HTTP until cert exists.
  # Once cert exists, we will rewrite config to force HTTPS.
  location / {
    proxy_pass http://127.0.0.1:${APP_PORT};
    proxy_http_version 1.1;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    # WebSocket
    proxy_set_header Upgrade $http_upgrade;
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
    return 301 https://$host$request_uri;
  }
}

server {
  listen 443 ssl http2;
  server_name ${DOMAIN};

  ssl_certificate     ${LE_FULLCHAIN};
  ssl_certificate_key ${LE_PRIVKEY};

  # Reasonable modern TLS defaults (kept conservative)
  ssl_session_timeout 1d;
  ssl_session_cache shared:SSL:10m;
  ssl_session_tickets off;

  # HSTS (comment out if you ever need to serve HTTP again)
  add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

  location / {
    proxy_pass http://127.0.0.1:${APP_PORT};
    proxy_http_version 1.1;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;

    # WebSocket
    proxy_set_header Upgrade $http_upgrade;
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

  # Ensure HTTP vhost is active for ACME
  write_nginx_http_only

  # certonly avoids rewriting nginx config; --keep-until-expiring avoids needless reissue
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

  # Now enforce HTTPS (requires cert to exist)
  if [[ -f "${LE_FULLCHAIN}" && -f "${LE_PRIVKEY}" ]]; then
    write_nginx_https_force
  else
    die "HTTPS is required but no cert exists. Fix DNS/80 reachability and rerun."
  fi

  post_checks
}

main "$@"