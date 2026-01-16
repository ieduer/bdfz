#!/usr/bin/env bash
#
# treehole.sh - 一鍵部署「極簡匿名樹洞」(FastAPI + SQLite + Nginx)
#
# 功能概覽：
#   - FastAPI 提供匿名發帖 / 隨機樹洞 / 最新樹洞 API + 簡單前端
#   - SQLite 單檔資料庫，超輕量
#   - 每 IP 每分鐘發帖次數限制，避免被灌爆
#   - 不需要登入、不記名，僅存 IP 雜湊（帶 salt）
#   - systemd 常駐 + Nginx 反向代理 (HTTP 80 / 可升級到 HTTPS 443)
#   - 內建 certbot + webroot 簽發 / 續期（若已有證書則不重複申請）
#   - 可選 Telegram 通知（新貼文推送到指定 chat）
#   - 最大限度匿名：
#       * Nginx 對該站點關閉 access_log（不在 Nginx 日誌中記錄 IP）
#       * Uvicorn 關閉 access log（不在 systemd/journal 中輸出客戶端 IP）
#
# 重新執行腳本：
#   - 會覆蓋 app.py / systemd / nginx 配置
#   - 會重啟 treehole.service，重載 Nginx
#   - 不覆蓋已存在的 .env（配置請自行手動改）
#

set -Eeuo pipefail
INSTALLER_VERSION="treehole-install-2026-01-15-v12-fstringfix"

# ==== 可按需修改的變量 ======================================

DOMAIN="tree.bdfz.net"  # TODO: 換成你真的域名，比如 tree.bdfz.net
APP_USER="treehole"
APP_DIR="/opt/treehole-app"
DATA_DIR="/srv/treehole"
SERVICE_NAME="treehole"
PYTHON_BIN="python3"

# ==== 基本設定 =============================================

VENV_DIR="${APP_DIR}/venv"
NGINX_SITE_AVAILABLE="/etc/nginx/sites-available/${SERVICE_NAME}.conf"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/${SERVICE_NAME}.conf"
CERTBOT_WEBROOT="/var/www/certbot"

log() {
  echo "[treehole] $*"
}

ensure_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    echo "請用 root 執行此腳本" >&2
    exit 1
  fi
}

print_version() {
  log "installer version: ${INSTALLER_VERSION}"
}

ensure_ubuntu() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
      log "警告：檢測到的系統不是 Ubuntu (${ID:-unknown})，腳本未必完全適配。"
      log "繼續執行，如出現問題請自行調整。"
    fi
  else
    log "警告：無法檢測系統版本 (/etc/os-release 不存在)，將繼續執行。"
  fi
}

install_packages() {
  log "安裝/更新必要套件 (python3-venv, python3-pip, nginx, sqlite3, build-essential, openssl, certbot, ca-certificates)..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    "${PYTHON_BIN}" \
    python3-venv \
    python3-pip \
    python3-dev \
    nginx \
    sqlite3 \
    build-essential \
    openssl \
    ca-certificates \
    certbot \
    python3-certbot-nginx
}

stop_previous() {
  log "停止舊的 ${SERVICE_NAME} 服務與殘留 uvicorn 進程（如有）..."
  systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
  # 僅殺死指定用戶的 uvicorn app:app，避免誤殺其它服務
  pkill -u "${APP_USER}" -f "uvicorn app:app" 2>/dev/null || true
}

create_app_user() {
  if id "${APP_USER}" >/dev/null 2>&1; then
    log "系統用戶 ${APP_USER} 已存在，略過建立。"
  else
    log "建立系統用戶 ${APP_USER}（無登入 shell）..."
    useradd --system --create-home --home-dir "/home/${APP_USER}" --shell /usr/sbin/nologin "${APP_USER}"
  fi
}

obtain_certificate_if_needed() {
  local cert_dir="/etc/letsencrypt/live/${DOMAIN}"
  if [[ -f "${cert_dir}/fullchain.pem" && -f "${cert_dir}/privkey.pem" ]]; then
    log "已檢測到 ${DOMAIN} 的現有 Let's Encrypt 證書，略過重新申請。"
    return
  fi
  log "尚未檢測到 /etc/letsencrypt/live/${DOMAIN}/fullchain.pem。"
  log "如需啟用 HTTPS，可透過 certbot 使用 webroot 模式申請證書。"
  read -r -p "是否現在使用 certbot 為 ${DOMAIN} 申請證書？ [y/N]: " answer || true
  case "${answer}" in
    y|Y)
      local email=""
      read -r -p "請輸入用於 Let's Encrypt 的管理員郵箱（必填）： " email || true
      if [[ -z "${email}" ]]; then
        log "未提供郵箱，無法自動申請證書，略過。"
        return
      fi
      log "使用 webroot 模式申請證書（certbot certonly --webroot）..."
      if certbot certonly --webroot -w "${CERTBOT_WEBROOT}" \
        -d "${DOMAIN}" \
        --email "${email}" \
        --agree-tos --non-interactive --expand \
        --deploy-hook "systemctl reload nginx"; then
        log "certbot 申請證書成功，已配置 deploy-hook 自動 reload nginx。"
      else
        log "certbot 申請證書失敗，請稍後手動檢查原因。"
      fi
      ;;
    *)
      log "已選擇暫不透過 certbot 申請證書。"
      ;;
  esac
}

create_dirs() {
  log "建立應用與資料目錄..."
  mkdir -p "${APP_DIR}"
  mkdir -p "${DATA_DIR}"
  mkdir -p "${CERTBOT_WEBROOT}"
  chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}" "${DATA_DIR}"
}

