#!/usr/bin/env bash
#
# pan.sh - 一鍵部署 SUEN の網盤 (pan.bdfz.net 公共上傳/下載服務)
# - Nginx + FastAPI + Uvicorn + SQLite (aiosqlite)
# - 流式上傳，大檔不吃記憶體
# - 支援多檔上傳、ZIP 打包下載、斷點續傳
# - 支援 Telegram 上傳 / 下載通知
# - 每日清理過期檔案與臨時 ZIP (systemd timer)
# - 自動申請/使用 Let’s Encrypt (避免重複申請)
#

set -Eeuo pipefail

INSTALLER_VERSION="pan-install-2025-12-08-v5"

DOMAIN="pan.bdfz.net"
APP_USER="panuser"
APP_DIR="/opt/pan-app"
DATA_DIR="/srv/pan"
TMP_DIR="${DATA_DIR}/tmp"
SERVICE_NAME="pan"
PYTHON_BIN="python3"
APP_PORT="8001"

NGINX_SITE_AVAILABLE="/etc/nginx/sites-available/${SERVICE_NAME}.conf"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/${SERVICE_NAME}.conf"
NGINX_DEFAULT_SITE="/etc/nginx/sites-enabled/default"
CERTBOT_WEBROOT="/var/www/certbot"
ENV_FILE="${APP_DIR}/.env"

log() {
  local level="$1"; shift
  printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$level" "$*" >&2
}

die() {
  log "ERROR" "$*"
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "請用 root 執行本腳本"
  fi
}

detect_os() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
  else
    OS_ID=""
  fi

  case "$OS_ID" in
    ubuntu|debian)
      log "INFO" "檢測到系統: $OS_ID"
      ;;
    *)
      die "目前腳本只支援 Debian/Ubuntu 類系統 (檢測到: ${OS_ID:-unknown})"
      ;;
  esac
}

ensure_packages() {
  log "INFO" "安裝必要套件..."
  apt-get update -y
  apt-get install -y \
    "$PYTHON_BIN" "$PYTHON_BIN-venv" python3-pip python3-dev build-essential \
    nginx sqlite3 \
    certbot python3-certbot-nginx
}

ensure_user() {
  if id "$APP_USER" >/dev/null 2>&1; then
    log "INFO" "使用已存在的系統帳號: $APP_USER"
  else
    log "INFO" "建立系統帳號: $APP_USER"
    useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
  fi
}

create_dirs() {
  mkdir -p "$APP_DIR" "$DATA_DIR" "$TMP_DIR" "$CERTBOT_WEBROOT"
  chown -R "$APP_USER":"$APP_USER" "$APP_DIR"
  chown -R "$APP_USER":"$APP_USER" "$DATA_DIR"

  # 確保 Nginx (www-data) 可以讀取 Certbot 的挑戰文件
  chmod 755 "$CERTBOT_WEBROOT"

  mkdir -p "$(dirname "$NGINX_SITE_AVAILABLE")" "$(dirname "$NGINX_SITE_ENABLED")"
}

write_env_file() {
  if [ -f "$ENV_FILE" ]; then
    log "INFO" "檢測到已存在的 .env: $ENV_FILE"
    read -r -p "是否覆蓋現有 .env? [y/N]: " ans || true
    case "$ans" in
      y|Y) log "INFO" "覆蓋 .env";;
      *)   log "INFO" "保留現有 .env"; return 0;;
    esac
  fi

  cat >"$ENV_FILE" <<EOF
# SUEN Pan 環境設定
DOMAIN=${DOMAIN}
DATA_DIR=${DATA_DIR}
TMP_DIR=${TMP_DIR}
DB_PATH=${DATA_DIR}/pan.db

# 單檔最大尺寸 (MB)
MAX_FILE_MB=20000

# 保留時間 (小時) - 預設 8 天
RETENTION_HOURS=192

# 上傳口令 (留空代表不需要)
UPLOAD_SECRET=

# Telegram 設定 (選填)
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
TELEGRAM_NOTIFY_UPLOAD=0
TELEGRAM_NOTIFY_DOWNLOAD=0
EOF

  chown "$APP_USER":"$APP_USER" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  log "INFO" "已寫入新的 .env 到 $ENV_FILE"
}

