#!/usr/bin/env bash
# Seiue Notification → Telegram - One-click Installer (Sidecar)
# v1.8.0-me-inbox-noninteractive
# - Auto-install & start systemd (no prompts)
# - ExecStartPre clears stale lock
# - No background first_run (避免重复实例)
# - 安装后一次性推送“最新一条”到 Telegram 作为成功确认（并设置水位避免重发）
# - 仅走 me 收件箱: /chalk/me/received-messages (owner.id=reflection_id)
# - 强 at-most-once：singleton + (last_ts,last_id) 水位 + per-id seen

set -euo pipefail

# ---- pretty output ----
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'
info()    { echo -e "${C_BLUE}INFO:${C_RESET} $1"; }
success() { echo -e "${C_GREEN}SUCCESS:${C_RESET} $1"; }
warn()    { echo -e "${C_YELLOW}WARNING:${C_RESET} $1"; }
error()   { echo -e "${C_RED}ERROR:${C_RESET} $1" >&2; }

# ---- root escalate for install only ----
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "此腳本需要 root 權限以安裝依賴/寫檔，正在使用 sudo 提權..."
  exec sudo -E bash "$0" "$@"
fi

# ---- real user / paths ----
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo ~"$REAL_USER")
INSTALL_DIR="${REAL_HOME}/.seiue-notify"
VENV_DIR="${INSTALL_DIR}/venv"
PY_SCRIPT="seiue_notify.py"
RUNNER="run.sh"
ENV_FILE=".env"
LOG_DIR="${INSTALL_DIR}/logs"

# ---- flags ----
RECONF=0
for arg in "$@"; do
  [ "$arg" = "--reconfigure" ] && RECONF=1
done
COLLECTED="0"

# ---- proxy passthrough ----
PROXY_ENV="$(env | grep -i -E '^(http_proxy|https_proxy|no_proxy|HTTP_PROXY|HTTPS_PROXY|NO_PROXY)=' || true)"
[ -n "${PROXY_ENV}" ] && info "檢測到代理，安裝與運行會沿用。"

# ---- run as real user ----
run_as_user() {
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$REAL_USER" -- "$@"
  else
    sudo -u "$REAL_USER" -- "$@"
  fi
}

# ----------------- 1) Pre-flight checks -----------------
check_environment() {
  info "--- 執行環境預檢 ---"
  local all_ok=true

  if ! curl -fsS --head --connect-timeout 8 "https://passport.seiue.com/login?school_id=3" >/dev/null; then
    error "無法連到 https://passport.seiue.com（請檢查網路/防火牆/代理）。"
    all_ok=false
  fi

  local PYBIN=""
  if command -v python3 >/dev/null 2>&1; then PYBIN="$(command -v python3)"; fi
  if [ -z "$PYBIN" ]; then
    warn "系統未找到 python3，將嘗試安裝（Ubuntu/Debian 使用 apt；CentOS 使用 yum）。"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y && apt-get install -y python3 python3-venv
    elif command -v yum >/dev/null 2>&1; then
      yum install -y python3 python3-venv || true
    fi
    PYBIN="$(command -v python3 || true)"
  fi
  if [ -z "$PYBIN" ]; then
    error "仍未找到 python3，請手動安裝後重試。"
    all_ok=false
  else
    if ! "$PYBIN" - <<'EOF' >/dev/null 2>&1
import sys
sys.exit(0 if sys.version_info >= (3,7) else 1)
EOF
    then
      error "需要 Python ≥ 3.7。"
      all_ok=false
    fi
  fi

  if [ "$all_ok" = false ]; then
    error "環境檢查未通過，請修正後再執行。"
    exit 1
  fi
  success "環境預檢通過。"
}

# ----------------- 2) Collect secrets -----------------
collect_inputs() {
  info "請輸入必要配置（僅用於生成 ${ENV_FILE}，權限 600 保存）。"

  read -p "Seiue 用戶名: " SEIUE_USERNAME
  [ -z "$SEIUE_USERNAME" ] && { error "用戶名不能為空"; exit 1; }

  read -s -p "Seiue 密碼: " SEIUE_PASSWORD; echo
  [ -z "$SEIUE_PASSWORD" ] && { error "密碼不能為空"; exit 1; }

  read -p "Telegram Bot Token（如：123456:ABC...）: " TG_BOT_TOKEN
  [ -z "$TG_BOT_TOKEN" ] && { error "Bot Token 不能為空"; exit 1; }

  read -p "Telegram Chat ID（群/頻道/個人）: " TG_CHAT_ID
  [ -z "$TG_CHAT_ID" ] && { error "Chat ID 不能為空"; exit 1; }

  read -p "輪詢間隔秒數（預設 90）: " POLL
  POLL="${POLL:-90}"

  export SEIUE_USERNAME SEIUE_PASSWORD TG_BOT_TOKEN TG_CHAT_ID POLL
  COLLECTED="1"
}