write_env_if_missing() {
  local env_file="${APP_DIR}/.env"
  if [[ -f "${env_file}" ]]; then
    log ".env 已存在，保持不變（如需修改請手動編輯 ${env_file}）。"
    return
  fi
  log "首次部署，將寫入預設 .env 並詢問 Telegram 配置（可留空）..."
  local default_salt
  default_salt="$(openssl rand -hex 16 2>/dev/null || echo 'change-me-salt')"
  local tg_token="" tg_chat=""
  read -r -p "Telegram bot token (可選，留空則不啟用通知): " tg_token || true
  read -r -p "Telegram chat ID (可選，留空則不啟用通知): " tg_chat || true
  cat >"${env_file}" <<ENV
# ===== treehole 環境配置 =====
# 資料庫位置
TREEHOLE_DB_PATH="${DATA_DIR}/treehole.db"

# IP 雜湊用的 salt（建議改成更長更隨機的字符串）
TREEHOLE_SECRET_SALT="${default_salt}"

# 發帖字數限制
TREEHOLE_MIN_POST_LENGTH=5
TREEHOLE_MAX_POST_LENGTH=1000

# 頻率限制：每 IP 每分鐘最多幾則貼文
TREEHOLE_POSTS_PER_MINUTE=5

# 最新列表默認顯示多少條
TREEHOLE_RECENT_LIMIT=50

# (可選) 你的域名（僅作記錄）
TREEHOLE_DOMAIN="${DOMAIN}"

# (可選) Telegram 通知配置：
#  - 如果兩個都非空，則每條新樹洞會推送到該 chat
TREEHOLE_TELEGRAM_BOT_TOKEN="${tg_token}"
TREEHOLE_TELEGRAM_CHAT_ID="${tg_chat}"
ENV
  chown "${APP_USER}:${APP_USER}" "${env_file}"
  chmod 600 "${env_file}"
}

write_app_code() {
  log "寫入 FastAPI 應用程式碼到 ${APP_DIR}/app.py ..."
  cat >"${APP_DIR}/app.py" <<'PYCODE'
import os
import hashlib
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import List, Optional

from fastapi import FastAPI, HTTPException, Request, BackgroundTasks
from fastapi.responses import HTMLResponse
from pydantic import BaseModel
from sqlalchemy import (
    Column,
    DateTime,
    Integer,
    String,
    create_engine,
    func,
    text,
)
from sqlalchemy.orm import declarative_base, sessionmaker, Session

try:
    from dotenv import load_dotenv
except ImportError:
    # 允許沒有 python-dotenv（但安裝腳本會裝）
    def load_dotenv(path: str) -> None:
        return

import httpx

BASE_DIR = Path(__file__).resolve().parent
load_dotenv(str(BASE_DIR / ".env"))

DB_PATH = os.getenv("TREEHOLE_DB_PATH", str(BASE_DIR / "treehole.db"))
SECRET_SALT = os.getenv("TREEHOLE_SECRET_SALT", "change-me-salt")
MIN_POST_LENGTH = int(os.getenv("TREEHOLE_MIN_POST_LENGTH", "5"))
MAX_POST_LENGTH = int(os.getenv("TREEHOLE_MAX_POST_LENGTH", "1000"))
POSTS_PER_MINUTE = int(os.getenv("TREEHOLE_POSTS_PER_MINUTE", "5"))
RECENT_LIMIT_DEFAULT = int(os.getenv("TREEHOLE_RECENT_LIMIT", "50"))

TELEGRAM_BOT_TOKEN = os.getenv("TREEHOLE_TELEGRAM_BOT_TOKEN", "").strip()
TELEGRAM_CHAT_ID = os.getenv("TREEHOLE_TELEGRAM_CHAT_ID", "").strip()
TELEGRAM_ENABLED = bool(TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID)

SQLALCHEMY_DATABASE_URL = f"sqlite:///{DB_PATH}"

engine = create_engine(
    SQLALCHEMY_DATABASE_URL,
    connect_args={"check_same_thread": False},
)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


class Post(Base):
    __tablename__ = "posts"

    id = Column(Integer, primary_key=True, index=True)
    content = Column(String(2000), nullable=False)
    tag = Column(String(64), nullable=True, index=True)
    created_at = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc), index=True)
    ip_hash = Column(String(64), nullable=False, index=True)


def init_db() -> None:
    db_path_dir = Path(DB_PATH).parent
    db_path_dir.mkdir(parents=True, exist_ok=True)
    # 開啟 WAL 模式，提高併發寫入能力
    with engine.connect() as connection:
        try:
            connection.execute(text("PRAGMA journal_mode=WAL;"))
        except Exception:
            pass
    Base.metadata.create_all(bind=engine)


def get_db() -> Session:
    return SessionLocal()


class PostCreate(BaseModel):
    content: str
    tag: Optional[str] = None


class PostOut(BaseModel):
    id: int
    content: str
    tag: Optional[str]
    created_at: datetime

    class Config:
        orm_mode = True
        json_encoders = {
            datetime: lambda v: (
                v.replace(tzinfo=timezone.utc) if getattr(v, "tzinfo", None) is None else v.astimezone(timezone.utc)
            ).isoformat()
        }


class PostsList(BaseModel):
    total: int
    offset: int
    limit: int
    posts: List[PostOut]


# --- Inject build id for HTML cache busting ---
BUILD_ID = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
app = FastAPI(title="Treehole", version="0.1.0")


@app.on_event("startup")
def startup_event() -> None:
    init_db()


def hash_ip(ip: str) -> str:
    data = f"{ip}|{SECRET_SALT}".encode("utf-8", errors="ignore")
    return hashlib.sha256(data).hexdigest()[:32]


def enforce_rate_limit(db: Session, ip_hash: str) -> None:
    if POSTS_PER_MINUTE <= 0:
        return
    now = datetime.now(timezone.utc)
    window_start = now - timedelta(seconds=60)
    count = (
        db.query(func.count(Post.id))
        .filter(Post.ip_hash == ip_hash, Post.created_at >= window_start)
        .scalar()
    )
    if count >= POSTS_PER_MINUTE:
        raise HTTPException(
            status_code=429,
            detail="Too many posts from this IP. Please slow down.",
        )