get_max_file_mb_from_env() {
  local val
  if [ -f "$ENV_FILE" ]; then
    val=$(grep -E '^MAX_FILE_MB=' "$ENV_FILE" | head -n1 | cut -d= -f2)
  fi
  if [ -z "$val" ]; then
    val=20000
  fi
  echo "$val"
}

check_tmp_space() {
  local max_file_mb required_mb avail_mb
  max_file_mb=$(get_max_file_mb_from_env)
  required_mb=$((max_file_mb * 2))

  mkdir -p "$DATA_DIR"
  avail_mb=$(df -Pm "$DATA_DIR" | awk 'NR==2 {print $4}')

  if [ -z "$avail_mb" ]; then
    log "WARN" "無法獲取 ${DATA_DIR} 所在分區可用空間，略過空間檢查"
    return 0
  fi

  log "INFO" "檔案空間檢查: MAX_FILE_MB=${max_file_mb}, 建議至少預留 ${required_mb} MB，可用 ${avail_mb} MB"

  if [ "$avail_mb" -lt "$required_mb" ]; then
    log "WARN" "可用空間低於建議值 (建議 >= ${required_mb} MB)"
    read -r -p "仍要繼續安裝嗎？這可能導致大檔上傳失敗。[y/N]: " ans || true
    case "$ans" in
      y|Y)
        log "INFO" "使用者選擇在空間不足情況下繼續"
        ;;
      *)
        die "已取消安裝，請先擴充分區或調低 MAX_FILE_MB 後重試"
        ;;
    esac
  fi
}

create_venv_and_deps() {
  log "INFO" "建立 Python 虛擬環境..."
  if [ ! -d "${APP_DIR}/venv" ]; then
    sudo -u "$APP_USER" -H "$PYTHON_BIN" -m venv "${APP_DIR}/venv"
  fi
  sudo -u "$APP_USER" -H "${APP_DIR}/venv/bin/pip" install --upgrade pip
  sudo -u "$APP_USER" -H "${APP_DIR}/venv/bin/pip" install \
    fastapi "uvicorn[standard]" aiosqlite httpx jinja2 python-multipart
}

write_app_code() {
  log "INFO" "寫入 FastAPI 應用程式碼..."
  local app_dir="${APP_DIR}/app"
  mkdir -p "$app_dir" "${APP_DIR}/templates" "${APP_DIR}/static"

  cat >"${app_dir}/main.py" <<'PY'
import os
import datetime
import html
import zipfile
import asyncio
import re
import uuid
from pathlib import Path
from typing import List, Optional

import aiosqlite
import httpx
from fastapi import FastAPI, Request, Form, UploadFile, File, HTTPException, Query
from fastapi.responses import HTMLResponse, FileResponse
from fastapi.templating import Jinja2Templates
from fastapi.staticfiles import StaticFiles
from starlette.background import BackgroundTask

BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = Path(os.environ.get("DATA_DIR", "/srv/pan"))
DB_PATH = Path(os.environ.get("DB_PATH", DATA_DIR / "pan.db")).resolve()
TMP_DIR = Path(os.environ.get("TMP_DIR", "/tmp"))
MAX_FILE_MB = int(os.environ.get("MAX_FILE_MB", "20000"))
RETENTION_HOURS = int(os.environ.get("RETENTION_HOURS", "192"))

TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN") or ""
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID") or ""
TELEGRAM_NOTIFY_UPLOAD = os.environ.get("TELEGRAM_NOTIFY_UPLOAD", "0") == "1"
TELEGRAM_NOTIFY_DOWNLOAD = os.environ.get("TELEGRAM_NOTIFY_DOWNLOAD", "0") == "1"

UPLOAD_SECRET = os.environ.get("UPLOAD_SECRET") or ""

app = FastAPI(title="SUEN Pan", version="1.0.0")

templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))
STATIC_DIR = BASE_DIR / "static"
STATIC_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


