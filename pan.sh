#!/usr/bin/env bash
#
# pan.sh - 一鍵部署 pan.bdfz.net 公共上傳/下載服務
#  - Nginx + FastAPI + Uvicorn + SQLite (aiosqlite 異步)
#  - 流式上傳，避免整個文件讀入記憶體
#  - 上傳/下載記錄到 SQLite
#  - 上傳 & 下載 Telegram 通知 (httpx 異步)
#  - 支援上傳口令 UPLOAD_SECRET（可選）
#  - 每日自動清理過期文件 (systemd timer + cleanup.py)
#

set -Eeuo pipefail

DOMAIN="pan.bdfz.net"
APP_USER="panuser"
APP_DIR="/opt/pan-app"
DATA_DIR="/srv/pan"
SERVICE_NAME="pan"
PYTHON_BIN="python3"

# 顏色輸出（簡單）
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
  echo -e "${RED}!!!${RESET} $*" >&2
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

install_packages() {
  log "[1/7] 安裝系統依賴 (nginx, python-venv, sqlite3)..."
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y \
    nginx \
    "${PYTHON_BIN}" \
    python3-venv \
    python3-pip \
    sqlite3 \
    ca-certificates \
    curl
}

create_user_and_dirs() {
  log "[2/7] 創建專用用戶與目錄..."

  if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    useradd --system --home "${APP_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
    log "已創建系統用戶 ${APP_USER}"
  else
    warn "系統用戶 ${APP_USER} 已存在，略過創建。"
  fi

  mkdir -p "${APP_DIR}" "${APP_DIR}/app" "${APP_DIR}/templates" "${APP_DIR}/static" "${DATA_DIR}/files"
  chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}" "${DATA_DIR}"
}

setup_venv_and_deps() {
  log "[3/7] 建立 Python 虛擬環境並安裝依賴..."

  if [[ ! -d "${APP_DIR}/venv" ]]; then
    "${PYTHON_BIN}" -m venv "${APP_DIR}/venv"
  fi

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

write_app_code() {
  log "[4/7] 寫入 FastAPI 應用程式代碼、模板與清理腳本..."

  # ---------------- app/main.py ----------------
  cat >"${APP_DIR}/app/main.py" <<'PY'
import os
import uuid
import datetime
from pathlib import Path
from typing import List, Optional

import aiosqlite
import aiofiles
import httpx
from fastapi import FastAPI, Request, Form, UploadFile, File, HTTPException
from fastapi.responses import HTMLResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = Path(os.environ.get("PAN_DATA_DIR", "/srv/pan"))
FILES_DIR = DATA_DIR / "files"
DB_PATH = DATA_DIR / "pan.db"

FILES_DIR.mkdir(parents=True, exist_ok=True)
DATA_DIR.mkdir(parents=True, exist_ok=True)

load_dotenv(BASE_DIR / ".env")

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "").strip()
BASE_URL = os.getenv("BASE_URL", "").strip() or "https://pan.example.com"
UPLOAD_SECRET = os.getenv("UPLOAD_SECRET", "").strip()
# 預設略低於 Nginx 100 GiB 上限，用於預留 multipart 開銷
MAX_FILE_MB = int(os.getenv("MAX_FILE_MB", "102300"))

app = FastAPI(title="pan.bdfz.net upload service")
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))


async def get_db():
  conn = await aiosqlite.connect(DB_PATH)
  conn.row_factory = aiosqlite.Row
  return conn


