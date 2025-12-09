#!/usr/bin/env bash
#
# pan.sh - 一鍵部署 SUENの網盤 (pan.bdfz.net 公共上傳/下載服務)
#  - Nginx + FastAPI + Uvicorn + SQLite (aiosqlite 異步)
#  - 流式上傳，避免整個文件讀入記憶體
#  - 上傳/下載記錄到 SQLite
#  - 上傳 & 下載 Telegram 通知 (httpx 異步)
#  - 上傳口令「必須」配置
#  - 每日自動清理過期文件 (systemd timer + cleanup.py)
#  - 內建 Let's Encrypt + 443，分兩階段配置避免「證書/配置死鎖」
#

set -Eeuo pipefail
INSTALLER_VERSION="pan-install-2025-12-09-v6"

DOMAIN="pan.bdfz.net"
APP_USER="panuser"
APP_DIR="/opt/pan-app"
DATA_DIR="/srv/pan"
TMP_DIR="${DATA_DIR}/tmp"
SERVICE_NAME="pan"
PYTHON_BIN="python3"

NGINX_SITE_AVAIL="/etc/nginx/sites-available/${SERVICE_NAME}.conf"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/${SERVICE_NAME}.conf"

SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"
SYSTEMD_CLEANUP_SERVICE="/etc/systemd/system/${SERVICE_NAME}-cleanup.service"
SYSTEMD_CLEANUP_TIMER="/etc/systemd/system/${SERVICE_NAME}-cleanup.timer"

echo "[*] Installer version: ${INSTALLER_VERSION}"

log() {
  local level="$1"; shift
  printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$level" "$*" >&2
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    log ERROR "請以 root 執行此腳本"
    exit 1
  fi
}

check_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  else
    log ERROR "無法檢測系統版本（缺少 /etc/os-release）"
    exit 1
  fi

  case "$ID" in
    ubuntu|debian)
      log INFO "已檢測到支援的系統：$PRETTY_NAME"
      ;;
    *)
      log ERROR "目前只支援 Ubuntu/Debian 系列（檢測到：$PRETTY_NAME）"
      exit 1
      ;;
  esac
}

ask_overwrite_var() {
  local var_name="$1"
  local current_value="$2"
  local default_answer="${3:-n}"

  read -r -p "檢測到已有 ${var_name}=${current_value}，是否修改？ [y/N] " ans || true
  ans="${ans:-${default_answer}}"
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    read -r -p "請輸入新的 ${var_name} 值: " new_value || true
    if [[ -n "${new_value}" ]]; then
      printf '%s' "$new_value"
      return 0
    fi
  fi
  printf '%s' "$current_value"
}

detect_existing_env() {
  if [[ -f "${APP_DIR}/.env" ]]; then
    log INFO "檢測到已存在的 ${APP_DIR}/.env，嘗試讀取配置以支援覆蓋安裝"
    set -a
    # shellcheck disable=SC1090
    . "${APP_DIR}/.env"
    set +a

    if [[ -n "${PAN_DOMAIN:-}" ]]; then
      DOMAIN="$(ask_overwrite_var "PAN_DOMAIN" "${PAN_DOMAIN}")"
    fi
    if [[ -n "${PAN_DATA_DIR:-}" ]]; then
      DATA_DIR="$(ask_overwrite_var "PAN_DATA_DIR" "${PAN_DATA_DIR}")"
    fi
    if [[ -n "${PAN_TMP_DIR:-}" ]]; then
      TMP_DIR="$(ask_overwrite_var "PAN_TMP_DIR" "${PAN_TMP_DIR}")"
    else
      TMP_DIR="${DATA_DIR}/tmp"
    fi
  else
    log INFO "未檢測到舊的 .env，將使用腳本內預設配置"
  fi
}

kill_previous_processes() {
  log INFO "嘗試停止之前的服務與進程..."

  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
    systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
  fi

  pkill -f "${APP_DIR}/venv/bin/uvicorn app:app" 2>/dev/null || true
  pkill -f "uvicorn app:app" 2>/dev/null || true
}

install_packages() {
  log INFO "更新套件索引..."
  apt-get update -y

  log INFO "安裝必要套件: nginx, python3, pip, venv, sqlite3, certbot..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    nginx \
    "${PYTHON_BIN}" \
    python3-venv \
    python3-pip \
    sqlite3 \
    curl \
    ca-certificates \
    certbot \
    python3-certbot-nginx \
    jq
}

create_app_user_and_dirs() {
  if ! id -u "${APP_USER}" &>/dev/null; then
    log INFO "創建系統用戶 ${APP_USER} (無登入權限)..."
    useradd --system --no-create-home --shell /usr/sbin/nologin "${APP_USER}"
  else
    log INFO "系統用戶 ${APP_USER} 已存在"
  fi

  log INFO "創建應用與數據目錄..."
  mkdir -p "${APP_DIR}"
  mkdir -p "${DATA_DIR}/uploads"
  mkdir -p "${TMP_DIR}"
  mkdir -p "${DATA_DIR}/db"
  mkdir -p "${DATA_DIR}/logs"

  chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}" "${DATA_DIR}"
  chmod 750 "${APP_DIR}" "${DATA_DIR}"
}

write_env_file() {
  log INFO "生成 .env 配置 (${APP_DIR}/.env)"

  local secret_key upload_secret max_age telegram_chat telegram_token
  secret_key="$(openssl rand -hex 32)"

  # 上傳口令必須存在
  if [[ -n "${PAN_UPLOAD_SECRET:-}" ]]; then
    upload_secret="${PAN_UPLOAD_SECRET}"
    log INFO "沿用現有 PAN_UPLOAD_SECRET。"
  elif [[ -n "${UPLOAD_SECRET:-}" ]]; then
    upload_secret="${UPLOAD_SECRET}"
    log INFO "從環境變量 UPLOAD_SECRET 讀取上傳口令。"
  else
    upload_secret=""
    while [[ -z "${upload_secret}" ]]; do
      read -r -s -p "請輸入上傳口令（必填，輸入後回車）： " upload_secret || true
      echo
      if [[ -z "${upload_secret}" ]]; then
        log ERROR "上傳口令不可為空，請重新輸入。"
      fi 
    done
  fi
  

  if [[ -n "${MAX_FILE_AGE_DAYS:-}" ]]; then
    max_age="${MAX_FILE_AGE_DAYS}"
  else
    max_age="7"
  fi

  telegram_chat="${PAN_TELEGRAM_CHAT_ID:-${TELEGRAM_CHAT_ID:-}}"
  telegram_token="${PAN_TELEGRAM_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"

  cat > "${APP_DIR}/.env" <<ENV
PAN_DOMAIN="${DOMAIN}"
PAN_DATA_DIR="${DATA_DIR}"
PAN_UPLOAD_DIR="${DATA_DIR}/uploads"
PAN_TMP_DIR="${TMP_DIR}"
PAN_DB_PATH="${DATA_DIR}/db/pan.db"
PAN_LOG_PATH="${DATA_DIR}/logs/app.log"

PAN_SECRET_KEY="${secret_key}"

PAN_UPLOAD_SECRET="${upload_secret}"
PAN_MAX_FILE_AGE_DAYS="${max_age}"

PAN_TELEGRAM_BOT_TOKEN="${telegram_token}"
PAN_TELEGRAM_CHAT_ID="${telegram_chat}"

PAN_MAX_UPLOAD_SIZE_MB="10240"
PAN_MAX_DOWNLOAD_SIZE_MB="0"
ENV

  chown "${APP_USER}:${APP_USER}" "${APP_DIR}/.env"
  chmod 600 "${APP_DIR}/.env"
}

