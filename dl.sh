#!/usr/bin/env bash
# dl.sh - ytweb with progress, HTTPS, 8h auto-clean
# version: v1.0-2025-11-05
# changes from v1.0:
# - mobile-friendly index.html (narrow padding, bigger inputs, collapsible log on mobile)
# - frontend auto-expand log on error/done
# - keep HTTPS/mixed-content fix
# domain: xz.bdfz.net

set -euo pipefail

DOMAIN="xz.bdfz.net"
APP_DIR="/opt/ytweb"
VENV_DIR="$APP_DIR/venv"
RUN_USER="www-data"
DOWNLOAD_DIR="/var/www/yt-downloads"
SERVICE_NAME="ytweb.service"
YTDLP_BIN="$VENV_DIR/bin/yt-dlp"

echo "[ytweb] installing version v1.0-2025-11-05 ..."

# 0) stop old
if systemctl list-units --full -all | grep -q "$SERVICE_NAME"; then
  systemctl stop "$SERVICE_NAME" || true
fi
pkill -f "$APP_DIR/app.py" 2>/dev/null || true

# 1) base packages
if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  apt-get install -y python3 python3-venv python3-pip nginx certbot python3-certbot-nginx ffmpeg
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y python3 python3-venv python3-pip nginx certbot python3-certbot-nginx ffmpeg || true
elif command -v yum >/dev/null 2>&1; then
  yum install -y python3 python3-venv python3-pip nginx certbot python3-certbot-nginx ffmpeg || true
else
  echo "install python3 + nginx + certbot + ffmpeg manually"
fi

# 2) dirs
mkdir -p "$APP_DIR" "$APP_DIR/templates" "$APP_DIR/static" "$DOWNLOAD_DIR"
chown -R "$RUN_USER":"$RUN_USER" "$DOWNLOAD_DIR" || true

# 3) venv
if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install flask python-dotenv yt-dlp werkzeug

# 4) app.py
cat > "$APP_DIR/app.py" <<'PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ytweb - tiny web ui for yt-dlp
version: v1.0-2025-11-05

