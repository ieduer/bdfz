#!/usr/bin/env bash
# dl.sh - ytweb with progress, HTTPS, 8h auto-clean, Telegram notify
# version: v1.8-2026-02-13
# changes from v1.5-2025-12-03:
# - 全新 Geek 風格 Glassmorphism UI（暗色主題、漸變背景、動畫效果）
# - 新增下載格式選項（偏好 MP4、最高解析度限制、僅音訊）
# - 新增進階選項（嵌入字幕、嵌入縮略圖、提取 MP3、僅下載單個視頻）
# - Terminal 風格日誌顯示
# - 使用 Inter + JetBrains Mono 字體
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

echo "[ytweb] installing version v1.8-2026-02-13 ..."

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
echo "[ytweb] installing base packages (python3, venv, pip, nginx, certbot, ffmpeg, curl, unzip) ..."
if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  apt-get install -y python3 python3-venv python3-pip nginx certbot python3-certbot-nginx ffmpeg curl unzip
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

# 1.5) deno (for yt-dlp youtube JS runtime)
# yt-dlp: Only deno is enabled by default; installing deno avoids YouTube 403/SABR issues.
if ! command -v deno >/dev/null 2>&1; then
  echo "[ytweb] installing deno (JS runtime for yt-dlp) ..."
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) DENO_ZIP="deno-x86_64-unknown-linux-gnu.zip" ;;
    aarch64|arm64) DENO_ZIP="deno-aarch64-unknown-linux-gnu.zip" ;;
    *)
      echo "[ytweb] unsupported arch for deno: $ARCH (skip)" >&2
      DENO_ZIP=""
      ;;
  esac

  if [ -n "$DENO_ZIP" ]; then
    TMPDIR="$(mktemp -d)"
    (
      set -e
      cd "$TMPDIR"
      curl -fL -o deno.zip "https://github.com/denoland/deno/releases/latest/download/${DENO_ZIP}"
      unzip -o deno.zip
      install -m 0755 deno /usr/local/bin/deno
    )
    rm -rf "$TMPDIR" || true
  fi
else
  echo "[ytweb] deno already installed: $(command -v deno)"
fi

if command -v deno >/dev/null 2>&1; then
  echo "[ytweb] deno version: $(deno --version | head -n 1)"
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

echo "[ytweb] upgrading pip and installing/refreshing dependencies (flask, dotenv, yt-dlp + curl_cffi, werkzeug, requests) ..."
"$V_PY" -m pip install --upgrade pip
"$V_PY" -m pip install --upgrade flask python-dotenv "yt-dlp[default,curl-cffi]" werkzeug requests

# 更新後的 yt-dlp 路徑 & 版本
YTDLP_BIN="$VENV_DIR/bin/yt-dlp"
YTDLP_VERSION="$("$YTDLP_BIN" --version 2>/dev/null || echo "unknown")"
echo "[ytweb] yt-dlp version: $YTDLP_VERSION (path: $YTDLP_BIN)"

# 3.5) yt-dlp system config (enable deno runtime; mitigate YouTube SABR/403)
if command -v deno >/dev/null 2>&1; then
  echo "[ytweb] writing /etc/yt-dlp.conf (deno runtime + youtube extractor args) ..."
  cat >/etc/yt-dlp.conf <<'CONF'
# yt-dlp global config (installed by ytweb dl.sh)
# Enable JS runtime (deno) for YouTube extraction
--js-runtimes deno:/usr/local/bin/deno

# Workaround for SABR/403: avoid android_sdkless client
--extractor-args youtube:player_client=default,-android_sdkless

# Reduce flaky fragment downloading
--concurrent-fragments 1
--retries 10
--fragment-retries 10
--retry-sleep 1
CONF
  chmod 0644 /etc/yt-dlp.conf
else
  echo "[ytweb] deno not found; skip /etc/yt-dlp.conf (YouTube may be flaky)" >&2
fi

