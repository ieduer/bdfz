#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Seiue Notification → Telegram sidecar
Dual channels: notice (通知中心) + system (me/received-messages)
- Per-channel idempotent watermarks (last_ts, last_id)
- Intra-channel dedupe by (channel:id)
- Cross-channel dedupe by SHA1(title + text_body) with TTL
- Startup watermark skipping (optional): do not replay history on first run
"""

import os, sys, time, json, html, fcntl, hashlib, logging, argparse
from typing import Dict, Any, List, Tuple, Optional
from datetime import datetime, timedelta

import pytz, requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

# ====== Config / ENV ======
SEIUE_USERNAME = os.getenv("SEIUE_USERNAME", "")
SEIUE_PASSWORD = os.getenv("SEIUE_PASSWORD", "")

X_SCHOOL_ID = os.getenv("X_SCHOOL_ID", "3")
X_ROLE = os.getenv("X_ROLE", "teacher")

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "")

POLL_SECONDS = int(os.getenv("NOTIFY_POLL_SECONDS", os.getenv("POLL_SECONDS", "90")))
MAX_LIST_PAGES = max(1, min(int(os.getenv("MAX_LIST_PAGES", "10") or "10"), 20))
READ_FILTER = os.getenv("READ_FILTER", "all").strip().lower()   # all | unread (system channel)
ENABLE_CHANNELS = [s.strip() for s in os.getenv("ENABLE_CHANNELS", "notice,system").split(",") if s.strip()]
SKIP_HISTORY_ON_FIRST_RUN = os.getenv("SKIP_HISTORY_ON_FIRST_RUN", "1").strip().lower() in ("1","true","yes","on")

SEEN_TTL_DAYS = int(os.getenv("SEEN_TTL_DAYS", "30"))

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
SINGLETON_LOCK_FILE = ".notify.lock"

BEIJING_TZ = pytz.timezone("Asia/Shanghai")


# ====== Logging ======
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s.%(msecs)03d - %(levelname)s - %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.FileHandler(LOG_FILE, encoding="utf-8", mode="a"),
        logging.StreamHandler(sys.stdout),
    ],
)

def now_cst_str() -> str:
    return datetime.now(BEIJING_TZ).strftime("%Y-%m-%d %H:%M:%S")

def escape_html(s: str) -> str:
    return html.escape(s, quote=False)


# ====== State & Idempotency ======
DEFAULT_STATE = {
    "version": 2,
    "channels": {
        "notice": {"last_ts": None, "last_id": 0},
        "system": {"last_ts": None, "last_id": 0}
    },
    "seen_ids": { "notice": {}, "system": {} },   # {"id": ts_str}
    "seen_hashes": {},                             # {"sha1": "2025-10-30 09:00:00"}
}

def load_state() -> Dict[str, Any]:
    if not os.path.exists(STATE_FILE):
        return json.loads(json.dumps(DEFAULT_STATE))
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            st = json.load(f)
        # migrate fields
        if "channels" not in st:
            st["channels"] = {"notice": {"last_ts": None, "last_id": 0}, "system": {"last_ts": None, "last_id": 0}}
        st.setdefault("seen_ids", {"notice": {}, "system": {}})
        st.setdefault("seen_hashes", {})
        st.setdefault("version", 2)
        return st
    except Exception:
        return json.loads(json.dumps(DEFAULT_STATE))

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

def sha1_of(title: str, text: str) -> str:
    h = hashlib.sha1()
    h.update((title or "").encode("utf-8"))
    h.update(b"\x00")
    h.update((text or "").encode("utf-8"))
    return h.hexdigest()

def gc_seen_hashes(state: Dict[str, Any], ttl_days: int = SEEN_TTL_DAYS) -> None:
    if ttl_days <= 0: return
    cutoff = datetime.now(BEIJING_TZ) - timedelta(days=ttl_days)
    keep: Dict[str, str] = {}
    for k, ts_str in state.get("seen_hashes", {}).items():
        try:
            dt = datetime.strptime(ts_str, "%Y-%m-%d %H:%M:%S").replace(tzinfo=BEIJING_TZ)
            if dt >= cutoff:
                keep[k] = ts_str
        except Exception:
            # bad timestamp -> drop
            pass
    state["seen_hashes"] = keep


# ====== Singleton lock ======
def acquire_singleton_lock_or_exit(base_dir: str):
    lock_path = os.path.join(base_dir, SINGLETON_LOCK_FILE)
    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.ftruncate(fd, 0)
        os.write(fd, str(os.getpid()).encode())
        return fd  # keep fd open
    except OSError:
        logging.error("另一個實例正在運行，為避免重複，本實例退出。")
        sys.exit(0)


# ====== Telegram ======
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

    def _post(self, endpoint: str, data: dict, files: Optional[dict] = None, label: str = "sendMessage", timeout: int = 60) -> bool:
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
        return self._post("sendMessage", {
            "chat_id": self.chat_id, "text": html_text, "parse_mode": "HTML", "disable_web_page_preview": True
        }, None, "sendMessage", timeout=30)

    def send_photo_bytes(self, data: bytes, caption_html: str = "") -> bool:
        if caption_html and len(caption_html) > TG_CAPTION_LIMIT:
            caption_html = caption_html[:TG_CAPTION_SAFE] + "…"
        files = {"photo": ("image.jpg", data)}
        return self._post("sendPhoto", {
            "chat_id": self.chat_id, "caption": caption_html, "parse_mode": "HTML",
        }, files, "sendPhoto", timeout=90)

    def send_document_bytes(self, data: bytes, filename: str, caption_html: str = "") -> bool:
        if caption_html and len(caption_html) > TG_CAPTION_LIMIT:
            caption_html = caption_html[:TG_CAPTION_SAFE] + "…"
        files = {"document": (filename, data)}
        return self._post("sendDocument", {
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


# ====== Seiue Client ======
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

        # endpoints
        self.inbox_url = "https://api.seiue.com/chalk/me/received-messages"             # system
        self.notice_url = "https://api.seiue.com/chalk/notification/notifications"      # notice

    def _preflight(self):
        try: self.s.get(self.login_url, timeout=15)
        except requests.RequestException: pass

    def login(self) -> bool:
        self._preflight()
        try:
            self.s.post(self.login_url,
                headers={"Content-Type":"application/x-www-form-urlencoded","Origin":"https://passport.seiue.com","Referer":self.login_url},
                data={"email": self.username, "password": self.password},
                timeout=30, allow_redirects=True)
            a = self.s.post(self.authorize_url,
                headers={"Content-Type":"application/x-www-form-urlencoded","X-Requested-With":"XMLHttpRequest","Origin":"https://chalk-c3.seiue.com","Referer":"https://chalk-c3.seiue.com/"},
                data={'client_id':'GpxvnjhVKt56qTmnPWH1sA','response_type':'token'},
                timeout=30)
            a.raise_for_status()
            data = a.json()
        except Exception as e:
            logging.error(f"Authorize/login failed: {e}")
            return False
        token = data.get("access_token"); ref = data.get("active_reflection_id")
        if not token or not ref:
            logging.error("Authorize missing token or reflection id.")
            return False
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
        try:
            # numeric seconds
            return float(s)
        except Exception:
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

    # ---------- SYSTEM channel (me inbox) ----------
    def list_system_incremental(self) -> List[Dict[str, Any]]:
        results: List[Dict[str, Any]] = []
        params_base = {
            "expand": "sender_reflection",
            "owner.id": self.reflection_id,
            "paginated": "1",
            "sort": "-published_at,-created_at",
        }
        if READ_FILTER == "unread":
            params_base["readed"] = "false"

        for page in range(1, MAX_LIST_PAGES + 1):
            params = dict(params_base, **{"page": str(page), "per_page": "20"})
            r = self._retry_after_auth(lambda: self.s.get(self.inbox_url, params=params, timeout=30))
            if r.status_code == 404:
                logging.error("system(me/inbox) 404"); break
            if r.status_code != 200:
                logging.error(f"system HTTP {r.status_code}: {r.text[:300]}"); break
            items = self._json_items(r)
            if not items: break
            results.extend(items)
        logging.info(f"SYSTEM fetched={len(results)}")
        return results

    # ---------- NOTICE channel (通知中心) ----------
    def list_notice_incremental(self) -> List[Dict[str, Any]]:
        """
        以 acting_as_receiver=true 拉取自己相关的通知。
        结构可能随版本变化，尽量容错；若 404/403/500，不影响系统通道。
        """
        results: List[Dict[str, Any]] = []
        params_base = {
            "acting_as_receiver": "true",
            "paginated": "1",
            "sort": "-published_at,-created_at",
            # 常见 expand：sender/attachments/whatever；仅加最小必要
        }
        for page in range(1, MAX_LIST_PAGES + 1):
            params = dict(params_base, **{"page": str(page), "per_page": "20"})
            r = self._retry_after_auth(lambda: self.s.get(self.notice_url, params=params, timeout=30))
            if r.status_code == 404:
                logging.warning("notice endpoint 404（平台未开放/权限限制？）"); break
            if r.status_code != 200:
                logging.warning(f"notice HTTP {r.status_code}: {r.text[:200]}"); break
            items = self._json_items(r)
            if not items: break
            results.extend(items)
        logging.info(f"NOTICE fetched={len(results)}")
        return results


# ====== Content rendering & attachments ======
def render_draftjs_content(content_json: str):
    # 兼容 Draft.js 的富文本（system 常见）；提取文本与附件
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
    # 提供纯文本用于跨通道去重
    plain_text = "\n\n".join([(html.unescape(b) if b else "") for b in [blk.get("text","") for blk in blocks]])
    return html_text, attachments, plain_text

def normalize_system_item(it: Dict[str, Any]) -> Tuple[str, float, str, str, List[Dict[str,Any]], str, Dict[str,Any]]:
    nid = str(it.get("id"))
    ts_str = it.get("published_at") or it.get("created_at") or ""
    ts = SeiueClient._parse_ts(ts_str) if ts_str else 0.0
    title = it.get("title") or ""
    content_str = it.get("content") or ""
    html_body, atts, plain = render_draftjs_content(content_str)
    sender_reflection = it.get("sender_reflection") or {}
    return nid, ts, title, html_body, atts, plain, sender_reflection

def normalize_notice_item(it: Dict[str, Any]) -> Tuple[str, float, str, str, List[Dict[str,Any]], str, Dict[str,Any]]:
    """
    尽量通用化：不同版本字段命名可能不同；
    优先取 published_at / created_at；正文尝试 content / body / message；
    附件规范化为同样的字典结构。
    """
    nid = str(it.get("id"))
    ts_str = it.get("published_at") or it.get("created_at") or ""
    ts = SeiueClient._parse_ts(ts_str) if ts_str else 0.0
    title = it.get("title") or it.get("subject") or ""
    content_str = it.get("content") or it.get("body") or it.get("message") or ""

    # notice 很多不是 draft.js；做个温和的处理：当作纯文本包一层
    try:
        # 若是 draft.js 字串就直接走 draft 渲染
        json.loads(content_str)
        html_body, atts, plain = render_draftjs_content(content_str)
    except Exception:
        html_body = escape_html(content_str or "")
        atts = []
        plain = content_str or ""

    # 尝试吸出附件（如果后端直接给 url 列表）
    for key in ("attachments","files","images"):
        val = it.get(key)
        if isinstance(val, list):
            for v in val:
                if isinstance(v, dict) and v.get("url"):
                    typ = "image" if ("image" in (v.get("type","").lower())) else "file"
                    name = v.get("name") or ( "image.jpg" if typ=="image" else "attachment.bin" )
                    atts.append({"type":typ,"name":name,"size":v.get("size") or "","url":v.get("url")})

    sender_reflection = it.get("sender") or {}
    return nid, ts, title, html_body, atts, plain, sender_reflection


# ====== Download with auth ======
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


# ====== Common UI ======
def build_header(tag: str, sender_reflection: Dict[str,Any]) -> str:
    name = ""
    try:
        name = sender_reflection.get("name") or sender_reflection.get("realname") or ""
    except Exception:
        pass
    title = "通知中心" if tag == "notice" else "校內訊息"
    tail = f" · 來自 {escape_html(name)}" if name else ""
    return f"📩 <b>{title}</b>{tail}\n"

def format_time(ts: float) -> str:
    if not ts: return ""
    dt = datetime.fromtimestamp(ts, tz=BEIJING_TZ)
    return dt.strftime("%Y-%m-%d %H:%M")

def send_one_item(tg:"Telegram", cli:"SeiueClient", tag:str, title:str, html_body:str, created_ts:float, atts: List[Dict[str,Any]]) -> bool:
    time_line = f"— 發布於 {format_time(created_ts)}" if created_ts else ""
    main_msg = f"<b>{escape_html(title)}</b>\n\n{html_body}"
    if time_line: main_msg += f"\n\n{time_line}"
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


# ====== Watermark helpers ======
def ensure_startup_watermark(cli: SeiueClient, state: Dict[str,Any], channel: str):
    """
    首次启动且开启 SKIP_HISTORY_ON_FIRST_RUN 时，为通道设置水位为“当前最新一条”的时间/ID；
    拉不到就用当前时间。
    """
    chst = state["channels"].setdefault(channel, {"last_ts": None, "last_id": 0})
    if chst.get("last_ts"):  # 已有水位
        return
    if not SKIP_HISTORY_ON_FIRST_RUN:
        return

    newest_ts, newest_id = 0.0, 0

    try:
        if channel == "system":
            items = cli.list_system_incremental()[:1]
            if items:
                nid, ts, title, html_body, atts, plain, sender = normalize_system_item(items[0])
                newest_ts, newest_id = ts, int(nid) if nid.isdigit() else 0
        elif channel == "notice":
            items = cli.list_notice_incremental()[:1]
            if items:
                nid, ts, title, html_body, atts, plain, sender = normalize_notice_item(items[0])
                newest_ts, newest_id = ts, int(nid) if str(nid).isdigit() else 0
    except Exception as e:
        logging.warning(f"{channel} 啟動水位讀取失敗：{e}")

    if not newest_ts:
        newest_ts = time.time()
    chst["last_ts"] = newest_ts
    chst["last_id"] = newest_id
    save_state(state)
    logging.info(f"{channel.upper()} 啟動已設置水位 last_ts={newest_ts} last_id={newest_id}")


# ====== Main loop ======
def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--once", action="store_true", help="僅掃描一次（調試用）")
    args, _ = parser.parse_known_args()

    if not (SEIUE_USERNAME and SEIUE_PASSWORD and TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID):
        print("缺少環境變量：SEIUE_USERNAME / SEIUE_PASSWORD / TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID", file=sys.stderr)
        sys.exit(1)

    lock_fd = acquire_singleton_lock_or_exit(BASE_DIR)
    tg = Telegram(TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID)
    cli = SeiueClient(SEIUE_USERNAME, SEIUE_PASSWORD)
    if not cli.login():
        print("Seiue 登入失敗。", file=sys.stderr); sys.exit(2)

    state = load_state()
    for ch in ENABLE_CHANNELS:
        ensure_startup_watermark(cli, state, ch)

    def process_channel(channel: str) -> None:
        st = load_state()  # 最新
        chst = st["channels"].setdefault(channel, {"last_ts": None, "last_id": 0})
        last_ts = float(chst.get("last_ts") or 0.0)
        last_id = int(chst.get("last_id") or 0)

        if channel == "system":
            raw_items = cli.list_system_incremental()
            norm = normalize_system_item
        elif channel == "notice":
            raw_items = cli.list_notice_incremental()
            norm = normalize_notice_item
        else:
            return

        new_items: List[Tuple[str,float,str,str,List[Dict[str,Any]],str,Dict[str,Any]]] = []
        newest_ts, newest_id = last_ts, last_id

        for it in raw_items:
            nid, ts, title, html_body, atts, plain, sender = norm(it)
            # 增量窗口
            if last_ts and (ts < last_ts or (ts == last_ts and (str(nid).isdigit() and int(nid) <= last_id))):
                continue
            new_items.append((nid, ts, title, html_body, atts, plain, sender))
            # 提升水位候选
            try:
                nid_int = int(str(nid))
            except Exception:
                nid_int = 0
            if (ts > newest_ts) or (ts == newest_ts and nid_int > newest_id):
                newest_ts, newest_id = ts, nid_int

        # 时间从旧到新发送（避免反向刷屏）
        new_items.sort(key=lambda x: (x[1], int(str(x[0])) if str(x[0]).isdigit() else 0))

        # 去重结构
        seen_ids = st["seen_ids"].setdefault(channel, {})
        seen_hashes = st.setdefault("seen_hashes", {})

        for nid, ts, title, html_body, atts, plain, sender in new_items:
            id_key = str(nid)
            if id_key in seen_ids:
                # 通道内已发过
                continue

            body_prefix = build_header(channel, sender)
            digest = sha1_of(title, plain or html_body)
            # 跨通道去重（见过的内容摘要就跳过）
            if digest in seen_hashes:
                # 仍然要更新通道水位与通道ID去重，避免下轮再碰到
                seen_ids[id_key] = now_cst_str()
                continue

            ok = tg.send_message_safely(body_prefix + f"\n<b>{escape_html(title)}</b>\n\n{html_body}") if title or html_body else tg.send_message(body_prefix + "(無內容)")
            if ok:
                # 附件
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

            # 标记去重
            seen_ids[id_key] = now_cst_str()
            seen_hashes[digest] = now_cst_str()
            # 及时写盘，防止崩溃重复
            st["seen_ids"][channel] = seen_ids
            st["seen_hashes"] = seen_hashes
            save_state(st)

        # 提升水位（仅当确实前进）
        if newest_ts and ((newest_ts > last_ts) or (newest_ts == last_ts and newest_id > last_id)):
            chst["last_ts"] = newest_ts
            chst["last_id"] = newest_id
            st["channels"][channel] = chst
            gc_seen_hashes(st)  # 偶尔做一下清理
            save_state(st)
            logging.info(f"{channel.upper()} 水位已提升 -> ts={newest_ts} id={newest_id}")

    # ====== loop ======
    logging.info(f"開始輪詢（通道：{','.join(ENABLE_CHANNELS)}），每 {POLL_SECONDS}s，頁數<= {MAX_LIST_PAGES}")
    while True:
        for ch in ENABLE_CHANNELS:
            try:
                process_channel(ch)
            except Exception as e:
                logging.exception(f"channel {ch} error: {e}")
        if args.once:
            break
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()