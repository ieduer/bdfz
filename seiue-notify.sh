#!/usr/bin/env bash
# Seiue Notification → Telegram sidecar installer/runner
# v1.5.0-discover-notification-center
# OS: macOS (Homebrew) & Linux-friendly; uses Python venv
# Commands:
#   install            初次安裝（建置 venv、寫入程式與 .env）
#   reconfigure        重新寫入 .env（僅覆蓋憑證/設定，不動程式）
#   run                前台執行（讀取 .env）
#   start              啟動服務（Linux: systemd；macOS: launchd）
#   stop               停止服務
#   restart            重啟服務
#   status             查看服務狀態
#   logs               追蹤日誌
#   confirm-once       發送最近 1 條消息以驗證（僅收件箱）
#   confirm-per-type   各類型各發 1 條（先通知中心，再回退收件箱）
#   discover           探測端點，輸出各類型計數（不推送）
#   upgrade            升級內嵌 Python、依賴
#   env-edit           編輯 .env
#   help               顯示幫助

set -euo pipefail

APP_NAME="seiue-notify"
APP_DIR="${HOME}/.seiue-notify"
PY_FILE="${APP_DIR}/seiue_notify.py"
VENV_DIR="${APP_DIR}/venv"
BIN_DIR="${VENV_DIR}/bin"
PYTHON_BIN="${PYTHON_BIN:-python3}"
ENV_FILE="${APP_DIR}/.env"
LOG_DIR="${APP_DIR}/logs"
LOG_FILE="${LOG_DIR}/notify.log"

UNAME="$(uname -s || true)"
IS_DARWIN="false"
IS_LINUX="false"
case "${UNAME}" in
  Darwin) IS_DARWIN="true" ;;
  Linux)  IS_LINUX="true" ;;
esac

SYSTEMD_USER_UNIT="${HOME}/.config/systemd/user/${APP_NAME}.service"
SYSTEMD_SYS_UNIT="/etc/systemd/system/${APP_NAME}.service"
LAUNCHD_PLIST="${HOME}/Library/LaunchAgents/com.bdfz.${APP_NAME}.plist"

mkdir -p "${APP_DIR}" "${LOG_DIR}"