async def init_db():
  async with await get_db() as conn:
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
        uploader_ip TEXT,
        user_agent TEXT,
        created_at TEXT NOT NULL
      )
      """
    )
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
    return xff.split(",")[0].strip()
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


@app.on_event("startup")
async def startup_event():
  await init_db()


app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
  return templates.TemplateResponse("index.html", {"request": request})


@app.post("/upload", response_class=HTMLResponse)
async def handle_upload(
  request: Request,
  upload_id: str = Form(...),
  category: Optional[str] = Form(None),
  note: Optional[str] = Form(None),
  secret: Optional[str] = Form(None),
  files: List[UploadFile] = File(...),
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

  async with await get_db() as conn:
    for upload_file in files:
      file_uuid = str(uuid.uuid4())
      safe_name = upload_file.filename.replace("/", "_").replace("\\", "_")

      subdir = FILES_DIR / datetime.datetime.utcnow().strftime("%Y/%m/%d")
      subdir.mkdir(parents=True, exist_ok=True)

      stored_path_rel = subdir.relative_to(FILES_DIR) / f"{file_uuid}__{safe_name}"
      dest_path = FILES_DIR / stored_path_rel

      size_bytes = 0
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
            await f.write(chunk)
      except HTTPException:
        if dest_path.exists():
          try:
            dest_path.unlink()
          except OSError:
            pass
        raise

      record_id = file_uuid
      await conn.execute(
        """
        INSERT INTO uploads (
          id, upload_id, category, note,
          original_name, stored_path, size_bytes,
          uploader_ip, user_agent, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
          record_id,
          upload_id,
          category or "",
          note or "",
          safe_name,
          str(stored_path_rel),
          size_bytes,
          client_ip,
          ua,
          now_iso,
        ),
      )
      created_records.append(
        {
          "id": record_id,
          "upload_id": upload_id,
          "category": category or "",
          "note": note or "",
          "original_name": safe_name,
          "size_bytes": size_bytes,
        }
      )

    await conn.commit()

  total_size = sum(r["size_bytes"] for r in created_records)
  lines = [
    "📤 <b>新上傳</b>",
    f"ID: <code>{upload_id}</code>",
  ]
  if category:
    lines.append(f"類別: {category}")
  if note:
    lines.append(f"備註: {note[:200]}")
  lines.append(f"上傳 IP: <code>{client_ip}</code>")
  lines.append(f"文件數: {len(created_records)}，總大小: {human_size(total_size)}")
  lines.append("")
  for r in created_records[:5]:
    lines.append(f"• {r['original_name']} ({human_size(r['size_bytes'])})")
  if len(created_records) > 5:
    lines.append(f"... 以及另外 {len(created_records) - 5} 個文件")
  lines.append("")
  detail_url = f"{BASE_URL}/id/{upload_id}"
  lines.append(f"詳情: {detail_url}")

  await send_telegram_message("\n".join(lines))

  return templates.TemplateResponse(
    "upload_success.html",
    {
      "request": request,
      "upload_id": upload_id,
      "records": created_records,
      "detail_url": detail_url,
    },
  )


@app.get("/id/{upload_id}", response_class=HTMLResponse)
async def list_by_upload_id(request: Request, upload_id: str):
  async with await get_db() as conn:
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

  return templates.TemplateResponse(
    "list_by_id.html",
    {
      "request": request,
      "upload_id": upload_id,
      "rows": rows,
      "base_url": BASE_URL,
    },
  )


@app.get("/d/{file_id}/{filename:path}")
@app.get("/d/{file_id}")
async def download_file(request: Request, file_id: str, filename: Optional[str] = None):
  async with await get_db() as conn:
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

  lines = [
    "📥 <b>文件被下載</b>",
    f"上傳 ID: <code>{row['upload_id']}</code>",
    f"文件: {row['original_name']}",
    f"下載 IP: <code>{client_ip}</code>",
  ]
  await send_telegram_message("\n".join(lines))

  return FileResponse(
    path=str(file_path),
    filename=row["original_name"],
    media_type="application/octet-stream",
  )


@app.get("/health")
async def health():
  return {"status": "ok"}
PY

  # ---------------- app/cleanup.py ----------------
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

  # 1. 先刪除資料庫記錄，確保對外狀態一致
  for row in rows_to_delete:
    file_id = row["id"]
    cur.execute("DELETE FROM downloads WHERE upload_file_id = ?", (file_id,))
    cur.execute("DELETE FROM uploads WHERE id = ?", (file_id,))

  conn.commit()

  # 2. 再刪物理文件；即使中途失敗，最多留下孤兒文件
  removed_files = 0
  for row in rows_to_delete:
    rel_path = row["stored_path"]
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

  # ---------------- templates ----------------
  cat >"${APP_DIR}/templates/base.html" <<'HTML'
