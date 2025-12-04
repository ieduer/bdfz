#!/usr/bin/env bash
# dl.sh - ytweb with progress, HTTPS, 8h auto-clean, Telegram notify
# version: v1.5-2025-12-03
# changes from v1.4-2025-12-03:
# - 移除所有硬編碼的 Telegram token / chat_id
# - systemd 使用 EnvironmentFile=-/etc/ytweb.env 注入 TG_BOT_TOKEN / TG_CHAT_ID
# - 安裝腳本首次安裝時生成 /etc/ytweb.env 模板（不含任何真實祕鑰）
# domain: xz.bdfz.net

set -euo pipefail

trap 'echo "[ytweb] ERROR on line $LINENO" >&2' ERR

DOMAIN="xz.bdfz.net"
APP_DIR="/opt/ytweb"
VENV_DIR="$APP_DIR/venv"
RUN_USER="www-data"
DOWNLOAD_DIR="/var/www/yt-downloads"
SERVICE_NAME="ytweb.service"
YTDLP_BIN="$VENV_DIR/bin/yt-dlp"

echo "[ytweb] installing version v1.5-2025-12-03 ..."

# 必須 root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[ytweb] please run as root, e.g.: sudo bash dl.sh" >&2
  exit 1
fi

# 依賴 systemd
if ! command -v systemctl >/dev/null 2>&1; then
  echo "[ytweb] systemctl not found. This installer assumes a systemd-based Linux." >&2
  exit 1
fi

# 0) stop old service/process
if systemctl list-units --full -all | grep -q "$SERVICE_NAME"; then
  echo "[ytweb] stopping old systemd service $SERVICE_NAME ..."
  systemctl stop "$SERVICE_NAME" || true
fi
echo "[ytweb] killing possible old app.py processes ..."
pkill -f "$APP_DIR/app.py" 2>/dev/null || true

# 1) base packages
PYTHON_BIN="python3"
echo "[ytweb] installing base packages (python3, venv, pip, nginx, certbot, ffmpeg, curl) ..."
if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  apt-get install -y python3 python3-venv python3-pip nginx certbot python3-certbot-nginx ffmpeg curl
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y python3 python3-venv python3-pip nginx certbot python3-certbot-nginx ffmpeg curl || true
elif command -v yum >/dev/null 2>&1; then
  yum install -y python3 python3-venv python3-pip nginx certbot python3-certbot-nginx ffmpeg curl || true
else
  echo "[ytweb] could not detect apt/dnf/yum. Please install python3 + nginx + certbot + ffmpeg + curl manually." >&2
fi

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "[ytweb] python3 not found after package installation. Abort." >&2
  exit 1
fi

# 2) dirs
echo "[ytweb] preparing directories ..."
mkdir -p "$APP_DIR" "$APP_DIR/templates" "$APP_DIR/static" "$DOWNLOAD_DIR" /var/www/html
chown -R "$RUN_USER":"$RUN_USER" "$DOWNLOAD_DIR" || true

# 3) venv
if [ ! -d "$VENV_DIR" ]; then
  echo "[ytweb] creating virtualenv at $VENV_DIR ..."
  "$PYTHON_BIN" -m venv "$VENV_DIR"
else
  echo "[ytweb] using existing virtualenv at $VENV_DIR ..."
fi

if [ ! -x "$VENV_DIR/bin/python" ]; then
  echo "[ytweb] virtualenv seems broken (no bin/python). Recreating ..." >&2
  rm -rf "$VENV_DIR"
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

V_PY="$VENV_DIR/bin/python"

echo "[ytweb] upgrading pip and installing/refreshing dependencies (flask, dotenv, yt-dlp, werkzeug, requests) ..."
"$V_PY" -m pip install --upgrade pip
"$V_PY" -m pip install --upgrade flask python-dotenv yt-dlp werkzeug requests

# 更新後的 yt-dlp 路徑 & 版本
YTDLP_BIN="$VENV_DIR/bin/yt-dlp"
YTDLP_VERSION="$("$YTDLP_BIN" --version 2>/dev/null || echo "unknown")"
echo "[ytweb] yt-dlp version: $YTDLP_VERSION (path: $YTDLP_BIN)"

# 4) app.py
cat > "$APP_DIR/app.py" <<'PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ytweb - tiny web ui for yt-dlp
version: v1.4-2025-12-03