async def init_db() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    async with aiosqlite.connect(DB_PATH) as conn:
        await conn.execute("PRAGMA journal_mode = WAL;")
        await conn.execute("PRAGMA busy_timeout = 5000;")
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS uploads (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              upload_id TEXT NOT NULL,
              original_name TEXT NOT NULL,
              stored_path TEXT NOT NULL,
              size_bytes INTEGER NOT NULL,
              created_at TIMESTAMP NOT NULL
            )
            """
        )
        await conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_uploads_upload_id
            ON uploads (upload_id)
            """
        )
        await conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_uploads_created_at
            ON uploads (created_at)
            """
        )
        await conn.commit()


@app.on_event("startup")
async def startup_event() -> None:
    await init_db()


def _sanitize_filename(name: str) -> str:
    name = name.replace("/", "_").replace("\\", "_")
    name = name.replace("\0", "")
    if len(name) > 255:
        base, dot, ext = name.rpartition(".")
        if not base:
            name = name[:255]
        else:
            allowed = 255 - len(dot) - len(ext)
            base = base[:allowed] if allowed > 0 else ""
            name = f"{base}{dot}{ext}"
    return name or "file"


def _now_utc() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc)


def _validate_upload_id(upload_id: str) -> str:
    if not upload_id:
        raise HTTPException(status_code=400, detail="upload_id is required")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", upload_id):
        raise HTTPException(status_code=400, detail="Invalid upload_id")
    return upload_id


async def insert_upload_records(records):
    if not records:
        return
    async with aiosqlite.connect(DB_PATH) as conn:
        await conn.execute("PRAGMA busy_timeout = 5000;")
        await conn.executemany(
            """
            INSERT INTO uploads (upload_id, original_name, stored_path, size_bytes, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            [
                (
                    upload_id,
                    original_name,
                    str(stored_path),
                    size_bytes,
                    _now_utc().isoformat(),
                )
                for (upload_id, original_name, stored_path, size_bytes) in records
            ],
        )
        await conn.commit()


async def send_telegram_message(text: str) -> None:
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        return
    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    payload = {
        "chat_id": TELEGRAM_CHAT_ID,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": True,
    }
    async with httpx.AsyncClient(timeout=10.0) as client:
        try:
            await client.post(url, json=payload)
        except Exception:
            pass


def _remove_file(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass
    except Exception:
        pass


@app.get("/", response_class=HTMLResponse)
async def index(request: Request, upload_id: Optional[str] = None) -> HTMLResponse:
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "upload_id": upload_id,
            "max_file_mb": MAX_FILE_MB,
            "has_secret": bool(UPLOAD_SECRET),
        },
    )


@app.post("/upload", response_class=HTMLResponse)
async def handle_upload(
    request: Request,
    upload_id: str = Form(...),
    secret: Optional[str] = Form(None),
    files: List[UploadFile] = File(...),
) -> HTMLResponse:
    upload_id = _validate_upload_id(upload_id)

    if UPLOAD_SECRET:
        if not secret or secret != UPLOAD_SECRET:
            raise HTTPException(status_code=403, detail="Invalid upload secret")

    upload_dir = DATA_DIR / "uploads" / upload_id
    upload_dir.mkdir(parents=True, exist_ok=True)

    written_paths = []
    db_records = []
    total_bytes = 0

    try:
        for file in files:
            filename = _sanitize_filename(file.filename or "file")
            target = upload_dir / filename

            size_bytes = 0
            with target.open("wb") as f:
                while True:
                    chunk = await file.read(1024 * 1024)
                    if not chunk:
                        break
                    size_bytes += len(chunk)
                    total_bytes += len(chunk)
                    f.write(chunk)

                    if size_bytes > MAX_FILE_MB * 1024 * 1024:
                        f.flush()
                        f.close()
                        try:
                            target.unlink()
                        except Exception:
                            pass
                        for p in written_paths:
                            try:
                                p.unlink()
                            except Exception:
                                pass
                        raise HTTPException(
                            status_code=413,
                            detail=f"單個文件超過限制：{MAX_FILE_MB} MB",
                        )

            written_paths.append(target)
            db_records.append((upload_id, filename, target, size_bytes))

        await insert_upload_records(db_records)

    except Exception:
        for p in written_paths:
            try:
                p.unlink()
            except Exception:
                pass
        raise

    if TELEGRAM_NOTIFY_UPLOAD and written_paths:
        escaped_id = html.escape(upload_id)
        escaped_count = len(written_paths)
        escaped_size_mb = total_bytes / (1024 * 1024)
        msg = (
            "📤 <b>新的上傳</b>\n"
            f"ID: <code>{escaped_id}</code>\n"
            f"文件數量: {escaped_count}\n"
            f"總大小: {escaped_size_mb:.2f} MB"
        )
        asyncio.create_task(send_telegram_message(msg))

    return templates.TemplateResponse(
        "upload_success.html",
        {
            "request": request,
            "upload_id": upload_id,
            "file_count": len(written_paths),
            "total_bytes": total_bytes,
            "max_file_mb": MAX_FILE_MB,
        },
    )