<!DOCTYPE html>
<html lang="zh-CN">
  <head>
    <meta charset="utf-8">
    <title>pan.bdfz.net - 附件上傳</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      body {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
        max-width: 900px;
        margin: 2rem auto;
        padding: 0 1rem;
        background: #f5f5f5;
      }
      header {
        margin-bottom: 1.5rem;
      }
      .card {
        background: #ffffff;
        border-radius: 8px;
        padding: 1.5rem;
        box-shadow: 0 2px 4px rgba(0,0,0,0.05);
      }
      label {
        display: block;
        margin-top: 0.75rem;
        font-weight: 600;
      }
      input[type="text"],
      textarea,
      select {
        width: 100%;
        padding: 0.4rem 0.5rem;
        margin-top: 0.25rem;
        border-radius: 4px;
        border: 1px solid #ccc;
        box-sizing: border-box;
      }
      input[type="file"] {
        margin-top: 0.4rem;
      }
      button {
        margin-top: 1rem;
        padding: 0.5rem 1.2rem;
        border: none;
        border-radius: 4px;
        background: #2563eb;
        color: #fff;
        font-weight: 600;
        cursor: pointer;
      }
      button:hover {
        background: #1d4ed8;
      }
      .hint {
        font-size: 0.85rem;
        color: #666;
      }
      .muted {
        color: #777;
        font-size: 0.9rem;
      }
      table {
        width: 100%;
        border-collapse: collapse;
        margin-top: 0.5rem;
      }
      th, td {
        padding: 0.4rem 0.5rem;
        border-bottom: 1px solid #e5e7eb;
        text-align: left;
      }
      th {
        background: #f3f4f6;
        font-size: 0.9rem;
      }
      a {
        color: #2563eb;
        text-decoration: none;
      }
      a:hover {
        text-decoration: underline;
      }
      .badge {
        display: inline-block;
        padding: 0.1rem 0.4rem;
        border-radius: 999px;
        background: #e5e7eb;
        font-size: 0.75rem;
      }
    </style>
  </head>
  <body>
    <header>
      <h1>pan.bdfz.net</h1>
      <p class="muted">附件上傳 / 下載服務（僅限課堂教學用途）</p>
    </header>
    <main class="card">
      {% block content %}{% endblock %}
    </main>
  </body>
</html>
HTML

  cat >"${APP_DIR}/templates/index.html" <<'HTML'
{% extends "base.html" %}
{% block content %}
<h2>上傳附件</h2>
<form action="/upload" method="post" enctype="multipart/form-data">
  <label for="upload_id">上傳 ID（必填，例如：班級作業代碼）</label>
  <input type="text" id="upload_id" name="upload_id" required>

  <label for="category">類別（可選，例如：作業 / 資料）</label>
  <input type="text" id="category" name="category" placeholder="作業 / 資料 / 其他">

  <label for="note">備註（可選）</label>
  <textarea id="note" name="note" rows="2" placeholder="例如：第 5 次作業，語文 X 班"></textarea>

  <label for="secret">上傳口令（如老師提供，必填）</label>
  <input type="text" id="secret" name="secret" placeholder="由老師提供">

  <label for="files">選擇文件（可多選）</label>
  <input type="file" id="files" name="files" multiple required>

  <p class="hint">
    備註：請合理控制單個文件大小；服務端會記錄上傳 IP、時間、大小並推送管理員，僅用於教學管理用途。
  </p>

  <button type="submit">開始上傳</button>
</form>
{% endblock %}
HTML

  cat >"${APP_DIR}/templates/upload_success.html" <<'HTML'
{% extends "base.html" %}
{% block content %}
<h2>上傳成功</h2>
<p>上傳 ID：<strong>{{ upload_id }}</strong></p>
<p>你可以使用以下地址查看本次上傳的文件列表：</p>
<p><a href="{{ detail_url }}">{{ detail_url }}</a></p>

