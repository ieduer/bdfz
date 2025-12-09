#!/usr/bin/env bash
#
# pan.sh - 一鍵部署 SUENの網盤 (pan.bdfz.net 公共上傳/下載服務)
#  - Nginx + FastAPI + Uvicorn + SQLite (aiosqlite 異步)
#  - 流式上傳，避免整個文件讀入記憶體
#  - 上傳/下載記錄到 SQLite
#  - 上傳 & 下載 Telegram 通知 (httpx 異步)
#  - 支援上傳口令 UPLOAD_SECRET（可選，全局口令）
#  - 每日自動清理過期文件 (systemd timer + cleanup.py)
#  - 內建 Let's Encrypt + 443，自動檢測已有證書，不重複申請
#

set -Eeuo pipefail
INSTALLER_VERSION="pan-install-2025-12-08-v2"

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
    source /etc/os-release
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
    source "${APP_DIR}/.env"
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

  if [[ -n "${UPLOAD_SECRET:-}" ]]; then
    upload_secret="${UPLOAD_SECRET}"
  else
    upload_secret=""
  fi

  if [[ -n "${MAX_FILE_AGE_DAYS:-}" ]]; then
    max_age="${MAX_FILE_AGE_DAYS}"
  else
    max_age="7"
  fi

  telegram_chat="${TELEGRAM_CHAT_ID:-}"
  telegram_token="${TELEGRAM_BOT_TOKEN:-}"

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

  cat > "${APP_DIR}/requirements.txt" <<'REQ'
fastapi==0.115.0
uvicorn[standard]==0.30.6
python-dotenv==1.0.1
aiosqlite==0.20.0
httpx==0.27.2
REQ

  chown "${APP_USER}:${APP_USER}" "${APP_DIR}/requirements.txt"

  sudo -u "${APP_USER}" -H "${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/requirements.txt"
}