# ----------------- 3) Install venv & deps -----------------
setup_layout() {
  info "準備安裝目錄：${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}" "${LOG_DIR}"
  chown -R "$REAL_USER:$(id -gn "$REAL_USER")" "$INSTALL_DIR"

  local PYBIN="$(command -v python3)"
  if ! "$PYBIN" -c 'import ensurepip' >/dev/null 2>&1; then
    info "未檢測到 ensurepip（python3-venv），嘗試安裝..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y
      apt-get install -y python3-venv python3.12-venv || apt-get install -y python3-venv || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y python3 python3-pip || true
    fi
  fi

  if ! run_as_user "$PYBIN" -m venv "$VENV_DIR"; then
    warn "python -m venv 失敗，嘗試安裝/修復後重試一次..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y
      apt-get install -y python3-venv python3.12-venv || apt-get install -y python3-venv || true
    fi
    run_as_user "$PYBIN" -m venv "$VENV_DIR"
  fi
  local VPY="${VENV_DIR}/bin/python"

  if ! run_as_user "$VPY" -m pip --version >/dev/null 2>&1; then
    info "在 venv 內引導安裝 pip（ensurepip）..."
    run_as_user "$VPY" -m ensurepip --upgrade || true
  fi

  info "升級 pip..."
  run_as_user env ${PROXY_ENV} "$VPY" -m pip install -q --upgrade pip || true

  info "安裝依賴（requests, pytz, urllib3）..."
  run_as_user env ${PROXY_ENV} "$VPY" -m pip install -q requests pytz urllib3
  success "虛擬環境與依賴就緒。"
}