def validate_content(content: str) -> str:
    stripped = content.strip()
    if len(stripped) < MIN_POST_LENGTH:
        raise HTTPException(
            status_code=400,
            detail=f"Content is too short (min {MIN_POST_LENGTH} characters).",
        )
    if len(stripped) > MAX_POST_LENGTH:
        raise HTTPException(
            status_code=400,
            detail=f"Content is too long (max {MAX_POST_LENGTH} characters).",
        )
    return stripped


def send_telegram_notification(post: PostOut) -> None:
    if not TELEGRAM_ENABLED:
        return
    try:
        created_str = (
            post.created_at.isoformat(sep=" ", timespec="seconds")
            if post.created_at
            else ""
        )
        tag = post.tag or "無標籤"
        content = post.content
        if len(content) > 500:
            content = content[:480] + "…"

        lines = [
            "🌲 新匿名樹洞",
            f"[{tag}]",
            "",
            content,
            "",
            f"於 {created_str}",
        ]
        text_msg = "\n".join(lines)
        url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
        payload = {
            "chat_id": TELEGRAM_CHAT_ID,
            "text": text_msg,
            "disable_web_page_preview": True,
        }
        httpx.post(url, json=payload, timeout=5.0)
    except Exception:
        pass

INDEX_HTML = r"""<!DOCTYPE html>
<html lang="zh-Hans">
<head>
  <meta charset="UTF-8" />
  <title>匿名樹洞 · Treehole</title>
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="treehole-build" content="__BUILD_ID__" />
  <style>
    :root {
      color-scheme: dark;
      --bg: #050608;
      --bg-panel: #111827;
      --bg-panel-light: #161e2e;
      --border: #1f2937;
      --text: #e5e7eb;
      --text-dim: #9ca3af;
      --accent: #22c55e;
      --accent-soft: rgba(34, 197, 94, 0.12);
      --danger: #f97373;
    }
    html.theme-light {
      color-scheme: light;
      --bg: #f8fafc;
      --bg-panel: #ffffff;
      --bg-panel-light: #f1f5f9;
      --border: #e2e8f0;
      --text: #0f172a;
      --text-dim: #475569;
      --accent: #16a34a;
      --accent-soft: rgba(22, 163, 74, 0.12);
      --danger: #ef4444;
    }
    html.theme-light body {
      background: radial-gradient(circle at top, #eef2ff 0, #f8fafc 55%, #ffffff 100%);
      color: var(--text);
    }
    html.theme-light textarea,
    html.theme-light input[type="text"] {
      background: #ffffff;
      color: var(--text);
    }

    * { box-sizing: border-box; }
    body {
      margin: 0;
      padding: 0;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Text",
                   "Helvetica Neue", sans-serif;
      background: radial-gradient(circle at top, #0f172a 0, #020617 55%, #000 100%);
      color: var(--text);
      min-height: 100vh;
      display: flex;
      align-items: flex-start;
      justify-content: center;
      padding-bottom: 24px;
    }

    .page {
      width: 100%;
      max-width: 1120px;
      margin: 24px auto;
      padding: 0 16px;
      display: grid;
      grid-template-columns: minmax(0, 2.2fr) minmax(0, 1.3fr);
      grid-template-areas: "feed compose";
      gap: 16px;
      align-items: start;
    }
    @media (max-width: 800px) {
      .page {
        grid-template-columns: minmax(0, 1fr);
        grid-template-areas: "feed" "compose";
        gap: 12px;
      }
    }

    .feed-panel { grid-area: feed; }
    .compose-panel { grid-area: compose; }

    .panel {
      background: linear-gradient(135deg, var(--bg-panel), #020617);
      border-radius: 16px;
      border: 1px solid var(--border);
      padding: 16px 18px 18px;
      box-shadow:
        0 24px 60px rgba(15, 23, 42, 0.75),
        0 0 0 1px rgba(15, 23, 42, 0.8);
      position: relative;
      overflow: hidden;
    }
    .panel::before {
      content: "";
      position: absolute;
      inset: -120px;
      background:
        radial-gradient(circle at 0 0, rgba(45, 212, 191, 0.08), transparent 55%),
        radial-gradient(circle at 100% 100%, rgba(56, 189, 248, 0.12), transparent 60%);
      opacity: 0.7;
      pointer-events: none;
    }
    .panel-inner {
      position: relative;
      z-index: 1;
    }

    h1, h2 {
      margin: 0 0 10px;
      letter-spacing: 0.03em;
    }
    h1 {
      font-size: 1.05rem;
      font-weight: 650;
      text-transform: uppercase;
    }
    h2 {
      font-size: 0.9rem;
      font-weight: 600;
      text-transform: uppercase;
      color: var(--text-dim);
    }

    textarea {
      width: 100%;
      min-height: 140px;
      resize: vertical;
      padding: 10px 11px;
      border-radius: 10px;
      border: 1px solid var(--border);
      background: linear-gradient(135deg, #020617, #020617);
      color: var(--text);
      font-size: 0.9rem;
      line-height: 1.5;
      outline: none;

      /* ✅ mobile scroll smoothness */
      -webkit-overflow-scrolling: touch;
      overscroll-behavior: contain;
      touch-action: pan-y;
    }
    textarea:focus {
      border-color: var(--accent);
      box-shadow: 0 0 0 1px rgba(34, 197, 94, 0.7);
    }

    input[type="text"] {
      width: 100%;
      padding: 7px 10px;
      border-radius: 999px;
      border: 1px solid var(--border);
      background: #020617;
      color: var(--text);
      font-size: 0.85rem;
      outline: none;
    }
    input[type="text"]:focus {
      border-color: var(--accent);
      box-shadow: 0 0 0 1px rgba(34, 197, 94, 0.7);
    }

    .counter-row {
      display: flex;
      justify-content: flex-end;
      margin-top: 6px;
      margin-bottom: 2px;
    }
    .counter {
      font-size: 0.78rem;
      color: var(--text-dim);
      user-select: none;
    }

    .row {
      display: flex;
      gap: 8px;
      align-items: center;
      margin-top: 10px;
    }
    .row > * {
      flex: 1;
    }
    .row > .tag-col {
      max-width: 150px;
      flex: 0 0 150px;
    }

    @media (max-width: 600px) {
      textarea {
        min-height: 120px;
      }
      .row {
        flex-direction: column;
        align-items: stretch;
        gap: 10px;
      }
      .row > .tag-col {
        max-width: none;
        flex: 1 1 auto;
      }
      button {
        width: 100%;
        justify-content: center;
      }
    }

    button {
      border: none;
      border-radius: 999px;
      padding: 8px 16px;
      font-size: 0.85rem;
      font-weight: 550;
      letter-spacing: 0.06em;
      text-transform: uppercase;
      cursor: pointer;
      background: radial-gradient(circle at 0 0, #4ade80 0, #16a34a 50%, #22c55e 100%);
      color: #022c22;
      box-shadow: 0 10px 30px rgba(34, 197, 94, 0.4);
      display: inline-flex;
      align-items: center;
      gap: 6px;
    }
    button:disabled {
      opacity: 0.65;
      cursor: default;
      box-shadow: none;
    }

    .muted-button {
      background: transparent;
      border: 1px solid var(--border);
      color: var(--text-dim);
      box-shadow: none;
    }

    .status {
      margin-top: 8px;
      font-size: 0.78rem;
      color: var(--text-dim);
      min-height: 1.2em;
      white-space: pre-wrap;
    }
    .status-error { color: var(--danger); }
    .status-ok { color: var(--accent); }

    .posts-header {
      display: flex;
      justify-content: space-between;
      align-items: baseline;
      gap: 6px;
      margin-bottom: 8px;
    }
    .posts-header small {
      font-size: 0.75rem;
      color: var(--text-dim);
    }

    /* ✅ Right column list scroll */
    .posts-list {
      display: flex;
      flex-direction: column;
      gap: 8px;
      max-height: calc(100dvh - 220px);
      overflow-y: auto;
      -webkit-overflow-scrolling: touch;
      overscroll-behavior: contain;
      padding-right: 4px;
      margin-right: -4px;
      margin-top: 2px;
      contain: content;
      scrollbar-gutter: stable;
      touch-action: pan-y;
    }
    @media (max-width: 800px) {
      .posts-list {
        max-height: 58dvh;
        padding-right: 2px;
        margin-right: -2px;
      }
    }

    .post-card {
      border-radius: 10px;
      padding: 9px 10px;
      background: linear-gradient(135deg, var(--bg-panel-light), #020617);
      border: 1px solid rgba(148, 163, 184, 0.25);
      position: relative;
      content-visibility: auto;
      contain-intrinsic-size: 120px;
    }
    .post-card-tag {
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.09em;
      color: var(--text-dim);
      margin-bottom: 4px;
    }
    .post-card-content {
      font-size: 0.9rem;
      white-space: pre-wrap;
      word-break: break-word;
      color: var(--text);
    }
    .post-card-meta {
      margin-top: 4px;
      font-size: 0.72rem;
      color: var(--text-dim);
      display: flex;
      justify-content: flex-start;
      align-items: center;
      gap: 8px;
    }

    .random-box {
      margin-top: 10px;
      padding: 8px 10px;
      border-radius: 10px;
      border: 1px dashed rgba(148, 163, 184, 0.5);
      background: radial-gradient(circle at 0 0, rgba(34, 197, 94, 0.1), transparent 55%);
      font-size: 0.85rem;
    }
    .random-box-title {
      font-size: 0.8rem;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      color: var(--text-dim);
      margin-bottom: 4px;
    }
    .random-box-content {
      white-space: pre-wrap;
      word-break: break-word;
      color: var(--text);
    }
    .random-box-empty { color: var(--text-dim); }

    .small {
      font-size: 0.75rem;
      color: var(--text-dim);
    }

    .footer-note {
      margin-top: 10px;
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      font-size: 0.75rem;
      color: var(--text-dim);
    }
    .footer-note-item {
      padding: 4px 8px;
      border-radius: 999px;
      border: 1px dashed rgba(148, 163, 184, 0.35);
      background: rgba(15, 23, 42, 0.8);
    }

    /* ===== Pixel cat ===== */
    .pixel-cat {
        margin-top: 20px;
        width: 100%;
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        gap: 8px;
        font-size: 0.75rem;
        color: var(--text-dim);
        opacity: 0.98;
        text-align: center;
        pointer-events: none;
    }
    .pixel-cat-walk {
        display: inline-block;
        animation: catWalk 9s ease-in-out infinite alternate;
    }
    .pixel-cat-art {
        font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas,
                     "Liberation Mono", "Courier New", monospace;
        line-height: 1.1;
        white-space: pre;
    }
    .pixel-cat-art svg {
        width: 120px;
        height: 96px;
        image-rendering: pixelated;
        filter: drop-shadow(0 6px 16px rgba(15, 23, 42, 0.95));
        animation: catFloat 3.8s ease-in-out infinite;
    }
    .pixel-cat-eye {
        transform-origin: center center;
        animation: catBlink 4.2s infinite;
    }
    .pixel-cat-meow {
        opacity: 0;
        transform-origin: left bottom;
        animation: catMeow 11s ease-in-out infinite;
    }

    /* ===== NOW clock (bottom-right, no text) ===== */
    .now-clock {
      position: absolute;
      right: 16px;
      bottom: 16px;
      width: 118px;
      height: 118px;
      border-radius: 999px;
      border: 1px solid rgba(148, 163, 184, 0.35);
      background:
        radial-gradient(circle at 30% 25%, rgba(34, 197, 94, 0.10), transparent 55%),
        radial-gradient(circle at 70% 80%, rgba(56, 189, 248, 0.08), transparent 60%),
        linear-gradient(135deg, rgba(17, 24, 39, 0.92), rgba(2, 6, 23, 0.92));
      box-shadow:
        0 18px 40px rgba(15, 23, 42, 0.75),
        0 0 0 1px rgba(15, 23, 42, 0.75);
      backdrop-filter: blur(10px);
      -webkit-backdrop-filter: blur(10px);
      display: grid;
      place-items: center;
      pointer-events: none;
      user-select: none;
      overflow: hidden;
    }
    .now-clock::before {
      content: "";
      position: absolute;
      inset: 10px;
      border-radius: 999px;
      border: 1px solid rgba(148, 163, 184, 0.18);
      background:
        repeating-conic-gradient(
          from -90deg,
          rgba(148,163,184,0.45) 0deg,
          rgba(148,163,184,0.45) 1deg,
          transparent 1deg,
          transparent 6deg
        );
      mask: radial-gradient(circle, transparent 0 54%, #000 55%);
      -webkit-mask: radial-gradient(circle, transparent 0 54%, #000 55%);
      opacity: 0.55;
    }
    .now-clock-center {
      position: relative;
      z-index: 1;
      width: 82px;
      height: 82px;
      border-radius: 999px;
      border: 1px solid rgba(148, 163, 184, 0.22);
      background: rgba(2, 6, 23, 0.55);
      display: grid;
      place-items: center;
    }
    .now-clock-text {
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas,
                   "Liberation Mono", "Courier New", monospace;
      font-size: 0.9rem;
      letter-spacing: 0.18em;
      text-indent: 0.18em;
      color: rgba(229, 231, 235, 0.92);
      text-transform: uppercase;
    }
    .now-hand {
      position: absolute;
      left: 50%;
      top: 50%;
      transform-origin: 50% 100%;
      transform: translate(-50%, -100%) rotate(0deg);
      width: 2px;
      height: 44px;
      border-radius: 999px;
      background: rgba(229, 231, 235, 0.75);
      box-shadow: 0 0 0 1px rgba(15,23,42,0.65);
    }
    .now-hand.second {
      width: 2px;
      height: 52px;
      background: rgba(34, 197, 94, 0.95);
      box-shadow: 0 0 14px rgba(34, 197, 94, 0.55);
    }
    .now-pin {
      position: absolute;
      left: 50%;
      top: 50%;
      width: 8px;
      height: 8px;
      border-radius: 999px;
      transform: translate(-50%, -50%);
      background: rgba(34, 197, 94, 0.85);
      box-shadow: 0 0 0 2px rgba(2, 6, 23, 0.85);
    }

    @media (max-width: 800px) {
      .now-clock {
        width: 104px;
        height: 104px;
        right: 14px;
        bottom: 14px;
      }
      .now-clock-center {
        width: 74px;
        height: 74px;
      }
    }

    @keyframes catFloat {
        0%, 100% { transform: translateY(0); }
        50% { transform: translateY(-3px); }
    }
    @keyframes catBlink {
        0%, 86%, 100% { transform: scaleY(1); }
        88% { transform: scaleY(0.15); }
        92% { transform: scaleY(1); }
    }
    @keyframes catWalk {
        0% { transform: translateX(-14px); }
        50% { transform: translateX(14px); }
        100% { transform: translateX(-6px); }
    }
    @keyframes catMeow {
        0%, 58% { opacity: 0; transform: scale(0.95) translateY(0); }
        62%, 72% { opacity: 1; transform: scale(1) translateY(-2px); }
        78%, 100% { opacity: 0; transform: scale(0.96) translateY(0); }
    }
  </style>
</head>
<body>
  <main class="page">

    <section class="panel compose-panel">
      <div class="panel-inner">
        <h1>匿名樹洞</h1>

        <form id="postForm">
          <textarea id="content" name="content" maxlength="1000"
            placeholder="這裡不記名、不追問，只代你保管片刻的情緒。"></textarea>

          <div class="counter-row">
            <span id="counter" class="counter">0/1000</span>
          </div>

          <div class="row">
            <div class="tag-col">
              <input id="tag" name="tag" type="text" placeholder="標籤（可選）" />
            </div>
            <div style="text-align: right;">
              <button type="submit" id="submitBtn">
                <span>投進樹洞</span>
              </button>
            </div>
          </div>
        </form>

        <div class="pixel-cat" aria-hidden="true">
          <div class="pixel-cat-walk">
            <div class="pixel-cat-art">
              <svg viewBox="0 0 96 64" aria-hidden="true">
                <g class="pixel-cat-meow">
                  <rect x="8" y="6" width="48" height="18" fill="#020617" stroke="#4b5563" stroke-width="1" />
                  <rect x="22" y="24" width="8" height="6" fill="#020617" stroke="#4b5563" stroke-width="1" />
                  <text x="14" y="18" font-family="monospace" font-size="8" fill="#e5e7eb">MEOW!</text>
                </g>

                <rect x="30" y="18" width="32" height="26" fill="#020617" stroke="#4b5563" stroke-width="1" />
                <rect x="32" y="20" width="28" height="22" fill="#020617" stroke="#1f2937" stroke-width="1" />

                <rect x="30" y="14" width="8" height="8" fill="#020617" stroke="#4b5563" stroke-width="1" />
                <rect x="54" y="14" width="8" height="8" fill="#020617" stroke="#4b5563" stroke-width="1" />

                <rect class="pixel-cat-eye" x="36" y="26" width="4" height="5" fill="#a7f3d0" />
                <rect class="pixel-cat-eye" x="52" y="26" width="4" height="5" fill="#a7f3d0" />

                <rect x="44" y="31" width="4" height="2" fill="#22c55e" />

                <rect x="38" y="31" width="3" height="2" fill="#10b981" />
                <rect x="51" y="31" width="3" height="2" fill="#10b981" />

                <rect x="43" y="34" width="2" height="1" fill="#22c55e" />
                <rect x="47" y="34" width="2" height="1" fill="#22c55e" />

                <rect x="42" y="36" width="8" height="2" fill="#020617" opacity="0.9" />
              </svg>
            </div>
          </div>
        </div>

        <div id="status" class="status"></div>

        <div class="footer-note">
          <div class="footer-note-item">不記名 · 僅存 IP 雜湊</div>
          <div class="footer-note-item">純文本 · 不支援圖片 / 附件</div>
          <div class="footer-note-item">請避免輸入真實姓名、電話等敏感資訊</div>
        </div>

        <!-- NOW CLOCK (bottom-right, no text) -->
        <div class="now-clock" id="nowClock" aria-hidden="true">
          <div class="now-clock-center">
            <div class="now-clock-text">NOW</div>
          </div>
          <div class="now-hand" id="nowHandMinute"></div>
          <div class="now-hand second" id="nowHandSecond"></div>
          <div class="now-pin"></div>
        </div>
      </div>
    </section>

    <section class="panel feed-panel">
      <div class="panel-inner">
        <div class="posts-header">
          <div>
            <h2>最新樹洞</h2>
            <small>按時間倒序顯示最近的樹洞。</small>
          </div>
          <div>
            <button type="button" class="muted-button" id="refreshBtn">刷新</button>
          </div>
        </div>
        <div id="posts" class="posts-list"></div>

        <div class="random-box" id="randomBox">
          <div class="random-box-title">隨機一則樹洞</div>
          <div id="randomContent" class="random-box-content random-box-empty">
            暫無內容，等你先說一句。
          </div>
        </div>
      </div>
    </section>

  </main>

  <script>
    const TREEHOLE_BUILD_ID = "__BUILD_ID__";

    // Auto theme: prefer OS dark-mode; otherwise use local time (07:00-19:00 = light)
    (function autoTheme() {
      try {
        const preferDark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
        if (preferDark) return;
        const h = new Date().getHours();
        const isLight = (h >= 7 && h < 19);
        if (isLight) document.documentElement.classList.add('theme-light');
      } catch (_) {}
    })();

    const statusEl = document.getElementById("status");
    const postsEl = document.getElementById("posts");
    const randomContentEl = document.getElementById("randomContent");
    const formEl = document.getElementById("postForm");
    const submitBtn = document.getElementById("submitBtn");
    const refreshBtn = document.getElementById("refreshBtn");

    function setStatus(msg, type) {
      statusEl.textContent = msg || "";
      statusEl.classList.remove("status-error", "status-ok");
      if (type === "error") statusEl.classList.add("status-error");
      if (type === "ok") statusEl.classList.add("status-ok");
    }

    function formatTime(iso) {
      try {
        let s = (iso || "").trim();
        if (!s) return "";
        if (s.endsWith("+00:00")) s = s.replace("+00:00", "Z");
        const hasTZ = /[zZ]$/.test(s) || /[+-]\d{2}:?\d{2}$/.test(s);
        if (!hasTZ) {
          s = s.replace(" ", "T") + "Z";
        }
        const d = new Date(s);
        if (Number.isNaN(d.getTime())) return "";

        const now = new Date();
        const diff = Math.floor((now.getTime() - d.getTime()) / 1000);
        if (!Number.isFinite(diff) || diff < 0) return d.toLocaleString();

        if (diff < 60) return "剛剛";
        if (diff < 3600) return `${Math.floor(diff / 60)} 分鐘前`;
        if (diff < 86400) return `${Math.floor(diff / 3600)} 小時前`;
        if (diff < 2592000) return `${Math.floor(diff / 86400)} 天前`;
        return d.toLocaleString();
      } catch (_) {
        return "";
      }
    }

    let currentOffset = 0;
    let currentLimit = 50;
    let totalPosts = 0;

    function renderPosts(list, total, offset, limit) {
      const frag = document.createDocumentFragment();

      if (!Array.isArray(list) || list.length === 0) {
        const div = document.createElement("div");
        div.className = "small";
        div.textContent = "暫無內容。可以試著先對樹說一句。";
        frag.appendChild(div);
        postsEl.replaceChildren(frag);
        return;
      }

      for (const p of list) {
        const card = document.createElement("article");
        card.className = "post-card";

        if (p.tag) {
          const tag = document.createElement("div");
          tag.className = "post-card-tag";
          tag.textContent = p.tag;
          card.appendChild(tag);
        }

        const content = document.createElement("div");
        content.className = "post-card-content";
        content.textContent = p.content || "";
        card.appendChild(content);

        const meta = document.createElement("div");
        meta.className = "post-card-meta";

        const left = document.createElement("span");
        left.className = "small";
        left.textContent = formatTime(p.created_at);

        meta.appendChild(left);
        card.appendChild(meta);

        frag.appendChild(card);
      }

      if (total > limit) {
        const controls = document.createElement("div");
        controls.style.display = "flex";
        controls.style.justifyContent = "center";
        controls.style.alignItems = "center";
        controls.style.marginTop = "10px";
        controls.style.gap = "10px";
        controls.className = "small";

        const prevBtn = document.createElement("button");
        prevBtn.textContent = "上一頁";
        prevBtn.type = "button";
        prevBtn.className = "muted-button";
        prevBtn.disabled = offset <= 0;
        prevBtn.onclick = async () => {
          await loadRecent(offset - limit, limit);
        };

        const nextBtn = document.createElement("button");
        nextBtn.textContent = "下一頁";
        nextBtn.type = "button";
        nextBtn.className = "muted-button";
        nextBtn.disabled = offset + limit >= total;
        nextBtn.onclick = async () => {
          await loadRecent(offset + limit, limit);
        };

        const pageInfo = document.createElement("span");
        pageInfo.textContent = `第 ${Math.floor(offset/limit)+1} 頁 / 共 ${Math.ceil(total/limit)} 頁`;

        controls.appendChild(prevBtn);
        controls.appendChild(pageInfo);
        controls.appendChild(nextBtn);
        frag.appendChild(controls);
      }

      postsEl.replaceChildren(frag);
    }

    async function loadRecent(offset = 0, limit = 50) {
      refreshBtn.disabled = true;
      try {
        const res = await fetch(`/api/posts/recent?limit=${limit}&offset=${offset}`, {
          headers: { "Accept": "application/json" },
        });
        if (!res.ok) throw new Error("載入失敗");
        const data = await res.json();
        currentOffset = data.offset || 0;
        currentLimit = data.limit || 50;
        totalPosts = data.total || 0;
        renderPosts(data.posts || [], totalPosts, currentOffset, currentLimit);
      } catch (err) {
        console.error(err);
        setStatus("載入最新樹洞失敗。", "error");
      } finally {
        refreshBtn.disabled = false;
      }
    }

    async function loadRandom() {
      try {
        const res = await fetch("/api/posts/random", {
          headers: { "Accept": "application/json" },
        });
        if (res.status === 404) {
          randomContentEl.textContent = "暫時沒有樹洞。";
          randomContentEl.classList.add("random-box-empty");
          return;
        }
        if (!res.ok) throw new Error("載入失敗");
        const data = await res.json();
        randomContentEl.textContent = data.content || "";
        randomContentEl.classList.remove("random-box-empty");
      } catch (err) {
        console.error(err);
        randomContentEl.textContent = "載入隨機樹洞失敗。";
        randomContentEl.classList.add("random-box-empty");
      }
    }

    // ===== counter (no float / no layout thrash) =====
    const contentInput = document.getElementById("content");
    const counterEl = document.getElementById("counter");

    function updateCounter() {
      const val = contentInput.value || "";
      counterEl.textContent = `${val.length}/1000`;
      if (val.length > 1000) counterEl.style.color = "var(--danger)";
      else counterEl.style.color = "var(--text-dim)";
    }
    contentInput.addEventListener("input", updateCounter);
    updateCounter();

    // ===== NOW clock (always now) =====
    const handMinute = document.getElementById("nowHandMinute");
    const handSecond = document.getElementById("nowHandSecond");

    function tickNowClock() {
      const d = new Date();
      const ms = d.getMilliseconds();
      const sec = d.getSeconds() + ms / 1000;
      const min = d.getMinutes() + sec / 60;

      const secDeg = sec * 6;
      const minDeg = min * 6;

      handSecond.style.transform = `translate(-50%, -100%) rotate(${secDeg}deg)`;
      handMinute.style.transform = `translate(-50%, -100%) rotate(${minDeg}deg)`;
      requestAnimationFrame(tickNowClock);
    }
    requestAnimationFrame(tickNowClock);

    formEl.addEventListener("submit", async (e) => {
      e.preventDefault();
      const content = document.getElementById("content").value;
      const tag = document.getElementById("tag").value;
      const payload = { content, tag: tag || null };
      submitBtn.disabled = true;
      setStatus("正在投遞樹洞…", "");
      try {
        const res = await fetch("/api/posts", {
          method: "POST",
          headers: {
            "Accept": "application/json",
            "Content-Type": "application/json",
          },
          body: JSON.stringify(payload),
        });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) {
          const msg = (data && data.detail) || "提交失敗。";
          throw new Error(msg);
        }
        document.getElementById("content").value = "";
        document.getElementById("tag").value = "";
        setStatus("已投進樹洞。", "ok");
        updateCounter();
        await loadRecent(0, currentLimit);
        await loadRandom();
      } catch (err) {
        console.error(err);
        setStatus(err.message || "提交失敗。", "error");
      } finally {
        submitBtn.disabled = false;
      }
    });

    refreshBtn.addEventListener("click", async () => {
      await loadRecent(currentOffset, currentLimit);
      await loadRandom();
    });

    (async function init() {
      await loadRecent();
      await loadRandom();
    })();
  </script>
</body>
</html>
"""
# Replace build id placeholder (avoid f-string brace issues in CSS/JS)
INDEX_HTML = INDEX_HTML.replace("__BUILD_ID__", BUILD_ID)
@app.get("/", response_class=HTMLResponse)
def index() -> HTMLResponse:
    # Avoid stale cached HTML/JS causing timezone display bugs
    return HTMLResponse(
        INDEX_HTML,
        headers={
            "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
            "Pragma": "no-cache",
            "Expires": "0",
        },
    )