@app.get("/d/{upload_id}/{filename}")
async def download_file(
    upload_id: str,
    filename: str,
) -> FileResponse:
    upload_id = _validate_upload_id(upload_id)
    upload_dir = DATA_DIR / "uploads" / upload_id

    try:
        target = (upload_dir / filename).resolve()
    except Exception:
        raise HTTPException(status_code=404, detail="File not found")

    base_dir = upload_dir.resolve()
    try:
        is_inside = target.is_relative_to(base_dir)
    except AttributeError:
        base_str = str(base_dir)
        target_str = str(target)
        is_inside = target_str == base_str or target_str.startswith(base_str + os.sep)

    if not is_inside:
        raise HTTPException(status_code=403, detail="Access denied")

    if not target.is_file():
        raise HTTPException(status_code=404, detail="File not found")

    if TELEGRAM_NOTIFY_DOWNLOAD:
        stat = target.stat()
        escaped_id = html.escape(upload_id)
        escaped_name = html.escape(filename)
        escaped_size = stat.st_size / (1024 * 1024)
        msg = (
            "📥 <b>文件下載</b>\n"
            f"ID: <code>{escaped_id}</code>\n"
            f"文件: <code>{escaped_name}</code>\n"
            f"大小: {escaped_size:.2f} MB"
        )
        asyncio.create_task(send_telegram_message(msg))

    return FileResponse(
        path=str(target),
        filename=filename,
        media_type="application/octet-stream",
    )


@app.get("/z/{upload_id}")
async def download_zip(upload_id: str) -> FileResponse:
    upload_id = _validate_upload_id(upload_id)

    upload_dir = DATA_DIR / "uploads" / upload_id
    if not upload_dir.is_dir():
        raise HTTPException(status_code=404, detail="Upload ID not found")

    zip_name = f"{upload_id}.zip"
    TMP_DIR.mkdir(parents=True, exist_ok=True)
    temp_zip_filename = f"{upload_id}_{uuid.uuid4().hex}.zip"
    zip_path = TMP_DIR / temp_zip_filename

    def create_zip_sync() -> None:
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for root, _, files in os.walk(upload_dir):
                for name in files:
                    full_path = Path(root) / name
                    rel_path = full_path.relative_to(upload_dir)
                    zf.write(full_path, arcname=str(rel_path))

    loop = asyncio.get_running_loop()
    try:
        await loop.run_in_executor(None, create_zip_sync)
    except Exception:
        _remove_file(zip_path)
        raise HTTPException(status_code=500, detail="Failed to create zip")

    if TELEGRAM_NOTIFY_DOWNLOAD:
        escaped_id = html.escape(upload_id)
        escaped_size = zip_path.stat().st_size / (1024 * 1024)
        msg = (
            "📦 <b>打包下載</b>\n"
            f"ID: <code>{escaped_id}</code>\n"
            f"ZIP 大小: {escaped_size:.2f} MB"
        )
        asyncio.create_task(send_telegram_message(msg))

    background = BackgroundTask(_remove_file, zip_path)

    return FileResponse(
        path=str(zip_path),
        media_type="application/zip",
        filename=zip_name,
        background=background,
    )