# 4) app.py
cat > "$APP_DIR/app.py" <<'PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ytweb - tiny web ui for yt-dlp
version: v1.8-2026-02-13

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


def run_ytdlp_task(task_id, url, fmt, options=None):
  """執行 yt-dlp 下載任務。

  如果 fmt 為 None，則不傳 -f，讓 yt-dlp 使用預設策略（bestvideo+bestaudio）。
  限制檔名長度，避免 Errno 36。
  options: dict with keys embed_subs, embed_thumbnail, extract_audio, no_playlist
  """
  if options is None:
    options = {}
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
  # YouTube: prefer enabling JS runtime (deno) + mitigate SABR/403
  try:
    uhost = (urlparse(url).netloc or "").lower()
  except Exception:
    uhost = ""
  if "youtube.com" in uhost or "youtu.be" in uhost:
    if os.path.isfile("/usr/local/bin/deno"):
      cmd += ["--js-runtimes", "deno:/usr/local/bin/deno"]
    cmd += ["--extractor-args", "youtube:player_client=default,-android_sdkless"]
    # a bit more robust for fragments
    cmd += ["--concurrent-fragments", "1", "--retries", "10", "--fragment-retries", "10", "--retry-sleep", "1"]

  # X/Twitter: often needs browser impersonation to pass GraphQL/guest-token checks
  if any(h in uhost for h in ("x.com", "twitter.com")):
    cmd += ["--impersonate", "chrome"]

  if fmt:
    cmd += ["-f", fmt]
  
  # 進階選項
  if options.get("embed_subs"):
    cmd += ["--embed-subs", "--sub-langs", "all"]
  if options.get("embed_thumbnail"):
    cmd += ["--embed-thumbnail"]
  if options.get("extract_audio"):
    cmd += ["-x", "--audio-format", "mp3"]
  if options.get("no_playlist"):
    cmd += ["--no-playlist"]
  
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

  # 進階選項
  options = {
    "embed_subs": request.form.get("embed_subs") == "1",
    "embed_thumbnail": request.form.get("embed_thumbnail") == "1",
    "extract_audio": request.form.get("extract_audio") == "1",
    "no_playlist": request.form.get("no_playlist") == "1",
  }

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
    args=(task_id, url, fmt_for_worker, options),
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