<h3>本次上傳的文件</h3>
<table>
  <thead>
    <tr>
      <th>文件名</th>
      <th>大小</th>
      <th>下載</th>
    </tr>
  </thead>
  <tbody>
    {% for r in records %}
    <tr>
      <td>{{ r.original_name }}</td>
      <td>{{ (r.size_bytes / 1024 / 1024) | round(2) }} MB</td>
      <td><a href="/d/{{ r.id }}">下載</a></td>
    </tr>
    {% endfor %}
  </tbody>
</table>

<p class="hint">提示：請將上方「查看列表」鏈接妥善保存或提交給老師。</p>
{% endblock %}
HTML

  cat >"${APP_DIR}/templates/list_by_id.html" <<'HTML'
{% extends "base.html" %}
{% block content %}
<h2>上傳 ID：{{ upload_id }}</h2>

{% if rows and rows|length > 0 %}
<table>
  <thead>
    <tr>
      <th>文件名</th>
      <th>大小 (預估)</th>
      <th>上傳時間 (UTC)</th>
      <th>上傳 IP</th>
      <th>下載</th>
    </tr>
  </thead>
  <tbody>
    {% for row in rows %}
    <tr>
      <td>{{ row["original_name"] }}</td>
      <td>{{ (row["size_bytes"] / 1024 / 1024) | round(2) }} MB</td>
      <td class="muted">{{ row["created_at"] }}</td>
      <td class="muted">{{ row["uploader_ip"] }}</td>
      <td><a href="/d/{{ row["id"] }}">下載</a></td>
    </tr>
    {% endfor %}
  </tbody>
</table>
{% else %}
<p>暫無記錄，請確認上傳 ID 是否正確。</p>
{% endif %}
{% endblock %}
HTML

  # ---------------- .env.example ----------------
  cat >"${APP_DIR}/.env.example" <<'ENV'
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
BASE_URL=https://pan.bdfz.net
UPLOAD_SECRET=CLASS-202412
MAX_FILE_MB=102300
PAN_DATA_DIR=/srv/pan
CLEANUP_DAYS=30
ENV

  chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"
}

setup_env_file() {
  log "[5/7] 配置 .env（Telegram / 口令 / 服務基礎配置）..."

  ENV_FILE="${APP_DIR}/.env"

  if [[ ! -f "${ENV_FILE}" ]]; then
    cp "${APP_DIR}/.env.example" "${ENV_FILE}"
    chown "${APP_USER}:${APP_USER}" "${ENV_FILE}"
    chmod 600 "${ENV_FILE}"
    log "已從 .env.example 初始化 .env"
  else
    warn ".env 已存在，將在此基礎上更新。"
  fi

  set_env_var() {
    local var="$1"
    local prompt="$2"
    local default="${3:-}"
    local cur val escaped

    cur="$(grep -E "^${var}=" "${ENV_FILE}" 2>/dev/null | sed "s/^${var}=//")" || cur=""

    if [[ -n "${cur}" ]]; then
      read -r -p "${prompt} [當前: ${cur}] (直接回車保留): " val || val=""
      if [[ -z "${val}" ]]; then
        val="${cur}"
      fi
    else
      if [[ -n "${default}" ]]; then
        read -r -p "${prompt} (預設: ${default}): " val || val=""
        [[ -z "${val}" ]] && val="${default}"
      else
        read -r -p "${prompt}: " val || val=""
      fi
    fi

    escaped="$(printf '%s\n' "${val}" | sed 's/[&/]/\\&/g')"
    local delimiter=$'\x01'

    if grep -qE "^${var}=" "${ENV_FILE}"; then
      sed -i "s${delimiter}^${var}=.*${delimiter}${var}=${escaped}${delimiter}" "${ENV_FILE}"
    else
      echo "${var}=${val}" >> "${ENV_FILE}"
    fi
  }

  echo
  echo "--- Telegram 設定 ---"
  set_env_var "TELEGRAM_BOT_TOKEN" "Telegram Bot Token（可留空以禁用通知）" ""
  set_env_var "TELEGRAM_CHAT_ID" "Telegram Chat ID（可留空以禁用通知）" ""

  echo
  echo "--- 基本服務配置 ---"
  set_env_var "BASE_URL" "BASE_URL（通知中的完整鏈接基準）" "https://${DOMAIN}"

  echo
  echo "--- 上傳口令（防止亂傳）---"
  set_env_var "UPLOAD_SECRET" "上傳口令（可留空 = 不啟用）" ""

  echo
  echo "--- 文件大小限制 / 自動清理策略 ---"
  set_env_var "MAX_FILE_MB" "單文件大小限制（MB）" "102300"
  set_env_var "CLEANUP_DAYS" "自動清理天數（例如 30）" "30"

  chown "${APP_USER}:${APP_USER}" "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"

  log ".env 已更新：${ENV_FILE}"
}