- explicit yt-dlp path via env YTDLP_BIN
- youtube url normalization (watch/shorts/live/youtu.be)
- 8h cleanup
- progress returns relative download_url to avoid mixed content
- ProxyFix + PREFERRED_URL_SCHEME=https
- auto 模式：不傳 -f，讓 yt-dlp 自行選擇 bestvideo+bestaudio
- 限制檔名長度，避免 Errno 36
- 下載完成後透過 Telegram 發送通知（由環境變量注入 TG_BOT_TOKEN / TG_CHAT_ID）
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

try:
  import requests  # type: ignore
except Exception:  # pragma: no cover
  requests = None

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DOWNLOAD_DIR = os.environ.get("YTWEB_DOWNLOAD_DIR", "/var/www/yt-downloads")
os.makedirs(DOWNLOAD_DIR, exist_ok=True)

YTDLP_BIN = os.environ.get("YTDLP_BIN", os.path.join(BASE_DIR, "venv", "bin", "yt-dlp"))
if not os.path.isfile(YTDLP_BIN):
  # fallback
  YTDLP_BIN = "/opt/ytweb/venv/bin/yt-dlp"

YTWEB_DOMAIN = os.environ.get("YTWEB_DOMAIN", "")
TG_BOT_TOKEN = os.environ.get("TG_BOT_TOKEN", "")
TG_CHAT_ID = os.environ.get("TG_CHAT_ID", "")

BEIJING_TZ = timezone(timedelta(hours=8))

app = Flask(
  __name__,
  template_folder=os.path.join(BASE_DIR, "templates"),
  static_folder=os.path.join(BASE_DIR, "static"),
)
# behind nginx; x_for=1 以獲取真實客戶端 IP
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)
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
  # youtu.be/ID
  if host in ("youtu.be", "www.youtu.be"):
    vid = path.lstrip("/")
    if vid:
      return f"https://www.youtube.com/watch?v={vid}"
  # m., music.
  if host in ("m.youtube.com", "music.youtube.com", "youtube.com"):
    host = "www.youtube.com"
  # shorts
  if "youtube.com" in host and path.startswith("/shorts/"):
    vid = path.split("/shorts/")[1].split("/")[0]
    if vid:
      return f"https://www.youtube.com/watch?v={vid}"
  # live
  if "youtube.com" in host and path.startswith("/live/"):
    vid = path.split("/live/")[1].split("/")[0]
    if vid:
      return f"https://www.youtube.com/watch?v={vid}"
  # watch?v=
  if "youtube.com" in host and path.startswith("/watch"):
    vid = qs.get("v", [""])[0]
    if vid:
      return f"https://www.youtube.com/watch?v={vid}"
  return u


def normalize_url(u: str) -> str:
  if "youtu" in u or "youtube.com" in u:
    return normalize_youtube_url(u)
  return u


def send_telegram_notification(task: dict, filename: str, download_path: str) -> None:
  """下載完成後的通知。

  push: 用戶 IP、北京時間、原始鏈接、解析後鏈接、文件名、下載鏈接
  """
  if not TG_BOT_TOKEN or not TG_CHAT_ID or not requests:
    return

  ip = task.get("client_ip") or "-"
  raw_url = task.get("raw_url") or ""
  norm_url = task.get("url") or ""

  now_bj = datetime.now(BEIJING_TZ).strftime("%Y-%m-%d %H:%M:%S")

  if YTWEB_DOMAIN and download_path.startswith("/"):
    full_url = f"https://{YTWEB_DOMAIN}{download_path}"
  else:
    full_url = download_path

  text_lines = [
    "ytweb 下載完成",
    f"IP: {ip}",
    f"北京時間: {now_bj}",
    f"原始鏈接: {raw_url}",
    f"解析後: {norm_url}",
    f"文件: {filename}",
    f"下載鏈接: {full_url}",
  ]
  text = "\n".join(text_lines)

  try:
    requests.post(
      f"https://api.telegram.org/bot{TG_BOT_TOKEN}/sendMessage",
      data={
        "chat_id": TG_CHAT_ID,
        "text": text,
      },
      timeout=5,
    )
  except Exception:
    # 失敗時靜默忽略，避免影響下載
    pass


