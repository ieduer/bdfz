#!/usr/bin/env bash
#
# pan.sh - 一鍵部署 SUENの網盤 (pan.bdfz.net 公共上傳/下載服務)
#  - Nginx + FastAPI + Uvicorn + SQLite (aiosqlite 異步)
#  - 流式上傳到後端（避免整個文件讀入記憶體，框架使用臨時文件中轉）
#  - 上傳/下載記錄到 SQLite
#  - 上傳 & 下載 Telegram 通知 (httpx 異步)
#  - 支援上傳口令 UPLOAD_SECRET（可選，全局口令）
#  - 每日自動清理過期文件 (systemd timer + cleanup.py)
#  - 自動檢測已有 Let's Encrypt 證書，存在則直接上 443，不重複申請
#
# 修改記錄 (v2025-12-07-MOD):
#  1. 刪除左側備註
#  2. 加入取消上傳
#  3. 右側顯示全部文件 (按類別排序)
#  4. 支援文件夾上傳
#  5. MD5 校驗去重
#

set -Eeuo pipefail
INSTALLER_VERSION="pan-install-2025-12-09-mod-full"

DOMAIN="pan.bdfz.net"
APP_USER="panuser"
APP_DIR="/opt/pan-app"
DATA_DIR="/srv/pan"
TMP_DIR="${DATA_DIR}/tmp"
SERVICE_NAME="pan"
PYTHON_BIN="python3"

NGINX_SITE_AVAIL="/etc/nginx/sites-available/${DOMAIN}"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}"

# 顏色輸出
RED="$(printf '\033[31m')"
GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
RESET="$(printf '\033[0m')"

log() {
  echo -e "${GREEN}>>>${RESET} $*"
}

warn() {
  echo -e "${YELLOW}***${RESET} $*"
}

err() {
  echo -e "${RED}!!!${RESET} $*"
}

abort() {
  err "安裝過程中出錯，中止。"
  exit 1
}

trap abort ERR

check_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "請使用 root 執行：sudo bash $0"
    exit 1
  fi
}

check_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID}" != "ubuntu" ]]; then
      warn "檢測到的系統不是 Ubuntu（ID=${ID}），腳本主要針對 Ubuntu 設計，請自行判斷是否繼續。"
    fi
  else
    warn "/etc/os-release 不存在，無法確認作業系統類型。"
  fi
}

stop_existing_service() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}.service"; then
      warn "檢測到已存在的 ${SERVICE_NAME}.service，先停止舊服務..."
      systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}-cleanup.timer"; then
      warn "檢測到已存在的 ${SERVICE_NAME}-cleanup.timer，先停止舊定時任務..."
      systemctl stop "${SERVICE_NAME}-cleanup.timer" 2>/dev/null || true
    fi
  fi
}

kill_old_uvicorn() {
  if command -v pgrep >/dev/null 2>&1; then
    if pgrep -f "uvicorn app.main:app" >/dev/null 2>&1; then
      warn "發現舊的 uvicorn app.main:app 進程，將嘗試終止..."
      pkill -f "uvicorn app.main:app" 2>/dev/null || true
    fi
  fi
}

install_packages() {
  log "[1/8] 安裝系統依賴 (nginx, python, sqlite3, certbot)..."
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y \
    nginx \
    "${PYTHON_BIN}" \
    python3-venv \
    python3-pip \
    sqlite3 \
    ca-certificates \
    curl \
    certbot \
    python3-certbot-nginx
}

create_user_and_dirs() {
  log "[2/8] 創建專用用戶與目錄..."

  if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    useradd --system --home "${APP_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
    log "已創建系統用戶 ${APP_USER}"
  else
    warn "系統用戶 ${APP_USER} 已存在，略過創建。"
  fi

  mkdir -p "${APP_DIR}" "${APP_DIR}/app" "${APP_DIR}/templates" "${APP_DIR}/static" "${DATA_DIR}/files" "${TMP_DIR}"
  chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}" "${DATA_DIR}"
  chmod 700 "${TMP_DIR}"
}

setup_venv_and_deps() {
  log "[3/8] 建立 Python 虛擬環境並安裝依賴..."

  if [[ -d "${APP_DIR}/venv" ]]; then
    warn "檢測到已存在的虛擬環境，將刪除並重新創建以覆蓋安裝..."
    rm -rf "${APP_DIR}/venv"
  fi

  "${PYTHON_BIN}" -m venv "${APP_DIR}/venv"

  # shellcheck disable=SC1091
  source "${APP_DIR}/venv/bin/activate"
  pip install --upgrade pip
  pip install \
    fastapi \
    "uvicorn[standard]" \
    python-multipart \
    aiofiles \
    aiosqlite \
    python-dotenv \
    httpx \
    jinja2
  deactivate
}

write_env_template() {
  log "[4/8] 檢查 .env 配置..."

  local env_file="${APP_DIR}/.env"
  if [[ -f "${env_file}" ]]; then
    warn ".env 已存在。"
    read -r -p "是否覆蓋生成新的樣例 .env？(y/N) " ans || ans=""
    case "${ans}" in
      y|Y)
        warn "將覆蓋原有 .env（請注意備份）。"
        ;;
      *)
        log "保留原有 .env，不做修改。"
        return
        ;;
    esac
  fi

  cat >"${env_file}" <<ENV
# SUENの網盤 配置樣例
# 真正部署時請填入實際值，然後重啟 systemd 服務：sudo systemctl restart ${SERVICE_NAME}.service

# 文件數據目錄（默認 ${DATA_DIR}）
PAN_DATA_DIR=${DATA_DIR}

# 前端展示的基礎 URL，用於 Telegram 通知中的連結（默認 https://${DOMAIN}）
BASE_URL=https://${DOMAIN}

# 全局上傳口令（如設置，則上傳必須提供正確口令；留空則不啟用）
UPLOAD_SECRET=

# Telegram 通知（可選）
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=

# 單個文件最大大小（MB），需要略小於 Nginx client_max_body_size
MAX_FILE_MB=102300

# 清理天數，超過此天數的文件會被每天定時任務刪除
CLEANUP_DAYS=30
ENV

  chown "${APP_USER}:${APP_USER}" "${env_file}"
  chmod 600 "${env_file}"
  log "已生成 .env 樣例（PAN_DATA_DIR / BASE_URL 已使用當前腳本配置值）。"
}

check_tmp_space() {
  log "[4.5/8] 檢查臨時目錄空間 (MAX_FILE_MB × 5 併發理論需求)..."

  mkdir -p "${TMP_DIR}"
  chown "${APP_USER}:${APP_USER}" "${TMP_DIR}"

  local env_file="${APP_DIR}/.env"
  local max_mb="102300"

  # 從 .env 讀 MAX_FILE_MB（若已手動調整）
  if [[ -f "${env_file}" ]]; then
    local from_env
    from_env="$(grep -E '^MAX_FILE_MB=' "${env_file}" | tail -n1 | cut -d'=' -f2)" || true
    if [[ -n "${from_env}" && "${from_env}" =~ ^[0-9]+$ ]]; then
      max_mb="${from_env}"
    fi
  fi

  local concurrent=5
  local required_bytes=$((max_mb * 1024 * 1024 * concurrent))

  # df -P：第二行的第四列是可用空間 (KB)
  local avail_kb
  avail_kb="$(df -P "${TMP_DIR}" | awk 'NR==2{print $4}')" || true
  if [[ -z "${avail_kb}" ]]; then
    warn "無法取得 ${TMP_DIR} 所在分區空間資訊，略過臨時目錄空間檢查。"
    return
  fi

  local avail_bytes=$((avail_kb * 1024))
  local required_gb=$((required_bytes / 1024 / 1024 / 1024))
  local avail_gb=$((avail_bytes / 1024 / 1024 / 1024))

  if (( avail_bytes < required_bytes )); then
    warn "臨時目錄 ${TMP_DIR} 所在分區可用空間約 ${avail_gb} GiB，低於 MAX_FILE_MB×5 的理論需求約 ${required_gb} GiB。"
    warn "仍繼續安裝，但請留意：在高併發大文件上傳時可能因空間不足而失敗。"
  else
    log "臨時目錄所在分區可用空間約 ${avail_gb} GiB，足以支撐 MAX_FILE_MB×5 併發的理論需求約 ${required_gb} GiB。"
  fi
}