# 5) geek-style glassmorphism template
cat > "$APP_DIR/templates/index.html" <<'HTML'
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <title>yt-dlp web · BDFZ-SUEN</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="Geek-style yt-dlp web interface for downloading videos">
  <!-- Favicon / Icons -->
  <link rel="icon" href="https://img.bdfz.net/20250503004.webp" type="image/webp">
  <link rel="shortcut icon" href="https://img.bdfz.net/20250503004.webp" type="image/webp">
  <link rel="apple-touch-icon" href="https://img.bdfz.net/20250503004.webp">
  <!-- Google Fonts -->
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg: #0a0e14;
      --bg-secondary: #0d1117;
      --fg: #e6edf3;
      --muted: #8b949e;
      --line: #21262d;
      --card: rgba(13, 17, 23, 0.8);
      --glass: rgba(13, 17, 23, 0.85);
      --accent: #58a6ff;
      --accent-glow: rgba(88, 166, 255, 0.4);
      --success: #3fb950;
      --success-glow: rgba(63, 185, 80, 0.3);
      --error: #f85149;
      --warning: #d29922;
      --radius: 12px;
      --radius-sm: 8px;
    }

    * { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      font-size: 14px;
      line-height: 1.6;
      background: var(--bg);
      color: var(--fg);
      min-height: 100vh;
    }

    /* Animated gradient background */
    body::before {
      content: '';
      position: fixed;
      top: 0; left: 0; right: 0;
      height: 500px;
      background: 
        radial-gradient(ellipse 80% 50% at 50% -20%, rgba(88, 166, 255, 0.15), transparent),
        radial-gradient(ellipse 60% 40% at 80% 10%, rgba(139, 92, 246, 0.12), transparent),
        radial-gradient(ellipse 50% 30% at 20% 20%, rgba(236, 72, 153, 0.08), transparent);
      pointer-events: none;
      z-index: -1;
      animation: gradientShift 8s ease-in-out infinite alternate;
    }

    @keyframes gradientShift {
      0% { opacity: 0.8; transform: scale(1); }
      100% { opacity: 1; transform: scale(1.05); }
    }

    /* Header */
    header {
      position: sticky;
      top: 0;
      z-index: 100;
      padding: 16px 20px;
      background: var(--glass);
      backdrop-filter: blur(20px) saturate(180%);
      -webkit-backdrop-filter: blur(20px) saturate(180%);
      border-bottom: 1px solid rgba(255,255,255,0.06);
      box-shadow: 0 8px 32px rgba(0,0,0,0.4);
    }

    .header-content {
      max-width: 960px;
      margin: 0 auto;
      display: flex;
      align-items: center;
      justify-content: space-between;
      flex-wrap: wrap;
      gap: 12px;
    }

    .brand {
      display: flex;
      align-items: center;
      gap: 12px;
    }

    .brand-icon {
      width: 36px;
      height: 36px;
      border-radius: 10px;
      object-fit: cover;
      border: 2px solid rgba(255,255,255,0.1);
    }

    .brand h1 {
      font-size: 20px;
      font-weight: 700;
      background: linear-gradient(135deg, #58a6ff, #a78bfa, #f472b6);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
      background-clip: text;
      letter-spacing: -0.5px;
    }

    .brand .version {
      font-size: 10px;
      color: var(--muted);
      font-weight: 500;
      padding: 2px 6px;
      background: rgba(255,255,255,0.05);
      border-radius: 4px;
      margin-left: 8px;
    }

    .stats-badge {
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 6px 12px;
      background: rgba(255,255,255,0.03);
      border: 1px solid rgba(255,255,255,0.06);
      border-radius: 99px;
      font-size: 12px;
      color: var(--muted);
    }

    .stats-badge .dot {
      width: 8px;
      height: 8px;
      background: var(--success);
      border-radius: 50%;
      animation: pulse 2s infinite;
    }

    @keyframes pulse {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.5; }
    }

    /* Main Content */
    main {
      max-width: 960px;
      margin: 0 auto;
      padding: 32px 20px 60px;
    }

    /* Info Banner */
    .info-banner {
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 12px 16px;
      background: linear-gradient(135deg, rgba(88, 166, 255, 0.1), rgba(139, 92, 246, 0.08));
      border: 1px solid rgba(88, 166, 255, 0.2);
      border-radius: var(--radius);
      margin-bottom: 24px;
      font-size: 13px;
    }

    .info-banner .icon { font-size: 16px; }

    /* Form Card */
    .form-card {
      background: var(--card);
      border: 1px solid rgba(255,255,255,0.06);
      border-radius: var(--radius);
      padding: 24px;
      backdrop-filter: blur(10px);
      box-shadow: 0 8px 32px rgba(0,0,0,0.3);
    }

    .form-title {
      font-size: 16px;
      font-weight: 600;
      margin-bottom: 20px;
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .form-group {
      margin-bottom: 16px;
    }

    label {
      display: block;
      font-size: 13px;
      font-weight: 500;
      color: var(--fg);
      margin-bottom: 6px;
    }

    label .hint {
      color: var(--muted);
      font-weight: 400;
      font-size: 11px;
    }

    input[type="url"],
    input[type="text"],
    select {
      width: 100%;
      padding: 12px 14px;
      background: rgba(255,255,255,0.03);
      border: 1px solid rgba(255,255,255,0.1);
      border-radius: var(--radius-sm);
      color: var(--fg);
      font-size: 14px;
      font-family: inherit;
      outline: none;
      transition: all 0.2s ease;
    }

    input:focus, select:focus {
      border-color: var(--accent);
      box-shadow: 0 0 0 3px var(--accent-glow);
      background: rgba(255,255,255,0.05);
    }

    input::placeholder { color: var(--muted); }

    select {
      cursor: pointer;
      appearance: none;
      background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' fill='none' viewBox='0 0 24 24' stroke='%238b949e'%3E%3Cpath stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M19 9l-7 7-7-7'/%3E%3C/svg%3E");
      background-repeat: no-repeat;
      background-position: right 12px center;
      background-size: 16px;
      padding-right: 40px;
    }

    select option {
      background: var(--bg-secondary);
      color: var(--fg);
    }

    /* Options Grid */
    .options-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
      gap: 12px;
      margin-bottom: 16px;
    }

    .option-item {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 10px 12px;
      background: rgba(255,255,255,0.02);
      border: 1px solid rgba(255,255,255,0.06);
      border-radius: var(--radius-sm);
      cursor: pointer;
      transition: all 0.2s ease;
    }

    .option-item:hover {
      background: rgba(255,255,255,0.04);
      border-color: rgba(255,255,255,0.1);
    }

    .option-item input[type="checkbox"] {
      width: 16px;
      height: 16px;
      accent-color: var(--accent);
      cursor: pointer;
    }

    .option-item span {
      font-size: 13px;
    }

    .form-help {
      font-size: 12px;
      color: var(--muted);
      margin-top: 8px;
      padding: 10px 12px;
      background: rgba(255,255,255,0.02);
      border-radius: var(--radius-sm);
      border-left: 3px solid var(--accent);
    }

    .form-help code {
      font-family: 'JetBrains Mono', monospace;
      font-size: 11px;
      background: rgba(255,255,255,0.06);
      padding: 2px 6px;
      border-radius: 4px;
    }

    /* Collapsible Advanced Options */
    .advanced-toggle {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 10px 0;
      cursor: pointer;
      font-size: 13px;
      color: var(--accent);
      border: none;
      background: none;
      width: 100%;
      text-align: left;
    }

    .advanced-toggle:hover { color: #79b8ff; }

    .advanced-toggle .arrow {
      transition: transform 0.2s ease;
    }

    .advanced-toggle.open .arrow {
      transform: rotate(90deg);
    }

    .advanced-section {
      display: none;
      padding-top: 12px;
      border-top: 1px solid rgba(255,255,255,0.06);
      margin-top: 8px;
    }

    .advanced-section.show {
      display: block;
      animation: fadeIn 0.3s ease;
    }

    @keyframes fadeIn {
      from { opacity: 0; transform: translateY(-8px); }
      to { opacity: 1; transform: translateY(0); }
    }

    /* Submit Button */
    button[type="submit"] {
      width: 100%;
      padding: 14px 20px;
      background: linear-gradient(135deg, var(--accent), #3b82f6);
      border: none;
      border-radius: var(--radius-sm);
      color: #fff;
      font-size: 15px;
      font-weight: 600;
      cursor: pointer;
      transition: all 0.2s ease;
      margin-top: 8px;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
    }

    button[type="submit"]:hover {
      transform: translateY(-2px);
      box-shadow: 0 8px 24px var(--accent-glow);
    }

    button[type="submit"]:active {
      transform: translateY(0);
    }

    /* Status Messages */
    .status-box {
      margin-top: 24px;
      padding: 20px;
      border-radius: var(--radius);
      animation: fadeIn 0.3s ease;
    }

    .status-box.running {
      background: linear-gradient(135deg, rgba(88, 166, 255, 0.1), rgba(88, 166, 255, 0.05));
      border: 1px solid rgba(88, 166, 255, 0.3);
    }

    .status-box.done {
      background: linear-gradient(135deg, rgba(63, 185, 80, 0.1), rgba(63, 185, 80, 0.05));
      border: 1px solid rgba(63, 185, 80, 0.3);
    }

    .status-box.error {
      background: linear-gradient(135deg, rgba(248, 81, 73, 0.1), rgba(248, 81, 73, 0.05));
      border: 1px solid rgba(248, 81, 73, 0.3);
    }

    .status-header {
      display: flex;
      align-items: center;
      gap: 10px;
      margin-bottom: 12px;
    }

    .status-header .icon { font-size: 20px; }

    .status-header h3 {
      font-size: 15px;
      font-weight: 600;
    }

    .status-info {
      font-size: 13px;
      color: var(--muted);
    }

    .status-info code {
      font-family: 'JetBrains Mono', monospace;
      font-size: 11px;
      background: rgba(255,255,255,0.06);
      padding: 2px 6px;
      border-radius: 4px;
      color: var(--fg);
    }

    /* Progress Bar */
    .progress-container {
      margin: 16px 0;
    }

    .progress-bar {
      width: 100%;
      height: 8px;
      background: rgba(255,255,255,0.1);
      border-radius: 99px;
      overflow: hidden;
      position: relative;
    }

    .progress-bar-inner {
      height: 100%;
      background: linear-gradient(90deg, var(--accent), #a78bfa);
      width: 0%;
      transition: width 0.3s ease;
      border-radius: 99px;
      position: relative;
    }

    .progress-bar-inner::after {
      content: '';
      position: absolute;
      top: 0; left: 0; right: 0; bottom: 0;
      background: linear-gradient(90deg, transparent, rgba(255,255,255,0.3), transparent);
      animation: shimmer 1.5s infinite;
    }

    @keyframes shimmer {
      0% { transform: translateX(-100%); }
      100% { transform: translateX(100%); }
    }

    .progress-text {
      display: flex;
      justify-content: space-between;
      font-size: 12px;
      color: var(--muted);
      margin-top: 6px;
    }

    /* Download Button */
    .download-btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      width: 100%;
      padding: 14px 20px;
      background: linear-gradient(135deg, var(--success), #22c55e);
      color: #fff;
      text-decoration: none;
      border-radius: var(--radius-sm);
      font-size: 15px;
      font-weight: 600;
      transition: all 0.2s ease;
      margin-top: 12px;
    }

    .download-btn:hover {
      transform: translateY(-2px);
      box-shadow: 0 8px 24px var(--success-glow);
    }

    /* Terminal-style Log */
    .log-container {
      margin-top: 16px;
    }

    .log-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 8px 12px;
      background: rgba(0,0,0,0.3);
      border-radius: var(--radius-sm) var(--radius-sm) 0 0;
      border: 1px solid rgba(255,255,255,0.06);
      border-bottom: none;
    }

    .log-header .dots {
      display: flex;
      gap: 6px;
    }

    .log-header .dot {
      width: 10px;
      height: 10px;
      border-radius: 50%;
    }

    .log-header .dot.red { background: #f85149; }
    .log-header .dot.yellow { background: #d29922; }
    .log-header .dot.green { background: #3fb950; }

    .log-header .title {
      font-family: 'JetBrains Mono', monospace;
      font-size: 11px;
      color: var(--muted);
    }

    .log {
      font-family: 'JetBrains Mono', monospace;
      font-size: 12px;
      line-height: 1.5;
      white-space: pre-wrap;
      word-break: break-all;
      background: rgba(0,0,0,0.4);
      padding: 16px;
      border: 1px solid rgba(255,255,255,0.06);
      border-top: none;
      border-radius: 0 0 var(--radius-sm) var(--radius-sm);
      max-height: 300px;
      overflow-y: auto;
      color: #7ee787;
    }

    .log::-webkit-scrollbar {
      width: 6px;
    }

    .log::-webkit-scrollbar-track {
      background: transparent;
    }

    .log::-webkit-scrollbar-thumb {
      background: rgba(255,255,255,0.1);
      border-radius: 3px;
    }

    .log.collapsed {
      display: none;
    }

    /* Footer */
    footer {
      text-align: center;
      padding: 24px 20px;
      font-size: 12px;
      color: var(--muted);
    }

    footer a {
      color: var(--accent);
      text-decoration: none;
    }

    footer a:hover {
      text-decoration: underline;
    }

    /* Responsive */
    @media (max-width: 640px) {
      .header-content {
        justify-content: center;
      }
      .stats-badge {
        display: none;
      }
      .options-grid {
        grid-template-columns: 1fr;
      }
    }
  </style>
</head>
<body>
  <header>
    <div class="header-content">
      <div class="brand">
        <img src="https://img.bdfz.net/20250503004.webp" alt="BDFZ" class="brand-icon">
        <h1>yt-dlp web<span class="version">v1.8</span></h1>
      </div>
      <div class="stats-badge">
        <span class="dot"></span>
        <span>Service Online</span>
      </div>
    </div>
  </header>

  <main>
    <div class="info-banner">
      <span class="icon">⏱️</span>
      <span>下載的檔案會在 <strong>8 小時</strong>後自動刪除，請及時保存</span>
    </div>

    <div class="form-card">
      <div class="form-title">
        <span>🎬</span>
        <span>下載視頻</span>
      </div>

      <form method="post" action="/download">
        <div class="form-group">
          <label for="url">視頻 URL <span class="hint">(必填)</span></label>
          <input type="url" id="url" name="url" required 
                 placeholder="YouTube / Bilibili / Twitter / TikTok / 其他支援的網站...">
        </div>

        <div class="form-group">
          <label for="format">下載格式</label>
          <select id="format" name="format">
            <option value="" selected>🚀 自動最佳 (bestvideo+bestaudio)</option>
            <option value="bv[ext=mp4]+ba[ext=m4a]/best[ext=mp4]/best">📹 偏好 MP4 容器</option>
            <option value="bv[height<=1080]+ba/best">📺 最高 1080p</option>
            <option value="bv[height<=720]+ba/best">📱 最高 720p (省流量)</option>
            <option value="bv[height<=480]+ba/best">📼 最高 480p (極致省流)</option>
            <option value="bestaudio[ext=m4a]/bestaudio">🎵 僅音訊 (M4A)</option>
            <option value="bestaudio">🎶 僅音訊 (最佳格式)</option>
            <option value="best">📦 單文件最佳</option>
          </select>
        </div>

        <button type="button" class="advanced-toggle" onclick="toggleAdvanced()">
          <span class="arrow">▶</span>
          <span>進階選項</span>
        </button>

        <div class="advanced-section" id="advancedSection">
          <div class="form-group">
            <label for="custom_format">自定義格式 <span class="hint">(覆蓋上方選擇)</span></label>
            <input type="text" id="custom_format" name="custom_format" 
                   placeholder="例如: bv*[height<=720][ext=mp4]+ba/best">
          </div>

          <div class="options-grid">
            <label class="option-item">
              <input type="checkbox" name="embed_subs" value="1">
              <span>📝 嵌入字幕</span>
            </label>
            <label class="option-item">
              <input type="checkbox" name="embed_thumbnail" value="1">
              <span>🖼️ 嵌入縮略圖</span>
            </label>
            <label class="option-item">
              <input type="checkbox" name="extract_audio" value="1">
              <span>🎵 提取為 MP3</span>
            </label>
            <label class="option-item">
              <input type="checkbox" name="no_playlist" value="1" checked>
              <span>🔗 僅下載單個視頻</span>
            </label>
          </div>

          <div class="form-help">
            📖 <strong>格式語法示例：</strong><br>
            <code>bv[ext=mp4]+ba/best</code> - 優先 MP4<br>
            <code>bv[height&lt;=720]+ba</code> - 最高 720p<br>
            <code>bv*+ba/b</code> - 視頻+音訊合併
          </div>
        </div>

        <button type="submit">
          <span>⬇️</span>
          <span>開始下載</span>
        </button>
      </form>
    </div>

    {% if error %}
    <div class="status-box error">
      <div class="status-header">
        <span class="icon">❌</span>
        <h3>發生錯誤</h3>
      </div>
      <p class="status-info">{{ error }}</p>
    </div>
    {% endif %}

    {% if started %}
    <div id="status-box" class="status-box running">
      <div class="status-header">
        <span class="icon">⏳</span>
        <h3>正在下載中...</h3>
      </div>
      <p class="status-info">
        任務 ID: <code id="task-id">{{ task_id }}</code>
        {% if normalized_url %}<br>已解析: <code>{{ normalized_url }}</code>{% endif %}
        {% if expires_at %}<br>過期時間: <code id="expire-time">{{ expires_at }}</code>{% endif %}
      </p>
      <div class="progress-container">
        <div class="progress-bar">
          <div id="pb" class="progress-bar-inner"></div>
        </div>
        <div class="progress-text">
          <span id="progress-pct">0%</span>
          <span>下載中...</span>
        </div>
      </div>
      <div class="log-container">
        <div class="log-header">
          <div class="dots">
            <span class="dot red"></span>
            <span class="dot yellow"></span>
            <span class="dot green"></span>
          </div>
          <span class="title">~/yt-dlp/output.log</span>
        </div>
        <div id="logs" class="log collapsed"></div>
      </div>
    </div>
    {% endif %}
  </main>

  <footer>
    Powered by <a href="https://github.com/yt-dlp/yt-dlp" target="_blank">yt-dlp</a> · 
    Built by <a href="https://bdfz.net" target="_blank">BDFZ-SUEN</a>
  </footer>

  <script>
  function toggleAdvanced() {
    const btn = document.querySelector('.advanced-toggle');
    const section = document.getElementById('advancedSection');
    btn.classList.toggle('open');
    section.classList.toggle('show');
  }

  (function() {
    const taskIdEl = document.getElementById('task-id');
    if (!taskIdEl) return;
    const taskId = taskIdEl.textContent.trim();
    const pb = document.getElementById('pb');
    const pctEl = document.getElementById('progress-pct');
    const logsEl = document.getElementById('logs');
    const statusBox = document.getElementById('status-box');

    function showLog() {
      if (logsEl) logsEl.classList.remove('collapsed');
    }

    function poll() {
      fetch('/progress/' + taskId)
        .then(r => r.json())
        .then(data => {
          if (data.progress !== undefined) {
            const pct = Math.round(data.progress);
            if (pb) pb.style.width = pct + '%';
            if (pctEl) pctEl.textContent = pct + '%';
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
            showLog();
            statusBox.className = 'status-box done';
            statusBox.innerHTML = `
              <div class="status-header">
                <span class="icon">✅</span>
                <h3>下載完成！</h3>
              </div>
              <p class="status-info">文件: <code>${data.filename || 'video'}</code></p>
              <a class="download-btn" href="${data.download_url}">
                <span>📥</span>
                <span>點擊下載文件</span>
              </a>
              <p class="status-info" style="margin-top:12px;">⏱️ 檔案將在 8 小時後自動刪除</p>
              <div class="log-container">
                <div class="log-header">
                  <div class="dots">
                    <span class="dot red"></span>
                    <span class="dot yellow"></span>
                    <span class="dot green"></span>
                  </div>
                  <span class="title">~/yt-dlp/output.log</span>
                </div>
                <div class="log">${logsEl ? logsEl.textContent : ''}</div>
              </div>
            `;
          } else if (data.status === 'error') {
            showLog();
            statusBox.className = 'status-box error';
            statusBox.innerHTML = `
              <div class="status-header">
                <span class="icon">❌</span>
                <h3>下載失敗</h3>
              </div>
              <p class="status-info">請查看下方日誌了解詳情</p>
              <div class="log-container">
                <div class="log-header">
                  <div class="dots">
                    <span class="dot red"></span>
                    <span class="dot yellow"></span>
                    <span class="dot green"></span>
                  </div>
                  <span class="title">~/yt-dlp/error.log</span>
                </div>
                <div class="log" style="color:#f85149;">${logsEl ? logsEl.textContent : ''}</div>
              </div>
            `;
          } else {
            setTimeout(poll, 1500);
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