setup_systemd() {
  log "[6/7] 設定 systemd 服務與定時清理..."

  SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
  CLEAN_SERVICE="/etc/systemd/system/${SERVICE_NAME}-cleanup.service"
  CLEAN_TIMER="/etc/systemd/system/${SERVICE_NAME}-cleanup.timer"

  cat >"${SERVICE_FILE}" <<EOF
[Unit]
Description=pan.bdfz.net upload/download service
After=network.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${APP_DIR}/venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  cat >"${CLEAN_SERVICE}" <<EOF
[Unit]
Description=pan.bdfz.net daily cleanup service
After=network.target

[Service]
Type=oneshot
User=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${APP_DIR}/venv/bin/python app/cleanup.py
EOF

  cat >"${CLEAN_TIMER}" <<EOF
[Unit]
Description=Run pan.bdfz.net cleanup daily

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true
Unit=${SERVICE_NAME}-cleanup.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}.service"
  systemctl enable --now "${SERVICE_NAME}-cleanup.timer"

  systemctl status "${SERVICE_NAME}.service" --no-pager || true
}

setup_nginx() {
  log "[7/7] 配置 Nginx 反向代理與限速..."

  # http 級別限速設定
  local LIMIT_CONF="/etc/nginx/conf.d/pan_upload_limit.conf"
  cat >"${LIMIT_CONF}" <<'EOF'
limit_req_zone $binary_remote_addr zone=pan_upload:10m rate=5r/m;
EOF

  NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"

  cat >"${NGINX_CONF}" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    client_max_body_size 100g;

    location /static/ {
        alias ${APP_DIR}/static/;
    }

    location /upload {
        limit_req zone=pan_upload burst=10 nodelay;

        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/"${DOMAIN}"

  if [[ -f /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi

  nginx -t
  systemctl reload nginx

  log "Nginx 已配置完成，目前使用 HTTP（80）。"

  echo
  read -r -p "是否現在使用 certbot 自動申請 Let's Encrypt 證書並啟用 HTTPS? [y/N] " use_ssl || use_ssl=""
  if [[ "${use_ssl}" =~ ^[Yy]$ ]]; then
    apt install -y certbot python3-certbot-nginx
    certbot --nginx -d "${DOMAIN}"
    log "如無報錯，HTTPS 已啟用。"
  else
    warn "已跳過自動配置 HTTPS。如需之後啟用，可執行：certbot --nginx -d ${DOMAIN}"
  fi
}

main() {
  check_root
  check_os
  install_packages
  create_user_and_dirs
  setup_venv_and_deps
  write_app_code
  setup_env_file
  setup_systemd
  setup_nginx

  echo
  log "========================================================"
  log " pan.bdfz.net 已部署完成"
  log " - 應用目錄: ${APP_DIR}"
  log " - 數據目錄: ${DATA_DIR}"
  log " - systemd 服務: ${SERVICE_NAME}.service"
  log " - 每日清理:   ${SERVICE_NAME}-cleanup.timer (03:30 UTC)"
  log " - .env 配置:  ${APP_DIR}/.env"
  log "========================================================"
  echo
  echo "建議下一步："
  echo "  1) 確認 DNS 已指向本機 IP 並可通過 http://${DOMAIN}/ 或 https://${DOMAIN}/ 訪問"
  echo "  2) 視情況在前置（如 Cloudflare / DMIT Nginx）上增加白名單與額外 WAF 規則。"
}

main "$@"