def run_ytdlp_task(task_id, url, fmt):
  """執行 yt-dlp 下載任務。

  如果 fmt 為 None，則不傳 -f，讓 yt-dlp 使用預設策略（bestvideo+bestaudio）。
  限制檔名長度，避免 Errno 36。
  """
  with LOCK:
    task = TASKS.get(task_id)
  if not task:
    return

  task_dir = task["dir"]
  # 限制 title 最長 60 字元，避免檔名過長；同時搭配 --trim-filenames
  output_tpl = os.path.join(task_dir, "%(title).60s-%(id)s.%(ext)s")

  cmd = [
    YTDLP_BIN,
    "--newline",
    "--trim-filenames",
    "80",
  ]
  if fmt:
    cmd += ["-f", fmt]
  cmd += [
    "-o",
    output_tpl,
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
      universal_newlines=True,
    )
  except FileNotFoundError:
    with LOCK:
      if task_id in TASKS:
        TASKS[task_id]["status"] = "error"
        TASKS[task_id]["logs"] = "\n".join(
          logs + ["ERROR: yt-dlp not found at " + YTDLP_BIN]
        )
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
        if task_id in TASKS:
          TASKS[task_id]["progress"] = pct
    with LOCK:
      if task_id in TASKS:
        TASKS[task_id]["logs"] = "\n".join(logs)

  proc.wait()

  # 選擇最終文件：排除 .part / .ytdl / 臨時文件，取最大的那個
  try:
    candidates = []
    for f in os.listdir(task_dir):
      if any(f.endswith(suf) for suf in (".part", ".ytdl", ".tmp")):
        continue
      full = os.path.join(task_dir, f)
      if os.path.isfile(full):
        try:
          size = os.path.getsize(full)
        except OSError:
          size = 0
        candidates.append((size, f))
    if candidates:
      candidates.sort(reverse=True)
      filename = candidates[0][1]
  except OSError:
    filename = None

  with LOCK:
    task = TASKS.get(task_id)
    if not task:
      return
    task["status"] = "done" if proc.returncode == 0 and filename else "error"
    task["filename"] = filename
    task["logs"] = "\n".join(logs)
    status = task["status"]
    task_snapshot = dict(task)

  if status == "done" and filename:
    download_path = f"/files/{task_id}/{filename}"
    try:
      send_telegram_notification(task_snapshot, filename, download_path)
    except Exception:
      pass


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
  # 下拉框的 value："" 代表 auto，不傳 -f
  fmt = request.form.get("format", "").strip()
  custom_fmt = request.form.get("custom_format", "").strip()
  if custom_fmt:
    fmt = custom_fmt
  fmt_for_worker = fmt if fmt else None  # None => auto
  if not url:
    return render_template("index.html", error="URL is required.")

  # 取得客戶端 IP（優先 X-Forwarded-For 第一個）
  xff = request.headers.get("X-Forwarded-For", "").split(",")[0].strip()
  client_ip = xff or (request.remote_addr or "")

  task_id = str(uuid.uuid4())
  task_dir = os.path.join(DOWNLOAD_DIR, task_id)
  os.makedirs(task_dir, exist_ok=True)
  expires_at = now_utc() + timedelta(hours=EXPIRE_HOURS)

  with LOCK:
    TASKS[task_id] = {
      "id": task_id,
      "url": url,
      "raw_url": raw_url,
      "format": fmt or "auto",
      "dir": task_dir,
      "status": "running",
      "progress": 0.0,
      "logs": "",
      "filename": None,
      "created_at": now_utc(),
      "expires_at": expires_at,
      "client_ip": client_ip,
    }

  t = threading.Thread(
    target=run_ytdlp_task,
    args=(task_id, url, fmt_for_worker),
    daemon=True,
  )
  t.start()

  return render_template(
    "index.html",
    started=True,
    task_id=task_id,
    expires_at=expires_at.isoformat(),
    normalized_url=url,
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
    "url": task.get("url"),
    "expires_at": task["expires_at"].isoformat()
    if task.get("expires_at")
    else None,
  }
  if task["status"] == "done" and task["filename"]:
    data["download_url"] = url_for(
      "get_file",
      task_id=task_id,
      filename=task["filename"],
      _external=False,
    )
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
  <!-- Favicon / Icons (WEBP, cache-busted) -->
  <link rel="icon" href="https://img.bdfz.net/20250503004.webp?v=20251122" type="image/webp">
  <link rel="shortcut icon" href="https://img.bdfz.net/20250503004.webp?v=20251122" type="image/webp">
  <link rel="apple-touch-icon" href="https://img.bdfz.net/20250503004.webp?v=20251122">
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
  <form method="post" action="/download">
    <label for="url" style="font-weight:600;font-size:0.85rem;">URL</label>
    <input type="url" id="url" name="url" required placeholder="https://www.youtube.com/watch?v=... / https://youtu.be/... / https://www.bilibili.com/...">
    <label for="format" style="font-weight:600;font-size:0.85rem;">常用格式 (yt-dlp -f)</label>
    <select id="format" name="format">
      <option value="" selected>auto (推薦：自動 bestvideo+bestaudio)</option>
      <option value="best">best (單文件，可能不是最佳)</option>
      <option value="bestaudio">bestaudio (最佳音訊)</option>
      <option value="bestvideo+bestaudio/best">bestvideo+bestaudio/best</option>
      <option value="worst">worst</option>
    </select>
    <label for="custom_format" style="font-weight:600;font-size:0.85rem;">自定義格式 (可選)</label>
    <input type="text" id="custom_format" name="custom_format" placeholder="例如：bv[ext=mp4]+ba/best">
    <p style="font-size:0.78rem;color:#6b7280;margin-top:-0.35rem;">進階示例：<code>bv[ext=mp4]+ba/best</code>（優先 MP4）、<code>bv[height&lt;=720]+ba/best</code>（最高 720p）。更多語法可參考 yt-dlp 文檔。</p>
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