@app.get("/api/health")
def health() -> dict:
    return {"status": "ok", "version": "0.1.0"}


@app.post("/api/posts", response_model=PostOut)
def create_post(payload: PostCreate, request: Request, background_tasks: BackgroundTasks) -> PostOut:
    db = get_db()
    try:
        client_ip = request.client.host or "0.0.0.0"
        ip_hash = hash_ip(client_ip)
        content = validate_content(payload.content)
        tag = (payload.tag or "").strip() or None

        enforce_rate_limit(db, ip_hash)

        now = datetime.now(timezone.utc)
        post = Post(
            content=content,
            tag=tag,
            created_at=now,
            ip_hash=ip_hash,
        )
        db.add(post)
        db.commit()
        db.refresh(post)

        post_out = PostOut.from_orm(post)

        if TELEGRAM_ENABLED:
            background_tasks.add_task(send_telegram_notification, post_out)

        return post_out
    finally:
        db.close()


@app.get("/api/posts/recent", response_model=PostsList)
def get_recent(
    limit: int = RECENT_LIMIT_DEFAULT,
    offset: int = 0,
) -> PostsList:
    db = get_db()
    try:
        safe_limit = max(1, min(limit, 200))
        safe_offset = max(0, offset)
        q = (
            db.query(Post)
            .order_by(Post.created_at.desc(), Post.id.desc())
            .offset(safe_offset)
            .limit(safe_limit)
        )
        posts = q.all()
        total = db.query(func.count(Post.id)).scalar() or 0
        return PostsList(
            total=total,
            offset=safe_offset,
            limit=safe_limit,
            posts=[PostOut.from_orm(p) for p in posts],
        )
    finally:
        db.close()