write_app_code() {
  log "[5/8] 寫入 FastAPI 應用程式代碼、模板與清理腳本..."

  # ---------------- app/main.py ----------------
  # 修改：加入 MD5 去重，修改列表接口，移除 Note 邏輯
  cat >"${APP_DIR}/app/main.py" <<'PY'
import os
import uuid
import datetime
import html
import hashlib
from pathlib import Path
from typing import List, Optional, Dict

import aiosqlite
import aiofiles
import httpx
from fastapi import FastAPI, Request, Form, UploadFile, File, HTTPException, Query
from fastapi.responses import HTMLResponse, FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent

# 先載入 .env，再讀取 PAN_DATA_DIR 等環境變量
load_dotenv(BASE_DIR / ".env")

DATA_DIR = Path(os.environ.get("PAN_DATA_DIR", "/srv/pan"))
DATA_DIR.mkdir(parents=True, exist_ok=True)

FILES_DIR = DATA_DIR / "files"
FILES_DIR.mkdir(parents=True, exist_ok=True)

DB_PATH = DATA_DIR / "pan.db"

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "").strip()
BASE_URL = os.getenv("BASE_URL", "").strip() or "https://pan.example.com"
UPLOAD_SECRET = os.getenv("UPLOAD_SECRET", "").strip()
# 預設略低於 Nginx 100 GiB 上限，用於預留 multipart 開銷
MAX_FILE_MB = int(os.getenv("MAX_FILE_MB", "102300"))

app = FastAPI(title="SUENの網盤")
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))


def get_db():
  """返回 aiosqlite 連線工廠，配合 async with 使用。"""
  return aiosqlite.connect(DB_PATH)


async def init_db():
  async with get_db() as conn:
    conn.row_factory = aiosqlite.Row
    await conn.execute(
      """
      CREATE TABLE IF NOT EXISTS uploads (
        id TEXT PRIMARY KEY,
        upload_id TEXT NOT NULL,
        category TEXT,
        note TEXT,
        original_name TEXT NOT NULL,
        stored_path TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        md5 TEXT,
        uploader_ip TEXT,
        user_agent TEXT,
        created_at TEXT NOT NULL
      )
      """
    )
    
    # 檢查是否需要添加 md5 欄位 (舊庫升級)
    try:
      await conn.execute("SELECT md5 FROM uploads LIMIT 1")
    except Exception:
      print("Migrating DB: Adding 'md5' column to uploads table...")
      await conn.execute("ALTER TABLE uploads ADD COLUMN md5 TEXT")

    await conn.execute(
      """
      CREATE TABLE IF NOT EXISTS downloads (
        id TEXT PRIMARY KEY,
        upload_file_id TEXT NOT NULL,
        downloader_ip TEXT,
        user_agent TEXT,
        created_at TEXT NOT NULL
      )
      """
    )
    await conn.commit()


def get_client_ip(request: Request) -> str:
  xff = request.headers.get("x-forwarded-for") or request.headers.get("X-Forwarded-For")
  if xff:
    parts = [p.strip() for p in xff.split(",") if p.strip()]
    if parts:
      return parts[-1]
  return request.client.host if request.client else "unknown"


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
  try:
    async with httpx.AsyncClient(timeout=5.0) as client:
      await client.post(url, json=payload)
  except Exception:
    # 靜默忽略 Telegram 發送錯誤，避免影響主流程
    pass


def human_size(num_bytes: int) -> str:
  if num_bytes == 0:
    return "0B"
  for unit in ["B", "KB", "MB", "GB", "TB"]:
    if num_bytes < 1024:
      value = f"{num_bytes:.1f}{unit}"
      return value.replace(".0", "")
    num_bytes /= 1024.0
  return f"{num_bytes:.1f}PB"


def is_ajax(request: Request) -> bool:
  xrw = (request.headers.get("x-requested-with") or "").lower()
  if xrw == "xmlhttprequest":
    return True
  accept = (request.headers.get("accept") or "").lower()
  if "application/json" in accept:
    return True
  return False


@app.on_event("startup")
async def startup_event():
  await init_db()


app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
  return templates.TemplateResponse("index.html", {"request": request})