@app.get("/api/list/{upload_id}")
async def api_list(upload_id: str):
    upload_id = _validate_upload_id(upload_id)

    upload_dir = DATA_DIR / "uploads" / upload_id
    if not upload_dir.is_dir():
        raise HTTPException(status_code=404, detail="Upload ID not found")

    files = []
    for p in sorted(upload_dir.glob("**/*")):
        if p.is_file():
            rel = p.relative_to(upload_dir).as_posix()
            files.append(
                {
                    "name": rel,
                    "size_bytes": p.stat().st_size,
                }
            )
    return {"upload_id": upload_id, "files": files}


@app.get("/api/all")
async def api_all(limit: int = Query(100, ge=1, le=1000)):
    rows_out = []
    async with aiosqlite.connect(DB_PATH) as conn:
        await conn.execute("PRAGMA busy_timeout = 5000;")
        conn.row_factory = aiosqlite.Row
        cur = await conn.execute(
            """
            SELECT upload_id, COUNT(*) AS file_count, SUM(size_bytes) AS total_size,
                   MIN(created_at) AS first_created_at, MAX(created_at) AS last_created_at
            FROM uploads
            GROUP BY upload_id
            ORDER BY last_created_at DESC
            LIMIT ?
            """,
            (limit,),
        )
        rows = await cur.fetchall()
    for row in rows:
        rows_out.append(
            {
                "upload_id": row["upload_id"],
                "file_count": row["file_count"],
                "total_size": row["total_size"],
                "first_created_at": row["first_created_at"],
                "last_created_at": row["last_created_at"],
            }
        )
    return {"items": rows_out}


@app.get("/api/zip/{upload_id}")
async def api_zip(upload_id: str):
    upload_id = _validate_upload_id(upload_id)
    return {
        "upload_id": upload_id,
        "note": "ZIP 檔為臨時檔案，通過 /z/{upload_id} 下載後會自動刪除，不保留在伺服器上",
    }


@app.get("/api/zip2/{upload_id}")
async def zip_by_upload_id(upload_id: str) -> FileResponse:
    upload_id = _validate_upload_id(upload_id)

    async with aiosqlite.connect(DB_PATH) as conn:
        await conn.execute("PRAGMA busy_timeout = 5000;")
        conn.row_factory = aiosqlite.Row
        cur = await conn.execute(
            """
            SELECT id, upload_id, stored_path, created_at
            FROM uploads
            WHERE upload_id = ?
            ORDER BY created_at ASC
            """,
            (upload_id,),
        )
        rows = [dict(row) for row in await cur.fetchall()]

    if not rows:
        raise HTTPException(status_code=404, detail="No files for this upload_id")

    TMP_DIR.mkdir(parents=True, exist_ok=True)
    zip_name = f"{upload_id}.zip"
    temp_zip_filename = f"{upload_id}_{uuid.uuid4().hex}.zip"
    zip_path = TMP_DIR / temp_zip_filename

    loop = asyncio.get_running_loop()

    def create_zip_sync() -> None:
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for row in rows:
                p = Path(row["stored_path"])
                if not p.is_file():
                    continue
                zf.write(p, arcname=p.name)

    try:
        await loop.run_in_executor(None, create_zip_sync)
    except Exception:
        _remove_file(zip_path)
        raise HTTPException(status_code=500, detail="Failed to create zip")

    background = BackgroundTask(_remove_file, zip_path)

    return FileResponse(
        path=str(zip_path),
        media_type="application/zip",
        filename=zip_name,
        background=background,
    )
PY

  cat >"${app_dir}/cleanup.py" <<'PY'
import os
import datetime
import sqlite3
from pathlib import Path

DATA_DIR = Path(os.environ.get("DATA_DIR", "/srv/pan"))
DB_PATH = Path(os.environ.get("DB_PATH", DATA_DIR / "pan.db")).resolve()
TMP_DIR = Path(os.environ.get("TMP_DIR", "/tmp"))
RETENTION_HOURS = int(os.environ.get("RETENTION_HOURS", "192"))


def log(msg: str) -> None:
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{now}] [cleanup] {msg}")


