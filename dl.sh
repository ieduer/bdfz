#!/usr/bin/env bash
# dl.sh - ytweb with progress, HTTPS, 8h auto-clean, Telegram notify
# version: v1.10-2026-04-08
# changes from v1.9-2026-03-30:
# - 全新 Geek 風格 Glassmorphism UI（暗色主題、漸變背景、動畫效果）
# - 新增下載格式選項（偏好 MP4、最高解析度限制、僅音訊）
# - 新增進階選項（嵌入字幕、嵌入縮略圖、提取 MP3、僅下載單個視頻）
# - 新增 URL 預填、cookies.txt 上傳、yt-dlp 預解析
# - Terminal 風格日誌顯示
# - 使用 Inter + JetBrains Mono 字體
# - 固定 curl-cffi 相容版本，恢復 X/Twitter impersonation
# - 新增 ffmpeg / impersonation 健康檢查與 /healthz
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

echo "[ytweb] installing version v1.10-2026-04-08 ..."

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

echo "[ytweb] upgrading pip and installing/refreshing dependencies (flask, dotenv, yt-dlp, werkzeug, requests, curl-cffi<0.15) ..."
"$V_PY" -m pip install --upgrade pip
"$V_PY" -m pip install --upgrade flask python-dotenv "yt-dlp[default]" werkzeug requests "curl-cffi>=0.14,<0.15"

# 更新後的 yt-dlp 路徑 & 版本
YTDLP_BIN="$VENV_DIR/bin/yt-dlp"
YTDLP_VERSION="$("$YTDLP_BIN" --version 2>/dev/null || echo "unknown")"
echo "[ytweb] yt-dlp version: $YTDLP_VERSION (path: $YTDLP_BIN)"
if ! "$YTDLP_BIN" --list-impersonate-targets 2>/dev/null | grep -q '^Chrome'; then
  echo "[ytweb] Chrome impersonation missing; forcing curl-cffi compatibility pin ..."
  "$V_PY" -m pip install --force-reinstall "curl-cffi>=0.14,<0.15"
fi
if ! "$YTDLP_BIN" --list-impersonate-targets 2>/dev/null | grep -q '^Chrome'; then
  echo "[ytweb] Chrome impersonation still unavailable after compatibility pin" >&2
  exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "[ytweb] ffmpeg still missing after package installation" >&2
  exit 1
fi

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
version: v1.10-2026-04-08