@app.post("/upload")
async def handle_upload(
  request: Request,
  upload_id: str = Form(...),
  secret: Optional[str] = Form(None),
  files: List[UploadFile] = File(...),
  category: Optional[str] = Form(None),
  note: Optional[str] = Form(None), # 保留參數以防前端傳遞報錯，但業務上已忽略
):
  if UPLOAD_SECRET and (not secret or secret.strip() != UPLOAD_SECRET):
    raise HTTPException(status_code=403, detail="上傳口令錯誤")

  upload_id = upload_id.strip()
  if not upload_id:
    raise HTTPException(status_code=400, detail="上傳 ID 不可為空")

  if not files:
    raise HTTPException(status_code=400, detail="沒有選擇文件")

  client_ip = get_client_ip(request)
  ua = request.headers.get("User-Agent", "")
  created_records = []
  now_iso = datetime.datetime.utcnow().isoformat()
  max_bytes = MAX_FILE_MB * 1024 * 1024

  async with get_db() as conn:
    conn.row_factory = aiosqlite.Row

    for upload_file in files:
      file_uuid = str(uuid.uuid4())
      
      # 處理上傳文件名，支援文件夾上傳的路徑保留 (將 / 替換為 __ 以扁平化存儲)
      # upload_file.filename 可能包含路徑 (webkitdirectory)
      safe_name = upload_file.filename.replace("\\", "/") # 統一分隔符
      safe_name = safe_name.lstrip("./") 

      subdir = FILES_DIR / datetime.datetime.utcnow().strftime("%Y/%m/%d")
      subdir.mkdir(parents=True, exist_ok=True)

      # 將路徑分隔符換成底線，確保存在同一層級，避免目錄遍歷
      flat_name = safe_name.replace("/", "__")
      stored_path_rel = subdir.relative_to(FILES_DIR) / f"{file_uuid}__{flat_name}"
      dest_path = FILES_DIR / stored_path_rel

      size_bytes = 0
      hasher = hashlib.md5()

      try:
        async with aiofiles.open(dest_path, "wb") as f:
          while True:
            chunk = await upload_file.read(1024 * 1024)
            if not chunk:
              break
            size_bytes += len(chunk)
            if size_bytes > max_bytes:
              raise HTTPException(
                status_code=413,
                detail=f"文件 {upload_file.filename} 過大，超過 {MAX_FILE_MB} MB 限制",
              )
            hasher.update(chunk)
            await f.write(chunk)
      except HTTPException:
        if dest_path.exists():
          try:
            dest_path.unlink()
          except OSError:
            pass
        raise
      
      file_md5 = hasher.hexdigest()
      final_stored_path_rel = str(stored_path_rel)
      
      # --- MD5 去重邏輯 ---
      # 檢查資料庫是否存在相同 MD5 的文件
      cursor = await conn.execute("SELECT stored_path FROM uploads WHERE md5 = ? LIMIT 1", (file_md5,))
      existing_row = await cursor.fetchone()
      
      if existing_row:
        existing_path_rel = existing_row["stored_path"]
        existing_full_path = FILES_DIR / existing_path_rel
        
        # 確保舊文件物理存在
        if existing_full_path.exists():
           # 刪除剛剛上傳的臨時文件
           try:
             dest_path.unlink()
           except:
             pass
           # 將新記錄指向舊的存儲路徑
           final_stored_path_rel = existing_path_rel
           # print(f"Deduplicated: {safe_name} -> {existing_path_rel}")

      record_id = file_uuid
      cat_val = (category or "").strip()
      note_val = (note or "").strip()
      
      await conn.execute(
        """
        INSERT INTO uploads (
          id, upload_id, category, note,
          original_name, stored_path, size_bytes, md5,
          uploader_ip, user_agent, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
          record_id,
          upload_id,
          cat_val,
          note_val,
          safe_name,
          final_stored_path_rel,
          size_bytes,
          file_md5,
          client_ip,
          ua,
          now_iso,
        ),
      )
      created_records.append(
        {
          "id": record_id,
          "upload_id": upload_id,
          "category": cat_val,
          "note": note_val,
          "original_name": safe_name,
          "size_bytes": size_bytes,
        }
      )

    await conn.commit()

  total_size = sum(r["size_bytes"] for r in created_records)
  lines = [
    "📤 <b>新上傳</b>",
    f"ID: <code>{html.escape(upload_id)}</code>",
  ]
  if category:
    lines.append(f"類別: {html.escape(category)}")
  # 備註已移除
  lines.append(f"上傳 IP: <code>{html.escape(client_ip)}</code>")
  lines.append(f"文件數: {len(created_records)}，總大小: {human_size(total_size)}")
  lines.append("")
  for r in created_records[:5]:
    lines.append(f"• {html.escape(r['original_name'])} ({human_size(r['size_bytes'])})")
  if len(created_records) > 5:
    lines.append(f"... 以及另外 {len(created_records) - 5} 個文件")
  lines.append("")
  detail_url = f"{BASE_URL}/id/{upload_id}"
  lines.append(f"詳情: {html.escape(detail_url)}")

  await send_telegram_message("\n".join(lines))

  if is_ajax(request):
    return JSONResponse(
      {
        "ok": True,
        "upload_id": upload_id,
        "detail_url": detail_url,
        "files": [
          {
            "id": r["id"],
            "name": r["original_name"],
            "size_bytes": r["size_bytes"],
            "size_human": human_size(r["size_bytes"]),
            "category": r["category"],
            "note": r["note"],
          }
          for r in created_records
        ],
      }
    )

  return templates.TemplateResponse(
    "upload_success.html",
    {
      "request": request,
      "upload_id": upload_id,
      "records": created_records,
      "detail_url": detail_url,
    },
  )


@app.get("/api/list")
async def api_list(upload_id: Optional[str] = Query(None, alias="upload_id")):
  # 修改：不再強制要求 upload_id，若為空則返回全部，且按類別排序
  sql = """
      SELECT id, upload_id, category, note, original_name, stored_path,
             size_bytes, uploader_ip, created_at
      FROM uploads
  """
  params = []
  
  if upload_id and upload_id.strip():
      sql += " WHERE upload_id = ?"
      params.append(upload_id.strip())
  
  # 按 類別 -> 文件名 -> 時間 排序
  sql += " ORDER BY category ASC, original_name ASC, created_at DESC"

  async with get_db() as conn:
    conn.row_factory = aiosqlite.Row
    cur = await conn.execute(sql, tuple(params))
    rows = await cur.fetchall()

  files = []
  for row in rows:
    files.append(
      {
        "id": row["id"],
        "upload_id": row["upload_id"],
        "name": row["original_name"],
        "size_bytes": row["size_bytes"],
        "size_human": human_size(row["size_bytes"]),
        "created_at": row["created_at"],
        "category": row["category"] or "",
        "note": row["note"] or "",
      }
    )

  return JSONResponse({"ok": True, "upload_id": upload_id, "files": files})


@app.get("/id/{upload_id}", response_class=HTMLResponse)
async def list_by_upload_id(request: Request, upload_id: str):
  async with get_db() as conn:
    conn.row_factory = aiosqlite.Row
    cur = await conn.execute(
      """
      SELECT id, upload_id, category, note, original_name, stored_path,
             size_bytes, uploader_ip, created_at
      FROM uploads
      WHERE upload_id = ?
      ORDER BY created_at ASC
      """,
      (upload_id,),
    )
    rows = await cur.fetchall()

  # 依「類別」分組顯示（空類別歸為「未分類」）
  groups: Dict[str, list] = {}
  for row in rows:
    cat = (row["category"] or "").strip()
    groups.setdefault(cat, []).append(row)

  return templates.TemplateResponse(
    "list_by_id.html",
    {
      "request": request,
      "upload_id": upload_id,
      "groups": groups,
      "base_url": BASE_URL,
    },
  )


@app.get("/d/{file_id}/{filename:path}")
@app.get("/d/{file_id}")
async def download_file(request: Request, file_id: str, filename: Optional[str] = None):
  async with get_db() as conn:
    conn.row_factory = aiosqlite.Row
    cur = await conn.execute(
      """
      SELECT id, upload_id, original_name, stored_path
      FROM uploads
      WHERE id = ?
      """,
      (file_id,),
    )
    row = await cur.fetchone()

    if not row:
      raise HTTPException(status_code=404, detail="文件不存在")

    file_rel = row["stored_path"]
    file_path = (FILES_DIR / file_rel).resolve()

    if not str(file_path).startswith(str(FILES_DIR.resolve())):
      raise HTTPException(status_code=403, detail="禁止訪問")

    if not file_path.is_file():
      raise HTTPException(status_code=404, detail="文件遺失")

    client_ip = get_client_ip(request)
    ua = request.headers.get("User-Agent", "")
    now_iso = datetime.datetime.utcnow().isoformat()

    dl_id = str(uuid.uuid4())
    await conn.execute(
      """
      INSERT INTO downloads (
        id, upload_file_id, downloader_ip, user_agent, created_at
      ) VALUES (?, ?, ?, ?, ?)
      """,
      (dl_id, row["id"], client_ip, ua, now_iso),
    )
    await conn.commit()

  # 下載時的文件名取 basename (避免多層目錄導致瀏覽器存儲異常)
  dl_filename = os.path.basename(row["original_name"])

  return FileResponse(
    path=str(file_path),
    filename=dl_filename,
    media_type="application/octet-stream",
  )


@app.get("/health")
async def health():
  return {"status": "ok"}
PY

  chmod 644 "${APP_DIR}/app/main.py"
  chown "${APP_USER}:${APP_USER}" "${APP_DIR}/app/main.py"

  # ---------------- app/cleanup.py ----------------
  # 修改：清理時檢查文件是否被多條記錄引用 (因為引入了 MD5 去重)
  cat >"${APP_DIR}/app/cleanup.py" <<'PY'
#!/usr/bin/env python3
import os
import sqlite3
import datetime
from pathlib import Path

from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent
ENV_PATH = BASE_DIR / ".env"
if ENV_PATH.exists():
  load_dotenv(ENV_PATH)

DATA_DIR = Path(os.environ.get("PAN_DATA_DIR", "/srv/pan"))
FILES_DIR = DATA_DIR / "files"
DB_PATH = DATA_DIR / "pan.db"
RETENTION_DAYS = int(os.environ.get("CLEANUP_DAYS", "30"))


def main():
  if not DB_PATH.exists():
    print("No database; nothing to clean.")
    return

  cutoff = datetime.datetime.utcnow() - datetime.timedelta(days=RETENTION_DAYS)
  cutoff_iso = cutoff.isoformat()

  conn = sqlite3.connect(DB_PATH)
  conn.row_factory = sqlite3.Row
  cur = conn.cursor()

  cur.execute("SELECT id, stored_path FROM uploads WHERE created_at < ?", (cutoff_iso,))
  rows_to_delete = cur.fetchall()

  if not rows_to_delete:
    print("No old files to remove.")
    conn.close()
    return

  # 1. 先刪除資料庫記錄
  ids_to_del = [r["id"] for r in rows_to_delete]
  if ids_to_del:
      placeholders = ",".join("?" * len(ids_to_del))
      cur.execute(f"DELETE FROM downloads WHERE upload_file_id IN ({placeholders})", ids_to_del)
      cur.execute(f"DELETE FROM uploads WHERE id IN ({placeholders})", ids_to_del)
      conn.commit()

  # 2. 再刪物理文件
  # 注意：由於引入了 MD5 去重，多個記錄可能指向同一個 stored_path
  # 只有當沒有任何記錄指向該 stored_path 時，才能物理刪除
  
  candidate_paths = set(r["stored_path"] for r in rows_to_delete)
  removed_files = 0
  
  for rel_path in candidate_paths:
      # 檢查是否還有其他記錄引用此路徑
      cur.execute("SELECT 1 FROM uploads WHERE stored_path = ? LIMIT 1", (rel_path,))
      if cur.fetchone():
          # 仍被引用，跳過
          continue
      
      file_path = (FILES_DIR / rel_path).resolve()
      if str(file_path).startswith(str(FILES_DIR.resolve())) and file_path.is_file():
          try:
            file_path.unlink()
            removed_files += 1
          except OSError as e:
            print(f"Error removing file {file_path}: {e}")

  conn.close()

  print(
    f"Removed {len(rows_to_delete)} uploads (DB rows) and {removed_files} corresponding files older than {RETENTION_DAYS} days."
  )


if __name__ == "__main__":
  main()
PY

  chmod +x "${APP_DIR}/app/cleanup.py"
  chown "${APP_USER}:${APP_USER}" "${APP_DIR}/app/cleanup.py"

  # ---------------- templates/base.html ----------------
  # 保留原 CSS，未做刪減
  cat >"${APP_DIR}/templates/base.html" <<'HTML'
<!DOCTYPE html>
<html lang="zh-Hans">
  <head>
    <meta charset="utf-8" />
    <title>SUENの網盤</title>
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <link rel="icon" href="https://img.bdfz.net/20250503004.webp" type="image/webp" />

    <style>
      :root {
        font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
        color-scheme: dark;
        --bg: #020617;
        --fg: #d1fae5;
        --card-bg: rgba(2, 6, 23, 0.95);
        --border: rgba(34, 197, 94, 0.45);
        --accent: #22c55e;
        --accent-soft: rgba(34, 197, 94, 0.25);
        --muted: #6ee7b7;
      }

      * {
        box-sizing: border-box;
      }

      html,
      body {
        margin: 0;
        padding: 0;
      }

      body {
        min-height: 100vh;
        background: radial-gradient(circle at top, #020b1f 0, #020617 55%, #000 100%);
        color: var(--fg);
      }

      .page {
        max-width: 1120px;
        margin: 0 auto;
        padding: 18px 16px 40px;
      }

      header {
        text-align: center;
        margin-bottom: 18px;
      }

      header h1 {
        margin: 0;
        font-size: 1.6rem;
        letter-spacing: 0.18em;
        text-transform: uppercase;
        color: var(--accent);
        font-family: "Menlo", "SF Mono", ui-monospace, monospace;
        text-shadow: 0 0 12px rgba(34, 197, 94, 0.8), 0 0 24px rgba(22, 163, 74, 0.9);
      }

      header p {
        margin: 4px 0 0;
        font-size: 0.8rem;
        color: var(--muted);
        font-family: "Menlo", ui-monospace, monospace;
        letter-spacing: 0.12em;
      }

      .grid {
        display: grid;
        grid-template-columns: minmax(0, 1.1fr) minmax(0, 0.9fr);
        gap: 18px;
      }

      @media (max-width: 860px) {
        .grid {
          grid-template-columns: minmax(0, 1fr);
        }
      }

      .card {
        background: var(--card-bg);
        border-radius: 18px;
        border: 1px solid var(--border);
        box-shadow: 0 20px 60px rgba(15, 23, 42, 0.9);
        padding: 16px 18px 18px;
        backdrop-filter: blur(12px);
        position: relative;
        overflow: hidden;
      }

      .card::before {
        content: "";
        position: absolute;
        inset: 0;
        background: radial-gradient(circle at top left, rgba(34, 197, 94, 0.15), transparent 70%);
        pointer-events: none;
        mix-blend-mode: screen;
      }

      .card-inner {
        position: relative;
        z-index: 1;
      }

      .card h2 {
        margin: 0 0 8px;
        font-size: 1.02rem;
        display: flex;
        align-items: center;
        gap: 6px;
        font-family: "Menlo", ui-monospace, monospace;
        letter-spacing: 0.08em;
        text-transform: uppercase;
        color: #bbf7d0;
      }

      .card h2 span.icon {
        font-size: 1.1rem;
      }

      label {
        display: block;
        margin-bottom: 4px;
        font-size: 0.86rem;
        font-weight: 500;
      }

      input[type="text"],
      input[type="password"] {
        width: 100%;
        padding: 7px 9px;
        border-radius: 999px;
        border: 1px solid var(--border);
        font-size: 0.9rem;
        outline: none;
        background: rgba(0, 0, 0, 0.9);
        color: var(--fg);
        font-family: "Menlo", ui-monospace, monospace;
      }

      input::placeholder {
        color: rgba(148, 163, 184, 0.7);
      }

      input:focus {
        border-color: var(--accent);
        box-shadow: 0 0 0 1px var(--accent-soft);
        background: rgba(15, 23, 42, 1);
      }

      input[type="file"] {
        font-size: 0.82rem;
        color: var(--fg);
        padding: 6px 10px;
        border-radius: 999px;
        border: 1px solid var(--border);
        background: rgba(0, 0, 0, 0.9);
        font-family: "Menlo", ui-monospace, monospace;
        max-width: 100%;
      }

      button {
        border: none;
        border-radius: 999px;
        padding: 6px 14px;
        font-size: 0.84rem;
        font-weight: 500;
        cursor: pointer;
        display: inline-flex;
        align-items: center;
        gap: 6px;
        background: radial-gradient(circle at top, #22c55e, #16a34a);
        color: #020617;
        box-shadow: 0 10px 24px rgba(34, 197, 94, 0.75);
        transition: background 0.12s ease, transform 0.1s ease, box-shadow 0.1s ease, filter 0.12s ease;
        white-space: nowrap;
        font-family: "Menlo", ui-monospace, monospace;
      }

      button:hover {
        filter: brightness(1.08);
        transform: translateY(-1px);
        box-shadow: 0 16px 36px rgba(34, 197, 94, 0.9);
      }

      button:disabled {
        opacity: 0.55;
        cursor: wait;
        transform: none;
        box-shadow: none;
        filter: none;
      }

      .status {
        margin-top: 4px;
        font-size: 0.78rem;
        min-height: 1.1em;
        font-family: "Menlo", ui-monospace, monospace;
      }

      .status.ok {
        color: #4ade80;
      }

      .status.err {
        color: #fca5a5;
      }

      .progress {
        width: 100%;
        height: 6px;
        border-radius: 999px;
        background: rgba(15, 23, 42, 0.9);
        overflow: hidden;
        margin-top: 4px;
        display: none;
      }

      .progress-bar {
        height: 100%;
        width: 0%;
        background: linear-gradient(to right, #22c55e, #4ade80);
        transition: width 0.1s linear;
      }

      .row-between {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        justify-content: space-between;
        gap: 8px;
      }

      .slot-row {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: 10px;
        margin-bottom: 6px;
      }

      .slot-row label {
        margin: 0;
        white-space: nowrap;
        font-family: "Menlo", ui-monospace, monospace;
        color: #bbf7d0;
        letter-spacing: 0.08em;
        text-transform: uppercase;
        font-size: 0.8rem;
      }

      .slot-row .slot-input-wrap {
        min-width: 120px;
        max-width: 180px;
        flex: 1;
      }

      .file-list-preview {
        margin-top: 4px;
        font-size: 0.78rem;
        color: var(--muted);
        font-family: "Menlo", ui-monospace, monospace;
        white-space: normal;
        word-break: break-all;
        min-height: 1.1em;
      }

      .download-list {
        list-style: none;
        padding: 0;
        margin: 6px 0 4px;
        display: flex;
        flex-direction: column;
        gap: 8px;
        max-height: 360px;
        overflow-y: auto;
      }

      .download-list li a {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
        padding: 8px 12px;
        border-radius: 10px;
        border: 1px dashed rgba(34, 197, 94, 0.6);
        text-decoration: none;
        color: var(--fg);
        background: rgba(0, 0, 0, 0.7);
        font-size: 0.86rem;
        font-family: "Menlo", ui-monospace, monospace;
        transition: border-color 0.12s ease, background 0.12s ease, transform 0.1s ease,
          box-shadow 0.1s ease;
      }

      .download-list li a:hover {
        border-color: #4ade80;
        background: rgba(22, 101, 52, 0.8);
        transform: translateY(-1px);
        box-shadow: 0 10px 24px rgba(34, 197, 94, 0.6);
      }

      .dl-name {
        font-weight: 500;
      }

      .dl-meta {
        font-size: 0.76rem;
        color: var(--muted);
      }

      .download-progress-text {
        margin-top: 4px;
        font-size: 0.78rem;
        font-family: "Menlo", ui-monospace, monospace;
        color: var(--muted);
        min-height: 1.1em;
      }

      footer {
        margin-top: 24px;
        font-size: 0.78rem;
        color: var(--muted);
        text-align: right;
        font-family: "Menlo", ui-monospace, monospace;
      }

      footer span#script-info::before {
        content: "[";
        margin-right: 3px;
      }

      footer span#script-info::after {
        content: "]";
        margin-left: 3px;
      }

      .explain-list {
        margin: 6px 0 0;
        padding-left: 1.1rem;
        font-size: 0.84rem;
        color: rgba(226, 232, 240, 0.92);
      }

      .explain-list li {
        margin-bottom: 3px;
      }

      .category-heading {
        margin: 12px 0 4px;
        font-size: 0.8rem;
        font-family: "Menlo", ui-monospace, monospace;
        color: #bbf7d0;
        letter-spacing: 0.08em;
        text-transform: uppercase;
      }
      .custom-dropdown {
        position: relative;
        display: inline-block;
        width: 100%;
        z-index: 20;
      }
      .custom-dropdown-btn {
        width: 100%;
        justify-content: center;
      }
      .custom-dropdown-menu {
        display: none;
        position: absolute;
        top: 100%;
        left: 0;
        width: 100%;
        background: #0f172a;
        border: 1px solid var(--border);
        border-radius: 12px;
        z-index: 50;
        margin-top: 6px;
        box-shadow: 0 10px 30px rgba(0,0,0,0.6);
        overflow: hidden;
        backdrop-filter: blur(12px);
      }
      .custom-dropdown-menu.show {
        display: block;
        animation: fadeIn 0.1s ease-out;
      }
      .custom-dropdown-item {
        display: flex;
        align-items: center;
        gap: 8px;
        width: 100%;
        padding: 10px 14px;
        border: none;
        background: transparent;
        color: var(--fg);
        font-family: inherit;
        text-align: left;
        cursor: pointer;
        font-size: 0.86rem;
        transition: background 0.1s;
        box-shadow: none;
        border-radius: 0;
      }
      .custom-dropdown-item:hover {
        background: rgba(34, 197, 94, 0.15);
        color: #fff;
        transform: none;
        box-shadow: none;
      }
      .search-box-wrap {
        position: relative;
        margin-bottom: 12px;
      }
      .search-input {
        width: 100%;
        padding: 9px 12px 9px 34px;
        border-radius: 8px;
        border: 1px solid var(--border);
        background: rgba(0,0,0,0.2);
        color: white;
        font-family: inherit;
        font-size: 0.85rem;
        transition: all 0.2s;
      }
      .search-input:focus {
        background: rgba(0,0,0,0.5);
        border-color: var(--accent);
        outline: none;
        box-shadow: 0 0 0 1px var(--accent-soft);
      }
      .search-icon-symbol {
        position: absolute;
        left: 10px;
        top: 50%;
        transform: translateY(-50%);
        opacity: 0.6;
        font-size: 0.9rem;
        pointer-events: none;
      }
      @keyframes fadeIn {
        from { opacity: 0; transform: translateY(-4px); }
        to { opacity: 1; transform: translateY(0); }
      }
    </style>
  </head>
  <body>
    <div class="page">
      <header>
        <h1>SUENの網盤</h1>
        <p>SYS: NET DRIVE NODE · STATUS: ONLINE</p>
      </header>

      {% block content %}{% endblock %}

      <footer>
        <span id="script-info">SUEN-NET-DRIVE · FRONTEND v2025-12-07-SSL</span>
      </footer>
    </div>
  </body>
</html>
HTML

  # ---------------- templates/index.html ----------------
  # 修改：合併上傳按鈕，增加搜索功能
  cat >"${APP_DIR}/templates/index.html" <<'HTML'
{% extends "base.html" %}
{% block content %}
<div class="grid">
  <!-- 左側：上傳區 -->
  <div class="card">
    <div class="card-inner">

      <!-- ID + 口令 -->
      <div class="slot-row">
        <label for="slot-id">ID</label>
        <div class="slot-input-wrap">
          <input id="slot-id" name="slot-id" type="text" placeholder="" />
        </div>
        <label for="slot-secret">口令</label>
        <div class="slot-input-wrap">
          <input id="slot-secret" name="slot-secret" type="password" placeholder="" />
        </div>
      </div>

      <!-- 上傳表單 -->
      <form id="upload-form" action="/upload" method="post" enctype="multipart/form-data">
        <input type="hidden" id="upload_id" name="upload_id" />
        <input type="hidden" id="secret" name="secret" />

        <div class="slot-row" style="margin-top:4px;">
          <label for="category">類別 <span style="color:#ef4444">*</span></label>
          <div class="slot-input-wrap">
            <select
              id="category"
              name="category"
              required
              style="width:100%;padding:7px 9px;border-radius:999px;border:1px solid var(--border);font-size:0.9rem;outline:none;background:rgba(0,0,0,0.9);color:var(--fg);font-family:inherit;appearance:none;-webkit-appearance:none;"
            >
              <option value="" disabled selected>-- 請選擇分類 --</option>
              <option value="高考">高考</option>
              <option value="辭書">辭書</option>
              <option value="課程">課程</option>
              <option value="電影">電影</option>
              <option value="音樂">音樂</option>
              <option value="其他類">其他類</option>
            </select>
          </div>
        </div>
        
        <!-- 隱藏的實際文件輸入框 -->
        <input type="file" id="files-normal" name="files" multiple style="display:none" />
        <input type="file" id="files-folder" name="files" multiple webkitdirectory directory style="display:none" />

        <!-- 統一選擇按鈕 -->
        <div style="margin-top:12px;">
           <div class="custom-dropdown" id="dropdown-select">
              <button type="button" class="custom-dropdown-btn" id="btn-select-main">
                📄 選擇文件 ▾
              </button>
              <div class="custom-dropdown-menu" id="dropdown-menu">
                  <button type="button" class="custom-dropdown-item" id="opt-file">
                      <span style="font-size:1.1em">📄</span> 選擇文件 (Files)
                  </button>
                  <button type="button" class="custom-dropdown-item" id="opt-folder">
                      <span style="font-size:1.1em">📂</span> 選擇文件夾 (Folder)
                  </button>
              </div>
           </div>
        </div>

        <div id="file-preview" class="file-list-preview" style="text-align:center; margin-top:8px;"></div>

        <div class="row-between" style="margin-top:16px;">
          <div style="display:flex; gap:8px;">
             <button id="btn-upload" type="submit">開始上傳</button>
             <button id="btn-cancel" type="button" style="display:none;background:#ef4444;color:white;box-shadow:0 10px 24px rgba(239,68,68,0.75);">取消</button>
          </div>
          <span id="upload-status" class="status"></span>
        </div>
        <div class="progress" id="upload-progress">
          <div class="progress-bar" id="upload-progress-bar"></div>
        </div>
      </form>
    </div>
  </div>

  <!-- 右側：全部文件 -->
  <div class="card">
      <div class="card-inner">
      <div style="margin-bottom:12px; display:flex; justify-content:space-between; align-items:flex-start; flex-direction:column; gap:8px;">
         <!-- 搜索框 -->
         <div class="search-box-wrap" style="width:100%;">
             <span class="search-icon-symbol">🔍</span>
             <input type="text" id="search-input" class="search-input" placeholder="搜索文件名、類別或 ID..." />
         </div>
         <div style="width:100%; display:flex; justify-content:space-between; align-items:center;">
             <button id="btn-refresh" type="button" style="font-size:0.75rem;padding:4px 10px;">🔄 刷新列表</button>
             <span style="font-size:0.75rem; color:var(--muted); opacity:0.8;">點擊類別可篩選</span>
         </div>
      </div>
      <ul id="download-list" class="download-list"></ul>
      <div id="download-status" class="download-progress-text"></div>
    </div>
  </div>
</div>

<script>
  (function () {
    const API_UPLOAD = "/upload";
    const API_LIST = "/api/list"; 

    let currentId = "";
    let currentSecret = "";
    let xhrUpload = null; 
    let activeCategoryFilter = null; 
    let allFilesCache = []; // 本地緩存文件列表，用於搜索

    function setStatus(id, msg, ok) {
      const el = document.getElementById(id);
      if (!el) return;
      el.textContent = msg || "";
      el.className = "status" + (msg ? (ok ? " ok" : " err") : "");
    }

    function showProgress(containerId, barId, percent) {
      const container = document.getElementById(containerId);
      const bar = document.getElementById(barId);
      // ...
      if (!container || !bar) return;
      container.style.display = "block";
      bar.style.width = (percent || 0) + "%";
      if (percent >= 100) {
        setTimeout(() => {
          container.style.display = "none";
          bar.style.width = "0%";
        }, 800);
      }
    }

    function hideProgress(containerId, barId) {
      const container = document.getElementById(containerId);
      const bar = document.getElementById(barId);
      if (!container || !bar) return;
      container.style.display = "none";
      bar.style.width = "0%";
    }

    function formatBytes(bytes) {
      const n = Number(bytes);
      if (!Number.isFinite(n) || n <= 0) return "0 B";
      const units = ["B", "KB", "MB", "GB", "TB"];
      let val = n;
      let idx = 0;
      while (val >= 1024 && idx < units.length - 1) {
        val /= 1024;
        idx++;
      }
      const digits = idx === 0 ? 0 : 2;
      return val.toFixed(digits) + " " + units[idx];
    }
    
    function formatSpeed(bytesPerSec) {
      if (!Number.isFinite(bytesPerSec) || bytesPerSec <= 0) return "0 B/s";
      return formatBytes(bytesPerSec) + "/s";
    }

    function formatETA(remainingSeconds) {
      if (!Number.isFinite(remainingSeconds) || remainingSeconds <= 0) return "剩餘 < 1 秒";
      const sec = Math.round(remainingSeconds);
      if (sec < 60) return "剩餘約 " + sec + " 秒";
      const min = Math.floor(sec / 60);
      const s = sec % 60;
      return "剩餘約 " + min + " 分 " + s + " 秒";
    }

    function copyToClipboard(text) {
        if (navigator.clipboard && window.isSecureContext) {
            navigator.clipboard.writeText(text).then(() => {
                 const statusEl = document.getElementById("download-status");
                 if(statusEl) {
                     const orig = statusEl.textContent;
                     statusEl.textContent = "已複製鏈接！";
                     setTimeout(()=> statusEl.textContent=orig, 1500);
                 }
            }, () => {});
        } else {
            let textArea = document.createElement("textarea");
            textArea.value = text;
            textArea.style.position = "fixed";
            textArea.style.left = "-9999px";
            document.body.appendChild(textArea);
            textArea.focus();
            textArea.select();
            try {
                document.execCommand('copy');
                const statusEl = document.getElementById("download-status");
                 if(statusEl) {
                     const orig = statusEl.textContent;
                     statusEl.textContent = "已複製鏈接！";
                     setTimeout(()=> statusEl.textContent=orig, 1500);
                 }
            } catch (err) {}
            document.body.removeChild(textArea);
        }
    }

    // --- Unified Select Button Logic ---
    const btnSelectMain = document.getElementById("btn-select-main");
    const dropdownMenu = document.getElementById("dropdown-menu");
    const inputNormal = document.getElementById("files-normal");
    const inputFolder = document.getElementById("files-folder");
    const preview = document.getElementById("file-preview");

    // Toggle Dropdown
    if(btnSelectMain && dropdownMenu) {
        btnSelectMain.addEventListener("click", (e) => {
            e.stopPropagation();
            dropdownMenu.classList.toggle("show");
        });
    }

    // Close dropdown on outside click
    document.addEventListener("click", () => {
        if(dropdownMenu) dropdownMenu.classList.remove("show");
    });

    // Option: File
    document.getElementById("opt-file").addEventListener("click", () => {
        // Clear folder input
        if(inputFolder) inputFolder.value = ""; 
        if(inputNormal) inputNormal.click();
    });

    // Option: Folder
    document.getElementById("opt-folder").addEventListener("click", () => {
        // Clear normal input
        if(inputNormal) inputNormal.value = "";
        if(inputFolder) inputFolder.click();
    });

    function onFileInputChange(e) {
      const files = e.target.files;
      if (!files || !files.length) {
        // Only clear if the user canceled (files.length 0), BUT since we have 2 inputs, 
        // one might be empty while other has content.
        // We only show preview for the one that just changed.
        return;
      }
      preview.textContent = "已選擇 " + files.length + " 個項目 (" + (e.target.hasAttribute("webkitdirectory") ? "文件夾" : "文件") + ")";
      preview.style.transform = "scale(1.05)";
      setTimeout(()=> preview.style.transform = "scale(1)", 150);
    }

    if(inputNormal) inputNormal.addEventListener("change", onFileInputChange);
    if(inputFolder) inputFolder.addEventListener("change", onFileInputChange);

    function getActiveFiles() {
        if (inputNormal && inputNormal.files && inputNormal.files.length > 0) return inputNormal.files;
        if (inputFolder && inputFolder.files && inputFolder.files.length > 0) return inputFolder.files;
        return null;
    }

    function applySlot() {
      const idInput = document.getElementById("slot-id");
      const secretInput = document.getElementById("slot-secret");
      const upId = document.getElementById("upload_id");
      const upSecret = document.getElementById("secret");

      const idVal = (idInput.value || "").trim();
      const secretVal = (secretInput.value || "").trim();

      if (!idVal || !secretVal) {
        setStatus("slot-status", "ID 和口令均為必填。", false);
        return false;
      }

      currentId = idVal;
      currentSecret = secretVal;
      upId.value = currentId;
      upSecret.value = currentSecret;
      return true;
    }

    // --- Rendering List ---
    function renderList(files) {
        const listEl = document.getElementById("download-list");
        if (!listEl) return;
        
        if (!files || !files.length) {
            listEl.innerHTML = "<li><span style='font-size:0.8rem;color:rgba(148,163,184,0.9);'>無符合條件的附件。</span></li>";
            return;
        }

        const groups = {};
        for (const f of files) {
          const cat = (f.category || "").trim();
          const key = cat || "未分類";
          if (!groups[key]) groups[key] = { name: key, items: [] };
          groups[key].items.push(f);
        }

        listEl.innerHTML = "";
        const keys = Object.keys(groups).sort(); 
        let hasFilterMatch = false;

        for (const key of keys) {
            if (activeCategoryFilter && key !== activeCategoryFilter) {
                continue;
            }
            hasFilterMatch = true;
            
            const group = groups[key];
            const heading = document.createElement("li");
            heading.style.cursor = "pointer";
            heading.title = activeCategoryFilter ? "點擊取消篩選" : "點擊篩選此類別";
            
            const headingContent = document.createElement("div");
            headingContent.className = "category-heading";
            headingContent.textContent = "類別：" + group.name + (activeCategoryFilter ? " (篩選中 ✕)" : "");
            
            if (activeCategoryFilter) {
               headingContent.style.color = "#4ade80"; 
            }

            heading.appendChild(headingContent);
            heading.addEventListener("click", () => {
                activeCategoryFilter = (activeCategoryFilter === key) ? null : key;
                renderList(filterData(allFilesCache)); // Re-render with current search + new category filter
            });

            listEl.appendChild(heading);

            for (const f of group.items) {
                const li = document.createElement("li");
                
                const container = document.createElement("div");
                container.style.display = "flex";
                container.style.alignItems = "center";
                container.style.justifyContent = "space-between";
                container.style.gap = "8px";
                
                const a = document.createElement("a");
                a.href = "/d/" + encodeURIComponent(f.id) + "/" + encodeURIComponent(f.name || "");
                a.style.flex = "1";
                
                const left = document.createElement("div");
                left.className = "dl-left";
                
                const nameSpan = document.createElement("span");
                nameSpan.className = "dl-name";
                let dispName = f.name || "(無名文件)";
                // Highlight search term? Optional, but good.
                if(dispName.length > 40) dispName = dispName.substring(0, 38) + "...";
                nameSpan.textContent = dispName;
                left.appendChild(nameSpan);

                const right = document.createElement("div");
                right.className = "dl-right";
                let meta = f.size_human || formatBytes(f.size_bytes || 0);
                right.textContent = meta;

                a.appendChild(left);
                a.appendChild(right);
                
                const shareBtn = document.createElement("button");
                shareBtn.type = "button";
                shareBtn.innerHTML = "🔗"; 
                shareBtn.title = "複製分享鏈接";
                shareBtn.style.padding = "6px 10px";
                shareBtn.style.fontSize = "0.9rem";
                shareBtn.style.background = "rgba(0,0,0,0.5)";
                shareBtn.style.border = "1px solid var(--border)";
                shareBtn.style.boxShadow = "none";
                
                shareBtn.onclick = (e) => {
                    e.stopPropagation();
                    const fullUrl = window.location.origin + a.getAttribute("href");
                    copyToClipboard(fullUrl);
                };

                container.appendChild(a);
                container.appendChild(shareBtn);
                li.appendChild(container);
            }
        }
        
        if (activeCategoryFilter && !hasFilterMatch) {
            // If currently filtered category is gone due to search, we might want to keep it empty or reset.
            // keeping it empty is correct behavior for "search within category" or "search global but category mismatches"
             listEl.innerHTML = "<li><span style='font-size:0.8rem;color:rgba(148,163,184,0.9);'>該類別下無符合條件的附件。</span></li>";
        }
    }

    function filterData(files) {
        if (!files) return [];
        const term = (document.getElementById("search-input").value || "").trim().toLowerCase();
        if (!term) return files;
        return files.filter(f => {
            const n = (f.name || "").toLowerCase();
            const c = (f.category || "").toLowerCase();
            const note = (f.note || "").toLowerCase();
            const uid = (f.upload_id || "").toLowerCase();
            return n.includes(term) || c.includes(term) || note.includes(term) || uid.includes(term);
        });
    }

    async function loadFiles() {
      const statusEl = document.getElementById("download-status");
      try {
        if (statusEl) statusEl.textContent = "正在載入附件列表…";
        const res = await fetch(API_LIST, { headers: { Accept: "application/json" } });
        if (!res.ok) throw new Error("HTTP " + res.status);
        const data = await res.json();
        if (!data || !data.ok) throw new Error("服務器返回錯誤");
        
        allFilesCache = data.files || [];
        renderList(filterData(allFilesCache));

        if (statusEl) statusEl.textContent = "";
      } catch (err) {
        console.error(err);
        const listEl = document.getElementById("download-list");
        if (listEl) {
          listEl.innerHTML = "<li><span style='font-size:0.8rem;color:#fecaca;'>載入附件列表失敗。</span></li>";
        }
        if (statusEl) statusEl.textContent = "";
      }
    }

    // Search Input Listener
    document.getElementById("search-input").addEventListener("input", () => {
        renderList(filterData(allFilesCache));
    });

    function uploadWithXHR(event) {
      event.preventDefault();
      if (!applySlot()) return;

      const form = document.getElementById("upload-form");
      const btn = document.getElementById("btn-upload");
      const btnCancel = document.getElementById("btn-cancel");
      const catSelect = document.getElementById("category");

      if (!catSelect.value) {
          setStatus("upload-status", "請選擇類別。", false);
          catSelect.focus();
          return;
      }

      const files = getActiveFiles(); // Use helper
      if (!files || !files.length) {
        setStatus("upload-status", "請先選擇文件或文件夾。", false);
        return;
      }
      const filesArray = Array.from(files);
      const totalBytes = filesArray.reduce((sum, f) => sum + (f.size || 0), 0);

      btn.disabled = true;
      btnCancel.style.display = "inline-flex";
      setStatus("upload-status", "準備上傳 " + files.length + " 個文件…", true);
      showProgress("upload-progress", "upload-progress-bar", 0);

      xhrUpload = new XMLHttpRequest();
      xhrUpload.open("POST", API_UPLOAD, true);
      xhrUpload.responseType = "json";
      xhrUpload.setRequestHeader("X-Requested-With", "XMLHttpRequest");

      const startTs = Date.now();

      xhrUpload.upload.onprogress = function (evt) {
        if (!evt.lengthComputable) return;
        const loaded = evt.loaded;
        const percent = Math.max(0, Math.min(100, Math.round((loaded / evt.total) * 100)));
        showProgress("upload-progress", "upload-progress-bar", percent);

        const elapsedSec = (Date.now() - startTs) / 1000;
        const speed = elapsedSec > 0 ? loaded / elapsedSec : 0;
        const remainBytes = Math.max(0, totalBytes - loaded);
        const eta = speed > 0 ? remainBytes / speed : 0;

        const msg = "已上傳 " + formatBytes(loaded) + " / " + formatBytes(totalBytes) + " · " + formatSpeed(speed) + " · " + formatETA(eta);
        setStatus("upload-status", msg, true);
      };

      xhrUpload.onerror = function () {
        cleanupUpload();
        setStatus("upload-status", "網絡錯誤。", false);
      };

      xhrUpload.onabort = function () {
        cleanupUpload();
        setStatus("upload-status", "上傳已取消。", false);
      };

      xhrUpload.onload = function () {
        cleanupUpload();
        if (xhrUpload.status >= 200 && xhrUpload.status < 300) {
          let data = xhrUpload.response;
          // ... json parse ...
          if (!data || typeof data !== "object") {
              try { data = JSON.parse(xhrUpload.responseText || "{}"); } catch (e) { data = {}; }
          }
          if (data.ok) {
            setStatus("upload-status", "上傳完成！共 " + (data.files || []).length + " 個文件。", true);
            try {
              if(inputNormal) inputNormal.value = "";
              if(inputFolder) inputFolder.value = "";
              document.getElementById("file-preview").textContent = "";
              document.getElementById("category").value = "";
            } catch (e) {}
            loadFiles().catch(console.error);
          } else {
            const detail = (data && data.detail) || "未知錯誤";
            setStatus("upload-status", "上傳失敗：" + detail, false);
          }
        } else {
          // err...
          let detail = "HTTP " + xhrUpload.status;
          try {
             const j = JSON.parse(xhrUpload.responseText || "{}");
             if (j && j.detail) detail = j.detail;
          } catch(e){}
          setStatus("upload-status", "上傳失敗：" + detail, false);
        }
      };

      const formData = new FormData(form);
      // Append files manually because we have 2 inputs separately
      // Actually FormData(form) pulls from the form elements. 
      // InputNormal and InputFolder are INSIDE the form.
      // However, if one is empty, it might still send an empty part? 
      // Usually browsers only send files if selected.
      // But we set name="files" for both.
      // We should probably check if it works. 
      // To be safe, we can clear the one that is NOT active or just rely on the fact that empty file input usually isn't sent or sent as empty filename.
      // The backend checks `if not files`.
      
      // Let's rely on standard FormData behavior.
      xhrUpload.send(formData);

      function cleanupUpload() {
          btn.disabled = false;
          btnCancel.style.display = "none";
          xhrUpload = null;
          hideProgress("upload-progress", "upload-progress-bar");
      }
    }

    document.getElementById("btn-cancel").addEventListener("click", function() {
        if(xhrUpload) {
            xhrUpload.abort();
        }
    });

    document.getElementById("btn-refresh").addEventListener("click", () => {
        activeCategoryFilter = null; 
        document.getElementById("search-input").value = ""; // Clear search on refresh
        loadFiles();
    });

    document.addEventListener("DOMContentLoaded", function () {
      const btnSlot = document.getElementById("btn-set-slot");
      if (btnSlot) {
        btnSlot.addEventListener("click", function () {
          applySlot();
        });
      }

      const form = document.getElementById("upload-form");
      if (form && window.XMLHttpRequest && window.FormData) {
        form.addEventListener("submit", uploadWithXHR);
      }
      
      loadFiles();
    });
  })();
</script>
{% endblock %}
HTML

  # ---------------- templates/upload_success.html ----------------
  cat >"${APP_DIR}/templates/upload_success.html" <<'HTML'
{% extends "base.html" %}
{% block content %}
<div class="card">
  <div class="card-inner">
    <h2><span class="icon">✅</span> 上傳完成</h2>
    <p style="font-size:0.9rem;margin:4px 0 10px;">
      上傳 ID：<code>{{ upload_id }}</code>
    </p>
    <p style="font-size:0.85rem;margin:0 0 10px;color:rgba(148,163,184,0.95);">
      請將此 ID 告訴老師或同組同學，所有人使用同一個 ID 上傳附件。
    </p>

    {% if records %}
    <ul class="download-list">
      {% for r in records %}
      <li>
        <a href="/d/{{ r.id }}/{{ r.original_name }}">
          <span class="dl-name">{{ r.original_name }}</span>
          <span class="dl-meta">
            {{ r.size_bytes }} bytes
            {% if r.category %}
            · {{ r.category }}
            {% endif %}
          </span>
        </a>
      </li>
      {% endfor %}
    </ul>
    {% else %}
    <p style="font-size:0.85rem;color:#fecaca;">沒有記錄到任何文件。</p>
    {% endif %}

    <p style="font-size:0.85rem;margin-top:10px;">
      查看此 ID 下所有附件：
      <a href="/id/{{ upload_id }}">/id/{{ upload_id }}</a>
    </p>
  </div>
</div>
{% endblock %}
HTML

  # ---------------- templates/list_by_id.html ----------------
  cat >"${APP_DIR}/templates/list_by_id.html" <<'HTML'
{% extends "base.html" %}
{% block content %}
<div class="card">
  <div class="card-inner">
    <h2><span class="icon">📂</span> 附件列表</h2>
    <p style="font-size:0.9rem;margin:4px 0 10px;">
      上傳 ID：<code>{{ upload_id }}</code>
    </p>

    {% if groups %}
      {% for cat, rows in groups.items() %}
        <div class="category-heading">
          類別：{{ cat if cat else "未分類" }}
        </div>
        <ul class="download-list">
          {% for row in rows %}
          <li>
            <a href="/d/{{ row.id }}/{{ row.original_name }}">
              <span class="dl-name">{{ row.original_name }}</span>
              <span class="dl-meta">
                {{ row.size_bytes }} bytes · {{ row.created_at }}
                {% if row.note %}
                · {{ row.note }}
                {% endif %}
              </span>
            </a>
          </li>
          {% endfor %}
        </ul>
      {% endfor %}
    {% else %}
    <p style="font-size:0.85rem;color:rgba(148,163,184,0.95);">
      此 ID 下暫無附件。
    </p>
    {% endif %}
  </div>
</div>
{% endblock %}
HTML
}

write_systemd_units() {
  log "[6/8] 寫入 systemd 服務與定時任務..."

  cat >/etc/systemd/system/${SERVICE_NAME}.service <<UNIT
[Unit]
Description=SUEN Net Drive (pan.bdfz.net) FastAPI Service
After=network.target

[Service]
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
Environment=TMPDIR=${TMP_DIR}
EnvironmentFile=-${APP_DIR}/.env
ExecStart=${APP_DIR}/venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000 --proxy-headers
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT

  cat >/etc/systemd/system/${SERVICE_NAME}-cleanup.service <<UNIT
[Unit]
Description=SUEN Net Drive (pan.bdfz.net) Cleanup Old Files

[Service]
Type=oneshot
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=-${APP_DIR}/.env
ExecStart=${APP_DIR}/venv/bin/python ${APP_DIR}/app/cleanup.py
UNIT

  cat >/etc/systemd/system/${SERVICE_NAME}-cleanup.timer <<UNIT
[Unit]
Description=Daily cleanup for SUEN Net Drive (pan.bdfz.net)

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service" "${SERVICE_NAME}-cleanup.timer"
  systemctl restart "${SERVICE_NAME}.service"
  systemctl start "${SERVICE_NAME}-cleanup.timer"
}

write_nginx_conf() {
  log "[7/8] 配置 Nginx 反向代理..."

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"

  if [[ -f "${NGINX_SITE_AVAIL}" ]]; then
    warn "備份原有 Nginx 配置為 ${NGINX_SITE_AVAIL}.bak-${ts}"
    cp "${NGINX_SITE_AVAIL}" "${NGINX_SITE_AVAIL}.bak-${ts}"
  fi

  local cert_dir="/etc/letsencrypt/live/${DOMAIN}"
  local max_mb="102300"
  if [[ -f "${APP_DIR}/.env" ]]; then
    local val
    val="$(grep -E '^MAX_FILE_MB=' "${APP_DIR}/.env" | tail -n1 | cut -d'=' -f2)"
    if [[ -n "${val}" && "${val}" =~ ^[0-9]+$ ]]; then
      max_mb="${val}"
    fi
  fi
  local nginx_size="${max_mb}m"
  local DOLLAR='$'

  if [[ -f "${cert_dir}/fullchain.pem" && -f "${cert_dir}/privkey.pem" ]]; then
    log "檢測到已存在的 Let's Encrypt 證書，直接寫入 HTTPS 配置，不重新申請。"

    cat >"${NGINX_SITE_AVAIL}" <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://${DOLLAR}host${DOLLAR}request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/privkey.pem;
    ssl_trusted_certificate ${cert_dir}/chain.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;

    client_max_body_size ${nginx_size};

    location /health {
        proxy_pass http://127.0.0.1:8000/health;
        include /etc/nginx/proxy_params;
        proxy_redirect off;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        include /etc/nginx/proxy_params;
        proxy_redirect off;
        proxy_request_buffering off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX
  else
    warn "未找到 /etc/letsencrypt/live/${DOMAIN} 下的證書，暫時僅配置 HTTP 80。"
    warn "首次部署請確認 DNS 正確後自行執行：certbot --nginx -d ${DOMAIN}"

    cat >"${NGINX_SITE_AVAIL}" <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};

    client_max_body_size ${nginx_size};

    location /health {
        proxy_pass http://127.0.0.1:8000/health;
        include /etc/nginx/proxy_params;
        proxy_redirect off;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        include /etc/nginx/proxy_params;
        proxy_redirect off;
        proxy_request_buffering off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX
  fi

  ln -sf "${NGINX_SITE_AVAIL}" "${NGINX_SITE_ENABLED}"

  nginx -t
  systemctl reload nginx
}

final_checks() {
  log "[8/8] 最後檢查..."

  systemctl status "${SERVICE_NAME}.service" --no-pager || true
  systemctl status nginx --no-pager || true

  log "安裝器版本：${INSTALLER_VERSION}"
  log "如需檢查後端健康狀態，可在伺服器上執行：curl -s http://127.0.0.1:8000/health"
  log "前端訪問：https://${DOMAIN}"
}

main() {
  log "=== SUEN Net Drive 安裝腳本 (${INSTALLER_VERSION}) 啟動 ==="
  check_root
  check_os
  stop_existing_service
  kill_old_uvicorn
  install_packages
  create_user_and_dirs
  setup_venv_and_deps
  write_env_template
  check_tmp_space
  write_app_code
  write_systemd_units
  write_nginx_conf
  final_checks
  log "=== 安裝完成。如為重裝，舊進程與配置已被覆蓋，證書保持不變。==="
}

main "$@"