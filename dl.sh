#!/usr/bin/env bash
# dl.sh - ytweb with progress, HTTPS, 8h auto-clean
# version: v0.2.0-2025-11-05
# features:
# - install/update /opt/ytweb
# - Flask backend (progress API)
# - 8h auto cleanup (in-app thread)
# - nginx + certbot for xz.bdfz.net
# - kill old processes / overwrite previous install

set -euo pipefail

DOMAIN="xz.bdfz.net"
APP_DIR="/opt/ytweb"
VENV_DIR="$APP_DIR/venv"
RUN_USER="www-data"
DOWNLOAD_DIR="/var/www/yt-downloads"
SERVICE_NAME="ytweb.service"

echo "[ytweb] installing version v0.2.0-2025-11-05 ..."

# 0) kill old processes / stop old service
if systemctl list-units --full -all | grep -q "$SERVICE_NAME"; then
  systemctl stop "$SERVICE_NAME" || true
fi
# 如果有人直接跑過 python /opt/ytweb/app.py，把它殺掉
pkill -f "$APP_DIR/app.py" 2>/dev/null || true

# 1) install base packages
if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  apt-get install -y python3 python3-venv python3-pip nginx certbot python3-certbot-nginx
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y python3 python3-venv python3-pip nginx certbot python3-certbot-nginx || true
elif command -v yum >/dev/null 2>&1; then
  yum install -y python3 python3-venv python3-pip nginx certbot python3-certbot-nginx || true
else
  echo "No supported package manager found. Please install python3, nginx, certbot manually."
fi

# 2) directories
mkdir -p "$APP_DIR"
mkdir -p "$APP_DIR/templates"
mkdir -p "$APP_DIR/static"
mkdir -p "$DOWNLOAD_DIR"
chown -R "$RUN_USER":"$RUN_USER" "$DOWNLOAD_DIR" || true

# 3) venv
if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install flask python-dotenv yt-dlp

# 4) write app.py (FULL)
cat > "$APP_DIR/app.py" <<'PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ytweb - tiny web ui for yt-dlp
version: v0.2.0-2025-11-05