- explicit yt-dlp path via env YTDLP_BIN
- youtube url normalization (watch/shorts/live/youtu.be)
- 8h cleanup
- progress returns relative download_url to avoid mixed content
- ProxyFix + PREFERRED_URL_SCHEME=https
- auto 模式：不傳 -f，讓 yt-dlp 自行選擇 bestvideo+bestaudio
- 限制檔名長度，避免 Errno 36
- 支援 cookies.txt 上傳，提升登入站點 / 受限視頻下載成功率
- 支援 yt-dlp JSON 預解析，顯示標題 / extractor / 部分格式
- 下載完成後透過 Telegram 發送通知（由環境變量注入 TG_BOT_TOKEN / TG_CHAT_ID）
- 啟動與健康檢查會驗證 ffmpeg 與 X/Twitter impersonation 可用性
"""
import json
import os
import shutil
import uuid
import subprocess
import tempfile
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
INFO_TIMEOUT_SECONDS = 45
MAX_COOKIE_FILE_BYTES = 2 * 1024 * 1024
PROG_RE = re.compile(r"(\d+(?:\.\d+)?)%")
HEALTH_CACHE_SECONDS = 300
_RUNTIME_HEALTH = None
_RUNTIME_HEALTH_TS = 0.0


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


def is_http_url(u: str) -> bool:
  try:
    parsed = urlparse(u)
  except Exception:
    return False
  return parsed.scheme in ("http", "https") and bool(parsed.netloc)


def format_duration(seconds) -> str:
  try:
    total = int(seconds or 0)
  except (TypeError, ValueError):
    return ""
  if total <= 0:
    return ""
  hours, remainder = divmod(total, 3600)
  minutes, secs = divmod(remainder, 60)
  if hours:
    return f"{hours}:{minutes:02d}:{secs:02d}"
  return f"{minutes}:{secs:02d}"


def format_bytes(size) -> str:
  try:
    value = float(size or 0)
  except (TypeError, ValueError):
    return ""
  if value <= 0:
    return ""
  for unit in ("B", "KB", "MB", "GB", "TB"):
    if value < 1024 or unit == "TB":
      if unit == "B":
        return f"{int(value)} {unit}"
      return f"{value:.1f} {unit}"
    value /= 1024
  return ""


def detect_curl_cffi_version() -> str:
  try:
    import curl_cffi  # type: ignore
  except Exception:
    return ""
  return str(getattr(curl_cffi, "__version__", "") or "")


def detect_impersonate_targets() -> list[str]:
  try:
    proc = subprocess.run(
      [YTDLP_BIN, "--list-impersonate-targets"],
      stdout=subprocess.PIPE,
      stderr=subprocess.STDOUT,
      text=True,
      timeout=15,
    )
  except Exception:
    return []

  targets = []
  for raw_line in (proc.stdout or "").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("[info]") or line.startswith("Client") or line.startswith("-"):
      continue
    first = line.split()[0].strip()
    if first:
      targets.append(first.lower())
  return targets


def get_runtime_health(force: bool = False) -> dict:
  global _RUNTIME_HEALTH, _RUNTIME_HEALTH_TS
  now = time.time()
  if not force and _RUNTIME_HEALTH and (now - _RUNTIME_HEALTH_TS) < HEALTH_CACHE_SECONDS:
    return _RUNTIME_HEALTH

  ytdlp_exists = os.path.isfile(YTDLP_BIN)
  yt_dlp_version = ""
  if ytdlp_exists:
    try:
      proc = subprocess.run(
        [YTDLP_BIN, "--version"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=10,
      )
      yt_dlp_version = (proc.stdout or "").strip()
    except Exception:
      yt_dlp_version = ""

  ffmpeg_path = shutil.which("ffmpeg") or ""
  targets = detect_impersonate_targets() if ytdlp_exists else []
  chrome_targets = [target for target in targets if target.startswith("chrome")]

  warnings = []
  if not ytdlp_exists:
    warnings.append(f"yt-dlp missing at {YTDLP_BIN}")
  if not ffmpeg_path:
    warnings.append("ffmpeg missing from PATH")
  if not chrome_targets:
    warnings.append("yt-dlp chrome impersonation unavailable for x.com/twitter.com")

  health = {
    "ok": bool(ytdlp_exists and ffmpeg_path and chrome_targets),
    "ytdlp_bin": YTDLP_BIN,
    "yt_dlp_version": yt_dlp_version,
    "ffmpeg_path": ffmpeg_path,
    "curl_cffi_version": detect_curl_cffi_version(),
    "impersonate_targets": targets,
    "x_impersonation_ok": bool(chrome_targets),
    "checked_at": now_utc().isoformat(),
    "warnings": warnings,
  }
  _RUNTIME_HEALTH = health
  _RUNTIME_HEALTH_TS = now
  return health


def build_ytdlp_base_cmd(url: str, cookies_path=None):
  cmd = [YTDLP_BIN]
  try:
    uhost = (urlparse(url).netloc or "").lower()
  except Exception:
    uhost = ""

  if cookies_path and os.path.isfile(cookies_path):
    cmd += ["--cookies", cookies_path]

  # YouTube: prefer enabling JS runtime (deno) + mitigate SABR/403
  if "youtube.com" in uhost or "youtu.be" in uhost:
    if os.path.isfile("/usr/local/bin/deno"):
      cmd += ["--js-runtimes", "deno:/usr/local/bin/deno"]
    cmd += ["--extractor-args", "youtube:player_client=default,-android_sdkless"]
    cmd += [
      "--concurrent-fragments",
      "1",
      "--retries",
      "10",
      "--fragment-retries",
      "10",
      "--retry-sleep",
      "1",
    ]

  # X/Twitter: often needs browser impersonation to pass GraphQL/guest-token checks
  if any(h in uhost for h in ("x.com", "twitter.com")):
    if get_runtime_health().get("x_impersonation_ok"):
      cmd += ["--impersonate", "chrome"]

  return cmd


def parse_ytdlp_json(raw: str):
  payload = raw.strip()
  if not payload:
    raise ValueError("empty yt-dlp response")
  lines = [line.strip() for line in payload.splitlines() if line.strip()]
  for line in reversed(lines):
    if (line.startswith("{") and line.endswith("}")) or (
      line.startswith("[") and line.endswith("]")
    ):
      return json.loads(line)
  return json.loads(payload)


def summarize_formats(info: dict, limit: int = 10):
  summarized = []
  seen = set()

  for fmt in info.get("formats") or []:
    format_id = str(fmt.get("format_id") or "").strip()
    if not format_id or format_id in seen:
      continue
    seen.add(format_id)

    vcodec = str(fmt.get("vcodec") or "none")
    acodec = str(fmt.get("acodec") or "none")
    if vcodec == "none" and acodec == "none":
      continue

    height = int(fmt.get("height") or 0)
    width = int(fmt.get("width") or 0)
    resolution = ""
    if width and height:
      resolution = f"{width}x{height}"
    else:
      resolution = str(fmt.get("resolution") or fmt.get("format_note") or "")

    label_bits = []
    if resolution:
      label_bits.append(resolution)
    elif fmt.get("ext"):
      label_bits.append(str(fmt.get("ext")))

    if vcodec == "none":
      label_bits.append("audio only")
    elif acodec == "none":
      label_bits.append("video only")
    else:
      label_bits.append("muxed")

    if fmt.get("fps"):
      try:
        label_bits.append(f"{int(float(fmt['fps']))}fps")
      except (TypeError, ValueError):
        pass

    size_text = format_bytes(fmt.get("filesize") or fmt.get("filesize_approx"))
    if size_text:
      label_bits.append(size_text)

    tbr = 0
    try:
      tbr = int(float(fmt.get("tbr") or 0))
    except (TypeError, ValueError):
      tbr = 0
    if tbr > 0:
      label_bits.append(f"{tbr}k")

    summarized.append(
      {
        "format_id": format_id,
        "label": f"{format_id} · {' · '.join(label_bits)}",
        "selector": format_id,
        "has_audio": acodec != "none",
        "has_video": vcodec != "none",
        "height": height,
        "tbr": tbr,
      }
    )

  summarized.sort(
    key=lambda item: (
      1 if item["has_audio"] and item["has_video"] else 0,
      1 if item["has_video"] else 0,
      item["height"],
      item["tbr"],
    ),
    reverse=True,
  )
  return summarized[:limit]


def build_info_payload(url: str, cookies_path=None):
  cmd = build_ytdlp_base_cmd(url, cookies_path)
  cmd += [
    "--dump-single-json",
    "--skip-download",
    "--no-playlist",
    "--no-warnings",
    "--encoding",
    "utf-8",
    url,
  ]

  proc = subprocess.run(
    cmd,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    timeout=INFO_TIMEOUT_SECONDS,
  )
  if proc.returncode != 0:
    error_lines = [
      line.strip()
      for line in (proc.stderr or proc.stdout or "").splitlines()
      if line.strip()
    ]
    raise RuntimeError(error_lines[-1] if error_lines else "yt-dlp metadata extraction failed")

  info = parse_ytdlp_json(proc.stdout or proc.stderr or "")
  if isinstance(info, dict) and info.get("_type") == "playlist":
    entries = info.get("entries") or []
    if entries:
      info = entries[0]

  if not isinstance(info, dict):
    raise RuntimeError("unexpected metadata payload from yt-dlp")

  return {
    "title": info.get("title") or url,
    "thumbnail": info.get("thumbnail") or "",
    "extractor": info.get("extractor_key") or info.get("extractor") or "unknown",
    "uploader": info.get("uploader") or info.get("channel") or "",
    "duration": format_duration(info.get("duration")),
    "webpage_url": info.get("webpage_url") or url,
    "is_live": bool(info.get("is_live")),
    "formats": summarize_formats(info),
  }


def save_cookie_upload(file_storage, destination_path: str):
  filename = (getattr(file_storage, "filename", "") or "").strip()
  if not filename:
    return None, None

  lower_name = filename.lower()
  if not lower_name.endswith((".txt", ".cookies", ".cookie")):
    return None, "cookies 文件請上傳 Netscape 格式的 cookies.txt / .cookies"

  data = file_storage.stream.read(MAX_COOKIE_FILE_BYTES + 1)
  if len(data) > MAX_COOKIE_FILE_BYTES:
    return None, "cookies 文件過大，請控制在 2 MB 以內"
  if not data.strip():
    return None, "cookies 文件為空"

  with open(destination_path, "wb") as fp:
    fp.write(data)
  return destination_path, None


def save_preview_cookie_upload(file_storage):
  filename = (getattr(file_storage, "filename", "") or "").strip()
  if not filename:
    return None, None

  fd, temp_path = tempfile.mkstemp(
    prefix="ytweb-preview-",
    suffix=".cookies.txt",
    dir=DOWNLOAD_DIR,
  )
  os.close(fd)
  cookie_path, error = save_cookie_upload(file_storage, temp_path)
  if error:
    try:
      os.remove(temp_path)
    except OSError:
      pass
  return cookie_path, error


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


def run_ytdlp_task(task_id, url, fmt, options=None, cookies_path=None):
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

  cmd = build_ytdlp_base_cmd(url, cookies_path)
  cmd += [
    "--newline",
    "--trim-filenames",
    "80",
  ]

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
  health = get_runtime_health()
  if not health.get("ffmpeg_path"):
    logs.append("WARNING: ffmpeg not found. The downloaded format may not be the best available.")
  try:
    uhost = (urlparse(url).netloc or "").lower()
  except Exception:
    uhost = ""
  if any(h in uhost for h in ("x.com", "twitter.com")) and not health.get("x_impersonation_ok"):
    logs.append(
      "WARNING: chrome impersonation is unavailable in this runtime; x.com/twitter.com downloads may fail."
    )

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
  prefill_url = (request.args.get("u") or request.args.get("url") or "").strip()
  return render_template("index.html", prefill_url=prefill_url)


@app.route("/api/info", methods=["POST"])
def api_info():
  raw_url = request.form.get("url", "").strip()
  if not raw_url:
    raw_url = (request.args.get("u") or request.args.get("url") or "").strip()
  url = normalize_url(raw_url)
  if not url:
    return jsonify({"error": "URL is required."}), 400
  if not is_http_url(url):
    return jsonify({"error": "Please provide a valid http(s) URL."}), 400

  preview_cookie_path = None
  try:
    preview_cookie_path, cookie_error = save_preview_cookie_upload(
      request.files.get("cookies_file")
    )
    if cookie_error:
      return jsonify({"error": cookie_error}), 400

    return jsonify(build_info_payload(url, preview_cookie_path))
  except subprocess.TimeoutExpired:
    return jsonify({"error": "預解析超時，請稍後再試。"}), 504
  except RuntimeError as exc:
    return jsonify({"error": str(exc)}), 400
  except Exception as exc:
    return jsonify({"error": f"metadata extraction failed: {exc}"}), 500
  finally:
    if preview_cookie_path and os.path.isfile(preview_cookie_path):
      try:
        os.remove(preview_cookie_path)
      except OSError:
        pass


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
    return render_template("index.html", error="URL is required.", prefill_url=raw_url)
  if not is_http_url(url):
    return render_template(
      "index.html",
      error="Please provide a valid http(s) URL.",
      prefill_url=raw_url,
    )

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
  cookies_path, cookie_error = save_cookie_upload(
    request.files.get("cookies_file"),
    os.path.join(task_dir, "cookies.txt"),
  )
  if cookie_error:
    try:
      os.rmdir(task_dir)
    except OSError:
      pass
    return render_template("index.html", error=cookie_error, prefill_url=raw_url)

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
      "cookies_path": cookies_path,
    }

  t = threading.Thread(
    target=run_ytdlp_task,
    args=(task_id, url, fmt_for_worker, options, cookies_path),
    daemon=True,
  )
  t.start()

  return render_template(
    "index.html",
    started=True,
    task_id=task_id,
    expires_at=expires_at.isoformat(),
    normalized_url=url,
    prefill_url=raw_url,
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


@app.route("/healthz", methods=["GET"])
def healthz():
  health = get_runtime_health(force=True)
  status_code = 200 if health.get("ok") else 503
  return jsonify(health), status_code


@app.route("/files/<task_id>/<path:filename>", methods=["GET"])
def get_file(task_id, filename):
  task_dir = os.path.join(DOWNLOAD_DIR, task_id)
  if not os.path.isdir(task_dir):
    abort(404)
  return send_from_directory(task_dir, filename, as_attachment=True)


if __name__ == "__main__":
  print(
    json.dumps(
      {"event": "ytweb-startup-health", **get_runtime_health(force=True)},
      ensure_ascii=False,
    ),
    flush=True,
  )
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

    input[type="file"] {
      width: 100%;
      padding: 10px 12px;
      background: rgba(255,255,255,0.03);
      border: 1px dashed rgba(255,255,255,0.16);
      border-radius: var(--radius-sm);
      color: var(--muted);
      font-size: 13px;
    }

    input[type="file"]::file-selector-button {
      margin-right: 10px;
      padding: 8px 12px;
      border: none;
      border-radius: 8px;
      background: rgba(88, 166, 255, 0.14);
      color: var(--fg);
      cursor: pointer;
    }

    .prefill-note {
      margin-top: 10px;
    }

    .actions-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 12px;
      margin-top: 8px;
    }

    @keyframes fadeIn {
      from { opacity: 0; transform: translateY(-8px); }
      to { opacity: 1; transform: translateY(0); }
    }

    /* Action Buttons */
    .primary-btn,
    .secondary-btn {
      width: 100%;
      padding: 14px 20px;
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

    .primary-btn {
      background: linear-gradient(135deg, var(--accent), #3b82f6);
    }

    .secondary-btn {
      background: linear-gradient(135deg, rgba(255,255,255,0.08), rgba(88, 166, 255, 0.16));
      border: 1px solid rgba(255,255,255,0.08);
      color: var(--fg);
    }

    .primary-btn:hover,
    .secondary-btn:hover {
      transform: translateY(-2px);
    }

    .primary-btn:hover {
      box-shadow: 0 8px 24px var(--accent-glow);
    }

    .secondary-btn:hover {
      box-shadow: 0 8px 24px rgba(88, 166, 255, 0.16);
    }

    .primary-btn:active,
    .secondary-btn:active {
      transform: translateY(0);
    }

    .secondary-btn:disabled {
      opacity: 0.6;
      cursor: wait;
      transform: none;
      box-shadow: none;
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

    .status-box.preview {
      background: linear-gradient(135deg, rgba(167, 139, 250, 0.12), rgba(88, 166, 255, 0.05));
      border: 1px solid rgba(167, 139, 250, 0.28);
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
      overflow-wrap: anywhere;
    }

    .preview-layout {
      display: grid;
      grid-template-columns: minmax(0, 220px) minmax(0, 1fr);
      gap: 16px;
      align-items: start;
    }

    .preview-thumb {
      width: 100%;
      max-width: 220px;
      aspect-ratio: 16 / 9;
      object-fit: cover;
      border-radius: var(--radius-sm);
      border: 1px solid rgba(255,255,255,0.08);
      background: rgba(255,255,255,0.03);
    }

    .preview-meta h4 {
      font-size: 16px;
      margin-bottom: 10px;
    }

    .preview-meta-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
      gap: 8px;
      margin-top: 12px;
    }

    .preview-meta-item {
      padding: 10px 12px;
      background: rgba(255,255,255,0.03);
      border: 1px solid rgba(255,255,255,0.06);
      border-radius: var(--radius-sm);
      font-size: 12px;
      color: var(--muted);
    }

    .preview-meta-item strong {
      display: block;
      color: var(--fg);
      margin-bottom: 4px;
      font-size: 12px;
    }

    .format-list {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-top: 14px;
    }

    .format-chip {
      border: 1px solid rgba(88, 166, 255, 0.22);
      background: rgba(88, 166, 255, 0.08);
      color: var(--fg);
      border-radius: 999px;
      padding: 8px 12px;
      font-size: 12px;
      cursor: pointer;
      transition: all 0.2s ease;
    }

    .format-chip:hover {
      background: rgba(88, 166, 255, 0.16);
      transform: translateY(-1px);
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
      .actions-grid {
        grid-template-columns: 1fr;
      }
      .preview-layout {
        grid-template-columns: 1fr;
      }
      .preview-thumb {
        max-width: none;
      }
    }
  </style>
</head>
<body>
  <header>
    <div class="header-content">
      <div class="brand">
        <img src="https://img.bdfz.net/20250503004.webp" alt="BDFZ" class="brand-icon">
        <h1>yt-dlp web<span class="version">v1.10</span></h1>
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

      <form id="download-form" method="post" action="/download" enctype="multipart/form-data">
        <div class="form-group">
          <label for="url">視頻 URL <span class="hint">(必填)</span></label>
          <input type="url" id="url" name="url" required 
                 value="{{ prefill_url or '' }}"
                 placeholder="YouTube / Bilibili / Douyin / X / TikTok / Instagram / 微信文章視頻 / 其他支援站點...">
        </div>

        {% if prefill_url %}
        <div class="form-help prefill-note">
          ↗ 已帶入外部鏈接。可以直接開始下載，也可以先用「預解析」確認 extractor 和可用格式。
        </div>
        {% endif %}

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

          <div class="form-group">
            <label for="cookies_file">cookies.txt <span class="hint">(登入站點 / 受限視頻時建議上傳)</span></label>
            <input type="file" id="cookies_file" name="cookies_file" accept=".txt,.cookies,.cookie,text/plain">
            <div class="form-help">
              🔐 上傳 Netscape 格式 cookies 文件後，會僅用於本次預解析 / 下載任務，並隨任務目錄一起在 8 小時內清理。
            </div>
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

        <div class="actions-grid">
          <button type="button" id="preview-btn" class="secondary-btn">
            <span>🔎</span>
            <span>預解析</span>
          </button>
          <button type="submit" class="primary-btn">
            <span>⬇️</span>
            <span>開始下載</span>
          </button>
        </div>
      </form>
    </div>

    <div id="preview-box" class="status-box preview" hidden>
      <div class="status-header">
        <span class="icon">🧭</span>
        <h3>預解析結果</h3>
      </div>
      <div id="preview-body" class="status-info"></div>
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
  function toggleAdvanced(forceState) {
    const btn = document.querySelector('.advanced-toggle');
    const section = document.getElementById('advancedSection');
    if (!btn || !section) return;
    const shouldOpen = typeof forceState === 'boolean'
      ? forceState
      : !btn.classList.contains('open');
    btn.classList.toggle('open', shouldOpen);
    section.classList.toggle('show', shouldOpen);
  }

  (function() {
    function escapeHtml(value) {
      return String(value ?? '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
    }

    function setPreviewState(kind, bodyHtml) {
      const previewBox = document.getElementById('preview-box');
      const previewBody = document.getElementById('preview-body');
      if (!previewBox || !previewBody) return;
      previewBox.hidden = false;
      previewBox.className = `status-box ${kind}`;
      previewBody.innerHTML = bodyHtml;
    }

    function renderPreview(data) {
      const formats = Array.isArray(data.formats) ? data.formats : [];
      const thumbHtml = data.thumbnail
        ? `<img class="preview-thumb" src="${escapeHtml(data.thumbnail)}" alt="thumbnail">`
        : '<div class="preview-thumb" style="display:flex;align-items:center;justify-content:center;color:var(--muted);">No thumbnail</div>';
      const metaItems = [
        { label: 'Extractor', value: data.extractor || 'unknown' },
        { label: '時長', value: data.duration || '未知' },
        { label: '發布者', value: data.uploader || '未知' },
        { label: '狀態', value: data.is_live ? '直播 / 回放' : '普通媒體' },
      ];
      const formatsHtml = formats.length
        ? `
          <div class="format-list">
            ${formats.map((item) => `
              <button type="button" class="format-chip" data-format="${escapeHtml(item.selector || item.format_id || '')}">
                ${escapeHtml(item.label || item.format_id || '')}
              </button>
            `).join('')}
          </div>
          <p class="status-info" style="margin-top:12px;">
            點任一 format id 可自動填入「自定義格式」。若該格式只有視頻或音訊，建議仍使用「自動最佳」。
          </p>
        `
        : '<p class="status-info" style="margin-top:12px;">此站點未返回可展示的格式列表，可直接使用「自動最佳」。</p>';

      return `
        <div class="preview-layout">
          ${thumbHtml}
          <div class="preview-meta">
            <h4>${escapeHtml(data.title || 'Untitled')}</h4>
            <p class="status-info">原頁面: <code>${escapeHtml(data.webpage_url || '')}</code></p>
            <div class="preview-meta-grid">
              ${metaItems.map((item) => `
                <div class="preview-meta-item">
                  <strong>${escapeHtml(item.label)}</strong>
                  ${escapeHtml(item.value)}
                </div>
              `).join('')}
            </div>
            ${formatsHtml}
          </div>
        </div>
      `;
    }

    async function previewInfo() {
      const urlInput = document.getElementById('url');
      const previewBtn = document.getElementById('preview-btn');
      const cookiesInput = document.getElementById('cookies_file');
      if (!urlInput) return;

      const rawUrl = urlInput.value.trim();
      if (!rawUrl) {
        setPreviewState('error', '<p class="status-info">請先輸入 URL。</p>');
        return;
      }

      if (previewBtn) previewBtn.disabled = true;
      setPreviewState(
        'running',
        '<p class="status-info">正在用 yt-dlp 預解析 extractor、標題、封面與可用格式，通常幾秒內返回。</p>'
      );

      const formData = new FormData();
      formData.append('url', rawUrl);
      if (cookiesInput && cookiesInput.files && cookiesInput.files[0]) {
        formData.append('cookies_file', cookiesInput.files[0]);
      }

      try {
        const response = await fetch('/api/info', {
          method: 'POST',
          body: formData,
        });
        const data = await response.json().catch(() => ({}));
        if (!response.ok) {
          throw new Error(data.error || '預解析失敗');
        }
        setPreviewState('preview', renderPreview(data));
      } catch (error) {
        const message = error instanceof Error ? error.message : '預解析失敗';
        setPreviewState('error', `<p class="status-info">${escapeHtml(message)}</p>`);
      } finally {
        if (previewBtn) previewBtn.disabled = false;
      }
    }

    const previewBtn = document.getElementById('preview-btn');
    if (previewBtn) {
      previewBtn.addEventListener('click', previewInfo);
    }

    document.addEventListener('click', (event) => {
      const chip = event.target.closest('.format-chip');
      if (!chip) return;
      const selector = chip.getAttribute('data-format') || '';
      const customFormatInput = document.getElementById('custom_format');
      if (!selector || !customFormatInput) return;
      customFormatInput.value = selector;
      toggleAdvanced(true);
      customFormatInput.focus();
      customFormatInput.scrollIntoView({ behavior: 'smooth', block: 'center' });
    });

    const params = new URLSearchParams(window.location.search);
    if ((params.get('u') || params.get('url')) && previewBtn && !document.getElementById('task-id')) {
      previewInfo();
    }

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

# 7) nginx
write_nginx_http_only() {
cat > /etc/nginx/sites-available/ytweb.conf <<NG
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    client_max_body_size 4m;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:5001;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NG
}

write_nginx_https() {
cat > /etc/nginx/sites-available/ytweb.conf <<NG
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    client_max_body_size 4m;

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
    client_max_body_size 4m;

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
}

write_nginx_http_only

echo "[ytweb] enabling nginx site ytweb.conf ..."
ln -sf /etc/nginx/sites-available/ytweb.conf /etc/nginx/sites-enabled/ytweb.conf
nginx -t
systemctl reload nginx

# 8) https cert (first time / renew when needed)
if command -v certbot >/dev/null 2>&1; then
  echo "[ytweb] running certbot --nginx for $DOMAIN (errors ignored if already configured) ..."
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email || true
  if [ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] && [ -s "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]; then
    write_nginx_https
  fi
  nginx -t && systemctl reload nginx
else
  echo "[ytweb] certbot not found; please configure TLS certificate for $DOMAIN manually." >&2
fi

# 9) healthcheck script + cron
cat >/usr/local/sbin/check-ytweb.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if ! curl -fsS --max-time 5 http://127.0.0.1:5001/healthz >/dev/null; then
  systemctl restart ytweb.service
fi
SH
chmod +x /usr/local/sbin/check-ytweb.sh

# install cron.d entry (idempotent, avoids mutating root user crontab)
cat >/etc/cron.d/ytweb-healthcheck <<'CRON'
* * * * * root /usr/local/sbin/check-ytweb.sh
CRON
chmod 0644 /etc/cron.d/ytweb-healthcheck

echo "[ytweb] install done. open: https://$DOMAIN/"
echo "[ytweb] yt-dlp version in use: $YTDLP_VERSION"
echo "[ytweb] curl_cffi version: $("$V_PY" - <<'PY'
try:
    import curl_cffi
    print(curl_cffi.__version__)
except Exception:
    print("missing")
PY
)"
echo "[ytweb] ffmpeg path: $(command -v ffmpeg)"
sleep 2
curl -fsS http://127.0.0.1:5001/healthz >/dev/null