# 6) systemd (Restart=always, secrets via /etc/ytweb.env)
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
Environment=YTWEB_DOMAIN=$DOMAIN
# optional env file (for secrets like TG_BOT_TOKEN / TG_CHAT_ID)
EnvironmentFile=-/etc/ytweb.env
ExecStart=$VENV_DIR/bin/python $APP_DIR/app.py
Restart=always
RestartSec=3
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
SERVICE

# 6.1) /etc/ytweb.env 模板（如不存在）
if [ ! -f /etc/ytweb.env ]; then
  echo "[ytweb] creating /etc/ytweb.env template (fill TG_BOT_TOKEN / TG_CHAT_ID manually) ..."
  cat > /etc/ytweb.env <<'ENV'
# ytweb environment (secrets)
# Fill in your Telegram bot token and chat id, then:
#   systemctl daemon-reload
#   systemctl restart ytweb.service

#TG_BOT_TOKEN="123456:REPLACE_ME"
#TG_CHAT_ID="123456789"
ENV
  chmod 600 /etc/ytweb.env
fi

echo "[ytweb] reloading systemd units ..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

# 7) nginx (force https)
cat > /etc/nginx/sites-available/ytweb.conf <<NG
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://127.0.0.1:5001;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
}
NG

echo "[ytweb] enabling nginx site ytweb.conf ..."
ln -sf /etc/nginx/sites-available/ytweb.conf /etc/nginx/sites-enabled/ytweb.conf
nginx -t
systemctl reload nginx

# 8) https cert (first time / renew when needed)
if command -v certbot >/dev/null 2>&1; then
  echo "[ytweb] running certbot --nginx for $DOMAIN (errors ignored if already configured) ..."
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email || true
  nginx -t && systemctl reload nginx
else
  echo "[ytweb] certbot not found; please configure TLS certificate for $DOMAIN manually." >&2
fi

# 9) healthcheck script + cron
cat >/usr/local/sbin/check-ytweb.sh <<'SH'
#!/bin/bash
# simple health check for ytweb on 127.0.0.1:5001
if ! curl -s --max-time 3 http://127.0.0.1:5001/ >/dev/null; then
  systemctl restart ytweb.service
fi
SH
chmod +x /usr/local/sbin/check-ytweb.sh

# add to root cron (idempotent)
if ! crontab -l 2>/dev/null | grep -q 'check-ytweb.sh'; then
  ( crontab -l 2>/dev/null ; echo "* * * * * /usr/local/sbin/check-ytweb.sh" ) | crontab -
fi

echo "[ytweb] install done. open: https://$DOMAIN/"
echo "[ytweb] yt-dlp version in use: $YTDLP_VERSION"