# ----------------- 4) Write Python notifier -----------------
write_python() {
  info "生成 Python 通知輪詢器（me/received-messages 單跳 + 去重強化 + 一次性確認）..."
  local TMP="$(mktemp)"
  cat > "$TMP" <<'EOF_PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Seiue Notification → Telegram sidecar (me/received-messages, single-hop)
v1.8.0 — singleton lock, startup watermark, (ts,id) dedupe, at-most-once, --confirm-once
"""
import json, logging, os, sys, time, html, fcntl, argparse
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

# 控制是否啟動時跳過歷史（只從當前時間/最新一條之後開始收）
SKIP_HISTORY_ON_FIRST_RUN = os.getenv("SKIP_HISTORY_ON_FIRST_RUN", "1").strip().lower() in ("1","true","yes","on")
# 簡單單例鎖：避免多進程同時運行導致重複推送
SINGLETON_LOCK_FILE = ".notify.lock"

# Telegram 控制
TELEGRAM_MIN_INTERVAL = float(os.getenv("TELEGRAM_MIN_INTERVAL_SECS", "1.5"))
TG_MSG_LIMIT = 4096
TG_MSG_SAFE = TG_MSG_LIMIT - 64
TG_CAPTION_LIMIT = 1024
TG_CAPTION_SAFE = TG_CAPTION_LIMIT - 16

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

def acquire_singleton_lock_or_exit(base_dir: str):
    lock_path = os.path.join(base_dir, SINGLETON_LOCK_FILE)
    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.ftruncate(fd, 0)
        os.write(fd, str(os.getpid()).encode())
        return fd  # keep fd open to hold the lock
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
            f.flush()
            os.fsync(f.fileno())
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

# -------- Seiue API --------
class SeiueClient:
    def __init__(self, username: str, password: str):
        self.username = username; self.password = password
        self.s = requests.Session()
        retries = Retry(total=5, backoff_factor=1.7, status_forcelist=(429,500,502,503,504))
        self.s.mount("https://", HTTPAdapter(max_retries=retries))
        self.s.headers.update({
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140 Safari/537.36",
            "Accept": "application/json, text/plain, */*",
            "Origin": "https://chalk-c3.seiue.com",
            "Referer": "https://chalk-c3.seiue.com/",
        })
        self.bearer = None; self.reflection_id = None
        self.login_url = "https://passport.seiue.com/login?school_id=3"
               self.authorize_url = "https://passport.seiue.com/authorize"
        self.inbox_url = "https://api.seiue.com/chalk/me/received-messages"

    def _preflight(self):
        try: self.s.get(self.login_url, timeout=15)
        except requests.RequestException: pass

    def login(self) -> bool:
        self._preflight()
        try:
            r = self.s.post(self.login_url,
                headers={"Content-Type":"application/x-www-form-urlencoded","Origin":"https://passport.seiue.com","Referer":self.login_url},
                data={"email": self.username, "password": self.password},
                timeout=30, allow_redirects=True)
        except requests.RequestException as e:
            logging.error(f"Login network error: {e}"); return False
        try:
            a = self.s.post(self.authorize_url,
                headers={"Content-Type":"application/x-www-form-urlencoded","X-Requested-With":"XMLHttpRequest","Origin":"https://chalk-c3.seiue.com","Referer":"https://chalk-c3.seiue.com/"},
                data={'client_id':'GpxvnjhVKt56qTmnPWH1sA','response_type':'token'},
                timeout=30)
            a.raise_for_status()
            data = a.json()
        except Exception as e:
            logging.error(f"Authorize failed: {e}"); return False
        token = data.get("access_token"); ref = data.get("active_reflection_id")
        if not token or not ref:
            logging.error("Authorize missing token or reflection id."); return False
        self.bearer = token; self.reflection_id = str(ref)
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
        if getattr(r, "status_code", None) in (401,403):
            logging.warning("401/403 encountered. Re-auth...")
            if self.login(): r = fn()
        return r

    @staticmethod
    def _parse_ts(s: str) -> float:
        fmts = ("%Y-%m-%d %H:%M:%S","%Y-%m-%dT%H:%M:%S%z","%Y-%m-%dT%H:%M:%S")
        for f in fmts:
            try: return datetime.strptime(s, f).timestamp()
            except Exception: pass
        return 0.0

    def _json_items(self, r: requests.Response) -> List[Dict[str, Any]]:
        try:
            data = r.json()
            if isinstance(data, dict) and isinstance(data.get("items"), list):
                return data["items"]
            if isinstance(data, list):
                return data
            return []
        except Exception as e:
            logging.error(f"JSON parse error: {e}")
            return []

    def list_my_received_incremental(self) -> List[Dict[str, Any]]:
        state = load_state()
        last_ts = float(state.get("last_seen_ts") or 0.0)
        last_id = int(state.get("last_seen_id") or 0)
        results: List[Dict[str, Any]] = []
        newest_ts = last_ts
        newest_id = last_id

        params_base = {
            "expand": "sender_reflection",
            "owner.id": self.reflection_id,
            "type": "message",
            "paginated": "1",
            "sort": "-published_at,-created_at",
        }
        if READ_FILTER == "unread":
            params_base["readed"] = "false"
        if not INCLUDE_CC:
            params_base["is_cc"] = "false"

        page = 1
        while page <= MAX_LIST_PAGES:
            params = dict(params_base, **{"page": str(page), "per_page": "20"})
            r = self._retry_after_auth(lambda: self.s.get(self.inbox_url, params=params, timeout=30))
            if r.status_code == 404:
                logging.error("me/received-messages not found (404)")
                break
            if r.status_code != 200:
                logging.error(f"me/received-messages HTTP {r.status_code}: {r.text[:300]}")
                break

            items = self._json_items(r)
            if not items:
                break

            for it in items:
                ts_str = it.get("published_at") or it.get("created_at") or ""
                ts = self._parse_ts(ts_str) if ts_str else 0.0
                nid_raw = it.get("id")
                try:
                    nid_int = int(str(nid_raw))
                except Exception:
                    nid_int = 0

                if last_ts:
                    if ts < last_ts or (ts == last_ts and nid_int <= last_id):
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

        logging.info(f"list: fetched={len(results)} pages_scanned={min(page-1, MAX_LIST_PAGES)}")
        return results

    def fetch_latest(self) -> Optional[Dict[str, Any]]:
        params = {
            "expand": "sender_reflection",
            "owner.id": self.reflection_id or "",
            "type": "message",
            "paginated": "1",
            "sort": "-published_at,-created_at",
            "page": "1",
            "per_page": "1",
        }
        r = self._retry_after_auth(lambda: self.s.get(self.inbox_url, params=params, timeout=30))
        if r.status_code != 200:
            logging.error(f"fetch_latest HTTP {r.status_code}: {r.text[:300]}")
            return None
        items = self._json_items(r)
        return items[0] if items else None

def render_draftjs_content(content_json: str):
    try:
        raw = json.loads(content_json or "{}")
    except Exception:
        raw = {}
    blocks = raw.get("blocks") or []
    entity_map = raw.get("entityMap") or {}

    entities = {}
    for k, v in entity_map.items():
        try: entities[int(k)] = v
        except Exception: pass

    from typing import List, Dict, Any
    lines: List[str] = []
    attachments: List[Dict[str, Any]] = []

    def decorate_styles(text: str, ranges):
        add_prefix = ""
        for r in ranges or []:
            style = r.get("style") or ""
            if style == "BOLD": text = f"<b>{escape_html(text)}</b>"
            elif style.startswith("color_"):
                if "red" in style: add_prefix = "❗" + add_prefix
                elif "orange" in style: add_prefix = "⚠️" + add_prefix
                elif "theme" in style: add_prefix = "⭐" + add_prefix
        if not text.startswith("<b>"): text = escape_html(text)
        return add_prefix + text

    for blk in blocks:
        t = blk.get("text","") or ""
        line = decorate_styles(t, blk.get("inlineStyleRanges") or [])

        for er in blk.get("entityRanges") or []:
            key = er.get("key")
            if key is None: continue
            ent = entities.get(int(key))
            if not ent: continue
            etype = (ent.get("type") or "").upper()
            data = ent.get("data") or {}
            if etype == "FILE":
                attachments.append({"type":"file","name":data.get("name") or "附件","size":data.get("size") or "","url":data.get("url") or ""})
            elif etype == "IMAGE":
                attachments.append({"type":"image","name":"image.jpg","size":"","url":data.get("src") or ""})

        align = (blk.get("data") or {}).get("align")
        if align == "align_right" and line.strip(): line = "—— " + line
        lines.append(line)

    while lines and not lines[-1].strip(): lines.pop()
    html_text = "\n\n".join([ln if ln.strip() else "​" for ln in lines])
    return html_text, attachments

def build_header(sender_reflection):
    name = ""
    try:
        name = sender_reflection.get("name") or sender_reflection.get("realname") or ""
    except Exception:
        pass
    return f"📩 <b>校內訊息</b>{' · 來自 ' + escape_html(name) if name else ''}\n"

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
        content = r.content; name = "attachment.bin"
        cd = r.headers.get("Content-Disposition") or ""
        if "filename=" in cd:
            name = cd.split("filename=",1)[1].strip('"; ')
        else:
            from urllib.parse import urlparse, unquote
            try:
                path = urlparse(r.url).path
                name = unquote(path.rsplit('/',1)[-1]) or name
            except Exception: pass
        return content, name
    except requests.RequestException as e:
        logging.error(f"download failed: {e}")
        return b"", "attachment.bin"

def ensure_startup_watermark(cli: "SeiueClient"):
    state = load_state()
    if state.get("last_seen_ts"):
        return
    if not SKIP_HISTORY_ON_FIRST_RUN:
        return
    newest_ts = 0.0
    newest_id = 0
    try:
        it0 = cli.fetch_latest()
        if it0:
            ts_str = it0.get("published_at") or it0.get("created_at") or ""
            newest_ts = SeiueClient._parse_ts(ts_str) if ts_str else 0.0
            try:
                newest_id = int(str(it0.get("id")))
            except Exception:
                newest_id = 0
    except Exception as e:
        logging.warning(f"無法獲取啟動水位（使用當前時間）: {e}")
    if not newest_ts:
        newest_ts = time.time()
    state["last_seen_ts"] = newest_ts
    state["last_seen_id"] = newest_id
    save_state(state)
    logging.info("啟動已設置水位（跳過歷史），last_seen_ts=%s last_seen_id=%s", newest_ts, newest_id)

def send_one_item(tg:"Telegram", cli:"SeiueClient", item: Dict[str,Any]) -> bool:
    nid = str(item.get("id"))
    title = item.get("title") or ""
    content_str = item.get("content") or ""
    html_body, atts = render_draftjs_content(content_str)
    header = build_header(item.get("sender_reflection") or {})
    created = item.get("published_at") or item.get("created_at") or ""
    created_fmt = format_time(created)
    time_line = f"— 發布於 {created_fmt}" if created_fmt else ""
    main_msg = f"{header}\n<b>{escape_html(title)}</b>\n\n{html_body}\n\n{time_line}"
    ok = tg.send_message_safely(main_msg)
    # attachments
    images = [a for a in atts if a.get("type") == "image" and a.get("url")]
    files  = [a for a in atts if a.get("type") == "file" and a.get("url")]
    for a in images:
        data, _ = download_with_auth(cli, a["url"])
        if data: ok = tg.send_photo_bytes(data, caption_html="") and ok
    for a in files:
        data, fname = download_with_auth(cli, a["url"])
        if data:
            cap = f"📎 <b>{escape_html(a.get('name') or fname)}</b>"
            size = a.get("size")
            if size: cap += f"（{escape_html(size)}）"
            if len(cap) > 1024: cap = cap[:1008] + "…"
            ok = tg.send_document_bytes(data, filename=(a.get("name") or fname), caption_html=cap) and ok
    return ok

def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--confirm-once", action="store_true", help="發送最近 1 條以確認安裝成功，並設置水位避免重發")
    args, _ = parser.parse_known_args()

    if not (SEIUE_USERNAME and SEIUE_PASSWORD and TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID):
        print("缺少環境變量：SEIUE_USERNAME / SEIUE_PASSWORD / TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID", file=sys.stderr)
        sys.exit(1)

    lock_fd = acquire_singleton_lock_or_exit(BASE_DIR)
    tg = Telegram(TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID)
    cli = SeiueClient(SEIUE_USERNAME, SEIUE_PASSWORD)
    if not cli.login():
        print("Seiue 登入失敗。", file=sys.stderr); sys.exit(2)

    ensure_startup_watermark(cli)

    if args.confirm_once:
        it0 = cli.fetch_latest()
        if it0:
            ok = send_one_item(tg, cli, it0)
            # 更新水位與 seen，避免稍後主循環重發
            state = load_state()
            try:
                ts_str = it0.get("published_at") or it0.get("created_at") or ""
                ts = SeiueClient._parse_ts(ts_str) if ts_str else int(time.time())
                nid_int = int(str(it0.get("id") or 0))
            except Exception:
                ts = int(time.time()); nid_int = 0
            state["last_seen_ts"] = max(float(state.get("last_seen_ts") or 0.0), ts)
            state["last_seen_id"] = max(int(state.get("last_seen_id") or 0), nid_int)
            seen = state.get("seen") or {}; seen[str(it0.get("id"))] = {"pushed_at": now_cst_str()}
            state["seen"] = seen; save_state(state)
            logging.info("確認消息已發送（id=%s） ok=%s", it0.get("id"), ok)
        else:
            logging.info("無可用的最新消息可確認發送。")
        sys.exit(0)

    # 正常輪詢
    state = load_state()
    seen: Dict[str, Any] = state.get("seen") or {}
    logging.info(f"開始輪詢（每 {POLL_SECONDS}s）...")

    while True:
        try:
            items = cli.list_my_received_incremental()
            new_items = [it for it in items if str(it.get("id") or "") not in seen]

            for d in sorted(new_items, key=lambda x: str(x.get("id"))):
                nid = str(d.get("id"))
                # 先標記為已處理（至多一次）
                seen[nid] = {"pushed_at": now_cst_str()}
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

  install -m 0644 -o "$REAL_USER" -g "$(id -gn "$REAL_USER")" "$TMP" "${INSTALL_DIR}/${PY_SCRIPT}"
  rm -f "$TMP"
  success "Python 輪詢器（去重強化 + 一次性確認）已生成。"
}

# ----------------- 5) Write .env and runner -----------------
write_env_and_runner() {
  info "寫入 ${ENV_FILE}（600 權限）與啟動腳本..."
  if [ "$COLLECTED" = "1" ]; then
    run_as_user bash -lc "cat > '${INSTALL_DIR}/${ENV_FILE}'" <<EOF
SEIUE_USERNAME=${SEIUE_USERNAME}
SEIUE_PASSWORD=${SEIUE_PASSWORD}
X_SCHOOL_ID=3
X_ROLE=teacher

TELEGRAM_BOT_TOKEN=${TG_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TG_CHAT_ID}

# 主輪詢間隔（秒）
NOTIFY_POLL_SECONDS=${POLL}
# 掃描頁數（最大頁；可視需求調大）
MAX_LIST_PAGES=3
# all | unread
READ_FILTER=all
# include cc messages? true/false
INCLUDE_CC=false
# 每條 Telegram 消息最小間隔（秒），避免 429
TELEGRAM_MIN_INTERVAL_SECS=1.5

# 啟動時跳過歷史（僅從當前水位之後推送）
SKIP_HISTORY_ON_FIRST_RUN=1
EOF
    run_as_user chmod 600 "${INSTALL_DIR}/${ENV_FILE}"
  else
    info "檢測到現有 ${ENV_FILE}，跳過交互式輸入。"
  fi

  run_as_user bash -lc "cat > '${INSTALL_DIR}/${RUNNER}'" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")" || exit 1
if [ -f ./.env ]; then set -a; source ./.env; set +a; else
  echo "未找到 .env" >&2; exit 1; fi
exec ./venv/bin/python ./seiue_notify.py
EOF
  run_as_user chmod +x "${INSTALL_DIR}/${RUNNER}"
  success "環境與啟動腳本就緒。"
}

# ----------------- 6) Install & Start systemd (no prompt) -----------------
install_and_start_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "此系統無 systemd，改用前台/後台工具（tmux/screen/nohup）自啟。"
    # 保險：先殺舊，清鎖，再後台起一份
    pkill -f '/\.seiue-notify/venv/bin/python .*/seiue_notify\.py' 2>/dev/null || true
    pkill -f '/\.seiue-notify/run\.sh' 2>/dev/null || true
    rm -f "${INSTALL_DIR}/.notify.lock" 2>/dev/null || true
    run_as_user bash -lc "cd '${INSTALL_DIR}' && nohup ./run.sh >/dev/null 2>&1 &"
    success "已在無 systemd 環境中後台啟動。"
    return 0
  fi

  local SVC="/etc/systemd/system/seiue-notify.service"
  cat > "$SVC" <<EOF
[Unit]
Description=Seiue Notification to Telegram Sidecar (me/inbox)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${REAL_USER}
Group=$(id -gn "$REAL_USER")
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStartPre=/usr/bin/rm -f ${INSTALL_DIR}/.notify.lock
ExecStart=${INSTALL_DIR}/venv/bin/python ${INSTALL_DIR}/seiue_notify.py
Restart=always
RestartSec=5
StandardOutput=append:${LOG_DIR}/notify.out.log
StandardError=append:${LOG_DIR}/notify.err.log
$(env | grep -i -E '^(http_proxy|https_proxy|no_proxy|HTTP_PROXY|HTTPS_PROXY|NO_PROXY)=' | sed 's/^/Environment=/')

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now seiue-notify.service

  # 确认服务已运行
  if systemctl is-active --quiet seiue-notify; then
    success "systemd 服務已啟動：seiue-notify.service"
  else
    error "systemd 服務未能啟動，輸出狀態如下："
    systemctl status seiue-notify --no-pager || true
    exit 2
  fi
}

# ----------------- 7) One-shot confirmation message -----------------
send_one_shot_confirmation() {
  info "發送最近 1 條消息到 Telegram 作為安裝確認（並設置水位以避免重發）..."
  run_as_user bash -lc "cd '${INSTALL_DIR}' && set -a && source ./.env && set +a && ./venv/bin/python ./seiue_notify.py --confirm-once || true"
  success "確認步驟已執行（若收件箱有最新一條，應已推送）。"
}

# ----------------- main -----------------
main() {
  LOCKDIR="/tmp/seiue_notify_installer.lock"
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    error "安裝器已在另一程序執行。"; exit 1
  fi
  trap 'rmdir "$LOCKDIR"' EXIT

  echo -e "${C_GREEN}--- Seiue 通知 Sidecar 安裝程序 v1.8.0-me-inbox-noninteractive ---${C_RESET}"
  check_environment
  mkdir -p "${INSTALL_DIR}" "${LOG_DIR}"; chown -R "$REAL_USER:$(id -gn "$REAL_USER")" "$INSTALL_DIR"

  if [ -f "${INSTALL_DIR}/${ENV_FILE}" ] && [ "$RECONF" -ne 1 ]; then
    info "檢測到已存在的 ${ENV_FILE}，跳過交互式輸入。"
  else
    collect_inputs
  fi
  setup_layout
  write_python
  write_env_and_runner

  # 不啟用任何 first_run，改為 systemd 自啟 + 一次性確認
  install_and_start_systemd
  send_one_shot_confirmation

  success "全部完成。"
  echo -e "${C_BLUE}服務狀態：${C_RESET}systemctl status seiue-notify --no-pager"
  echo -e "${C_BLUE}日誌查看：${C_RESET}journalctl -u seiue-notify -f"
  echo -e "${C_BLUE}配置目錄：${C_RESET}${INSTALL_DIR}"
}
main