@app.get("/api/posts/random", response_model=PostOut)
def get_random() -> PostOut:
    db = get_db()
    try:
        p = db.query(Post).order_by(func.random()).first()
        if not p:
            raise HTTPException(status_code=404, detail="No posts yet.")
        return PostOut.from_orm(p)
    finally:
        db.close()
PYCODE

  chown "${APP_USER}:${APP_USER}" "${APP_DIR}/app.py"
}

sanity_check_app_py() {
  log "語法檢查 app.py（避免 f-string / 字符串大括號導致服務炸裂）..."
  "${PYTHON_BIN}" -m py_compile "${APP_DIR}/app.py"
}

setup_venv_and_deps() {
  log "建立 Python 虛擬環境並安裝依賴..."
  if [[ ! -d "${VENV_DIR}" ]]; then
    "${PYTHON_BIN}" -m venv "${VENV_DIR}"
  fi
  "${VENV_DIR}/bin/pip" install --upgrade pip
  "${VENV_DIR}/bin/pip" install \
    "fastapi<0.100.0" \
    "pydantic<2.0" \
    "uvicorn[standard]" \
    SQLAlchemy \
    python-dotenv \
    httpx
  chown -R "${APP_USER}:${APP_USER}" "${VENV_DIR}"
}

write_systemd_unit() {
  log "寫入 systemd 服務單元到 /etc/systemd/system/${SERVICE_NAME}.service ..."
  cat >/etc/systemd/system/"${SERVICE_NAME}.service" <<UNIT
[Unit]
Description=Treehole Anonymous Service (FastAPI)
After=network.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=${VENV_DIR}/bin/uvicorn app:app --host 127.0.0.1 --port 8000 --proxy-headers --forwarded-allow-ips='*' --no-access-log
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT
}