info()    { printf "\033[0;34mINFO:\033[0m %s\n" "$*"; }
warn()    { printf "\033[0;33mWARN:\033[0m %s\n" "$*"; }
error()   { printf "\033[0;31mERROR:\033[0m %s\n" "$*"; }
success() { printf "\033[0;32mSUCCESS:\033[0m %s\n" "$*"; }
die()     { error "$*"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

ensure_python() {
  if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    if [ "${IS_DARWIN}" = "true" ]; then
      warn "python3 not found. On macOS run: brew install python@3.12"
    fi
    die "python3 is required."
  fi
}

ensure_venv() {
  ensure_python
  if [ ! -d "${VENV_DIR}" ]; then
    info "Creating venv at ${VENV_DIR}"
    "${PYTHON_BIN}" -m venv "${VENV_DIR}"
  fi
  info "Upgrading pip & installing deps"
  "${BIN_DIR}/python" -m pip install --upgrade pip >/dev/null
  "${BIN_DIR}/pip" install --upgrade requests pytz urllib3 >/dev/null
}

write_env() {
  info "Writing ${ENV_FILE}"
  cat > "${ENV_FILE}" <<'ENV_EOF'
# === Seiue Notify Environment ===
# 必填
export SEIUE_USERNAME="YOUR_SEIUE_USERNAME"
export SEIUE_PASSWORD="YOUR_SEIUE_PASSWORD"
export TELEGRAM_BOT_TOKEN="YOUR_TG_BOT_TOKEN"
export TELEGRAM_CHAT_ID="YOUR_TG_CHAT_ID"

# 選填（有默認）
export X_SCHOOL_ID="3"
export X_ROLE="teacher"

# 輪詢秒數（預設 90）
export NOTIFY_POLL_SECONDS="90"
# 列表最大頁數（1~20，預設 3）
export MAX_LIST_PAGES="3"
# all | unread（預設 all）
export READ_FILTER="all"
# 是否包含抄送 (true/false；預設 false)
export INCLUDE_CC="false"
# 首次啟動是否跳過歷史（1/true=yes；預設 1）
export SKIP_HISTORY_ON_FIRST_RUN="1"
# Telegram 最小發送間隔秒（預設 1.5，支持 TELEGRAM_MIN_INTERVAL_SECS 或拼寫錯誤變量以兼容）
export TELEGRAM_MIN_INTERVAL_SECS="1.5"
# 調試：落盤原始樣本（0/1，預設 0）
export DEBUG_SAVE_RAW="0"
ENV_EOF
}

write_python() {
  info "Writing python app to ${PY_FILE}"
  cat > "${PY_FILE}" <<'EOF_PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Seiue Notification → Telegram sidecar
v1.5.0 — adds Notification Center discovery + stronger type detection
 - NEW: `--discover` probes multiple endpoints and prints per-type counts.
 - NEW: Notification Center fetch (received-notifications family) as a second channel.
 - `--confirm-per-type` now merges results from Inbox + Notification Center.
 - Type detection widened (more Chinese keywords + aggregated messages scan).
Compatibility: Python ≥ 3.7
"""
import json, logging, os, sys, time, html, fcntl, argparse, re
from zlib import crc32
from typing import Dict, Any, List, Tuple, Optional
from datetime import datetime

import requests, pytz
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

# -------- Env --------
SEIUE_USERNAME = os.getenv("SEIUE_USERNAME", "")
SEIUE_PASSWORD = os.getenv("SEIUE_PASSWORD", "")
X_SCHOOL_ID = os.getenv("X_SCHOOL_ID", "3")
X_ROLE = os.getenv("X_ROLE", "teacher")

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "")

POLL_SECONDS = int(os.getenv("NOTIFY_POLL_SECONDS", os.getenv("POLL_SECONDS", "90")))
MAX_LIST_PAGES = max(1, min(int(os.getenv("MAX_LIST_PAGES", "3") or "3"), 20))
READ_FILTER = os.getenv("READ_FILTER", "all").strip().lower()   # all | unread
INCLUDE_CC = os.getenv("INCLUDE_CC", "false").strip().lower() in ("1","true","yes","on")

SKIP_HISTORY_ON_FIRST_RUN = os.getenv("SKIP_HISTORY_ON_FIRST_RUN", "1").strip().lower() in ("1","true","yes","on")
SINGLETON_LOCK_FILE = ".notify.lock"

TELEGRAM_MIN_INTERVAL = float(os.getenv("TELEAGRAM_MIN_INTERVAL_SECS", os.getenv("TELEGRAM_MIN_INTERVAL_SECS", "1.5")))
TG_MSG_LIMIT = 4096
TG_MSG_SAFE = TG_MSG_LIMIT - 64
TG_CAPTION_LIMIT = 1024
TG_CAPTION_SAFE = TG_CAPTION_LIMIT - 16

DEBUG_SAVE_RAW = os.getenv("DEBUG_SAVE_RAW", "0").strip().lower() in ("1","true","yes","on")

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_DIR = os.path.join(BASE_DIR, "logs")
os.makedirs(LOG_DIR, exist_ok=True)
STATE_FILE = os.path.join(BASE_DIR, "notify_state.json")
LOG_FILE = os.path.join(LOG_DIR, "notify.log")

BEIJING_TZ = pytz.timezone("Asia/Shanghai")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s.%(msecs)03d - %(levelname)s - %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[logging.FileHandler(LOG_FILE, encoding="utf-8", mode="a"), logging.StreamHandler(sys.stdout)],
)

# -------- Helpers --------
def acquire_singleton_lock_or_exit(base_dir: str):
    lock_path = os.path.join(base_dir, SINGLETON_LOCK_FILE)
    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.ftruncate(fd, 0)
        os.write(fd, str(os.getpid()).encode())
        return fd
    except OSError:
        logging.error("另一個實例正在運行，為避免重複，本實例退出。")
        sys.exit(0)

def now_cst_str() -> str:
    return datetime.now(BEIJING_TZ).strftime("%Y-%m-%d %H:%M:%S")

def escape_html(s: str) -> str:
    return html.escape(s, quote=False)

def load_state() -> Dict[str, Any]:
    if not os.path.exists(STATE_FILE):
        return {"seen": {}, "last_seen_ts": None, "last_seen_id": 0}
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            st = json.load(f)
            st.setdefault("seen", {})
            st.setdefault("last_seen_ts", None)
            st.setdefault("last_seen_id", 0)
            return st
    except Exception:
        return {"seen": {}, "last_seen_ts": None, "last_seen_id": 0}

def save_state(state: Dict[str, Any]) -> None:
    try:
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False, indent=2)
            f.flush(); os.fsync(f.fileno())
        os.replace(tmp, STATE_FILE)
    except Exception as e:
        logging.warning(f"Failed to save state: {e}")

# -------- Telegram --------
class Telegram:
    def __init__(self, token: str, chat_id: str):
        self.base = f"https://api.telegram.org/bot{token}"
        self.chat_id = chat_id
        self.s = requests.Session()
        retries = Retry(total=3, backoff_factor=1.2, status_forcelist=(429,500,502,503,504))
        self.s.mount("https://", HTTPAdapter(max_retries=retries))
        self._last_send_ts = 0.0

    def _honor_min_interval(self):
        delta = time.time() - self._last_send_ts
        if delta < TELEGRAM_MIN_INTERVAL:
            time.sleep(TELEGRAM_MIN_INTERVAL - delta)

    def _post_with_retry(self, endpoint: str, data: dict, files: Optional[dict] = None, label: str = "sendMessage", timeout: int = 60) -> bool:
        max_attempts = 6
        backoff = 1.0
        for attempt in range(1, max_attempts + 1):
            try:
                self._honor_min_interval()
                url = f"{self.base}/{endpoint}"
                r = self.s.post(url, data=data, files=files, timeout=timeout)
                self._last_send_ts = time.time()
                if r.status_code == 200:
                    return True
                if r.status_code == 429:
                    retry_after = 3
                    try:
                        j = r.json()
                        retry_after = int(j.get("parameters", {}).get("retry_after", retry_after))
                    except Exception:
                        pass
                    retry_after = max(1, min(retry_after + 1, 60))
                    logging.warning(f"{label} 429: retry after {retry_after}s (attempt {attempt}/{max_attempts})")
                    time.sleep(retry_after); continue
                if 500 <= r.status_code < 600:
                    logging.warning(f"{label} {r.status_code}: {r.text[:200]} (attempt {attempt}/{max_attempts})")
                    time.sleep(backoff); backoff = min(backoff * 2, 15); continue
                logging.warning(f"{label} failed {r.status_code}: {r.text[:300]}"); return False
            except requests.RequestException as e:
                logging.warning(f"{label} network error: {e} (attempt {attempt}/{max_attempts})")
                time.sleep(backoff); backoff = min(backoff * 2, 15)
        logging.warning(f"{label} failed after {max_attempts} attempts."); return False

    def send_message(self, html_text: str) -> bool:
        return self._post_with_retry("sendMessage", {
            "chat_id": self.chat_id, "text": html_text, "parse_mode": "HTML", "disable_web_page_preview": True
        }, None, "sendMessage", timeout=30)

    def send_photo_bytes(self, data: bytes, caption_html: str = "") -> bool:
        if caption_html and len(caption_html) > TG_CAPTION_LIMIT:
            caption_html = caption_html[:TG_CAPTION_SAFE] + "…"
        files = {"photo": ("image.jpg", data)}
        return self._post_with_retry("sendPhoto", {
            "chat_id": self.chat_id, "caption": caption_html, "parse_mode": "HTML",
        }, files, "sendPhoto", timeout=90)

    def send_document_bytes(self, data: bytes, filename: str, caption_html: str = "") -> bool:
        if caption_html and len(caption_html) > TG_CAPTION_LIMIT:
            caption_html = caption_html[:TG_CAPTION_SAFE] + "…"
        files = {"document": (filename, data)}
        return self._post_with_retry("sendDocument", {
            "chat_id": self.chat_id, "caption": caption_html, "parse_mode": "HTML",
        }, files, "sendDocument", timeout=180)

    def send_message_safely(self, html_text: str) -> bool:
        if len(html_text) <= TG_MSG_LIMIT:
            return self.send_message(html_text)
        parts: List[str] = []
        def split_para(s: str) -> List[str]:
            return [p for p in s.split("\n\n")]
        buf = ""
        for para in split_para(html_text):
            add = (("\n\n" if buf else "") + para)
            if len(add) > TG_MSG_SAFE:
                lines = para.split("\n")
                for ln in lines:
                    tentative = (buf + ("\n" if buf else "") + ln)
                    if len(tentative) > TG_MSG_SAFE:
                        if buf:
                            parts.append(buf); buf = ln
                        else:
                            start = 0
                            while start < len(ln):
                                parts.append(ln[start:start+TG_MSG_SAFE]); start += TG_MSG_SAFE
                            buf = ""
                    else:
                        buf = tentative
            else:
                tentative = buf + add
                if len(tentative) > TG_MSG_SAFE:
                    parts.append(buf); buf = para
                else:
                    buf = tentative
        if buf: parts.append(buf)
        ok = True; total = len(parts)
        for i, chunk in enumerate(parts, 1):
            head = f"(Part {i}/{total})\n"
            ok = self.send_message(head + chunk) and ok
        return ok

# -------- Seiue API Client --------
class SeiueClient:
    def __init__(self, username: str, password: str):
        self.username = username
        self.password = password
        self.s = requests.Session()
        retries = Retry(total=5, backoff_factor=1.7, status_forcelist=(429,500,502,503,504))
        self.s.mount("https://", HTTPAdapter(max_retries=retries))
        self.s.headers.update({
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140 Safari/537.36",
            "Accept": "application/json, text/plain, */*",
            "Origin": "https://chalk-c3.seiue.com",
            "Referer": "https://chalk-c3.seiue.com/",
        })
        self.bearer = None
        self.reflection_id = None
        self.login_url = "https://passport.seiue.com/login?school_id=3"
        self.authorize_url = "https://passport.seiue.com/authorize"
        self.inbox_url = "https://api.seiue.com/chalk/me/received-messages"
        # Notification center candidates (received by current user)
        self.notif_candidates = [
            ("https://api.seiue.com/chalk/notification/received-notifications", {"receiver.id": "RID"}),
            ("https://api.seiue.com/chalk/notification/notifications/received", {"receiver.id": "RID"}),
            ("https://api.seiue.com/chalk/notification/notifications", {"receiver.id": "RID", "received": "1"}),
        ]

    def _preflight(self):
        try:
            self.s.get(self.login_url, timeout=15)
        except requests.RequestException:
            pass

    def login(self) -> bool:
        self._preflight()
        try:
            self.s.post(self.login_url,
                        headers={"Content-Type":"application/x-www-form-urlencoded",
                                 "Origin":"https://passport.seiue.com",
                                 "Referer":self.login_url},
                        data={"email": self.username, "password": self.password},
                        timeout=30, allow_redirects=True)
            a = self.s.post(self.authorize_url,
                            headers={"Content-Type":"application/x-www-form-urlencoded",
                                     "X-Requested-With":"XMLHttpRequest",
                                     "Origin":"https://chalk-c3.seiue.com",
                                     "Referer":"https://chalk-c3.seiue.com/"},
                            data={"client_id":"GpxvnjhVKt56qTmnPWH1sA","response_type":"token"},
                            timeout=30)
            a.raise_for_status()
            data = a.json()
        except Exception as e:
            logging.error(f"Authorize failed: {e}")
            return False
        token = data.get("access_token")
        ref = data.get("active_reflection_id")
        if not token or not ref:
            logging.error("Authorize missing token or reflection id.")
            return False
        self.bearer = token
        self.reflection_id = str(ref)
        self.s.headers.update({
            "Authorization": f"Bearer {self.bearer}",
            "x-school-id": X_SCHOOL_ID,
            "x-role": X_ROLE,
            "x-reflection-id": self.reflection_id,
        })
        logging.info(f"Auth OK, reflection_id={self.reflection_id}")
        return True

    def _retry_after_auth(self, fn):
        r = fn()
        if getattr(r, "status_code", None) in (401, 403):
            logging.warning("401/403 encountered. Re-auth...")
            if self.login():
                r = fn()
        return r

    @staticmethod
    def _parse_ts(s: str) -> float:
        fmts = ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S")
        for f in fmts:
            try:
                return datetime.strptime(s, f).timestamp()
            except Exception:
                pass
        return 0.0

    def _json_items(self, r: requests.Response) -> List[Dict[str, Any]]:
        try:
            data = r.json()
            if isinstance(data, dict):
                for key in ("items","data","results","rows"):
                    if isinstance(data.get(key), list):
                        return data[key]
            if isinstance(data, list):
                return data
            return []
        except Exception as e:
            logging.error(f"JSON parse error: {e}")
            return []

    # ---------- Normal Inbox ----------
    def normalize_item_inplace(self, it: Dict[str, Any]) -> None:
        agg = it.get("aggregated_messages") or []
        if (not it.get("title") or not it.get("content")) and agg:
            for sub in agg:
                if sub.get("content") or sub.get("title"):
                    it.setdefault("title", sub.get("title"))
                    it.setdefault("content", sub.get("content"))
                    break
        sid = it.get("id")
        if sid is None and agg:
            sid = next((a.get("id") for a in agg if a.get("id") is not None), None)
        if sid is None:
            basis = f"{it.get('title') or ''}|{it.get('published_at') or it.get('created_at') or ''}"
            sid = crc32(basis.encode("utf-8")) & 0xffffffff
        it["_sid"] = str(sid)

    def _list_page_inbox(self, page: int, per_page: int = 20, *, include_cc: Optional[str]=None, read_filter: Optional[str]=None) -> List[Dict[str, Any]]:
        params = {
            "expand": "sender_reflection,aggregated_messages",
            "owner.id": self.reflection_id,
            "paginated": "1",
            "sort": "-published_at,-created_at",
            "page": str(page),
            "per_page": str(per_page),
        }
        rf = READ_FILTER if read_filter is None else read_filter
        if rf == "unread":
            params["readed"] = "false"
        icc = include_cc
        if icc is None:
            if not INCLUDE_CC:
                params["is_cc"] = "false"
        else:
            if icc in ("true","false"):
                params["is_cc"] = icc  # icc == "all" → 不加 is_cc

        logging.info(f"GET inbox params={params}")
        r = self._retry_after_auth(lambda: self.s.get(self.inbox_url, params=params, timeout=30))
        if r.status_code != 200:
            logging.error(f"inbox HTTP {r.status_code}: {r.text[:300]}")
            return []
        items = self._json_items(r)
        for it in items:
            self.normalize_item_inplace(it)
        return items

    # ---------- Notification Center (experimental) ----------
    def _list_page_notif_center(self, page: int, per_page: int = 20) -> List[Dict[str, Any]]:
        """Try a few received-notifications endpoints; return first successful page."""
        for url, base_params in self.notif_candidates:
            params = dict(base_params)
            # RID placeholder
            for k, v in list(params.items()):
                if v == "RID":
                    params[k] = self.reflection_id
            params.update({
                "paginated": "1",
                "expand": "sender,receiver,aggregated_messages",
                "sort": "-published_at,-created_at",
                "page": str(page),
                "per_page": str(per_page),
            })
            logging.info(f"GET notif params url={url} params={params}")
            r = self._retry_after_auth(lambda: self.s.get(url, params=params, timeout=30))
            if r.status_code == 200:
                items = self._json_items(r)
                if DEBUG_SAVE_RAW and items:
                    try:
                        with open(os.path.join(LOG_DIR, f"notif_raw_p{page}.json"), "w", encoding="utf-8") as f:
                            json.dump({"url": url, "params": params, "items": items[:5]}, f, ensure_ascii=False, indent=2)
                    except Exception:
                        pass
                # normalize minimal fields
                for it in items:
                    it.setdefault("sender_reflection", it.get("sender") or {})
                    it.setdefault("published_at", it.get("published_at") or it.get("created_at") or "")
                    self.normalize_item_inplace(it)
                return items
            else:
                logging.info(f"notif center candidate {url} → HTTP {r.status_code}")
        return []

    # ---------- Type guessing ----------
    def _guess_type(self, it: Dict[str, Any]) -> str:
        # explicit field first
        for key in ("type","message_type","category"):
            t = (it.get(key) or "").lower()
            if t:
                break
        else:
            t = ""

        # look into aggregated messages
        if not t:
            for a in it.get("aggregated_messages") or []:
                for key in ("type","message_type","category"):
                    at = (a.get(key) or "").lower()
                    if at:
                        t = at; break
                if t: break

        # keyword fallback
        if not t or t not in ("leave","attendance","evaluation","notice","message"):
            zh = ((it.get("title") or "") + "\n" + (it.get("content") or "")).lower()
            def has(words: List[str]) -> bool:
                return any(w in zh for w in words)
            if has(["请假","請假","销假","銷假","审批","審批","批准","批复","銷假"]):
                t = "leave"
            elif has(["考勤","出勤","签到","簽到","打卡","迟到","遲到","早退","缺勤","旷课","曠課","出勤统计","考勤记录"]):
                t = "attendance"
            elif has(["评价","評價","德育","操行","评语","評語","已发布评价","已發佈評價","測評","问卷","問卷"]):
                t = "evaluation"
            elif has(["通知","公告","通告","已发布通知","已發佈通知"]):
                t = "notice"
            else:
                t = "message"
        return t

    # ---------- High-level list ops ----------
    def list_inbox_incremental(self) -> List[Dict[str, Any]]:
        state = load_state()
        last_ts = float(state.get("last_seen_ts") or 0.0)
        last_id = int(state.get("last_seen_id") or 0)
        results: List[Dict[str, Any]] = []
        newest_ts = last_ts
        newest_id = last_id

        page = 1
        while page <= MAX_LIST_PAGES:
            items = self._list_page_inbox(page)
            if not items:
                break
            for it in items:
                ts_str = it.get("published_at") or it.get("created_at") or ""
                ts = self._parse_ts(ts_str) if ts_str else 0.0
                try:
                    nid_int = int(str(it.get("_sid")))
                except Exception:
                    nid_int = crc32(str(it.get("_sid")).encode("utf-8")) & 0xffffffff

                if last_ts and (ts < last_ts or (ts == last_ts and nid_int <= last_id)):
                    continue

                results.append(it)
                if (ts > newest_ts) or (ts == newest_ts and nid_int > newest_id):
                    newest_ts = ts
                    newest_id = nid_int
            page += 1

        if newest_ts and ((newest_ts > last_ts) or (newest_ts == last_ts and newest_id > last_id)):
            state["last_seen_ts"] = newest_ts
            state["last_seen_id"] = newest_id
            save_state(state)

        logging.info(f"inbox list: fetched={len(results)} pages_scanned={min(page-1, MAX_LIST_PAGES)}")
        return results

    def fetch_latest_inbox(self) -> Optional[Dict[str, Any]]:
        items = self._list_page_inbox(1, per_page=1)
        return items[0] if items else None

    def fetch_latest_by_type_once(self) -> Dict[str, Optional[Dict[str, Any]]]:
        """按類型挑最新 1 條（優先 Notification Center，再回退到 Inbox），並提升水位。"""
        want_types = ["leave", "attendance", "evaluation", "notice", "message"]
        picked: Dict[str, Optional[Dict[str, Any]]] = {t: None for t in want_types}

        def _key(it: Dict[str, Any]):
            ts_str = it.get("published_at") or it.get("created_at") or ""
            ts = SeiueClient._parse_ts(ts_str) if ts_str else 0.0
            try:
                nid_int = int(str(it.get("_sid")))
            except Exception:
                nid_int = crc32(str(it.get("_sid")).encode("utf-8")) & 0xffffffff
            return (ts, nid_int)

        # 1) Scan Notification Center (wider)
        page = 1
        target_pages = max(MAX_LIST_PAGES, 10)
        while page <= target_pages:
            items = self._list_page_notif_center(page)
            if not items:
                break
            for it in items:
                t = self._guess_type(it)
                if t not in picked: t = "message"
                cur = picked.get(t)
                if cur is None or _key(it) > _key(cur):
                    picked[t] = it
            if all(picked.values()):
                break
            page += 1

        # 2) Fill gaps from Inbox
        page = 1
        while page <= target_pages and (None in picked.values()):
            items = self._list_page_inbox(page, include_cc="all", read_filter="all")
            if not items:
                break
            for it in items:
                t = self._guess_type(it)
                if t not in picked: t = "message"
                if picked[t] is None or _key(it) > _key(picked[t]):
                    picked[t] = it
            page += 1

        return picked

# -------- DraftJS rendering + send --------
def render_draftjs_content(content_json: str):
    try:
        raw = json.loads(content_json or "{}")
    except Exception:
        raw = {}
    blocks = raw.get("blocks") or []
    entity_map = raw.get("entityMap") or {}

    entities = {}
    for k, v in entity_map.items():
        try:
            entities[int(k)] = v
        except Exception:
            pass

    lines: List[str] = []
    attachments: List[Dict[str, Any]] = []

    def decorate_styles(text: str, ranges):
        add_prefix = ""
        for r in ranges or []:
            style = r.get("style") or ""
            if style == "BOLD":
                text = f"<b>{escape_html(text)}</b>"
            elif style.startswith("color_"):
                if "red" in style:
                    add_prefix = "❗" + add_prefix
                elif "orange" in style:
                    add_prefix = "⚠️" + add_prefix
                elif "theme" in style:
                    add_prefix = "⭐" + add_prefix
        if not text.startswith("<b>"):
            text = escape_html(text)
        return add_prefix + text

    for blk in blocks:
        t = blk.get("text", "") or ""
        line = decorate_styles(t, blk.get("inlineStyleRanges") or [])

        for er in blk.get("entityRanges") or []:
            key = er.get("key")
            if key is None: continue
            ent = entities.get(int(key))
            if not ent: continue
            etype = (ent.get("type") or "").upper()
            data = ent.get("data") or {}
            if etype == "FILE":
                attachments.append({"type": "file", "name": data.get("name") or "附件", "size": data.get("size") or "", "url": data.get("url") or ""})
            elif etype == "IMAGE":
                attachments.append({"type": "image", "name": "image.jpg", "size": "", "url": data.get("src") or ""})

        align = (blk.get("data") or {}).get("align")
        if align == "align_right" and line.strip():
            line = "—— " + line
        lines.append(line)

    while lines and not lines[-1].strip():
        lines.pop()
    html_text = "\n\n".join([ln if ln.strip() else "​" for ln in lines])
    return html_text, attachments

def build_header(sender_reflection, type_str: str):
    name = ""
    try:
        name = sender_reflection.get("name") or sender_reflection.get("realname") or ""
    except Exception:
        pass
    label = {
        "leave": "请假",
        "attendance": "考勤",
        "evaluation": "评价",
        "notice": "通知",
        "message": "消息",
    }.get((type_str or "").lower(), "消息")
    who = f" · 來自 {escape_html(name)}" if name else ""
    return f"📩 <b>校內{label}</b>{who}\n"

def format_time(ts: str) -> str:
    try:
        dt = datetime.strptime(ts, "%Y-%m-%d %H:%M:%S").replace(tzinfo=BEIJING_TZ)
        return dt.strftime("%Y-%m-%d %H:%M")
    except Exception:
        return ts or ""

def download_with_auth(cli: "SeiueClient", url: str) -> Tuple[bytes, str]:
    try:
        r = cli._retry_after_auth(lambda: cli.s.get(url, timeout=60, stream=True))
        if r.status_code != 200:
            logging.error(f"download HTTP {r.status_code}: {r.text[:300]}")
            return b"", "attachment.bin"
        content = r.content
        name = "attachment.bin"
        cd = r.headers.get("Content-Disposition") or ""
        if "filename=" in cd:
            name = cd.split("filename=", 1)[1].strip('"; ')
        else:
            from urllib.parse import urlparse, unquote
            try:
                path = urlparse(r.url).path
                name = unquote(path.rsplit("/", 1)[-1]) or name
            except Exception:
                pass
        return content, name
    except requests.RequestException as e:
        logging.error(f"download failed: {e}")
        return b"", "attachment.bin"

def send_one_item(tg: "Telegram", cli: "SeiueClient", item: Dict[str, Any]) -> bool:
    agg = item.get("aggregated_messages") or []
    title = item.get("title") or (agg and (agg[0].get("title") or "")) or ""
    content_str = item.get("content") or (agg and (agg[0].get("content") or "")) or ""
    if not content_str:
        content_str = json.dumps({"blocks": [{"text": ""}]})
    html_body, atts = render_draftjs_content(content_str)
    type_guess = cli._guess_type(item)
    header = build_header(item.get("sender_reflection") or {}, type_guess)
    created = item.get("published_at") or item.get("created_at") or ""
    created_fmt = format_time(created)
    time_line = f"— 發布於 {created_fmt}" if created_fmt else ""
    main_msg = f"{header}\n<b>{escape_html(title)}</b>\n\n{html_body}\n\n{time_line}"
    ok = tg.send_message_safely(main_msg)

    images = [a for a in atts if a.get("type") == "image" and a.get("url")]
    files = [a for a in atts if a.get("type") == "file" and a.get("url")]
    for a in images:
        data, _ = download_with_auth(cli, a["url"])
        if data:
            ok = tg.send_photo_bytes(data, caption_html="") and ok
    for a in files:
        data, fname = download_with_auth(cli, a["url"])
        if data:
            cap = f"📎 <b>{escape_html(a.get('name') or fname)}</b>"
            size = a.get("size")
            if size: cap += f"（{escape_html(size)}）"
            if len(cap) > 1024: cap = cap[:1008] + "…"
            ok = tg.send_document_bytes(data, filename=(a.get("name") or fname), caption_html=cap) and ok
    return ok

def ensure_startup_watermark(cli: "SeiueClient"):
    state = load_state()
    if state.get("last_seen_ts"): return
    if not SKIP_HISTORY_ON_FIRST_RUN: return
    newest_ts = 0.0; newest_id = 0
    try:
        it0 = cli.fetch_latest_inbox()
        if it0:
            ts_str = it0.get("published_at") or it0.get("created_at") or ""
            newest_ts = SeiueClient._parse_ts(ts_str) if ts_str else 0.0
            sid = str(it0.get("_sid"))
            try: newest_id = int(sid)
            except Exception: newest_id = crc32(sid.encode("utf-8")) & 0xffffffff
    except Exception as e:
        logging.warning(f"無法獲取啟動水位（使用當前時間）: {e}")
    if not newest_ts: newest_ts = time.time()
    state["last_seen_ts"] = newest_ts
    state["last_seen_id"] = newest_id
    save_state(state)
    logging.info("啟動已設置水位（跳過歷史基準），last_seen_ts=%s last_seen_id=%s", newest_ts, newest_id)

def confirm_per_type_once(tg: "Telegram", cli: "SeiueClient"):
    state = load_state()
    picked = cli.fetch_latest_by_type_once()
    pushed_any = False
    max_ts = float(state.get("last_seen_ts") or 0.0)
    max_id = int(state.get("last_seen_id") or 0)
    seen = state.get("seen") or {}

    for t, it in picked.items():
        if not it: continue
        ok = send_one_item(tg, cli, it)
        ts_str = it.get("published_at") or it.get("created_at") or ""
        ts = SeiueClient._parse_ts(ts_str) if ts_str else int(time.time())
        sid = str(it.get("_sid"))
        try: nid_int = int(sid)
        except Exception: nid_int = crc32(sid.encode("utf-8")) & 0xffffffff
        seen[sid] = {"pushed_at": now_cst_str(), "type": t}
        if (ts > max_ts) or (ts == max_ts and nid_int > max_id):
            max_ts, max_id = ts, nid_int
        pushed_any = ok or pushed_any
        logging.info("per-type 確認已發送（type=%s sid=%s ok=%s）", t, sid, ok)

    if pushed_any:
        state["seen"] = seen
        state["last_seen_ts"] = max_ts
        state["last_seen_id"] = max_id
        save_state(state)
        logging.info("per-type 確認完成，已提升水位到: ts=%s id=%s", max_ts, max_id)
    else:
        logging.info("per-type 確認：無可發送項（通知中心/收件箱都未命中）。")

# -------- Discover mode --------
def discover(cli: "SeiueClient"):
    print("== DISCOVER START ==")
    suites = []
    # Inbox
    items = cli._list_page_inbox(1, per_page=50, include_cc="all", read_filter="all")
    suites.append(("inbox", items))
    # Notification center candidates
    nitems = cli._list_page_notif_center(1, per_page=50)
    suites.append(("notif_center", nitems))

    for name, items in suites:
        counts = {"leave":0,"attendance":0,"evaluation":0,"notice":0,"message":0}
        for it in items:
            t = cli._guess_type(it)
            if t not in counts: t = "message"
            counts[t]+=1
        print(f"[{name}] total={len(items)}  counts={counts}")
        if DEBUG_SAVE_RAW and items:
            try:
                with open(os.path.join(LOG_DIR, f"{name}_sample.json"), "w", encoding="utf-8") as f:
                    json.dump(items[:5], f, ensure_ascii=False, indent=2)
            except Exception:
                pass
    print("== DISCOVER END ==")

# -------- Main --------
def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--confirm-once", action="store_true", help="發送最近 1 條以確認安裝成功（僅 Inbox），並設置水位")
    parser.add_argument("--confirm-per-type", action="store_true", help="按類型各發 1 條（通知中心優先，再回退 Inbox），並提升水位")
    parser.add_argument("--discover", action="store_true", help="檢測不同端點，輸出每類型計數（不推送）")
    args, _ = parser.parse_known_args()

    if not (SEIUE_USERNAME and SEIUE_PASSWORD and TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID):
        print("缺少環境變量：SEIUE_USERNAME / SEIUE_PASSWORD / TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID", file=sys.stderr)
        sys.exit(1)

    lock_fd = acquire_singleton_lock_or_exit(BASE_DIR)
    tg = Telegram(TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID)
    cli = SeiueClient(SEIUE_USERNAME, SEIUE_PASSWORD)
    if not cli.login():
        print("Seiue 登入失敗。", file=sys.stderr)
        sys.exit(2)

    ensure_startup_watermark(cli)

    if args.discover:
        discover(cli)
        sys.exit(0)

    if args.confirm_per_type:
        confirm_per_type_once(tg, cli)
        sys.exit(0)

    if args.confirm_once:
        it0 = cli.fetch_latest_inbox()
        if it0:
            ok = send_one_item(tg, cli, it0)
            state = load_state()
            try:
                ts_str = it0.get("published_at") or it0.get("created_at") or ""
                ts = SeiueClient._parse_ts(ts_str) if ts_str else int(time.time())
                sid = str(it0.get("_sid"))
                try: nid_int = int(sid)
                except Exception: nid_int = crc32(sid.encode("utf-8")) & 0xffffffff
            except Exception:
                ts = int(time.time()); nid_int = 0
            state["last_seen_ts"] = max(float(state.get("last_seen_ts") or 0.0), ts)
            state["last_seen_id"] = max(int(state.get("last_seen_id") or 0), nid_int)
            seen = state.get("seen") or {}
            seen[str(it0.get("_sid"))] = {"pushed_at": now_cst_str()}
            state["seen"] = seen
            save_state(state)
            logging.info("確認消息已發送（sid=%s） ok=%s", it0.get("_sid"), ok)
        else:
            logging.info("無可用的最新消息可確認發送。")
        sys.exit(0)

    # 常駐輪詢（仍以 Inbox 為主；通知中心目前僅用於確認與未來擴展）
    state = load_state()
    seen: Dict[str, Any] = state.get("seen") or {}
    logging.info(f"開始輪詢（每 {POLL_SECONDS}s）...")

    while True:
        try:
            items = cli.list_inbox_incremental()
            new_items = [it for it in items if str(it.get("_sid")) not in seen]

            def _key(it: Dict[str, Any]):
                ts_str = it.get("published_at") or it.get("created_at") or ""
                ts = SeiueClient._parse_ts(ts_str) if ts_str else 0.0
                try: nid = int(str(it.get("_sid")))
                except Exception: nid = crc32(str(it.get("_sid")).encode("utf-8")) & 0xffffffff
                return (ts, nid)
            new_items.sort(key=_key)

            for d in new_items:
                sid = str(d.get("_sid"))
                seen[sid] = {"pushed_at": now_cst_str(), "type": cli._guess_type(d)}
                state["seen"] = seen
                save_state(state)
                send_one_item(tg, cli, d)

            time.sleep(POLL_SECONDS)
        except KeyboardInterrupt:
            logging.info("收到中斷，退出。"); break
        except Exception as e:
            logging.exception(f"主循環異常：{e}")
            time.sleep(min(POLL_SECONDS, 60))

if __name__ == "__main__":
    main()
EOF_PY
  chmod +x "${PY_FILE}"
}

write_systemd_user_unit() {
  mkdir -p "$(dirname "${SYSTEMD_USER_UNIT}")"
  cat > "${SYSTEMD_USER_UNIT}" <<EOF
[Unit]
Description=Seiue Notification → Telegram
After=network-online.target

[Service]
Type=simple
Environment=ENV_FILE=${ENV_FILE}
WorkingDirectory=${APP_DIR}
ExecStart=/bin/bash -lc 'source "${ENV_FILE}" && exec "${BIN_DIR}/python" "${PY_FILE}"'
Restart=on-failure
RestartSec=5s
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=default.target
EOF
}

write_launchd_plist() {
  mkdir -p "$(dirname "${LAUNCHD_PLIST}")"
  cat > "${LAUNCHD_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.bdfz.${APP_NAME}</string>
  <key>WorkingDirectory</key><string>${APP_DIR}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>source "${ENV_FILE}" &amp;&amp; exec "${BIN_DIR}/python" "${PY_FILE}"</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${LOG_FILE}</string>
  <key>StandardErrorPath</key><string>${LOG_FILE}</string>
</dict>
</plist>
EOF
}

install_cmd() {
  ensure_venv
  write_python
  if [ ! -f "${ENV_FILE}" ]; then
    write_env
    warn "請編輯 ${ENV_FILE} 填入 SEIUE_USERNAME/SEIUE_PASSWORD/TELEGRAM_* 後再啟動。"
  fi
  if [ "${IS_LINUX}" = "true" ] && command -v systemctl >/dev/null 2>&1; then
    write_systemd_user_unit
    systemctl --user daemon-reload || true
    info "用戶級 systemd 服務已寫入：${SYSTEMD_USER_UNIT}"
  elif [ "${IS_DARWIN}" = "true" ]; then
    write_launchd_plist
    info "launchd plist 已寫入：${LAUNCHD_PLIST}"
  else
    warn "非 systemd / launchd 環境：將使用前台 run 模式。"
  fi
  success "Install finished."
}

reconfigure_cmd() {
  write_env
  success "Reconfigured ${ENV_FILE}."
}

start_cmd() {
  if [ "${IS_LINUX}" = "true" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload || true
    systemctl --user enable "${APP_NAME}.service" || true
    systemctl --user start "${APP_NAME}.service"
    success "systemd user service started."
  elif [ "${IS_DARWIN}" = "true" ]; then
    launchctl unload "${LAUNCHD_PLIST}" >/dev/null 2>&1 || true
    launchctl load "${LAUNCHD_PLIST}"
    success "launchd service loaded."
  else
    die "No service manager available. Use: $0 run"
  fi
}

stop_cmd() {
  if [ "${IS_LINUX}" = "true" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl --user stop "${APP_NAME}.service" || true
    success "systemd user service stopped."
  elif [ "${IS_DARWIN}" = "true" ]; then
    launchctl unload "${LAUNCHD_PLIST}" || true
    success "launchd service unloaded."
  else
    warn "No service manager; nothing to stop."
  fi
}

restart_cmd() {
  stop_cmd
  start_cmd
}

status_cmd() {
  if [ "${IS_LINUX}" = "true" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl --user status "${APP_NAME}.service" || true
  elif [ "${IS_DARWIN}" = "true" ]; then
    launchctl list | grep "com.bdfz.${APP_NAME}" || true
    echo "Log: ${LOG_FILE}"
  else
    warn "No service manager; check logs: ${LOG_FILE}"
  fi
}

logs_cmd() {
  : > "${LOG_FILE}" 2>/dev/null || true
  tail -f "${LOG_FILE}"
}

run_cmd() {
  ensure_venv
  if [ ! -f "${ENV_FILE}" ]; then
    write_env
    die "已生成 ${ENV_FILE}，請先填好變量再執行。"
  fi
  set +u
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set -u
  exec "${BIN_DIR}/python" "${PY_FILE}"
}

confirm_once_cmd() {
  ensure_venv
  set +u; source "${ENV_FILE}"; set -u
  exec "${BIN_DIR}/python" "${PY_FILE}" --confirm-once
}

confirm_per_type_cmd() {
  ensure_venv
  set +u; source "${ENV_FILE}"; set -u
  exec "${BIN_DIR}/python" "${PY_FILE}" --confirm-per-type
}

discover_cmd() {
  ensure_venv
  set +u; source "${ENV_FILE}"; set -u
  exec "${BIN_DIR}/python" "${PY_FILE}" --discover
}

upgrade_cmd() {
  ensure_venv
  write_python
  "${BIN_DIR}/pip" install --upgrade requests pytz urllib3 >/dev/null
  success "Upgraded python app & deps."
}

env_edit_cmd() {
  "${EDITOR:-nano}" "${ENV_FILE}"
}

usage() {
  cat <<EOF
Usage: $0 <command>

Commands:
  install            初次安裝（建置 venv、寫入程式與 .env）
  reconfigure        重新寫入 .env（僅覆蓋憑證/設定，不動程式）
  run                前台執行（讀取 .env）
  start              啟動服務（Linux: systemd；macOS: launchd）
  stop               停止服務
  restart            重啟服務
  status             查看服務狀態
  logs               追蹤日誌
  confirm-once       發送最近 1 條消息以驗證（僅收件箱）
  confirm-per-type   各類型各發 1 條（先通知中心，再回退收件箱）
  discover           探測端點，輸出各類型計數（不推送）
  upgrade            升級內嵌 Python、依賴
  env-edit           編輯 .env
  help               顯示幫助
EOF
}

cmd="${1:-help}"
case "${cmd}" in
  install)           install_cmd ;;
  reconfigure)       reconfigure_cmd ;;
  run)               run_cmd ;;
  start)             start_cmd ;;
  stop)              stop_cmd ;;
  restart)           restart_cmd ;;
  status)            status_cmd ;;
  logs)              logs_cmd ;;
  confirm-once)      confirm_once_cmd ;;
  confirm-per-type)  confirm_per_type_cmd ;;
  discover)          discover_cmd ;;
  upgrade)           upgrade_cmd ;;
  env-edit)          env_edit_cmd ;;
  help|--help|-h)    usage ;;
  *)                 usage; exit 2 ;;
esac