def cleanup_uploads() -> None:
    if not DB_PATH.exists():
        log(f"DB 不存在，略過 uploads 清理: {DB_PATH}")
        return

    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(
        hours=RETENTION_HOURS
    )
    cutoff_iso = cutoff.isoformat()

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cur.execute(
        """
        SELECT id, upload_id, stored_path, created_at
        FROM uploads
        WHERE created_at < ?
        """,
        (cutoff_iso,),
    )
    rows = cur.fetchall()
    conn.close()

    log(f"找到 {len(rows)} 筆過期記錄 (cutoff={cutoff_iso})")

    removed_files = 0
    removed_dirs = 0
    kept_rows = 0
    deleted_ids = []

    for row in rows:
        upload_id = row["upload_id"]
        stored_path = Path(row["stored_path"])
        file_deleted = False

        try:
            if stored_path.is_file():
                stored_path.unlink()
                removed_files += 1
                log(f"已刪除檔案 {stored_path} (upload_id={upload_id})")
                file_deleted = True
            elif not stored_path.exists():
                file_deleted = True

            parent = stored_path.parent
            try:
                if parent.is_dir() and not any(parent.iterdir()):
                    parent.rmdir()
                    removed_dirs += 1
                    log(f"已刪除空目錄 {parent}")
            except Exception as e:
                log(f"刪除目錄 {parent} 失敗: {e}")

        except Exception as e:
            log(f"刪除檔案 {stored_path} 失敗 (upload_id={upload_id}): {e}")

        if file_deleted:
            deleted_ids.append(row["id"])
        else:
            kept_rows += 1

    if deleted_ids:
        conn = sqlite3.connect(DB_PATH)
        conn.execute("PRAGMA journal_mode = WAL;")
        conn.execute("PRAGMA busy_timeout = 5000;")
        placeholders = ",".join("?" for _ in deleted_ids)
        conn.execute(f"DELETE FROM uploads WHERE id IN ({placeholders})", deleted_ids)
        conn.commit()
        conn.close()

    log(
        f"uploads 清理完成: removed_files={removed_files}, "
        f"removed_dirs={removed_dirs}, kept_rows={kept_rows}"
    )


def cleanup_tmp_zips() -> None:
    TMP_DIR.mkdir(parents=True, exist_ok=True)
    now = datetime.datetime.now(datetime.timezone.utc)
    cutoff_delta = datetime.timedelta(hours=RETENTION_HOURS)

    count = 0
    for p in TMP_DIR.glob("*.zip"):
        try:
            mtime = datetime.datetime.fromtimestamp(
                p.stat().st_mtime, tz=datetime.timezone.utc
            )
            if now - mtime > cutoff_delta:
                p.unlink()
                count += 1
                log(f"已刪除過期 ZIP: {p}")
        except Exception as e:
            log(f"刪除 ZIP {p} 失敗: {e}")
    log(f"tmp ZIP 清理完成: removed={count}")


def main() -> None:
    log("開始清理過期檔案與 ZIP...")
    cleanup_uploads()
    cleanup_tmp_zips()
    log("清理任務完成")


if __name__ == "__main__":
    main()
PY

  cat >"${APP_DIR}/templates/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="zh-Hant">
<head>
  <meta charset="utf-8">
  <title>SUEN Pan 上傳</title>
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
  <h1>SUEN Pan</h1>
  <form action="/upload" method="post" enctype="multipart/form-data">
    <label>上傳 ID:
      <input type="text" name="upload_id" required value="{{ upload_id or '' }}">
    </label>
    {% if has_secret %}
    <label>上傳口令:
      <input type="password" name="secret">
    </label>
    {% endif %}
    <p>單檔大小上限：約 {{ max_file_mb }} MB</p>
    <input type="file" name="files" multiple required>
    <button type="submit">上傳</button>
  </form>
</body>
</html>
HTML

  cat >"${APP_DIR}/templates/upload_success.html" <<'HTML'
<!DOCTYPE html>
<html lang="zh-Hant">
<head>
  <meta charset="utf-8">
  <title>上傳完成 - SUEN Pan</title>
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
  <h1>上傳完成</h1>
  <p>上傳 ID: <code>{{ upload_id }}</code></p>
  <p>檔案數量: {{ file_count }}</p>
  <p>總大小：約 <code>{{ (total_bytes / (1024*1024)) | round(2) }} MB</code></p>
  <p>
    下載連結示例：<br>
    <code>/z/{{ upload_id }}</code> 打包下載全部。
  </p>