write_nginx_conf() {
  log "寫入 Nginx 站點配置 (${NGINX_SITE_AVAILABLE}) ..."
  local has_le_cert="no"
  if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" && -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]]; then
    has_le_cert="yes"
    log "檢測到 Let’s Encrypt 證書，將生成 HTTPS 配置。"
  else
    log "尚未檢測到 /etc/letsencrypt/live/${DOMAIN}/fullchain.pem，暫時僅配置 HTTP。"
    log "之後可用 certbot 簽發證書後重新執行本腳本切換為 HTTPS。"
  fi
  mkdir -p "${CERTBOT_WEBROOT}"
  if [[ "${has_le_cert}" == "yes" ]]; then
    cat >"${NGINX_SITE_AVAILABLE}" <<'NGINX'
server {
    listen 80;
    listen [::]:80;
    server_name DOMAIN_PLACEHOLDER;

    server_tokens off;

    access_log off;
    error_log  /var/log/nginx/treehole_error.log;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name DOMAIN_PLACEHOLDER;

    server_tokens off;

    ssl_certificate /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/privkey.pem;
    access_log off;
    error_log  /var/log/nginx/treehole_error.log;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 10s;
        proxy_send_timeout 120s;
        proxy_read_timeout 120s;
        proxy_request_buffering off;
    }
}
NGINX
  else
    cat >"${NGINX_SITE_AVAILABLE}" <<'NGINX'
