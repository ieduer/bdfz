#!/usr/bin/env bash
# Seiue Notification → Telegram - One-click Installer (Sidecar) v1.3.0-inbox-twohop
# Target: Linux VPS (Ubuntu/Debian/CentOS 等)，macOS 亦可
# 行為：安裝到 ~/.seiue-notify ，建立 venv、生成 Python 通知輪詢器（收件箱兩段式：read-statuses → received-notifications）、推送到 Telegram

set -euo pipefail

# ---- pretty output ----
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'
info()    { echo -e "${C_BLUE}INFO:${C_RESET} $1"; }
success() { echo -e "${C_GREEN}SUCCESS:${C_RESET} $1"; }
warn()    { echo -e "${C_YELLOW}WARNING:${C_RESET} $1"; }
error()   { echo -e "${C_RED}ERROR:${C_RESET} $1" >&2; }

# ---- root escalate（僅用於安裝依賴；程式本身以一般使用者身份跑）----
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
  if [ -z "$SEIUE_USERNAME" ]; then error "用戶名不能為空"; exit 1; fi

  read -s -p "Seiue 密碼: " SEIUE_PASSWORD; echo
  if [ -z "$SEIUE_PASSWORD" ]; then error "密碼不能為空"; exit 1; fi

  read -p "Telegram Bot Token（如：123456:ABC...）: " TG_BOT_TOKEN
  if [ -z "$TG_BOT_TOKEN" ]; then error "Bot Token 不能為空"; exit 1; fi

  read -p "Telegram Chat ID（群/頻道/個人）: " TG_CHAT_ID
  if [ -z "$TG_CHAT_ID" ]; then error "Chat ID 不能為空"; exit 1; fi

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

# ----------------- 4) Write Python notifier (Inbox two-hop) -----------------
write_python() {
  info "生成 Python 通知輪詢器（inbox-twohop）..."
  local TMP="$(mktemp)"
  cat > "$TMP" <<'EOF_PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Seiue Notification → Telegram sidecar (Inbox two-hop)
- 正確的收件箱拉取流程（避免 403）：
  1) 用 /chalk/notification/notification-read-statuses?receiver.reflection_id=<me>
     分頁拉取「發給我」的通知 ID 列表（並可帶 expand=notification）。
  2) 用 /chalk/notification/received-notifications?id_in=...&expand=read_statuses,receiver
     批量換取詳細內容（含 DraftJS content）。