create_venv_and_install_deps() {
  log INFO "創建 Python venv 並安裝依賴..."

  if [[ ! -d "${APP_DIR}/venv" ]]; then
    sudo -u "${APP_USER}" -H "${PYTHON_BIN}" -m venv "${APP_DIR}/venv"
  fi

  local pip_bin
  pip_bin="${APP_DIR}/venv/bin/pip"

  "${pip_bin}" install --upgrade pip wheel

  # ★ 這裡新增 python-multipart 依賴，解決 FastAPI 上傳解析錯誤 ★
  cat > "${APP_DIR}/requirements.txt" <<'REQ'
fastapi>=0.115.0
uvicorn[standard]==0.30.6
python-dotenv==1.0.1
aiosqlite==0.20.0
httpx==0.27.2
python-multipart==0.0.9
REQ

  chown "${APP_USER}:${APP_USER}" "${APP_DIR}/requirements.txt"
  sudo -u "${APP_USER}" -H "${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/requirements.txt"
}

write_app_main() {
  log INFO "寫入 FastAPI 主程式 app.py"

  cat > "${APP_DIR}/app.py" <<'PY'
import os
import uuid
from datetime import datetime, timedelta
from typing import Optional, List

import aiosqlite
from fastapi import FastAPI, UploadFile, File, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, StreamingResponse
from urllib.parse import quote
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from dotenv import load_dotenv
import httpx

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DOTENV_PATH = os.path.join(BASE_DIR, ".env")
load_dotenv(DOTENV_PATH)

PAN_DOMAIN = os.getenv("PAN_DOMAIN", "localhost")
PAN_UPLOAD_DIR = os.getenv("PAN_UPLOAD_DIR", "/srv/pan/uploads")
PAN_TMP_DIR = os.getenv("PAN_TMP_DIR", "/srv/pan/tmp")
PAN_DB_PATH = os.getenv("PAN_DB_PATH", "/srv/pan/db/pan.db")
PAN_LOG_PATH = os.getenv("PAN_LOG_PATH", "/srv/pan/logs/app.log")

PAN_UPLOAD_SECRET = os.getenv("PAN_UPLOAD_SECRET", "")
PAN_MAX_FILE_AGE_DAYS = int(os.getenv("PAN_MAX_FILE_AGE_DAYS", "7"))
PAN_MAX_UPLOAD_SIZE_MB = int(os.getenv("PAN_MAX_UPLOAD_SIZE_MB", "10240"))
PAN_MAX_DOWNLOAD_SIZE_MB = int(os.getenv("PAN_MAX_DOWNLOAD_SIZE_MB", "0"))

PAN_TELEGRAM_BOT_TOKEN = os.getenv("PAN_TELEGRAM_BOT_TOKEN", "")
PAN_TELEGRAM_CHAT_ID = os.getenv("PAN_TELEGRAM_CHAT_ID", "")

os.makedirs(PAN_UPLOAD_DIR, exist_ok=True)
os.makedirs(PAN_TMP_DIR, exist_ok=True)
os.makedirs(os.path.dirname(PAN_DB_PATH), exist_ok=True)
os.makedirs(os.path.dirname(PAN_LOG_PATH), exist_ok=True)

app = FastAPI(
    title="SUEN Pan Service",
    description="公共上傳/下載服務",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[f"https://{PAN_DOMAIN}", f"http://{PAN_DOMAIN}", "*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

UPLOAD_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS files (
    id TEXT PRIMARY KEY,
    original_name TEXT NOT NULL,
    stored_name TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    category TEXT,
    created_at TIMESTAMP NOT NULL,
    last_access TIMESTAMP,
    uploader_ip TEXT,
    notes TEXT
);
"""

async def init_db():
  async with aiosqlite.connect(PAN_DB_PATH) as db:
    await db.execute(UPLOAD_TABLE_SQL)
    await db.execute("CREATE INDEX IF NOT EXISTS idx_files_created_at ON files(created_at)")
    await db.execute("CREATE INDEX IF NOT EXISTS idx_files_category ON files(category)")
    await db.commit()

class RollingLogger:
  def __init__(self, path: str):
    self.path = path

  def log(self, level: str, msg: str):
    now = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{now}] [{level}] {msg}\n"
    try:
      with open(self.path, "a", encoding="utf-8") as f:
        f.write(line)
    except Exception:
      pass

logger = RollingLogger(PAN_LOG_PATH)

@app.on_event("startup")
async def on_startup():
  await init_db()
  if not PAN_UPLOAD_SECRET:
    logger.log("ERROR", "PAN_UPLOAD_SECRET 未配置，上傳將被拒絕。")

async def send_telegram_message(text: str):
  if not PAN_TELEGRAM_BOT_TOKEN or not PAN_TELEGRAM_CHAT_ID:
    return
  url = f"https://api.telegram.org/bot{PAN_TELEGRAM_BOT_TOKEN}/sendMessage"
  payload = {
    "chat_id": PAN_TELEGRAM_CHAT_ID,
    "text": text,
    "parse_mode": "HTML",
    "disable_web_page_preview": True,
  }
  try:
    async with httpx.AsyncClient(timeout=10) as client:
      await client.post(url, json=payload)
  except Exception as e:
    logger.log("WARN", f"Send TG failed: {e}")

def format_size(num: int) -> str:
  step = 1024.0
  for unit in ["B", "KB", "MB", "GB", "TB"]:
    if num < step:
      return f"{num:.1f}{unit}" if unit != "B" else f"{num}{unit}"
    num /= step
  return f"{num:.1f}PB"

def build_content_disposition(filename: str) -> str:
  """Return a Content-Disposition header value safe for non-ASCII filenames."""
  try:
    # If this passes, we can safely use a simple filename="..." form
    filename.encode("latin-1")
  except UnicodeEncodeError:
    # Use RFC 5987 encoding for non-ASCII
    quoted = quote(filename)
    return f"attachment; filename*=UTF-8''{quoted}"
  else:
    # ASCII / latin-1 only
    return f'attachment; filename="{filename}"'

def require_valid_upload_secret(secret: str):
  if not PAN_UPLOAD_SECRET:
    logger.log("ERROR", "嘗試上傳但 PAN_UPLOAD_SECRET 未配置。")
    raise HTTPException(status_code=500, detail="服務未配置上傳口令")
  if not secret or secret != PAN_UPLOAD_SECRET:
    raise HTTPException(status_code=403, detail="UPLOAD_SECRET 不正確")

async def insert_file_record(
  file_id: str,
  original_name: str,
  stored_name: str,
  size_bytes: int,
  category: Optional[str],
  uploader_ip: Optional[str],
):
  now = datetime.utcnow()
  async with aiosqlite.connect(PAN_DB_PATH) as db:
    await db.execute(
      "INSERT INTO files (id, original_name, stored_name, size_bytes, category, created_at, last_access, uploader_ip, notes) "
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      (file_id, original_name, stored_name, size_bytes, category or "", now, now, uploader_ip or "", ""),
    )
    await db.commit()

async def mark_access(file_id: str):
  now = datetime.utcnow()
  async with aiosqlite.connect(PAN_DB_PATH) as db:
    await db.execute(
      "UPDATE files SET last_access=? WHERE id=?",
      (now, file_id),
    )
    await db.commit()

async def fetch_file_record(file_id: str):
  async with aiosqlite.connect(PAN_DB_PATH) as db:
    db.row_factory = aiosqlite.Row
    cur = await db.execute("SELECT * FROM files WHERE id=?", (file_id,))
    row = await cur.fetchone()
    await cur.close()
    return row

async def query_all_files():
  async with aiosqlite.connect(PAN_DB_PATH) as db:
    db.row_factory = aiosqlite.Row
    cur = await db.execute("SELECT * FROM files ORDER BY created_at DESC")
    rows = await cur.fetchall()
    await cur.close()
    return rows

async def cleanup_expired_files():
  if PAN_MAX_FILE_AGE_DAYS <= 0:
    logger.log("INFO", "清理任務已禁用，因為 PAN_MAX_FILE_AGE_DAYS <= 0")
    return

  cutoff = datetime.utcnow() - timedelta(days=PAN_MAX_FILE_AGE_DAYS)
  deleted_count = 0
  total_freed = 0

  async with aiosqlite.connect(PAN_DB_PATH) as db:
    db.row_factory = aiosqlite.Row
    cur = await db.execute("SELECT * FROM files WHERE created_at < ?", (cutoff,))
    rows = await cur.fetchall()

    for row in rows:
      fid = row["id"]
      stored = row["stored_name"]
      size_bytes = row["size_bytes"]
      fpath = os.path.join(PAN_UPLOAD_DIR, stored)
      if os.path.exists(fpath):
        try:
          os.remove(fpath)
          deleted_count += 1
          total_freed += size_bytes
        except Exception as e:
          logger.log("WARN", f"刪除文件失敗 {fpath}: {e}")

    await db.execute("DELETE FROM files WHERE created_at < ?", (cutoff,))
    await db.commit()

  if deleted_count > 0:
    msg = f"清理過期文件：共刪除 {deleted_count} 個，釋放 {format_size(total_freed)}。"
    logger.log("INFO", msg)
    await send_telegram_message(f"[清理任務完成]\n{msg}")
  else:
    logger.log("INFO", "清理任務結束：沒有過期文件。")

@app.get("/ping")
async def ping():
  return {"status": "ok", "version": "1.0.0"}

def guess_category(filename: str) -> str:
  lower = filename.lower()
  if any(lower.endswith(ext) for ext in [".mp4", ".mkv", ".avi", ".mov", ".mp3", ".flac", ".wav"]):
    return "影音"
  if any(lower.endswith(ext) for ext in [".zip", ".rar", ".7z", ".tar", ".gz", ".bz2"]):
    return "壓縮包"
  if any(lower.endswith(ext) for ext in [".pdf", ".doc", ".docx", ".ppt", ".pptx", ".xls", ".xlsx"]):
    return "學術"
  if any(lower.endswith(ext) for ext in [".jpg", ".jpeg", ".png", ".gif", ".webp", ".tiff"]):
    return "圖片"
  return "其他"

@app.post("/upload")
async def upload_files(
  request: Request,
  upload_secret: str = Form(""),
  category: str = Form(""),
  files: List[UploadFile] = File(...),
):
  require_valid_upload_secret(upload_secret)

  client_ip = request.client.host if request.client else ""
  max_bytes = PAN_MAX_UPLOAD_SIZE_MB * 1024 * 1024
  total_received = 0

  saved_items = []

  for upload in files:
    orig_name = upload.filename or "unnamed"
    cat = category or guess_category(orig_name)

    file_uuid = str(uuid.uuid4())
    stored_name = f"{file_uuid}_{orig_name}"
    dest_path = os.path.join(PAN_UPLOAD_DIR, stored_name)

    size_bytes = 0
    with open(dest_path, "wb") as f:
      while True:
        chunk = await upload.read(1024 * 1024)
        if not chunk:
          break
        size_bytes += len(chunk)
        total_received += len(chunk)
        f.write(chunk)

        if max_bytes > 0 and total_received > max_bytes:
          f.close()
          try:
            os.remove(dest_path)
          except Exception:
            pass
          raise HTTPException(status_code=413, detail="超過服務器上傳限制")

    await insert_file_record(
      file_id=file_uuid,
      original_name=orig_name,
      stored_name=stored_name,
      size_bytes=size_bytes,
      category=cat,
      uploader_ip=client_ip,
    )

    saved_items.append({
      "id": file_uuid,
      "name": orig_name,
      "size": size_bytes,
      "category": cat,
    })

  if saved_items:
    lines = [f"<b>新上傳 {len(saved_items)} 個文件</b>"]
    for item in saved_items:
      size_str = format_size(item["size"])
      link = f"https://{PAN_DOMAIN}/d/{item['id']}/{item['name']}"
      lines.append(f"• {item['name']} ({size_str})\n{link}")
    await send_telegram_message("\n".join(lines))

  return {"ok": True, "files": saved_items}

@app.get("/d/{file_id}/{file_name}")
async def download_file(file_id: str, file_name: str):
  row = await fetch_file_record(file_id)
  if not row:
    raise HTTPException(status_code=404, detail="文件不存在")

  stored_name = row["stored_name"]
  path = os.path.join(PAN_UPLOAD_DIR, stored_name)
  if not os.path.exists(path):
    raise HTTPException(status_code=404, detail="文件已被刪除")

  await mark_access(file_id)

  size_bytes = os.path.getsize(path)
  if PAN_MAX_DOWNLOAD_SIZE_MB > 0:
    max_dl_bytes = PAN_MAX_DOWNLOAD_SIZE_MB * 1024 * 1024
    if size_bytes > max_dl_bytes:
      raise HTTPException(status_code=413, detail="文件過大，暫不允許直接下載")

  filename = row["original_name"] or file_name

  async def file_iterator(chunk_size: int = 1024 * 1024):
    with open(path, "rb") as f:
      while True:
        chunk = f.read(chunk_size)
        if not chunk:
          break
        yield chunk

  headers = {
    "Content-Disposition": build_content_disposition(filename)
  }

  return StreamingResponse(
    file_iterator(),
    media_type="application/octet-stream",
    headers=headers,
  )

@app.get("/list")
async def list_files():
  rows = await query_all_files()
  files = []
  for row in rows:
    files.append({
      "id": row["id"],
      "name": row["original_name"],
      "stored_name": row["stored_name"],
      "size_bytes": row["size_bytes"],
      "size_human": format_size(row["size_bytes"]),
      "category": row["category"] or "",
      "created_at": row["created_at"],
    })
  return {"files": files}

@app.post("/cleanup")
async def trigger_cleanup():
  await cleanup_expired_files()
  return {"ok": True}

TEMPLATES_DIR = os.path.join(BASE_DIR, "templates")
STATIC_DIR = os.path.join(BASE_DIR, "static")
os.makedirs(TEMPLATES_DIR, exist_ok=True)
os.makedirs(STATIC_DIR, exist_ok=True)

app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

INDEX_HTML_PATH = os.path.join(TEMPLATES_DIR, "index.html")
if not os.path.exists(INDEX_HTML_PATH):
  with open(INDEX_HTML_PATH, "w", encoding="utf-8") as f:
    f.write("<!DOCTYPE html><html><body>初始模板尚未生成，請重新部署。</body></html>")

@app.get("/", response_class=HTMLResponse)
async def index():
  with open(INDEX_HTML_PATH, "r", encoding="utf-8") as f:
    return HTMLResponse(content=f.read(), status_code=200)
PY

  chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}/app.py"
}

write_templates_html() {
  log INFO "寫入前端模板 templates/index.html"

  mkdir -p "${APP_DIR}/templates"
  cat > "${APP_DIR}/templates/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="zh-Hant">
<head>
  <meta charset="UTF-8" />
  <title>SUEN の 網盤 - 上傳 / 下載</title>
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <style>
    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
    }

    body {
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: radial-gradient(circle at top, #1f2933 0, #0b1015 45%, #020409 100%);
      color: #e5e7eb;
      min-height: 100vh;
      display: flex;
      align-items: stretch;
      justify-content: center;
      padding: 32px 16px;
    }

    .page-wrapper {
      width: 100%;
      max-width: 1200px;
      display: flex;
      flex-direction: column;
      gap: 16px;
    }

    .page-header {
      display: flex;
      flex-direction: column;
      gap: 6px;
    }

    .title-row {
      display: flex;
      align-items: baseline;
      gap: 8px;
      flex-wrap: wrap;
    }

    .title-row h1 {
      font-size: 1.6rem;
      font-weight: 700;
      letter-spacing: 0.03em;
    }

    .main-grid {
      display: grid;
      grid-template-columns: minmax(0, 1.1fr) minmax(0, 1.4fr);
      gap: 16px;
      align-items: flex-start;
    }

    @media (max-width: 880px) {
      .main-grid {
        grid-template-columns: minmax(0, 1fr);
      }
    }

    .card {
      background: radial-gradient(circle at top left, #101827 0, #020617 55%, #020617 100%);
      border-radius: 18px;
      border: 1px solid rgba(148, 163, 184, 0.45);
      box-shadow:
        0 18px 60px rgba(15, 23, 42, 0.9),
        0 0 0 1px rgba(15, 23, 42, 0.9);
      position: relative;
      overflow: hidden;
    }

    .card::before {
      content: "";
      position: absolute;
      inset: -40%;
      background:
        radial-gradient(circle at 10% 0, rgba(56, 189, 248, 0.16) 0, transparent 50%),
        radial-gradient(circle at 100% 100%, rgba(22, 163, 74, 0.12) 0, transparent 48%);
      mix-blend-mode: screen;
      opacity: 0.8;
      pointer-events: none;
    }

    .card-inner {
      position: relative;
      padding: 18px 18px 20px;
      display: flex;
      flex-direction: column;
      gap: 14px;
      z-index: 1;
    }

    .card-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      margin-bottom: 4px;
    }

    .card-title {
      display: flex;
      flex-direction: column;
      gap: 2px;
    }

    .card-title h2 {
      font-size: 1.05rem;
      font-weight: 600;
      letter-spacing: 0.04em;
      text-transform: uppercase;
    }

    .card-subtitle {
      font-size: 0.8rem;
      color: #9ca3af;
    }

    .pill-badge {
      border-radius: 999px;
      padding: 3px 10px;
      font-size: 0.8rem;
      border: 1px solid rgba(96, 165, 250, 0.6);
      background: linear-gradient(to right, rgba(37, 99, 235, 0.18), rgba(22, 163, 74, 0.18));
      color: #d1fae5;
      white-space: nowrap;
    }

    .upload-dropzone {
      border-radius: 12px;
      border: 1px dashed rgba(148, 163, 184, 0.7);
      background: radial-gradient(circle at top left, rgba(15, 118, 110, 0.16), rgba(15, 23, 42, 0.85));
      padding: 14px 12px;
      display: flex;
      flex-direction: column;
      gap: 10px;
      cursor: pointer;
      transition: border-color 0.15s ease, background-color 0.15s ease, box-shadow 0.15s ease;
    }

    .upload-dropzone.dragover {
      border-color: rgba(56, 189, 248, 0.9);
      box-shadow: 0 0 0 1px rgba(56, 189, 248, 0.5);
      background: radial-gradient(circle at top left, rgba(34, 197, 235, 0.18), rgba(15, 23, 42, 0.9));
    }

    .upload-top-row {
      display: flex;
      align-items: center;
      gap: 9px;
      justify-content: space-between;
    }

    .upload-main-copy {
      display: flex;
      flex-direction: column;
      gap: 3px;
    }

    .upload-main-copy-title {
      font-size: 0.95rem;
      font-weight: 500;
    }

    .upload-main-copy-sub {
      font-size: 0.8rem;
      color: #9ca3af;
    }

    .upload-buttons-row {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      align-items: center;
    }

    .btn {
      border-radius: 999px;
      border: none;
      padding: 6px 14px;
      font-size: 0.85rem;
      font-weight: 500;
      cursor: pointer;
      background: linear-gradient(to right, #22c55e, #16a34a);
      color: #ecfdf5;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      box-shadow:
        0 0 0 1px rgba(34, 197, 94, 0.4),
        0 10px 25px rgba(22, 163, 74, 0.6);
      transition: transform 0.12s ease, box-shadow 0.12s ease, filter 0.12s ease;
      white-space: nowrap;
    }

    .btn.secondary {
      background: rgba(15, 23, 42, 0.9);
      color: #e5e7eb;
      box-shadow:
        0 0 0 1px rgba(148, 163, 184, 0.5),
        0 10px 20px rgba(15, 23, 42, 0.9);
    }

    .btn:hover {
      transform: translateY(-1px);
      filter: brightness(1.05);
    }

    .btn:active {
      transform: translateY(0);
      box-shadow:
        0 0 0 1px rgba(34, 197, 94, 0.5),
        0 6px 15px rgba(22, 163, 74, 0.8);
    }

    .btn-icon {
      font-size: 1rem;
    }

    .upload-preview {
      font-size: 0.8rem;
      color: #cbd5f5;
      margin-top: 2px;
    }

    .upload-preview strong {
      color: #e5e7eb;
    }

    .upload-meta-row {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 8px;
      margin-top: 6px;
    }

    .upload-meta-row label {
      font-size: 0.8rem;
      color: #9ca3af;
    }

    .upload-meta-row select,
    .upload-meta-row input[type="password"] {
      background: rgba(15, 23, 42, 0.95);
      color: #e5e7eb;
      border-radius: 999px;
      border: 1px solid rgba(148, 163, 184, 0.6);
      padding: 3px 10px;
      font-size: 0.8rem;
      outline: none;
    }

    .upload-meta-row select:focus,
    .upload-meta-row input[type="password"]:focus {
      border-color: rgba(56, 189, 248, 0.8);
      box-shadow: 0 0 0 1px rgba(56, 189, 248, 0.5);
    }

    .upload-progress-shell {
      margin-top: 10px;
      font-size: 0.8rem;
      color: #e5e7eb;
      display: flex;
      flex-direction: column;
      gap: 4px;
    }

    .progress-bar-bg {
      position: relative;
      height: 6px;
      border-radius: 999px;
      background: rgba(15, 23, 42, 0.9);
      overflow: hidden;
      border: 1px solid rgba(55, 65, 81, 0.9);
    }

    .progress-bar-fill {
      position: absolute;
      inset: 0;
      width: 0%;
      background: linear-gradient(
        90deg,
        rgba(52, 211, 153, 0.1),
        rgba(52, 211, 153, 0.9),
        rgba(56, 189, 248, 0.9)
      );
      box-shadow: 0 0 18px rgba(56, 189, 248, 0.7);
      transition: width 0.12s ease-out;
    }

    .upload-progress-text {
      font-size: 0.78rem;
      color: #9ca3af;
    }

    .upload-bottom-row {
      display: flex;
      align-items: center;
      justify-content: flex-end;
      gap: 10px;
      margin-top: 6px;
    }

    .upload-bottom-right {
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .btn-cancel {
      background: transparent;
      border-radius: 999px;
      border: 1px solid rgba(248, 113, 113, 0.76);
      color: #fecaca;
      padding: 4px 10px;
      font-size: 0.78rem;
      cursor: pointer;
    }

    .btn-cancel:hover {
      background: rgba(127, 29, 29, 0.85);
    }

    .btn-muted {
      background: transparent;
      border-radius: 999px;
      border: 1px solid rgba(148, 163, 184, 0.5);
      color: #9ca3af;
      padding: 4px 10px;
      font-size: 0.78rem;
      cursor: pointer;
    }

    .btn-muted:hover {
      border-color: rgba(148, 163, 184, 0.9);
      color: #e5e7eb;
    }

    .file-area {
      margin-top: 4px;
      border-radius: 12px;
      background: linear-gradient(to bottom, rgba(15, 23, 42, 0.95), rgba(15, 23, 42, 0.98));
      border: 1px solid rgba(31, 41, 55, 0.9);
      max-height: 480px;
      overflow-y: auto;
      scrollbar-width: thin;
      scrollbar-color: #4b5563 #020617;
    }

    .file-area::-webkit-scrollbar {
      width: 8px;
    }

    .file-area::-webkit-scrollbar-thumb {
      background: #4b5563;
      border-radius: 999px;
    }

    .file-area::-webkit-scrollbar-track {
      background: #020617;
    }

    .category-block {
      padding: 8px 10px 6px;
      border-bottom: 1px solid rgba(31, 41, 55, 0.9);
    }

    .category-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      margin-bottom: 4px;
    }

    .category-title {
      font-size: 0.85rem;
      font-weight: 500;
      letter-spacing: 0.04em;
      text-transform: uppercase;
      color: #9ca3af;
      display: flex;
      align-items: center;
      gap: 6px;
    }

    .category-count {
      font-size: 0.75rem;
      color: #6b7280;
    }

    .category-list {
      list-style: none;
      display: flex;
      flex-direction: column;
      gap: 2px;
      margin-top: 4px;
    }

    .category-list-item {
      font-size: 0.8rem;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 6px;
      padding: 3px 6px;
      border-radius: 8px;
      cursor: default;
      transition: background 0.1s ease;
    }

    .category-list-item:hover {
      background: rgba(15, 23, 42, 0.9);
    }

    .item-main {
      display: flex;
      align-items: center;
      gap: 8px;
      flex: 1;
      min-width: 0;
    }

    .item-main a {
      color: #e5e7eb;
      text-decoration: none;
      word-break: break-all;
    }

    .item-main a:hover {
      text-decoration: underline;
      color: #a5b4fc;
    }

    .item-meta {
      display: flex;
      align-items: center;
      gap: 8px;
      white-space: nowrap;
      font-size: 0.78rem;
      color: #9ca3af;
    }

    .btn-share {
      border-radius: 999px;
      border: 1px solid rgba(148, 163, 184, 0.6);
      background: transparent;
      color: #e5e7eb;
      padding: 2px 8px;
      font-size: 0.75rem;
      cursor: pointer;
    }

    .btn-share:hover {
      border-color: rgba(56, 189, 248, 0.9);
      color: #a5b4fc;
    }

    .download-progress-text {
      font-size: 0.78rem;
      color: #9ca3af;
      padding: 6px 10px 8px;
    }

    .search-box-wrap {
      position: relative;
      width: 100%;
    }

    .search-input {
      width: 100%;
      border-radius: 999px;
      border: 1px solid rgba(148, 163, 184, 0.55);
      padding: 6px 28px 6px 26px;
      font-size: 0.82rem;
      background: rgba(15, 23, 42, 0.95);
      color: #e5e7eb;
      outline: none;
    }

    .search-input::placeholder {
      color: #6b7280;
    }

    .search-input:focus {
      border-color: rgba(56, 189, 248, 0.9);
      box-shadow: 0 0 0 1px rgba(56, 189, 248, 0.5);
    }

    .search-icon-symbol {
      position: absolute;
      top: 50%;
      left: 8px;
      transform: translateY(-50%);
      font-size: 0.85rem;
      color: #6b7280;
      pointer-events: none;
    }
  </style>
</head>
<body>
  <div class="page-wrapper">
    <header class="page-header">
      <div class="title-row">
        <h1>SUEN の 網盤</h1>
      </div>
    </header>

    <main class="main-grid">
      <section>
        <div class="card">
          <div class="card-inner">
            <div class="card-header">
              <div class="card-title">
                <h2>上傳區</h2>
              </div>
              <div class="pill-badge">STREAMING UPLOAD</div>
            </div>

            <div id="upload-dropzone" class="upload-dropzone">
              <div class="upload-top-row">
                <div class="upload-main-copy">
                </div>
              </div>

              <div class="upload-buttons-row" style="margin-top:4px;">
                <button type="button" class="btn" id="btn-sel-file">
                  <span class="btn-icon">📄</span><span>選擇文件</span>
                </button>
                <button type="button" class="btn secondary" id="btn-sel-folder">
                  <span class="btn-icon">📁</span><span>選擇資料夾</span>
                </button>
              </div>

              <input type="file" id="file-input-files" multiple style="display:none;" />
              <input type="file" id="file-input-folder" webkitdirectory directory multiple style="display:none;" />

              <div id="upload-preview" class="upload-preview">
                尚未選擇文件。
              </div>

              <div class="upload-meta-row">
                <label for="category-select">分類：</label>
                <select id="category-select">
                  <option value="高考">高考</option>
                  <option value="學術">學術</option>
                  <option value="影音">影音</option>
                  <option value="壓縮包">壓縮包</option>
                  <option value="圖片">圖片</option>
                  <option value="其他">其他</option>
                </select>

                <label for="upload-secret">上傳口令：</label>
                <input type="password" id="upload-secret" />
              </div>
            </div>

            <div class="upload-progress-shell">
              <div class="progress-bar-bg">
                <div id="progress-bar-fill" class="progress-bar-fill"></div>
              </div>
              <div id="upload-progress-text" class="upload-progress-text">
                暫無上傳任務。
              </div>
            </div>

            <div class="upload-bottom-row">
              <div class="upload-bottom-right">
                <button type="button" class="btn-muted" id="btn-refresh-list">刷新列表</button>
                <button type="button" class="btn-cancel" id="btn-cancel">取消上傳</button>
                <button type="button" class="btn" id="btn-upload">
                  <span class="btn-icon">⬆️</span><span>開始上傳</span>
                </button>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section>
        <div class="card">
          <div class="card-inner" style="position:relative;">
            <div style="display:flex;align-items:center;gap:8px;margin-bottom:12px;">
              <div class="search-box-wrap" style="flex:1;">
                <span class="search-icon-symbol">🔍</span>
                <input type="text" id="search-input" class="search-input" placeholder="全局搜索..." />
              </div>
              <button type="button" id="btn-refresh" style="white-space:nowrap;padding:6px 12px;font-size:0.8rem;">刷新</button>
            </div>

            <div id="file-area-container">
              <div class="file-area">
                <div id="download-status" class="download-progress-text" style="text-align:center;">正在載入...</div>
              </div>
            </div>
          </div>
        </div>
      </section>
    </main>
  </div>

  <script>
    (function () {
      "use strict";

      const API_BASE = "";
      let selectedFiles = [];
      let currentUploadXHR = null;
      let uploadStartTime = null;
      let allFilesCache = [];

      function formatBytes(bytes) {
        if (!bytes || bytes <= 0) return "0B";
        const k = 1024;
        const sizes = ["B", "KB", "MB", "GB", "TB"];
        const i = Math.floor(Math.log(bytes) / Math.log(k));
        const v = bytes / Math.pow(k, i);
        return (i === 0 ? v.toFixed(0) : v.toFixed(1)) + sizes[i];
      }

      function formatSpeed(bytesPerSec) {
        if (!bytesPerSec || bytesPerSec <= 0) return "0B/s";
        return formatBytes(bytesPerSec) + "/s";
      }

      function formatETA(seconds) {
        if (!seconds || seconds <= 0 || !isFinite(seconds)) return "剩餘時間未知";
        const s = Math.round(seconds);
        const m = Math.floor(s / 60);
        const sec = s % 60;
        if (m > 0) {
          return `約 ${m} 分 ${sec} 秒`;
        }
        return `約 ${sec} 秒`;
      }

      function setStatus(id, text) {
        const el = document.getElementById(id);
        if (!el) return;
        el.textContent = text;
      }

      function updateUploadPreview() {
        const preview = document.getElementById("upload-preview");
        if (!selectedFiles.length) {
          preview.innerHTML = "尚未選擇文件。";
          return;
        }
        let totalSize = 0;
        for (const f of selectedFiles) {
          totalSize += f.size || 0;
        }
        const count = selectedFiles.length;
        preview.innerHTML =
          `已選擇 <strong>${count}</strong> 項，合計 <strong>${formatBytes(totalSize)}</strong>。`;
      }

      function attachFileInputHandlers() {
        const fileInput = document.getElementById("file-input-files");
        const folderInput = document.getElementById("file-input-folder");
        const btnFile = document.getElementById("btn-sel-file");
        const btnFolder = document.getElementById("btn-sel-folder");

        btnFile.addEventListener("click", () => fileInput.click());
        btnFolder.addEventListener("click", () => folderInput.click());

        function handleFiles(e) {
          const files = Array.from(e.target.files || []);
          if (!files.length) return;
          for (const f of files) {
            selectedFiles.push(f);
          }
          updateUploadPreview();
        }

        fileInput.addEventListener("change", handleFiles);
        folderInput.addEventListener("change", handleFiles);
      }

      function attachDropzoneHandlers() {
        const dz = document.getElementById("upload-dropzone");
        ["dragenter", "dragover"].forEach(evtName => {
          dz.addEventListener(evtName, (e) => {
            e.preventDefault();
            e.stopPropagation();
            dz.classList.add("dragover");
          });
        });

        ["dragleave", "drop"].forEach(evtName => {
          dz.addEventListener(evtName, (e) => {
            e.preventDefault();
            e.stopPropagation();
            dz.classList.remove("dragover");
          });
        });

        dz.addEventListener("drop", (e) => {
          const dt = e.dataTransfer;
          if (!dt) return;
          const fileList = Array.from(dt.files || []);
          if (!fileList.length) return;
          for (const f of fileList) {
            selectedFiles.push(f);
          }
          updateUploadPreview();
        });
      }

      async function loadFiles() {
        try {
          setStatus("download-status", "正在載入...");
          const resp = await fetch(`${API_BASE}/list`);
          if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
          const data = await resp.json();
          allFilesCache = data.files || [];
          renderFileList(allFilesCache);
          setStatus("download-status", `共 ${allFilesCache.length} 個附件。`);
        } catch (err) {
          console.error("loadFiles error:", err);
          const container = document.getElementById("file-area-container");
          container.innerHTML = `
            <div class="file-area">
              <div id="download-status" class="download-progress-text">載入列表時出錯，請稍後重試。</div>
            </div>
          `;
        }
      }

      function renderFileList(files) {
        const container = document.getElementById("file-area-container");
        container.innerHTML = "";

        const searchInput = document.getElementById("search-input");
        const searchVal = (searchInput && searchInput.value ? searchInput.value : "").trim().toLowerCase();

        let filtered = files;
        if (searchVal) {
          filtered = files.filter(f => (f.name || "").toLowerCase().includes(searchVal));
        }

        const byCat = {};
        for (const f of filtered) {
          const cat = f.category || "其他";
          if (!byCat[cat]) byCat[cat] = [];
          byCat[cat].push(f);
        }

        const fixedCategories = ["高考", "學術", "影音", "壓縮包", "圖片", "其他"];
        const orderCats = [];

        for (const c of fixedCategories) {
          if (byCat[c] && byCat[c].length) orderCats.push(c);
        }

        const extraCats = Object.keys(byCat)
          .filter(c => !fixedCategories.includes(c));
        extraCats.sort();
        for (const c of extraCats) {
          orderCats.push(c);
        }

        const area = document.createElement("div");
        area.className = "file-area";

        if (!orderCats.length) {
          const empty = document.createElement("div");
          empty.className = "download-progress-text";
          empty.style.textAlign = "center";
          empty.textContent = "目前沒有可用附件。";
          area.appendChild(empty);
        } else {
          for (const cat of orderCats) {
            const list = byCat[cat];
            area.appendChild(renderCategorySection(cat, list));
          }
        }

        const statusBar = document.createElement("div");
        statusBar.id = "download-status";
        statusBar.className = "download-progress-text";
        statusBar.textContent = "";

        container.appendChild(area);
        container.appendChild(statusBar);
      }

      function renderCategorySection(catName, fileList) {
        const block = document.createElement("div");
        block.className = "category-block";

        const header = document.createElement("div");
        header.className = "category-header";

        const title = document.createElement("div");
        title.className = "category-title";
        title.textContent = catName;

        const count = document.createElement("div");
        count.className = "category-count";
        count.textContent = `${fileList.length} 項`;

        header.appendChild(title);
        header.appendChild(count);

        const ul = document.createElement("ul");
        ul.className = "category-list";

        fileList.forEach(f => {
          const li = document.createElement("li");
          li.className = "category-list-item";

          const main = document.createElement("div");
          main.className = "item-main";

          const link = document.createElement("a");
          const name = f.name || f.stored_name || f.id;
          const encodedName = encodeURIComponent(name);
          link.href = `/d/${encodeURIComponent(f.id)}/${encodedName}`;
          link.textContent = name;
          link.target = "_blank";
          main.appendChild(link);

          const meta = document.createElement("div");
          meta.className = "item-meta";
          const sizeSpan = document.createElement("span");
          sizeSpan.textContent = f.size_human || formatBytes(f.size_bytes || 0);
          meta.appendChild(sizeSpan);

          const btn = document.createElement("button");
          btn.type = "button";
          btn.className = "btn-share";
          btn.textContent = "複製";
          btn.addEventListener("click", () => {
            const fullUrl = `${location.protocol}//${location.host}/d/${encodeURIComponent(f.id)}/${encodeURIComponent(name)}`;
            navigator.clipboard.writeText(fullUrl)
              .then(() => setStatus("download-status", "已複製分享鏈接。"))
              .catch(() => setStatus("download-status", "複製失敗，請手動複製。"));
          });

          li.appendChild(main);
          li.appendChild(meta);
          li.appendChild(btn);

          ul.appendChild(li);
        });

        block.appendChild(header);
        block.appendChild(ul);
        return block;
      }

      function resetProgress() {
        const bar = document.getElementById("progress-bar-fill");
        if (bar) bar.style.width = "0%";
        setStatus("upload-progress-text", "暫無上傳任務。");
      }

      function startUpload() {
        if (currentUploadXHR) {
          alert("已有上傳任務正在進行。");
          return;
        }

        if (!selectedFiles.length) {
          alert("請先選擇文件或資料夾。");
          return;
        }

        const secretInput = document.getElementById("upload-secret");
        const categorySelect = document.getElementById("category-select");

        const secret = secretInput ? secretInput.value.trim() : "";
        if (!secret) {
          alert("請先輸入口令。");
          return;
        }

        const category = categorySelect ? categorySelect.value : "";

        const formData = new FormData();
        formData.append("upload_secret", secret);
        formData.append("category", category);
        for (const f of selectedFiles) {
          formData.append("files", f);
        }

        const xhr = new XMLHttpRequest();
        currentUploadXHR = xhr;
        uploadStartTime = Date.now();

        const bar = document.getElementById("progress-bar-fill");

        xhr.upload.onprogress = (event) => {
          if (!event.lengthComputable) return;
          const loaded = event.loaded;
          const total = event.total;
          const now = Date.now();
          const elapsedSec = (now - uploadStartTime) / 1000;
          const speed = elapsedSec > 0 ? loaded / elapsedSec : 0;
          const remaining = total - loaded;
          const etaSec = speed > 0 ? remaining / speed : 0;

          const percent = total > 0 ? (loaded / total) * 100 : 0;
          if (bar) {
            bar.style.width = `${percent.toFixed(1)}%`;
          }

          setStatus(
            "upload-progress-text",
            `已上傳 ${percent.toFixed(1)}% · ${formatBytes(loaded)} / ${formatBytes(total)} · ${formatSpeed(speed)} · ${formatETA(etaSec)}`
          );
        };

        xhr.onreadystatechange = () => {
          if (xhr.readyState !== XMLHttpRequest.DONE) return;
          const ok = xhr.status >= 200 && xhr.status < 300;
          if (ok) {
            try {
              const data = JSON.parse(xhr.responseText || "{}");
              const count = (data.files || []).length;
              setStatus("upload-progress-text", count > 0 ? `上傳完成，共 ${count} 項。` : "上傳完成。");
            } catch {
              setStatus("upload-progress-text", "上傳完成。");
            }
            selectedFiles = [];
            updateUploadPreview();
            loadFiles();
          } else {
            let msg = "上傳失敗。";
            try {
              const data = JSON.parse(xhr.responseText || "{}");
              if (data.detail) msg = `上傳失敗：${data.detail}`;
            } catch (_) {}
            setStatus("upload-progress-text", msg);
          }
          currentUploadXHR = null;
          uploadStartTime = null;
          if (bar) bar.style.width = "0%";
        };

        xhr.onerror = () => {
          setStatus("upload-progress-text", "上傳出錯，請稍後重試。");
          currentUploadXHR = null;
          uploadStartTime = null;
          if (bar) bar.style.width = "0%";
        };

        xhr.open("POST", `${API_BASE}/upload`);
        xhr.send(formData);
        setStatus("upload-progress-text", "開始上傳...");
      }

      function cancelUpload() {
        if (currentUploadXHR) {
          currentUploadXHR.abort();
          currentUploadXHR = null;
          uploadStartTime = null;
          resetProgress();
          setStatus("upload-progress-text", "已取消上傳。");
        }
      }

      document.addEventListener("DOMContentLoaded", () => {
        attachFileInputHandlers();
        attachDropzoneHandlers();

        const btnUpload = document.getElementById("btn-upload");
        const btnCancel = document.getElementById("btn-cancel");
        const btnRefresh = document.getElementById("btn-refresh");
        const btnRefreshList = document.getElementById("btn-refresh-list");
        const searchInput = document.getElementById("search-input");

        if (btnUpload) btnUpload.addEventListener("click", startUpload);
        if (btnCancel) btnCancel.addEventListener("click", cancelUpload);
        if (btnRefresh) btnRefresh.addEventListener("click", loadFiles);
        if (btnRefreshList) btnRefreshList.addEventListener("click", loadFiles);
        if (searchInput) {
          searchInput.addEventListener("input", () => {
            renderFileList(allFilesCache);
          });
        }

        loadFiles();
      });
    })();
  </script>
</body>
</html>
HTML
}

write_cleanup_script() {
  log INFO "寫入每日清理腳本 cleanup.py"

  cat > "${APP_DIR}/cleanup.py" <<'PY'
import os
import asyncio
from datetime import datetime, timedelta

import aiosqlite
import httpx
from dotenv import load_dotenv

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DOTENV_PATH = os.path.join(BASE_DIR, ".env")
load_dotenv(DOTENV_PATH)

PAN_UPLOAD_DIR = os.getenv("PAN_UPLOAD_DIR", "/srv/pan/uploads")
PAN_DB_PATH = os.getenv("PAN_DB_PATH", "/srv/pan/db/pan.db")
PAN_MAX_FILE_AGE_DAYS = int(os.getenv("PAN_MAX_FILE_AGE_DAYS", "7"))

PAN_TELEGRAM_BOT_TOKEN = os.getenv("PAN_TELEGRAM_BOT_TOKEN", "")
PAN_TELEGRAM_CHAT_ID = os.getenv("PAN_TELEGRAM_CHAT_ID", "")

def format_size(num: int) -> str:
  step = 1024.0
  for unit in ["B", "KB", "MB", "GB", "TB"]:
    if num < step:
      return f"{num:.1f}{unit}" if unit != "B" else f"{num}{unit}"
    num /= step
  return f"{num:.1f}PB"

async def send_telegram_message(text: str):
  if not PAN_TELEGRAM_BOT_TOKEN or not PAN_TELEGRAM_CHAT_ID:
    return
  url = f"https://api.telegram.org/bot{PAN_TELEGRAM_BOT_TOKEN}/sendMessage"
  payload = {
    "chat_id": PAN_TELEGRAM_CHAT_ID,
    "text": text,
    "parse_mode": "HTML",
    "disable_web_page_preview": True,
  }
  try:
    async with httpx.AsyncClient(timeout=10) as client:
      await client.post(url, json=payload)
  except Exception:
    pass

async def cleanup():
  if PAN_MAX_FILE_AGE_DAYS <= 0:
    print("[cleanup] PAN_MAX_FILE_AGE_DAYS <= 0, 不執行清理。")
    return

  cutoff = datetime.utcnow() - timedelta(days=PAN_MAX_FILE_AGE_DAYS)
  deleted_count = 0
  total_freed = 0

  async with aiosqlite.connect(PAN_DB_PATH) as db:
    db.row_factory = aiosqlite.Row
    cur = await db.execute("SELECT * FROM files WHERE created_at < ?", (cutoff,))
    rows = await cur.fetchall()

    for row in rows:
      fid = row["id"]
      stored = row["stored_name"]
      size_bytes = row["size_bytes"]
      path = os.path.join(PAN_UPLOAD_DIR, stored)
      if os.path.exists(path):
        try:
          os.remove(path)
          deleted_count += 1
          total_freed += size_bytes
          print(f"[cleanup] 刪除 {path}")
        except Exception as e:
          print(f"[cleanup] 刪除失敗 {path}: {e}")

    await db.execute("DELETE FROM files WHERE created_at < ?", (cutoff,))
    await db.commit()

  if deleted_count > 0:
    msg = f"清理過期文件：共刪除 {deleted_count} 個，釋放 {format_size(total_freed)}。"
    print("[cleanup]", msg)
    await send_telegram_message(f"[清理任務完成]\n{msg}")
  else:
    print("[cleanup] 無過期文件。")

if __name__ == "__main__":
  asyncio.run(cleanup())
PY

  chown "${APP_USER}:${APP_USER}" "${APP_DIR}/cleanup.py"
  chmod 750 "${APP_DIR}/cleanup.py"
}

write_systemd_service() {
  log INFO "寫入 systemd 服務單元：${SYSTEMD_SERVICE}"

  cat > "${SYSTEMD_SERVICE}" <<SERVICE
[Unit]
Description=SUEN Net Drive (pan.bdfz.net) FastAPI Service
After=network.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
Environment="PATH=${APP_DIR}/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EnvironmentFile=${APP_DIR}/.env
ExecStart=${APP_DIR}/venv/bin/uvicorn app:app --host 127.0.0.1 --port 8000 --proxy-headers --forwarded-allow-ips '*'
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SERVICE

  chown root:root "${SYSTEMD_SERVICE}"
  chmod 644 "${SYSTEMD_SERVICE}"
}

write_cleanup_systemd() {
  log INFO "寫入清理任務的 systemd 服務與定時器"

  cat > "${SYSTEMD_CLEANUP_SERVICE}" <<SERVICE
[Unit]
Description=SUEN Net Drive (pan.bdfz.net) Cleanup Service

[Service]
Type=oneshot
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
Environment="PATH=${APP_DIR}/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=${APP_DIR}/venv/bin/python ${APP_DIR}/cleanup.py
SERVICE

  cat > "${SYSTEMD_CLEANUP_TIMER}" <<TIMER
[Unit]
Description=每日清理 SUEN Net Drive 過期文件

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
TIMER

  chown root:root "${SYSTEMD_CLEANUP_SERVICE}" "${SYSTEMD_CLEANUP_TIMER}"
  chmod 644 "${SYSTEMD_CLEANUP_SERVICE}" "${SYSTEMD_CLEANUP_TIMER}"
}

disable_legacy_nginx_sites() {
  if [[ -L /etc/nginx/sites-enabled/pan.bdfz.net ]]; then
    log INFO "檢測到舊的 Nginx 站點 pan.bdfz.net，將禁用以避免衝突"
    rm -f /etc/nginx/sites-enabled/pan.bdfz.net
  fi

  if [[ -f /etc/nginx/sites-available/pan.bdfz.net ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    log INFO "備份舊的 /etc/nginx/sites-available/pan.bdfz.net -> .bak-${ts}"
    cp -a /etc/nginx/sites-available/pan.bdfz.net "/etc/nginx/sites-available/pan.bdfz.net.bak-${ts}"
  fi
}

write_nginx_http_conf() {
  log INFO "寫入初始 Nginx HTTP 配置 (用於申請證書)..."
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

  cat > "${NGINX_SITE_AVAIL}" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
NGINX

  ln -sf "${NGINX_SITE_AVAIL}" "${NGINX_SITE_ENABLED}"

  if nginx -t; then
    systemctl reload nginx
  else
    log WARN "Nginx 配置測試失敗，嘗試重啟服務..."
    systemctl restart nginx || true
  fi
}

obtain_certificate_if_needed() {
  if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    log INFO "已檢測到現有證書，跳過申請步驟。"
    return
  fi

  log INFO "未檢測到現有證書，準備申請 Let's Encrypt 證書..."
  mkdir -p /var/www/letsencrypt

  local email
  if [[ -n "${CERTBOT_EMAIL:-}" ]]; then
    email="${CERTBOT_EMAIL}"
  else
    read -r -p "請輸入用於 Let's Encrypt 的電子郵件地址: " email || true
  fi

  if [[ -z "${email}" ]]; then
    log ERROR "未提供電子郵件，無法自動申請證書。"
    return
  fi

  certbot certonly --webroot -w /var/www/letsencrypt \
    -d "${DOMAIN}" \
    --email "${email}" \
    --agree-tos \
    --non-interactive || {
      log ERROR "Certbot 申請失敗。請檢查域名解析是否正確指向本機。"
      exit 1
    }
}

write_nginx_ssl_conf() {
  log INFO "證書已就緒，寫入 Nginx HTTPS 配置..."

  cat > "${NGINX_SITE_AVAIL}" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
    }

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/${DOMAIN}/chain.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    client_max_body_size 10240m;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_request_buffering off;
    }
}
NGINX
}

reload_services() {
  log INFO "重啟/啟動 Nginx 與應用服務..."

  systemctl daemon-reload

  systemctl enable "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  systemctl enable "${SERVICE_NAME}-cleanup.timer" >/dev/null 2>&1 || true

  systemctl restart "${SERVICE_NAME}.service"
  systemctl restart "${SERVICE_NAME}-cleanup.timer" || true

  nginx -t
  systemctl reload nginx

  systemctl status "${SERVICE_NAME}.service" --no-pager || true
}

main() {
  require_root
  check_os
  log INFO "開始部署 SUEN の 網盤..."
  detect_existing_env
  kill_previous_processes
  install_packages
  create_app_user_and_dirs
  write_env_file
  create_venv_and_install_deps
  write_app_main
  write_templates_html
  write_cleanup_script
  write_systemd_service
  write_cleanup_systemd

  disable_legacy_nginx_sites

  write_nginx_http_conf
  obtain_certificate_if_needed
  write_nginx_ssl_conf
  reload_services

  log INFO "============================================="
  log INFO " SUEN の 網盤 已部署完成。"
  log INFO " 請在瀏覽器訪問：https://${DOMAIN}/"
  log INFO "============================================="
}

main "$@"