server {
    listen 80;
    listen [::]:80;
    server_name DOMAIN_PLACEHOLDER;

    server_tokens off;

    access_log off;
    error_log  /var/log/nginx/treehole_error.log;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 10s;
        proxy_send_timeout 120s;
        proxy_read_timeout 120s;
        proxy_request_buffering off;
    }
}
NGINX
  fi
  sed -i "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" "${NGINX_SITE_AVAILABLE}"
  ln -sf "${NGINX_SITE_AVAILABLE}" "${NGINX_SITE_ENABLED}"
  if [[ -f /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi
}

reload_services() {
  log "重新載入 systemd 並啟動服務..."
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  systemctl restart "${SERVICE_NAME}.service"

  log "測試 Nginx 配置..."
  nginx -t
  log "重載 Nginx..."
  systemctl reload nginx
}

main() {
  print_version
  ensure_root
  ensure_ubuntu

  stop_previous

  install_packages
  create_app_user
  create_dirs
  write_env_if_missing
  write_app_code
  sanity_check_app_py
  setup_venv_and_deps
  write_systemd_unit

  write_nginx_conf
  reload_services

  obtain_certificate_if_needed

  write_nginx_conf
  reload_services

  log "部署完成。請在 DNS 中將 ${DOMAIN} 指向本機 IP。"
  log "當前狀態："
  log "  - 若已存在 /etc/letsencrypt/live/${DOMAIN}/fullchain.pem，則已啟用 HTTPS (443)。"
  log "  - 若尚未有證書，暫時僅提供 HTTP，ACME webroot 在 ${CERTBOT_WEBROOT}。"
  log "若後續簽發好證書，可重新執行本腳本，自動切換為 HTTPS。"
  log "如果需要調整 Telegram 通知，請編輯 ${APP_DIR}/.env 然後：systemctl restart ${SERVICE_NAME}"
}

main "$@"