</body>
</html>
HTML

  cat >"${APP_DIR}/static/style.css" <<'CSS'
body {
  font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  max-width: 720px;
  margin: 2rem auto;
  padding: 0 1rem;
}
h1 {
  margin-bottom: 1rem;
}
label {
  display: block;
  margin: 0.5rem 0;
}
input[type="text"],
input[type="password"],
input[type="file"] {
  display: block;
  margin-top: 0.25rem;
}
button {
  margin-top: 1rem;
  padding: 0.5rem 1.25rem;
}
CSS

  chown -R "$APP_USER":"$APP_USER" "$APP_DIR"
}

write_systemd_units() {
  log "INFO" "寫入 systemd 服務..."

  cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=SUEN Pan FastAPI service
After=network.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${APP_DIR}/venv/bin/uvicorn app.main:app --host 127.0.0.1 --port ${APP_PORT} --proxy-headers
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/${SERVICE_NAME}-cleanup.service <<EOF
[Unit]
Description=SUEN Pan cleanup service

[Service]
Type=oneshot
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${APP_DIR}/venv/bin/python app/cleanup.py
EOF

  cat >/etc/systemd/system/${SERVICE_NAME}-cleanup.timer <<EOF
[Unit]
Description=SUEN Pan cleanup timer

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

disable_old_units() {
  systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
  systemctl stop "${SERVICE_NAME}-cleanup.service" 2>/dev/null || true
  systemctl stop "${SERVICE_NAME}-cleanup.timer" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}-cleanup.timer" 2>/dev/null || true
}

write_nginx_conf_http_only() {
  cat >"$NGINX_SITE_AVAILABLE" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    client_max_body_size 0;

    root ${CERTBOT_WEBROOT};

    location /.well-known/acme-challenge/ {
        root ${CERTBOT_WEBROOT};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
}

write_nginx_conf_full() {
  cat >"$NGINX_SITE_AVAILABLE" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    client_max_body_size 0;

    root ${CERTBOT_WEBROOT};

    location /.well-known/acme-challenge/ {
        root ${CERTBOT_WEBROOT};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    client_max_body_size 0;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_request_buffering off;
    }
}
EOF
}

ensure_cert() {
  if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
    log "INFO" "已存在證書，略過申請: /etc/letsencrypt/live/${DOMAIN}/"
    return 0
  fi

  log "INFO" "尚未發現證書，準備透過 webroot 申請 Let’s Encrypt..."

  write_nginx_conf_http_only
  ln -sf "$NGINX_SITE_AVAILABLE" "$NGINX_SITE_ENABLED"
  rm -f "$NGINX_DEFAULT_SITE" 2>/dev/null || true

  nginx -t
  systemctl reload nginx

  certbot certonly \
    --webroot -w "$CERTBOT_WEBROOT" \
    -d "$DOMAIN" \
    --agree-tos \
    --register-unsafely-without-email \
    --non-interactive
}

reload_nginx_with_full_conf() {
  write_nginx_conf_full
  ln -sf "$NGINX_SITE_AVAILABLE" "$NGINX_SITE_ENABLED"
  rm -f "$NGINX_DEFAULT_SITE" 2>/dev/null || true
  nginx -t
  systemctl reload nginx
}

enable_units() {
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service"
  systemctl enable "${SERVICE_NAME}-cleanup.timer"
  systemctl start "${SERVICE_NAME}.service"
  systemctl start "${SERVICE_NAME}-cleanup.timer"
}

main() {
  log "INFO" "SUEN Pan 安裝腳本啟動 (版本: ${INSTALLER_VERSION})"

  require_root
  detect_os
  ensure_packages
  ensure_user
  create_dirs
  write_env_file
  check_tmp_space
  create_venv_and_deps
  write_app_code

  disable_old_units
  write_systemd_units
  ensure_cert
  reload_nginx_with_full_conf
  enable_units

  log "INFO" "安裝完成。"
  log "INFO" "請確認 DNS 已指向本機，然後訪問: https://${DOMAIN}/"
}

main "$@"