- explicit yt-dlp path via env YTDLP_BIN
- youtube url normalization
- 8h cleanup
- progress returns relative download_url to avoid mixed content
- ProxyFix + PREFERRED_URL_SCHEME=https
"""
import os
import uuid
import subprocess
import threading
import time
import re
from datetime import datetime, timedelta, timezone
from urllib.parse import urlparse, parse_qs
from flask import Flask, request, render_template, send_from_directory, abort, url_for, jsonify
from werkzeug.middleware.proxy_fix import ProxyFix

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DOWNLOAD_DIR = os.environ.get("YTWEB_DOWNLOAD_DIR", "/var/www/yt-downloads")
os.makedirs(DOWNLOAD_DIR, exist_ok=True)

YTDLP_BIN = os.environ.get("YTDLP_BIN", os.path.join(BASE_DIR, "venv", "bin", "yt-dlp"))
if not os.path.isfile(YTDLP_BIN):
    YTDLP_BIN = "/opt/ytweb/venv/bin/yt-dlp"

app = Flask(__name__, template_folder=os.path.join(BASE_DIR, "templates"), static_folder=os.path.join(BASE_DIR, "static"))
app.wsgi_app = ProxyFix(app.wsgi_app, x_proto=1, x_host=1)
app.config["PREFERRED_URL_SCHEME"] = "https"

TASKS = {}
LOCK = threading.Lock()
EXPIRE_HOURS = 8

PROG_RE = re.compile(r"(\d+(?:\.\d+)?)%")

def now_utc():
    return datetime.now(timezone.utc)

def normalize_youtube_url(u: str) -> str:
    try:
        parsed = urlparse(u)
    except Exception:
        return u
    host = (parsed.netloc or "").lower()
    path = parsed.path or ""
    qs = parse_qs(parsed.query or "")
    if host in ("youtu.be", "www.youtu.be"):
        vid = path.lstrip("/")
        if vid:
            return f"https://www.youtube.com/watch?v={vid}"
    if host in ("m.youtube.com", "music.youtube.com", "youtube.com"):
        host = "www.youtube.com"
    if "youtube.com" in host and path.startswith("/shorts/"):
        vid = path.split("/shorts/")[1].split("/")[0]
        if vid:
            return f"https://www.youtube.com/watch?v={vid}"
    if "youtube.com" in host and path.startswith("/live/"):
        vid = path.split("/live/")[1].split("/")[0]
        if vid:
            return f"https://www.youtube.com/watch?v={vid}"
    if "youtube.com" in host and path.startswith("/watch"):
        vid = qs.get("v", [""])[0]
        if vid:
            return f"https://www.youtube.com/watch?v={vid}"
    return u

def normalize_url(u: str) -> str:
    if "youtu" in u or "youtube.com" in u:
        return normalize_youtube_url(u)
    return u

def run_ytdlp_task(task_id: str, url: str, fmt: str):
    with LOCK:
        task = TASKS.get(task_id)
    if not task:
        return
    task_dir = task["dir"]
    output_tpl = os.path.join(task_dir, "%(title)s-%(id)s.%(ext)s")
    cmd = [
        YTDLP_BIN,
        "--newline",
        "-f", fmt,
        "-o", output_tpl,
        url,
    ]
    logs = [f"cmd: {' '.join(cmd)}"]
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            universal_newlines=True
        )
    except FileNotFoundError:
        with LOCK:
            TASKS[task_id]["status"] = "error"
            TASKS[task_id]["logs"] = "\n".join(logs + ["ERROR: yt-dlp not found at " + YTDLP_BIN])
        return

    filename = None
    for line in proc.stdout:
        line = line.rstrip("\n")
        logs.append(line)
        m = PROG_RE.search(line)
        if m:
            try:
                pct = float(m.group(1))
            except ValueError:
                pct = 0.0
            with LOCK:
                TASKS[task_id]["progress"] = pct
        with LOCK:
            TASKS[task_id]["logs"] = "\n".join(logs)
    proc.wait()
    files = os.listdir(task_dir)
    if files:
        filename = files[0]
    with LOCK:
        TASKS[task_id]["status"] = "done" if proc.returncode == 0 and filename else "error"
        TASKS[task_id]["filename"] = filename
        TASKS[task_id]["logs"] = "\n".join(logs)

def cleanup_worker():
    while True:
        now = now_utc()
        to_delete = []
        with LOCK:
            for tid, info in list(TASKS.items()):
                if info.get("expires_at") and now > info["expires_at"]:
                    to_delete.append(tid)
        for tid in to_delete:
            task_dir = os.path.join(DOWNLOAD_DIR, tid)
            if os.path.isdir(task_dir):
                for root, dirs, files in os.walk(task_dir, topdown=False):
                    for f in files:
                        try:
                            os.remove(os.path.join(root, f))
                        except OSError:
                            pass
                    for d in dirs:
                        try:
                            os.rmdir(os.path.join(root, d))
                        except OSError:
                            pass
                try:
                    os.rmdir(task_dir)
                except OSError:
                    pass
            with LOCK:
                TASKS.pop(tid, None)
        time.sleep(600)

@app.route("/", methods=["GET"])
def index():
    return render_template("index.html")

@app.route("/download", methods=["POST"])
def download():
    raw_url = request.form.get("url", "").strip()
    url = normalize_url(raw_url)
    fmt = request.form.get("format", "best").strip() or "best"
    custom_fmt = request.form.get("custom_format", "").strip()
    if custom_fmt:
        fmt = custom_fmt
    if not url:
        return render_template("index.html", error="URL is required.")
    task_id = str(uuid.uuid4())
    task_dir = os.path.join(DOWNLOAD_DIR, task_id)
    os.makedirs(task_dir, exist_ok=True)
    expires_at = now_utc() + timedelta(hours=EXPIRE_HOURS)
    with LOCK:
        TASKS[task_id] = {
            "id": task_id,
            "url": url,
            "raw_url": raw_url,
            "format": fmt,
            "dir": task_dir,
            "status": "running",
            "progress": 0.0,
            "logs": "",
            "filename": None,
            "created_at": now_utc(),
            "expires_at": expires_at,
        }
    t = threading.Thread(target=run_ytdlp_task, args=(task_id, url, fmt), daemon=True)
    t.start()
    return render_template("index.html", started=True, task_id=task_id, expires_at=expires_at.isoformat(), normalized_url=url)

@app.route("/progress/<task_id>", methods=["GET"])
def progress(task_id):
    with LOCK:
        task = TASKS.get(task_id)
    if not task:
        return jsonify({"error": "not found"}), 404
    data = {
        "status": task["status"],
        "progress": task["progress"],
        "logs": task["logs"],
        "task_id": task["id"],
        "url": task.get("url"),
        "expires_at": task["expires_at"].isoformat() if task.get("expires_at") else None,
    }
    if task["status"] == "done" and task["filename"]:
        data["download_url"] = url_for("get_file", task_id=task_id, filename=task["filename"], _external=False)
        data["filename"] = task["filename"]
    return jsonify(data)

@app.route("/files/<task_id>/<path:filename>", methods=["GET"])
def get_file(task_id, filename):
    task_dir = os.path.join(DOWNLOAD_DIR, task_id)
    if not os.path.isdir(task_dir):
        abort(404)
    return send_from_directory(task_dir, filename, as_attachment=True)

if __name__ == "__main__":
    cleaner = threading.Thread(target=cleanup_worker, daemon=True)
    cleaner.start()
    app.run(host="127.0.0.1", port=5001, debug=False)
PY

# 5) mobile-friendly template
cat > "$APP_DIR/templates/index.html" <<'HTML'
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <title>yt-dlp web · bdfz</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    :root {
      --gap: 1rem;
      --radius: 6px;
      --primary: #0d6efd;
      --bg-soft: #e8fff1;
    }
    body {
      max-width: 720px;
      margin: 0 auto;
      padding: 1rem 1rem 3rem;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      line-height: 1.5;
      background: #fff;
    }
    h1 {
      margin-top: 0.5rem;
      margin-bottom: 1rem;
      font-size: 1.6rem;
    }
    .top-note {
      background: #f3f4f6;
      border: 1px solid #e5e7eb;
      border-radius: 9999px;
      padding: 0.35rem 0.9rem;
      font-size: 0.78rem;
      margin-bottom: 1rem;
      display: inline-block;
    }
    input, select, button, textarea {
      width: 100%;
      padding: 0.6rem 0.55rem;
      margin-bottom: 0.8rem;
      border: 1px solid #d1d5db;
      border-radius: var(--radius);
      font-size: 1rem;
      box-sizing: border-box;
    }
    button {
      background: #4b5563;
      color: #fff;
      border: none;
      cursor: pointer;
      font-weight: 600;
    }
    button:hover {
      background: #374151;
    }
    .log-wrap {
      margin-top: 0.5rem;
    }
    .log {
      white-space: pre-wrap;
      background: #f6f6f6;
      padding: 0.75rem;
      border: 1px solid #ddd;
      border-radius: var(--radius);
      max-height: 220px;
      overflow-y: auto;
      font-size: 0.8rem;
    }
    .log.is-collapsed {
      max-height: 0;
      padding: 0;
      border-width: 0;
      overflow: hidden;
    }
    .ok {
      background: var(--bg-soft);
      padding: 1rem;
      border: 1px solid #bde5c8;
      border-radius: var(--radius);
      margin-bottom: 1rem;
    }
    .err {
      background: #ffe8e8;
      padding: 1rem;
      border: 1px solid #f5c2c2;
      border-radius: var(--radius);
      margin-bottom: 1rem;
    }
    a.btn {
      display: inline-block;
      background: var(--primary);
      color: #fff;
      padding: 0.6rem 0.75rem;
      text-decoration: none;
      border-radius: var(--radius);
      font-weight: 600;
      width: 100%;
      text-align: center;
      box-sizing: border-box;
    }
    .progress-bar {
      width: 100%;
      background: #e5e7eb;
      height: 12px;
      border-radius: 9999px;
      overflow: hidden;
      margin-bottom: 0.5rem;
    }
    .progress-bar-inner {
      height: 100%;
      background: var(--primary);
      width: 0%;
      transition: width .3s ease;
    }
    @media (min-width: 720px) {
      body { padding-top: 2rem; }
      a.btn { width: auto; }
      .log.is-collapsed { max-height: 220px; padding: 0.75rem; border-width: 1px; }
    }
  </style>
</head>
<body>
  <div class="top-note">檔案會在 8 小時後自動刪除</div>
  <h1>yt-dlp web</h1>
  <p style="margin-top:-0.4rem;">貼你要下的影片 / 音訊 / 社交平台鏈接。基於 yt-dlp，能下的都會試。</p>
  <form method="post" action="/download">
    <label for="url" style="font-weight:600;font-size:0.85rem;">URL</label>
    <input type="url" id="url" name="url" required placeholder="https://www.youtube.com/watch?v=... / https://youtu.be/... / https://www.bilibili.com/...">
    <label for="format" style="font-weight:600;font-size:0.85rem;">常用格式 (yt-dlp -f)</label>
    <select id="format" name="format">
      <option value="best" selected>best (影片最佳)</option>
      <option value="bestaudio">bestaudio (最佳音訊)</option>
      <option value="bestvideo+bestaudio/best">bestvideo+bestaudio/best</option>
      <option value="worst">worst</option>
    </select>
    <label for="custom_format" style="font-weight:600;font-size:0.85rem;">自定義格式 (可選)</label>
    <input type="text" id="custom_format" name="custom_format" placeholder="例如：bv[ext=mp4]+ba/best">
    <button type="submit">開始下載</button>
  </form>

  {% if error %}
    <div class="err">{{ error }}</div>
  {% endif %}

  {% if started %}
    <div id="status-box" class="ok">
      <p style="margin-top:0;">任務已建立，正在下載中…（幾秒後進度才會跳）</p>
      <p style="margin-bottom:0.2rem;">任務ID：<code id="task-id">{{ task_id }}</code></p>
      {% if normalized_url %}
      <p style="margin-bottom:0.2rem;">已規整鏈接：<code>{{ normalized_url }}</code></p>
      {% endif %}
      {% if expires_at %}
      <p style="margin-bottom:0;">將在 <strong id="expire-time">{{ expires_at }}</strong> 之後刪除。</p>
      {% endif %}
    </div>
    <div class="progress-bar">
      <div id="pb" class="progress-bar-inner"></div>
    </div>
    <div class="log-wrap">
      <div id="logs" class="log is-collapsed"></div>
    </div>
  {% endif %}

  <script>
  (function() {
    const taskIdEl = document.getElementById('task-id');
    if (!taskIdEl) return;
    const taskId = taskIdEl.textContent.trim();
    const pb = document.getElementById('pb');
    const logsEl = document.getElementById('logs');
    const statusBox = document.getElementById('status-box');

    function expandLog() {
      if (logsEl) logsEl.classList.remove('is-collapsed');
    }

    function poll() {
      fetch('/progress/' + taskId)
        .then(r => r.json())
        .then(data => {
          if (data.progress !== undefined && pb) {
            pb.style.width = data.progress + '%';
          }
          if (data.logs && logsEl) {
            logsEl.textContent = data.logs;
            logsEl.scrollTop = logsEl.scrollHeight;
          }
          if (data.expires_at) {
            const et = document.getElementById('expire-time');
            if (et) et.textContent = data.expires_at;
          }
          if (data.status === 'done' && data.download_url) {
            expandLog();
            statusBox.innerHTML = '<p>下載完成：</p><p><a class="btn" href="' + data.download_url + '">點此下載 ' + (data.filename || '') + '</a></p><p>檔案將在 8 小時後刪除。</p>';
          } else if (data.status === 'error') {
            expandLog();
            statusBox.innerHTML = '<p>下載失敗，下面是日誌。</p>';
          } else {
            setTimeout(poll, 2000);
          }
        })
        .catch(() => {
          setTimeout(poll, 3000);
        });
    }
    poll();
  })();
  </script>
</body>
</html>
HTML

# 6) systemd
cat > /etc/systemd/system/"$SERVICE_NAME" <<SERVICE
[Unit]
Description=yt-dlp web frontend (Flask)
After=network.target

[Service]
User=$RUN_USER
Group=$RUN_USER
WorkingDirectory=$APP_DIR
Environment=YTWEB_DOWNLOAD_DIR=$DOWNLOAD_DIR
Environment=YTDLP_BIN=$YTDLP_BIN
ExecStart=$VENV_DIR/bin/python $APP_DIR/app.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

# 7) nginx
cat > /etc/nginx/sites-available/ytweb.conf <<NG
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:5001;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
NG

ln -sf /etc/nginx/sites-available/ytweb.conf /etc/nginx/sites-enabled/ytweb.conf
nginx -t && systemctl reload nginx

# 8) https
if command -v certbot >/dev/null 2>&1; then
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email || true
fi

echo "[ytweb] install done. open: https://$DOMAIN/"