changes:
- async download with progress
- /progress/<task_id> endpoint
- 8h auto-delete worker
- show expire time in frontend
"""
import os
import uuid
import subprocess
import threading
import time
import re
from datetime import datetime, timedelta, timezone
from flask import Flask, request, render_template, send_from_directory, abort, url_for, jsonify

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DOWNLOAD_DIR = os.environ.get("YTWEB_DOWNLOAD_DIR", "/var/www/yt-downloads")
os.makedirs(DOWNLOAD_DIR, exist_ok=True)

app = Flask(__name__, template_folder=os.path.join(BASE_DIR, "templates"), static_folder=os.path.join(BASE_DIR, "static"))

# task store: {task_id: {...}}
TASKS = {}
LOCK = threading.Lock()
EXPIRE_HOURS = 8

# regex for yt-dlp progress line
PROG_RE = re.compile(r'\[download\]\s+(\d{1,3}\.\d+)%')

def now_utc():
    return datetime.now(timezone.utc)

def run_ytdlp_task(task_id: str, url: str, fmt: str):
    with LOCK:
        task = TASKS.get(task_id)
    if not task:
        return
    task_dir = task["dir"]
    output_tpl = os.path.join(task_dir, "%(title)s-%(id)s.%(ext)s")
    cmd = [
        "yt-dlp",
        "-f", fmt,
        "-o", output_tpl,
        url,
    ]
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        universal_newlines=True
    )
    logs = []
    filename = None
    for line in proc.stdout:
        line = line.rstrip("\n")
        logs.append(line)
        m = PROG_RE.search(line)
        if m:
            pct = float(m.group(1))
            with LOCK:
                TASKS[task_id]["progress"] = pct
        with LOCK:
            TASKS[task_id]["logs"] = "\n".join(logs)
    proc.wait()
    # list files to find the created one
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
            # delete files
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
        time.sleep(600)  # every 10 minutes

@app.route("/", methods=["GET"])
def index():
    return render_template("index.html")

@app.route("/download", methods=["POST"])
def download():
    url = request.form.get("url", "").strip()
    fmt = request.form.get("format", "best").strip() or "best"
    # allow custom format
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
    # return page that polls progress
    return render_template(
        "index.html",
        started=True,
        task_id=task_id,
        expires_at=expires_at.isoformat()
    )

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
        "expires_at": task["expires_at"].isoformat() if task.get("expires_at") else None,
    }
    if task["status"] == "done" and task["filename"]:
        data["download_url"] = url_for("get_file", task_id=task_id, filename=task["filename"], _external=True)
        data["filename"] = task["filename"]
    return jsonify(data)

@app.route("/files/<task_id>/<path:filename>", methods=["GET"])
def get_file(task_id, filename):
    task_dir = os.path.join(DOWNLOAD_DIR, task_id)
    if not os.path.isdir(task_dir):
        abort(404)
    return send_from_directory(task_dir, filename, as_attachment=True)

@app.route("/tasks/<task_id>", methods=["GET"])
def task_info(task_id):
    with LOCK:
        task = TASKS.get(task_id)
    if not task:
        abort(404)
    files = []
    if os.path.isdir(task["dir"]):
        files = os.listdir(task["dir"])
    return jsonify({
        "task_id": task_id,
        "files": files,
        "status": task["status"],
        "progress": task["progress"],
    })

if __name__ == "__main__":
    # start cleanup worker
    cleaner = threading.Thread(target=cleanup_worker, daemon=True)
    cleaner.start()
    app.run(host="127.0.0.1", port=5001, debug=False)
PY

# 5) template with progress + formats + expire time
cat > "$APP_DIR/templates/index.html" <<'HTML'
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <title>yt-dlp web · bdfz</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body { max-width: 720px; margin: 2rem auto; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    input, select, button, textarea { width: 100%; padding: 0.5rem; margin-bottom: 1rem; }
    .log { white-space: pre-wrap; background: #f6f6f6; padding: 1rem; border: 1px solid #ddd; max-height: 260px; overflow-y: auto; }
    .ok { background: #e8fff1; padding: 1rem; border: 1px solid #bde5c8; margin-bottom: 1rem; }
    .err { background: #ffe8e8; padding: 1rem; border: 1px solid #f5c2c2; margin-bottom: 1rem; }
    a.btn { display: inline-block; background: #0d6efd; color: #fff; padding: 0.5rem 1rem; text-decoration: none; border-radius: 4px; }
    .progress-bar { width: 100%; background: #ddd; height: 10px; border-radius: 5px; overflow: hidden; margin-bottom: 1rem; }
    .progress-bar-inner { height: 10px; background: #0d6efd; width: 0%; transition: width .3s ease; }
    small { color: #666; }
  </style>
</head>
<body>
  <h1>yt-dlp web</h1>
  <p>輸入影片 / 音訊鏈接，服務端下載。檔案會在 <strong>8 小時</strong> 後自動刪除。</p>
  <form method="post" action="/download">
    <label for="url">URL</label>
    <input type="url" id="url" name="url" required placeholder="https://www.youtube.com/watch?v=...">
    <label for="format">常用格式 (yt-dlp -f)</label>
    <select id="format" name="format">
      <option value="best" selected>best (影片最佳)</option>
      <option value="bestaudio">bestaudio (最佳音訊)</option>
      <option value="worst">worst</option>
      <option value="bestvideo+bestaudio/best">bestvideo+bestaudio/best</option>
    </select>
    <label for="custom_format">自定義格式 (可選)</label>
    <input type="text" id="custom_format" name="custom_format" placeholder="例如：bv[ext=mp4]+ba/best">
    <button type="submit">開始下載</button>
  </form>

  {% if error %}
    <div class="err">{{ error }}</div>
  {% endif %}

  {% if started %}
    <div id="status-box" class="ok">
      <p>任務已建立，正在下載中…</p>
      <p>任務ID：<code id="task-id">{{ task_id }}</code></p>
      {% if expires_at %}
      <p>將在 <strong id="expire-time">{{ expires_at }}</strong> 之後刪除。</p>
      {% endif %}
    </div>
    <div class="progress-bar">
      <div id="pb" class="progress-bar-inner"></div>
    </div>
    <div id="logs" class="log"></div>
  {% endif %}

  <script>
  (function() {
    const taskIdEl = document.getElementById('task-id');
    if (!taskIdEl) return;
    const taskId = taskIdEl.textContent.trim();
    const pb = document.getElementById('pb');
    const logsEl = document.getElementById('logs');
    const statusBox = document.getElementById('status-box');

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
            statusBox.innerHTML = '<p>下載完成：</p><p><a class="btn" href="' + data.download_url + '">點此下載 ' + (data.filename || '') + '</a></p><p>檔案將在 8 小時後刪除。</p>';
          } else if (data.status === 'error') {
            statusBox.innerHTML = '<p>下載失敗，查看下方日誌。</p>';
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

# 6) systemd service
cat > /etc/systemd/system/"$SERVICE_NAME" <<SERVICE
[Unit]
Description=yt-dlp web frontend (Flask)
After=network.target

[Service]
User=$RUN_USER
Group=$RUN_USER
WorkingDirectory=$APP_DIR
Environment=YTWEB_DOWNLOAD_DIR=$DOWNLOAD_DIR
ExecStart=$VENV_DIR/bin/python $APP_DIR/app.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

# 7) nginx http -> flask
cat > /etc/nginx/sites-available/ytweb.conf <<NG
server {
    listen 80;
    server_name $DOMAIN;

    # certbot will use this
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:5001;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NG

ln -sf /etc/nginx/sites-available/ytweb.conf /etc/nginx/sites-enabled/ytweb.conf
nginx -t && systemctl reload nginx

# 8) HTTPS with certbot (auto renew)
if command -v certbot >/dev/null 2>&1; then
  # --register-unsafely-without-email 是為了自動化，之後你要可以自己加 email
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email || true
  # certbot 會自己裝 cron/systemd timer
fi

echo "[ytweb] install done. open: https://$DOMAIN/"