- 用 created_at 水位線控制增量；401/403 自動重登（帶 Origin/Referer）。
- Telegram: HTML 文字 + 圖片 sendPhoto + 檔案 sendDocument。
"""
import json, logging, os, sys, time, html
from typing import Dict, Any, List, Tuple
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

def now_cst_str() -> str:
    return datetime.now(BEIJING_TZ).strftime("%Y-%m-%d %H:%M:%S")

def escape_html(s: str) -> str:
    return html.escape(s, quote=False)

def load_state() -> Dict[str, Any]:
    if not os.path.exists(STATE_FILE):
        return {"seen": {}, "last_seen_created_at": None}
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {"seen": {}, "last_seen_created_at": None}

def save_state(state: Dict[str, Any]) -> None:
    try:
        with open(STATE_FILE, "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False, indent=2)
    except Exception as e:
        logging.warning(f"Failed to save state: {e}")

# -------- Telegram --------
class Telegram:
    def __init__(self, token: str, chat_id: str):
        self.base = f"https://api.telegram.org/bot{token}"
        self.chat_id = chat_id
        self.s = requests.Session()
        retries = Retry(total=4, backoff_factor=1.5, status_forcelist=(429,500,502,503,504))
        self.s.mount("https://", HTTPAdapter(max_retries=retries))

    def send_message(self, html_text: str) -> bool:
        try:
            r = self.s.post(f"{self.base}/sendMessage", data={
                "chat_id": self.chat_id, "text": html_text, "parse_mode": "HTML", "disable_web_page_preview": True
            }, timeout=30)
            if r.status_code == 200: return True
            logging.warning(f"sendMessage failed {r.status_code}: {r.text[:300]}")
        except requests.RequestException as e:
            logging.warning(f"sendMessage network error: {e}")
        return False

    def send_photo_bytes(self, data: bytes, caption_html: str = "") -> bool:
        files = {"photo": ("image.jpg", data)}
        try:
            r = self.s.post(f"{self.base}/sendPhoto", data={
                "chat_id": self.chat_id, "caption": caption_html, "parse_mode": "HTML",
            }, files=files, timeout=60)
            if r.status_code == 200: return True
            logging.warning(f"sendPhoto failed {r.status_code}: {r.text[:300]}")
        except requests.RequestException as e:
            logging.warning(f"sendPhoto network error: {e}")
        return False

    def send_document_bytes(self, data: bytes, filename: str, caption_html: str = "") -> bool:
        files = {"document": (filename, data)}
        try:
            r = self.s.post(f"{self.base}/sendDocument", data={
                "chat_id": self.chat_id, "caption": caption_html, "parse_mode": "HTML",
            }, files=files, timeout=120)
            if r.status_code == 200: return True
            logging.warning(f"sendDocument failed {r.status_code}: {r.text[:300]}")
        except requests.RequestException as e:
            logging.warning(f"sendDocument network error: {e}")
        return False

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
        self.read_status_url = "https://api.seiue.com/chalk/notification/notification-read-statuses"
        self.received_url    = "https://api.seiue.com/chalk/notification/received-notifications"

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

    def _parse_ts(self, s: str) -> float:
        for fmt in ("%Y-%m-%d %H:%M:%S","%Y-%m-%dT%H:%M:%S%z","%Y-%m-%dT%H:%M:%S"):
            try: return datetime.strptime(s, fmt).timestamp()
            except Exception: pass
        return 0.0

    def list_my_received_ids(self, page: int) -> List[str]:
        """從 read-statuses 拉取與我相關的通知 ID（發給我）"""
        params = {
            "paginated": "1",
            "order": "-created_at",
            "page": str(page),
            "receiver.reflection_id": self.reflection_id,
            "expand": "notification",
        }
        r = self._retry_after_auth(lambda: self.s.get(self.read_status_url, params=params, timeout=30))
        if r.status_code != 200:
            logging.error(f"read-statuses HTTP {r.status_code}: {r.text[:300]}")
            return []
        try:
            data = r.json()
            items = data["items"] if isinstance(data, dict) and "items" in data else (data if isinstance(data, list) else [])
        except Exception as e:
            logging.error(f"read-statuses JSON parse error: {e}")
            return []
        ids: List[str] = []
        for it in items:
            nid = it.get("notification_id") or (it.get("notification", {}) or {}).get("id")
            if nid: ids.append(str(nid))
        return ids

    def list_notifications_incremental(self) -> List[Dict[str, Any]]:
        """
        兩段式收件箱：
          - 先從 read-statuses 取 ID（限定我）。
          - 再用 received-notifications 批量取詳情。
        用 created_at 水位線截斷，減少重複推送。
        """
        state = load_state()
        last_seen = state.get("last_seen_created_at")
        last_ts = self._parse_ts(last_seen) if last_seen else 0.0
        newest = last_seen or ""
        results: List[Dict[str, Any]] = []

        # 1) 聚合最近幾頁 ID
        all_ids: List[str] = []
        page = 1
        while page <= MAX_LIST_PAGES:
            ids = self.list_my_received_ids(page)
            if not ids: break
            all_ids.extend(ids)
            page += 1
        if not all_ids:
            logging.info("list: no ids, pages_scanned=%d", page-1)
            return []

        # 去重保持順序（最新在前）
        seen_set, uniq_ids = set(), []
        for i in all_ids:
            if i not in seen_set:
                seen_set.add(i); uniq_ids.append(i)

        # 2) 分批換詳情
        from math import ceil
        batch = 40
        for b in range(ceil(len(uniq_ids)/batch)):
            chunk = uniq_ids[b*batch:(b+1)*batch]
            params = {
                "id_in": ",".join(chunk),
                "expand": "read_statuses,receiver"
            }
            r = self._retry_after_auth(lambda: self.s.get(self.received_url, params=params, timeout=30))
            if r.status_code != 200:
                logging.error(f"received-notifications HTTP {r.status_code}: {r.text[:300]}")
                continue
            try:
                data = r.json()
                items = data["items"] if isinstance(data, dict) and "items" in data else (data if isinstance(data, list) else [])
            except Exception as e:
                logging.error(f"received-notifications JSON parse error: {e}")
                items = []

            for it in items:
                created = it.get("created_at") or it.get("updated_at") or ""
                cts = self._parse_ts(created) if created else 0.0
                if last_ts and cts <= last_ts:
                    continue
                if created and (self._parse_ts(created) > self._parse_ts(newest or "1970-01-01 00:00:00")):
                    newest = created
                results.append(it)

        if newest:
            state["last_seen_created_at"] = newest
            save_state(state)

        logging.info("list: aggregated=%d pages_scanned=%d", len(results), min(page-1, MAX_LIST_PAGES))
        return results

# -------- DraftJS renderer --------
def render_draftjs_content(content_json: str):
    """解析 Draft.js，返回 (html_text, attachments[{type:'image'|'file',name,size,url}])"""
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
            key = er.get("key"); 
            if key is None: continue
            ent = entities.get(int(key)); 
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

def build_header(scope_names):
    scope = "、".join((scope_names or [])[:2]) if scope_names else "通知"
    return f"🔔 <b>校內通知</b> · {escape_html(scope)}\n"

def summarize_stats(read_statuses):
    total = len(read_statuses or [])
    readed = sum(1 for r in (read_statuses or []) if r.get("readed") is True)
    return f"— 已讀 {readed}/{total}"

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

# -------- Main --------
def main():
    if not (SEIUE_USERNAME and SEIUE_PASSWORD and TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID):
        print("缺少環境變量：SEIUE_USERNAME / SEIUE_PASSWORD / TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID", file=sys.stderr)
        sys.exit(1)

    tg = Telegram(TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID)
    cli = SeiueClient(SEIUE_USERNAME, SEIUE_PASSWORD)
    if not cli.login():
        print("Seiue 登入失敗。", file=sys.stderr); sys.exit(2)

    state = load_state()
    seen: Dict[str, Any] = state.get("seen") or {}
    logging.info(f"開始輪詢（每 {POLL_SECONDS}s）...")

    while True:
        try:
            items = cli.list_notifications_incremental()
            # 新訊息（按 id 去重）
            new_items = [it for it in items if str(it.get("id") or "") not in seen]

            for d in sorted(new_items, key=lambda x: str(x.get("id"))):
                nid = str(d.get("id"))
                content_str = d.get("content") or ""
                html_body, atts = render_draftjs_content(content_str)

                # 取 scope_names（從 read_statuses 中首個元素）
                scope_names = []
                try:
                    rs = d.get("read_statuses") or []
                    if rs and isinstance(rs, list):
                        scope_names = rs[0].get("scope_names") or []
                except Exception:
                    pass

                header = build_header(scope_names)
                footer = summarize_stats(d.get("read_statuses") or [])
                created = d.get("created_at") or d.get("updated_at") or ""
                created_fmt = format_time(created)
                time_line = f"— 發布於 {created_fmt}" if created_fmt else ""

                main_msg = f"{header}\n{html_body}\n\n{time_line}  ·  {footer}"
                tg.send_message(main_msg)

                # 附件：圖片先、文件後
                images = [a for a in atts if a.get("type") == "image" and a.get("url")]
                files  = [a for a in atts if a.get("type") == "file" and a.get("url")]

                for a in images:
                    data, _ = download_with_auth(cli, a["url"])
                    if data: tg.send_photo_bytes(data, caption_html="")

                for a in files:
                    data, fname = download_with_auth(cli, a["url"])
                    if data:
                        cap = f"📎 <b>{escape_html(a.get('name') or fname)}</b>"
                        size = a.get("size")
                        if size: cap += f"（{escape_html(size)}）"
                        tg.send_document_bytes(data, filename=(a.get("name") or fname), caption_html=cap)

                # 記錄已推送
                seen[nid] = {"pushed_at": now_cst_str()}
                state["seen"] = seen
                save_state(state)

            time.sleep(POLL_SECONDS)
        except KeyboardInterrupt:
            logging.info("收到中斷，退出。"); break
        except Exception as e:
            logging.exception(f"主循環異常：{e}")
            time.sleep(min(POLL_SECONDS, 60))

if __name__ == "__main__":
    main()
EOF_PY

  # 寫入並設置權限
  install -m 0644 -o "$REAL_USER" -g "$(id -gn "$REAL_USER")" "$TMP" "${INSTALL_DIR}/${PY_SCRIPT}"
  rm -f "$TMP"
  success "Python 輪詢器（inbox-twohop）已生成。"
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

NOTIFY_POLL_SECONDS=${POLL}
# 少量翻頁（通常 3 頁足夠）
MAX_LIST_PAGES=3
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

# ----------------- 6) Optional: systemd service -----------------
maybe_install_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "此系統無 systemd，略過服務安裝。你可用 ${INSTALL_DIR}/run.sh 前台/後台工具（如 tmux/screen）。"
    return 0
  fi

  read -p "要安裝為 systemd 常駐服務嗎？[y/N]: " choice
  if [[ ! "$choice" =~ ^[Yy]$ ]]; then
    info "略過 systemd 安裝。"
    return 0
  fi

  local SVC="/etc/systemd/system/seiue-notify.service"
  cat > "$SVC" <<EOF
[Unit]
Description=Seiue Notification to Telegram Sidecar (Inbox two-hop)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${REAL_USER}
Group=$(id -gn "$REAL_USER")
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
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
  success "systemd 已啟用：seiue-notify.service"
  info "查看日誌：journalctl -u seiue-notify -f"
}

# ----------------- 7) First run -----------------
first_run() {
  info "首次啟動測試..."
  run_as_user bash -lc "cd '${INSTALL_DIR}' && ./run.sh &>/dev/null & sleep 2 || true"
  success "已啟動（若需前台觀察，直接執行 ${INSTALL_DIR}/run.sh）。"
}

# ----------------- main -----------------
main() {
  LOCKDIR="/tmp/seiue_notify_installer.lock"
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    error "安裝器已在另一程序執行。"; exit 1
  fi
  trap 'rmdir "$LOCKDIR"' EXIT

  echo -e "${C_GREEN}--- Seiue 通知 Sidecar 安裝程序 v1.3.0-inbox-twohop ---${C_RESET}"
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
  first_run
  maybe_install_systemd

  success "全部完成。安裝路徑：${INSTALL_DIR}"
  echo -e "${C_BLUE}手動啟動：${C_RESET}${INSTALL_DIR}/run.sh"
  echo -e "${C_BLUE}重啟服務：${C_RESET}systemctl restart seiue-notify"
}
main