write_app_main() {
  log INFO "寫入 FastAPI 主程式 app.py"

  cat > "${APP_DIR}/app.py" <<'PY'
import os
import uuid
import time
import asyncio
import aiosqlite
from datetime import datetime, timedelta
from typing import Optional, List

from fastapi import FastAPI, UploadFile, File, Form, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse, StreamingResponse, JSONResponse
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
    version="1.0.0"
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

@app.on_event("startup")
async def on_startup():
    await init_db()

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

async def send_telegram_message(text: str):
    if not PAN_TELEGRAM_BOT_TOKEN or not PAN_TELEGRAM_CHAT_ID:
        return
    url = f"https://api.telegram.org/bot{PAN_TELEGRAM_BOT_TOKEN}/sendMessage"
    payload = {
        "chat_id": PAN_TELEGRAM_CHAT_ID,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": True
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

def validate_upload_secret(secret: str) -> bool:
    if not PAN_UPLOAD_SECRET:
        return True
    return secret == PAN_UPLOAD_SECRET

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
        cur = await db.execute(
            "SELECT * FROM files WHERE created_at < ?",
            (cutoff,),
        )
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
        return "影音資源"
    if any(lower.endswith(ext) for ext in [".zip", ".rar", ".7z", ".tar", ".gz", ".bz2"]):
        return "壓縮包"
    if any(lower.endswith(ext) for ext in [".pdf", ".doc", ".docx", ".ppt", ".pptx", ".xls", ".xlsx"]):
        return "學術資料"
    if any(lower.endswith(ext) for ext in [".jpg", ".jpeg", ".png", ".gif", ".webp", ".tiff"]):
        return "圖片圖像"
    return "其他"

@app.post("/upload")
async def upload_files(
    request: Request,
    upload_secret: str = Form(""),
    category: str = Form(""),
    files: List[UploadFile] = File(...),
):
    if not validate_upload_secret(upload_secret):
        raise HTTPException(status_code=403, detail="UPLOAD_SECRET 不正確")

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
        "Content-Disposition": f'attachment; filename="{filename}"'
    }
    return StreamingResponse(
        file_iterator(),
        media_type="application/octet-stream",
        headers=headers
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

    .title-tagline {
      font-size: 0.9rem;
      color: #9ca3af;
    }

    .meta-row {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      font-size: 0.8rem;
      color: #9ca3af;
    }

    .meta-pill {
      border-radius: 999px;
      padding: 3px 10px;
      background: rgba(148, 163, 184, 0.12);
      border: 1px solid rgba(148, 163, 184, 0.35);
      display: inline-flex;
      align-items: center;
      gap: 5px;
    }

    .meta-pill span.icon {
      font-size: 0.9rem;
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

    .upload-hint {
      font-size: 0.75rem;
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
      justify-content: space-between;
      gap: 10px;
      margin-top: 6px;
    }

    .upload-bottom-left {
      font-size: 0.78rem;
      color: #9ca3af;
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

    .list-header-row {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
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

    .row-between {
      display: flex;
      align-items: center;
      justify-content: space-between;
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

    .dl-name {
      min-width: 0;
      word-break: break-all;
    }

    .mg-top-4 {
      margin-top: 4px;
    }
  </style>
</head>
<body>
  <div class="page-wrapper">
    <header class="page-header">
      <div class="title-row">
        <h1>SUEN の 網盤</h1>
        <div class="title-tagline">一個乾淨的公共上傳 / 下載小站，給學生和同事用的大型檔案通道。</div>
      </div>
      <div class="meta-row">
        <div class="meta-pill">
          <span class="icon">☁️</span><span>後端 FastAPI + Uvicorn + SQLite</span>
        </div>
        <div class="meta-pill">
          <span class="icon">🔒</span><span>可選上傳口令 · HTTPS</span>
        </div>
        <div class="meta-pill">
          <span class="icon">🧹</span><span>自動清理過期文件 · Telegram 通知</span>
        </div>
      </div>
    </header>

    <main class="main-grid">
      <section>
        <div class="card">
          <div class="card-inner">
            <div class="card-header">
              <div class="card-title">
                <h2>上傳區</h2>
                <div class="card-subtitle">選擇文件或資料夾，一鍵上傳到伺服器。</div>
              </div>
              <div class="pill-badge">STREAMING UPLOAD</div>
            </div>

            <div id="upload-dropzone" class="upload-dropzone">
              <div class="upload-top-row">
                <div class="upload-main-copy">
                  <div class="upload-main-copy-title">拖曳到此處，或使用按鈕選擇</div>
                  <div class="upload-main-copy-sub">
                    支援單檔或整個資料夾，伺服器端限制由管理員設定（預設 10 GB）。
                  </div>
                </div>
              </div>

              <div class="upload-buttons-row mg-top-4">
                <button type="button" class="btn" id="btn-sel-file">
                  <span class="btn-icon">📄</span><span>選擇文件</span>
                </button>
                <button type="button" class="btn secondary" id="btn-sel-folder">
                  <span class="btn-icon">📁</span><span>選擇資料夾</span>
                </button>
                <div class="upload-hint">
                  也可以直接把文件 / 資料夾拖進來。重複選擇會累加。
                </div>
              </div>

              <input type="file" id="file-input-files" multiple style="display:none;" />
              <input type="file" id="file-input-folder" webkitdirectory directory multiple style="display:none;" />

              <div id="upload-preview" class="upload-preview">
                尚未選擇文件。
              </div>

              <div class="upload-meta-row">
                <label for="category-select">分類：</label>
                <select id="category-select">
                  <option value="">自動判斷</option>
                  <option value="高考作文">高考作文</option>
                  <option value="學術資料">學術資料</option>
                  <option value="教學課件">教學課件</option>
                  <option value="影音資源">影音資源</option>
                  <option value="壓縮包">壓縮包</option>
                  <option value="圖片圖像">圖片圖像</option>
                  <option value="其他">其他</option>
                </select>

                <label for="upload-secret">上傳口令：</label>
                <input type="password" id="upload-secret" placeholder="若未設定可留空" />
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
              <div class="upload-bottom-left">
                檔案會在一定時間後自動清理（具體由管理員設定）。
              </div>
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
            <div class="row-between" style="margin-bottom:12px;gap:8px;">
              <div class="search-box-wrap" style="flex:1;margin-bottom:0;">
                <span class="search-icon-symbol">🔍</span>
                <input type="text" id="search-input" class="search-input" placeholder="全局搜索..." />
              </div>
              <button type="button" id="btn-refresh" style="white-space:nowrap;padding:6px 12px;font-size:0.8rem;">刷新</button>
            </div>

            <div id="file-area-container">
              <!-- Rendered content goes here -->
              <div id="download-status" class="download-progress-text" style="text-align:center;">正在載入...</div>
            </div>
          </div>
        </div>
      </section>
    </main>
  </div>

  <script>
    const API_BASE = "";
    let selectedFiles = [];
    let currentUploadXHR = null;

    function formatBytes(bytes) {
      if (bytes === 0) return "0B";
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
        `已選擇 <strong>${count}</strong> 項，合計 <strong>${formatBytes(totalSize)}</strong>。` +
        ` 當前選擇將在一次上傳任務中提交。`;
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
        const resp = await fetch(`${API_BASE}/list`);
        if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
        const data = await resp.json();

        renderFileList(data.files || []);
      } catch (err) {
        console.error("loadFiles error:", err);
        const container = document.getElementById("file-area-container");
        container.innerHTML = `
          <div class="file-area">
            <div class="download-progress-text">載入列表時出錯，請稍後重試。</div>
          </div>
        `;
      }
    }

    function renderFileList(files) {
      const container = document.getElementById("file-area-container");
      container.innerHTML = "";

      const searchVal = document.getElementById("search-input").value.trim().toLowerCase();
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

      const fixedCategories = [
        "高考作文",
        "學術資料",
        "教學課件",
        "影音資源",
        "壓縮包",
        "圖片圖像",
        "其他"
      ];

      const orderCats = [];
      for (const c of fixedCategories) {
        if (byCat[c] && byCat[c].length) orderCats.push(c);
      }

      const uncategorized = filtered.filter(f => !f.category);
      if (uncategorized.length) {
        byCat["未分類"] = uncategorized;
        orderCats.push("未分類");
      }

      const area = document.createElement("div");
      area.className = "file-area";

      for (const cat of orderCats) {
        const list = byCat[cat];
        area.appendChild(renderCategorySection(cat, list));
      }

      if (!orderCats.length) {
        area.innerHTML = `
          <div class="download-progress-text">
            暫無文件。當有人上傳後，這裡會顯示所有分類下的附件清單。
          </div>
        `;
      }

      const existingStatus = document.getElementById("download-status");
      const statusBar = document.createElement("div");
      statusBar.id = "download-status";
      statusBar.className = "download-progress-text";
      statusBar.textContent = existingStatus ? existingStatus.textContent : "提示：點擊文件名下載，右側按鈕可複製分享鏈接。";

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
      count.textContent = `${fileList.length} 個附件`;

      header.appendChild(title);
      header.appendChild(count);
      block.appendChild(header);

      const ul = document.createElement("ul");
      ul.className = "category-list";

      fileList.forEach(f => {
        const li = document.createElement("li");
        li.className = "category-list-item";

        const main = document.createElement("div");
        main.className = "item-main";

        const a = document.createElement("a");
        a.href = `/d/${encodeURIComponent(f.id)}/${encodeURIComponent(f.name || "download")}`;
        const nameSpan = document.createElement("span");
        nameSpan.className = "dl-name";
        const dispName = f.name || "(無名文件)";
        nameSpan.textContent = dispName;
        a.appendChild(nameSpan);

        main.appendChild(a);

        const meta = document.createElement("div");
        meta.className = "item-meta";

        const sizeSpan = document.createElement("span");
        sizeSpan.textContent = f.size_human || "";
        meta.appendChild(sizeSpan);

        const shareBtn = document.createElement("button");
        shareBtn.type = "button";
        shareBtn.className = "btn-share";
        shareBtn.textContent = "複製分享鏈接";
        shareBtn.addEventListener("click", (e) => {
          e.stopPropagation();
          e.preventDefault();
          const link = `${window.location.origin}/d/${encodeURIComponent(f.id)}/${encodeURIComponent(f.name || "download")}`;
          copyToClipboard(link);
        });
        meta.appendChild(shareBtn);

        li.appendChild(main);
        li.appendChild(meta);
        ul.appendChild(li);
      });

      block.appendChild(ul);
      return block;
    }

    function copyToClipboard(text) {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(() => {
          setStatus("download-status", "已複製分享鏈接到剪貼簿。");
        }).catch(() => {
          fallbackCopy(text);
        });
      } else {
        fallbackCopy(text);
      }
    }

    function fallbackCopy(text) {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.top = "-9999px";
      document.body.appendChild(ta);
      ta.select();
      try {
        document.execCommand("copy");
        setStatus("download-status", "已複製分享鏈接到剪貼簿。");
      } catch (e) {
        setStatus("download-status", "無法自動複製，請手動選取地址。");
      } finally {
        document.body.removeChild(ta);
      }
    }

    // --- Download with progress & ETA ---
    function startDownloadWithProgress(urlStr, filenameHint) {
      const statusEl = document.getElementById("download-status");
      if (!statusEl) {
        window.location.href = urlStr;
        return;
      }
      const MAX_BLOB_BYTES = 2 * 1024 * 1024 * 1024;

      statusEl.textContent = "正在準備下載...";

      fetch(urlStr, { method: "HEAD" }).then((res) => {
        const lenHeader = res.headers.get("Content-Length") || res.headers.get("content-length");
        const total = lenHeader ? parseInt(lenHeader, 10) : NaN;

        if (!Number.isFinite(total) || total <= 0 || total > MAX_BLOB_BYTES) {
          statusEl.textContent = "已開始下載（大文件或未知大小，請查看瀏覽器下載進度）。";
          window.location.href = urlStr;
          return;
        }

        const xhr = new XMLHttpRequest();
        xhr.open("GET", urlStr, true);
        xhr.responseType = "blob";
        const startedAt = Date.now();

        xhr.onprogress = function (evt) {
          if (!evt.lengthComputable) return;
          const loaded = evt.loaded;
          const totalBytes = evt.total || total;
          const elapsedSec = (Date.now() - startedAt) / 1000;
          const speed = elapsedSec > 0 ? loaded / elapsedSec : 0;
          const remainBytes = Math.max(0, totalBytes - loaded);
          const eta = speed > 0 ? remainBytes / speed : 0;

          const msg =
            "下載 " +
            formatBytes(loaded) +
            " / " +
            formatBytes(totalBytes) +
            " · " +
            formatSpeed(speed) +
            " · " +
            formatETA(eta);
          statusEl.textContent = msg;
        };

        xhr.onerror = function () {
          statusEl.textContent = "下載失敗，請稍後重試。";
        };

        xhr.onload = function () {
          if (xhr.status >= 200 && xhr.status < 300) {
            const blob = xhr.response;
            const totalBytes = blob ? blob.size : total;
            let filename = filenameHint || "";
            if (!filename) {
              try {
                const urlObj = new URL(urlStr);
                filename = decodeURIComponent(urlObj.pathname.split("/").pop() || "");
              } catch (e) {
                filename = "download.bin";
              }
            }
            const blobUrl = URL.createObjectURL(blob);
            const a = document.createElement("a");
            a.href = blobUrl;
            a.download = filename || "download.bin";
            document.body.appendChild(a);
            a.click();
            setTimeout(() => {
              URL.revokeObjectURL(blobUrl);
              document.body.removeChild(a);
            }, 1000);
            statusEl.textContent =
              "下載完成：" +
              filename +
              (Number.isFinite(totalBytes) ? "（" + formatBytes(totalBytes) + "）" : "");
          } else {
            statusEl.textContent = "下載失敗：HTTP " + xhr.status;
          }
        };

        xhr.send();
      }).catch(() => {
        statusEl.textContent = "已開始下載（無法預估大小，請查看瀏覽器下載進度）。";
        window.location.href = urlStr;
      });
    }

    // --- Unified Select Button Logic is above; now hook global download handler ---
    document.addEventListener("click", function (e) {
      const a = e.target.closest("a");
      if (!a) return;
      const href = a.getAttribute("href");
      if (!href) return;
      let urlObj;
      try {
        urlObj = new URL(href, window.location.origin);
      } catch (err) {
        return;
      }
      if (!urlObj.pathname || !urlObj.pathname.startsWith("/d/")) return;
      e.preventDefault();
      const filenameHint = decodeURIComponent(urlObj.pathname.split("/").pop() || "");
      startDownloadWithProgress(urlObj.toString(), filenameHint);
    });

    function uploadWithXHR() {
      if (!selectedFiles.length) {
        alert("請先選擇文件或資料夾。");
        return;
      }

      const formData = new FormData();
      const cat = document.getElementById("category-select").value;
      const secret = document.getElementById("upload-secret").value;

      formData.append("category", cat);
      formData.append("upload_secret", secret);

      selectedFiles.forEach((f) => {
        formData.append("files", f, f.webkitRelativePath || f.name);
      });

      const xhr = new XMLHttpRequest();
      currentUploadXHR = xhr;

      xhr.open("POST", `${API_BASE}/upload`, true);

      const progressFill = document.getElementById("progress-bar-fill");
      const progressText = document.getElementById("upload-progress-text");

      const startTime = Date.now();

      xhr.upload.onprogress = function (e) {
        if (!e.lengthComputable) return;
        const percent = (e.loaded / e.total) * 100;
        const elapsedSec = (Date.now() - startTime) / 1000;
        const speed = e.loaded / (elapsedSec || 1);
        const remainingBytes = e.total - e.loaded;
        const etaSec = remainingBytes / (speed || 1);

        progressFill.style.width = `${percent.toFixed(1)}%`;
        progressText.textContent =
          `已上傳 ${formatBytes(e.loaded)} / ${formatBytes(e.total)} · ` +
          `${formatSpeed(speed)} · ${formatETA(etaSec)}`;
      };

      xhr.onload = function () {
        if (xhr.status >= 200 && xhr.status < 300) {
          progressFill.style.width = "100%";
          progressText.textContent = "上傳完成。正在刷新列表...";
          selectedFiles = [];
          updateUploadPreview();
          loadFiles();
        } else {
          progressText.textContent = `上傳失敗：HTTP ${xhr.status}`;
        }
        currentUploadXHR = null;
      };

      xhr.onerror = function () {
        progressText.textContent = "上傳過程中出現錯誤。";
        currentUploadXHR = null;
      };

      progressFill.style.width = "0%";
      progressText.textContent = "開始上傳...";
      xhr.send(formData);
    }

    document.getElementById("btn-cancel").addEventListener("click", () => {
      if (currentUploadXHR) {
        currentUploadXHR.abort();
        currentUploadXHR = null;
        setStatus("upload-progress-text", "已中止當前上傳。");
      } else {
        setStatus("upload-progress-text", "當前沒有進行中的上傳任務。");
      }
    });

    document.getElementById("btn-refresh").addEventListener("click", () => {
      document.getElementById("search-input").value = "";
      loadFiles();
    });

    document.addEventListener("DOMContentLoaded", function () {
      attachFileInputHandlers();
      attachDropzoneHandlers();

      const searchInput = document.getElementById("search-input");
      searchInput.addEventListener("input", () => {
        loadFiles();
      });

      document.getElementById("btn-refresh-list").addEventListener("click", () => {
        document.getElementById("search-input").value = "";
        loadFiles();
      });

      document.getElementById("btn-upload").addEventListener("click", uploadWithXHR);

      loadFiles();
    });
  </script>
</body>
</html>
HTML

  chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}/templates"
}

write_cleanup_script() {
  log INFO "寫入每日清理腳本 cleanup.py"

  cat > "${APP_DIR}/cleanup.py" <<'PY'
import os
import asyncio
from dotenv import load_dotenv

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DOTENV_PATH = os.path.join(BASE_DIR, ".env")
load_dotenv(DOTENV_PATH)

from app import cleanup_expired_files

if __name__ == "__main__":
    asyncio.run(cleanup_expired_files())
PY

  chown "${APP_USER}:${APP_USER}" "${APP_DIR}/cleanup.py"
}

write_systemd_service() {
  log INFO "寫入 systemd 服務單元：${SYSTEMD_SERVICE}"

  cat > "${SYSTEMD_SERVICE}" <<SERVICE
[Unit]
Description=SUEN Pan FastAPI Service
After=network.target

[Service]
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
Environment="PYTHONUNBUFFERED=1"
Environment="PATH=${APP_DIR}/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=${APP_DIR}/venv/bin/uvicorn app:app --host 127.0.0.1 --port 9001 --proxy-headers --forwarded-allow-ips='*'
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service"
}

write_cleanup_systemd() {
  log INFO "寫入清理任務的 systemd 服務與定時器"

  cat > "${SYSTEMD_CLEANUP_SERVICE}" <<SERVICE
[Unit]
Description=Cleanup expired files for SUEN Pan

[Service]
Type=oneshot
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
Environment="PATH=${APP_DIR}/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=${APP_DIR}/venv/bin/python cleanup.py
SERVICE

  cat > "${SYSTEMD_CLEANUP_TIMER}" <<TIMER
[Unit]
Description=Daily cleanup for SUEN Pan

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
Unit=${SERVICE_NAME}-cleanup.service

[Install]
WantedBy=timers.target
TIMER

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}-cleanup.timer"
  systemctl start "${SERVICE_NAME}-cleanup.timer"
}

write_nginx_conf() {
  log INFO "寫入 Nginx 配置：${NGINX_SITE_AVAIL}"

  cat > "${NGINX_SITE_AVAIL}" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/${DOMAIN}/chain.pem;

    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    client_max_body_size 100g;

    location / {
        proxy_pass http://127.0.0.1:9001;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_connect_timeout 600;
        proxy_send_timeout 600;
        proxy_read_timeout 600;

        proxy_request_buffering off;
        proxy_buffering off;
    }
}
NGINX

  if [[ ! -e "${NGINX_SITE_ENABLED}" ]]; then
    ln -s "${NGINX_SITE_AVAIL}" "${NGINX_SITE_ENABLED}"
  fi
}

obtain_or_ensure_cert() {
  if [[ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
    log INFO "未找到現有證書，準備使用 certbot 申請..."
    mkdir -p /var/www/html
    certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos -m "admin@${DOMAIN}" || {
      log ERROR "certbot 申請證書失敗，請手動檢查 DNS / 防火牆配置。"
    }
  else
    log INFO "已檢測到現有證書，跳過申請步驟。"
  fi
}

restart_services() {
  log INFO "重啟/啟動 Nginx 與應用服務..."
  nginx -t
  systemctl restart nginx
  systemctl restart "${SERVICE_NAME}.service"
}

main() {
  require_root
  check_os
  detect_existing_env
  install_packages
  create_app_user_and_dirs
  write_env_file
  create_venv_and_install_deps
  write_app_main
  write_templates_html
  write_cleanup_script
  write_systemd_service
  write_cleanup_systemd
  write_nginx_conf
  obtain_or_ensure_cert
  restart_services

  log INFO "============================================="
  log INFO " SUEN の 網盤 已部署完成。"
  log INFO " 請在瀏覽器訪問：https://${DOMAIN}/"
  log INFO "============================================="
}

main "$@"