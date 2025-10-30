#!/usr/bin/env bash
# Seiue 全類型系統消息 → Telegram（單文件版，無子命令）
# 目標：推送 “全部類型”（請假/考勤/評價/通知/消息）
# 來源端點：
#   1) 收件箱：/chalk/me/received-messages
#   2) 通知中心（系統消息列表）：/chalk/me/received-messages?notice=true&readed=false&type_not_in=...
# 首次啟動會各類型各推 1 條作為成功確認，之後走增量推送
set -euo pipefail

# ===== 必填（可改這裡或寫到 ~/.seiue-notify/.env）=====
SEIUE_USERNAME="${SEIUE_USERNAME:-YOUR_SEIUE_USERNAME}"
SEIUE_PASSWORD="${SEIUE_PASSWORD:-YOUR_SEIUE_PASSWORD}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-YOUR_TG_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-YOUR_TG_CHAT_ID}"

# ===== 可選 =====
POLL_SECONDS="${POLL_SECONDS:-90}"      # 輪詢間隔秒
MAX_PAGES="${MAX_PAGES:-10}"            # 每輪拉取頁數上限（每頁 20）
X_SCHOOL_ID="${X_SCHOOL_ID:-3}"
X_ROLE="${X_ROLE:-teacher}"
SKIP_HISTORY_ON_FIRST_RUN="${SKIP_HISTORY_ON_FIRST_RUN:-1}" # 1=不回灌歷史
TRACE_HTTP="${TRACE_HTTP:-0}"           # 1=打印請求/回應頭（隱去 Authorization）

# ===== 內部 =====
APP_DIR="${HOME}/.seiue-notify"
VENV="${APP_DIR}/venv"
PY="${VENV}/bin/python"
ENV_FILE="${APP_DIR}/.env"
STATE_FILE="${APP_DIR}/state.json"
LOG_FILE="${APP_DIR}/notify.log"

mkdir -p "${APP_DIR}"

# 如果存在 .env，讀入以覆蓋上面變量
if [ -f "${ENV_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

# 基本校驗
[ "${SEIUE_USERNAME}" != "YOUR_SEIUE_USERNAME" ] || { echo "請填 SEIUE_USERNAME"; exit 2; }
[ "${SEIUE_PASSWORD}" != "YOUR_SEIUE_PASSWORD" ] || { echo "請填 SEIUE_PASSWORD"; exit 2; }
[ "${TELEGRAM_BOT_TOKEN}" != "YOUR_TG_BOT_TOKEN" ] || { echo "請填 TELEGRAM_BOT_TOKEN"; exit 2; }
[ "${TELEGRAM_CHAT_ID}" != "YOUR_TG_CHAT_ID" ] || { echo "請填 TELEGRAM_CHAT_ID"; exit 2; }

# 準備 venv + 依賴
if [ ! -x "${PY}" ]; then
  command -v python3 >/dev/null 2>&1 || { echo "需要 python3"; exit 3; }
  python3 -m venv "${VENV}"
  "${PY}" -m pip install --upgrade pip >/dev/null
  "${VENV}/bin/pip" install --upgrade requests pytz urllib3 >/dev/null
fi

# 寫入/更新 Python 主程序
cat > "${APP_DIR}/app.py" <<'PY'
# -*- coding: utf-8 -*-
import os, sys, time, json, html, re, fcntl
from datetime import datetime
from zlib import crc32
from typing import Dict, Any, List, Optional, Tuple

import requests, pytz
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

APP_DIR = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = os.path.join(APP_DIR, "state.json")
LOG_FILE = os.path.join(APP_DIR, "notify.log")

SEIUE_USERNAME = os.getenv("SEIUE_USERNAME")
SEIUE_PASSWORD = os.getenv("SEIUE_PASSWORD")
TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID")
X_SCHOOL_ID = os.getenv("X_SCHOOL_ID","3")
X_ROLE = os.getenv("X_ROLE","teacher")
POLL_SECONDS = int(float(os.getenv("POLL_SECONDS","90")))
MAX_PAGES = int(os.getenv("MAX_PAGES","10"))
SKIP_HISTORY_ON_FIRST_RUN = os.getenv("SKIP_HISTORY_ON_FIRST_RUN","1") in ("1","true","yes","on")
TRACE_HTTP = os.getenv("TRACE_HTTP","0") in ("1","true","yes","on")

BEIJING = pytz.timezone("Asia/Shanghai")

def log(msg: str):
    ts = datetime.now(BEIJING).strftime("%Y-%m-%d %H:%M:%S")
    line = f"{ts} {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE,"a",encoding="utf-8") as f:
            f.write(line+"\n")
    except Exception:
        pass

def load_state()->Dict[str,Any]:
    if not os.path.exists(STATE_FILE):
        return {"last_seen_ts":0.0, "last_seen_id":0, "confirm_done":False, "seen":{}}
    try:
        with open(STATE_FILE,"r",encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {"last_seen_ts":0.0, "last_seen_id":0, "confirm_done":False, "seen":{}}

def save_state(st:Dict[str,Any]):
    tmp = STATE_FILE+".tmp"
    with open(tmp,"w",encoding="utf-8") as f:
        json.dump(st,f,ensure_ascii=False)
        f.flush(); os.fsync(f.fileno())
    os.replace(tmp, STATE_FILE)

def lock_singleton():
    p = os.path.join(APP_DIR, ".lock")
    fd = os.open(p, os.O_CREAT|os.O_RDWR, 0o644)
    fcntl.flock(fd, fcntl.LOCK_EX|fcntl.LOCK_NB)
    os.ftruncate(fd,0)
    os.write(fd, str(os.getpid()).encode())
    return fd

class TG:
    def __init__(self, token:str, chat_id:str):
        self.base = f"https://api.telegram.org/bot{token}"
        self.chat_id = chat_id
        self.s = requests.Session()
        r = Retry(total=3, backoff_factor=1.2, status_forcelist=(429,500,502,503,504))
        self.s.mount("https://", HTTPAdapter(max_retries=r))
        self.last = 0.0
    def _pace(self):
        d = time.time()-self.last
        if d < 1.2: time.sleep(1.2-d)
    def send(self, text:str)->bool:
        self._pace()
        r = self.s.post(f"{self.base}/sendMessage", data={
            "chat_id": self.chat_id,
            "text": text if len(text)<=4096 else text[:4060]+"…",
            "parse_mode":"HTML",
            "disable_web_page_preview": True
        }, timeout=30)
        self.last = time.time()
        if r.status_code==200: return True
        if r.status_code==429:
            try: ra=int(r.json().get("parameters",{}).get("retry_after",3))
            except: ra=3
            time.sleep(min(ra+1,60)); return self.send(text)
        return False

class Seiue:
    def __init__(self, user:str, pwd:str):
        self.u, self.p = user, pwd
        self.s = requests.Session()
        r = Retry(total=5, backoff_factor=1.6, status_forcelist=(429,500,502,503,504))
        self.s.mount("https://", HTTPAdapter(max_retries=r))
        self.s.headers.update({
            "User-Agent":"Mozilla/5.0",
            "Accept":"application/json, text/plain, */*",
            "Origin":"https://chalk-c3.seiue.com",
            "Referer":"https://chalk-c3.seiue.com/"
        })
        self.bearer = None
        self.rid = None
        self.login_url = "https://passport.seiue.com/login?school_id=3"
        self.auth_url  = "https://passport.seiue.com/authorize"
        self.inbox_url = "https://api.seiue.com/chalk/me/received-messages"
        self.notice_url = self.inbox_url  # same endpoint, different filters
    def login(self)->bool:
        try:
            self.s.post(self.login_url, headers={"Content-Type":"application/x-www-form-urlencoded","Origin":"https://passport.seiue.com"},
                        data={"email": self.u, "password": self.p}, timeout=30)
            j = self.s.post(self.auth_url, headers={"Content-Type":"application/x-www-form-urlencoded","X-Requested-With":"XMLHttpRequest",
                                                    "Origin":"https://chalk-c3.seiue.com"},
                            data={"client_id":"GpxvnjhVKt56qTmnPWH1sA","response_type":"token"}, timeout=30).json()
            tok = j.get("access_token"); rid = str(j.get("active_reflection_id") or "")
            if not tok or not rid: log("Authorize 缺少 token/reflection_id"); return False
            self.bearer, self.rid = tok, rid
            self.s.headers.update({"Authorization": f"Bearer {tok}", "x-school-id": os.getenv("X_SCHOOL_ID","3"),
                                   "x-role": os.getenv("X_ROLE","teacher"), "x-reflection-id": rid})
            log(f"Auth OK, reflection_id={rid}")
            return True
        except Exception as e:
            log(f"Authorize 失敗: {e}"); return False
    def _req(self, fn):
        r = fn()
        if getattr(r,"status_code",None) in (401,403):
            log("401/403：重登"); 
            if self.login(): r = fn()
        return r
    @staticmethod
    def _ts(s:str)->float:
        for fmt in ("%Y-%m-%d %H:%M:%S","%Y-%m-%dT%H:%M:%S%z","%Y-%m-%dT%H:%M:%S"):
            try: return datetime.strptime(s,fmt).timestamp()
            except: pass
        return 0.0
    def _items(self, r:requests.Response)->List[Dict[str,Any]]:
        try:
            d = r.json()
            if isinstance(d,dict):
                for k in ("items","data","results","rows"):
                    if isinstance(d.get(k),list): return d[k]
            if isinstance(d,list): return d
        except Exception as e:
            log(f"JSON 解析錯誤: {e}")
        return []
    def list_inbox_page(self, page:int, per_page:int=20, include_cc_all:bool=True)->List[Dict[str,Any]]:
        params = {
            "expand":"sender_reflection,aggregated_messages",
            "owner.id": self.rid,
            "paginated":"1",
            "sort":"-published_at,-created_at",
            "page": str(page),
            "per_page": str(per_page)
        }
        if TRACE_HTTP:
            safe_headers = {k:("Bearer ***" if k.lower()=="authorization" else v) for k,v in self.s.headers.items()}
            log(f"GET inbox page={page} params={params} headers={safe_headers}")
        r = self._req(lambda: self.s.get(self.inbox_url, params=params, timeout=30))
        if TRACE_HTTP:
            try: log(f"RES {r.status_code} len={len(r.content)} headers={dict(r.headers)}")
            except: pass
        if r.status_code != 200:
            log(f"inbox HTTP {r.status_code}: {r.text[:200]}")
            return []
        items = self._items(r)
        for it in items:
            agg = it.get("aggregated_messages") or []
            if (not it.get("title") or not it.get("content")) and agg:
                for a in agg:
                    if a.get("title") or a.get("content"):
                        it.setdefault("title", a.get("title"))
                        it.setdefault("content", a.get("content"))
                        break
            sid = it.get("id")
            if sid is None and agg:
                sid = next((a.get("id") for a in agg if a.get("id") is not None), None)
            if sid is None:
                basis = f"{it.get('title') or ''}|{it.get('published_at') or it.get('created_at') or ''}"
                sid = crc32(basis.encode("utf-8")) & 0xffffffff
            it["_sid"] = str(sid)
        return items
    def list_notice_page(self, page:int, per_page:int=20)->List[Dict[str,Any]]:
        # 系統消息列表（通知中心）
        params = {
            "expand": "aggregated_messages",
            "notice": "true",
            "owner.id": self.rid,
            "readed": "false",
            "type_not_in": "exam.schedule_result_for_examinee,exam.schedule_result_for_examiner,exam.stats_received,exam.published_for_adminclass_teacher,exam.published_for_examinee,exam.published_scoring_for_examinee,exam.published_for_teacher,exam.published_for_mentor,schcal.holiday_created,schcal.holiday_deleted,schcal.holiday_updated,schcal.makeup_created,schcal.makeup_deleted,schcal.makeup_updated,evaluation.completed_notice_for_subject,reporting.warning_received,report_report.report_publish_published,class_adjustment.stage_approved,class_adjustment.stage_invalid,intl_goal.goal_submitted,intl_goal.goal_changed,class_review.un_completed,election.lotting_result",
            "paginated": "1",
            "sort": "-published_at,-created_at",
            "page": str(page),
            "per_page": str(per_page)
        }
        if TRACE_HTTP:
            safe_headers = {k:("Bearer ***" if k.lower()=="authorization" else v) for k,v in self.s.headers.items()}
            log(f"GET notice page={page} params={params} headers={safe_headers}")
        r = self._req(lambda: self.s.get(self.notice_url, params=params, timeout=30))
        if TRACE_HTTP:
            try: log(f"RES {r.status_code} len={len(r.content)} headers={dict(r.headers)}")
            except: pass
        if r.status_code != 200:
            log(f"notice HTTP {r.status_code}: {r.text[:200]}")
            return []
        items = self._items(r)
        for it in items:
            sid = it.get("id") or it.get("_id")
            if sid is None:
                basis = f"{it.get('title') or ''}|{it.get('published_at') or it.get('created_at') or ''}"
                sid = crc32(str(basis).encode("utf-8")) & 0xffffffff
            it["_sid"] = str(sid)
        return items

def render_draft(content_json:str)->str:
    try:
        raw = json.loads(content_json or "{}")
    except Exception:
        raw = {}
    blocks = raw.get("blocks") or []
    out=[]
    for b in blocks:
        t = b.get("text","") or ""
        if not t.strip(): out.append("​"); continue
        text = html.escape(t, quote=False)
        for r in b.get("inlineStyleRanges") or []:
            style = r.get("style") or ""
            if style=="BOLD":
                text = f"<b>{text}</b>"
            elif "red" in style: text = "❗"+text
            elif "orange" in style: text = "⚠️"+text
        if (b.get("data") or {}).get("align") == "align_right":
            text = "—— "+text
        out.append(text)
    while out and not out[-1].strip(): out.pop()
    return "\n\n".join(out) if out else "​"

def render_content(raw_content: str, rendered_flag: bool) -> str:
    # 系統消息多為純文本（rendered=true）
    if rendered_flag or (raw_content and not raw_content.strip().startswith("{")):
        return html.escape(raw_content or "")
    return render_draft(raw_content or "")

def guess_type(title:str, content:str, domain:str="", typ_str:str="")->str:
    d = (domain or "").lower()
    t = (typ_str or "").lower()
    if "attendance" in d or "attendance" in t: return "attendance"
    if "leave" in d or "absence" in t or "leave" in t: return "leave"
    if "evaluation" in d or "evaluation" in t: return "evaluation"
    if "notice" in d: return "notice"
    z = (title or "") + "\n" + (content or "")
    if re.search(r"请假|請假|销假|銷假|审批|審批|批复|銷假", z): return "leave"
    if re.search(r"考勤|出勤|签到|簽到|打卡|迟到|遲到|早退|缺勤|旷课|曠課|出勤统计|考勤记录|考勤结果通知", z): return "attendance"
    if re.search(r"评价|評價|德育|操行|评语|評語|已发布评价|已發佈評價|測評|问卷|問卷", z): return "evaluation"
    if re.search(r"通知|公告|通告|已发布通知|已發佈通知", z): return "notice"
    return "message"

def header(who:str, typ:str)->str:
    label = {"leave":"请假","attendance":"考勤","evaluation":"评价","notice":"通知","message":"消息"}.get(typ,"消息")
    tail = f" · 來自 {html.escape(who)}" if who else ""
    return f"📩 <b>校內{label}</b>{tail}\n"

def fmt_time(s:str)->str:
    try:
        dt = datetime.strptime(s,"%Y-%m-%d %H:%M:%S").replace(tzinfo=BEIJING)
        return dt.strftime("%Y-%m-%d %H:%M")
    except: return s or ""

def send_item(tg:TG, it:Dict[str,Any])->bool:
    title = it.get("title") or ""
    content = it.get("content") or ""
    body = render_content(content, bool(it.get("rendered")))
    sender = ""
    try:
        sr = it.get("sender_reflection") or {}
        sender = sr.get("name") or sr.get("realname") or ""
    except: pass
    typ = guess_type(title, content, str(it.get("domain") or ""), str(it.get("type") or ""))
    when = it.get("published_at") or it.get("created_at") or ""
    line_time = f"\n\n— 發布於 {fmt_time(when)}" if when else ""
    text = f"{header(sender,typ)}\n<b>{html.escape(title)}</b>\n\n{body}{line_time}"
    return tg.send(text)

def sid_key(it:Dict[str,Any])->Tuple[float,int]:
    ts_s = it.get("published_at") or it.get("created_at") or ""
    ts = Seiue._ts(ts_s) if ts_s else 0.0
    sid = str(it.get("_sid"))
    try: nid = int(sid)
    except: nid = crc32(sid.encode("utf-8")) & 0xffffffff
    return (ts,nid)

def fetch_latest_per_type(cli:Seiue)->Dict[str,Optional[Dict[str,Any]]]:
    want = {"leave":None,"attendance":None,"evaluation":None,"notice":None,"message":None}
    page=1
    while page<=MAX_PAGES:
        items = cli.list_inbox_page(page, per_page=20, include_cc_all=True)
        nitems = cli.list_notice_page(page, per_page=20)
        for src in (items, nitems):
            if not src: 
                continue
            for it in src:
                typ = guess_type(it.get("title") or "", it.get("content") or "", str(it.get("domain") or ""), str(it.get("type") or ""))
                if typ not in want: typ="message"
                cur = want[typ]
                if cur is None or sid_key(it)>sid_key(cur):
                    want[typ]=it
        if all(v is not None for v in want.values()): break
        page+=1
    return want

def main():
    lock_singleton()
    for k in ("SEIUE_USERNAME","SEIUE_PASSWORD","TELEGRAM_BOT_TOKEN","TELEGRAM_CHAT_ID"):
        if not os.getenv(k): print(f"缺少 {k}", file=sys.stderr); sys.exit(2)
    tg = TG(os.getenv("TELEGRAM_BOT_TOKEN"), os.getenv("TELEGRAM_CHAT_ID"))
    cli = Seiue(os.getenv("SEIUE_USERNAME"), os.getenv("SEIUE_PASSWORD"))
    if not cli.login(): sys.exit(3)

    st = load_state()

    # 首啟各類型各推 1 條（確認成功）
    if not st.get("confirm_done", False):
        picked = fetch_latest_per_type(cli)
        max_ts, max_id = st.get("last_seen_ts",0.0), st.get("last_seen_id",0)
        any_pushed=False
        for typ, it in picked.items():
            if not it: continue
            ok = send_item(tg, it)
            t,i = sid_key(it)
            if (t>max_ts) or (t==max_ts and i>max_id):
                max_ts, max_id = t,i
            any_pushed = ok or any_pushed
            log(f"確認推送：{typ} sid={it.get('_sid')} ok={ok}")
        if SKIP_HISTORY_ON_FIRST_RUN:
            if max_ts==0.0: max_ts = time.time()
            st["last_seen_ts"], st["last_seen_id"] = max_ts, max_id
        st["confirm_done"] = True
        save_state(st)

    log(f"開始輪詢（收件箱+通知中心），每 {POLL_SECONDS}s，頁數<= {MAX_PAGES}")
    while True:
        try:
            last_ts = float(st.get("last_seen_ts",0.0)); last_id = int(st.get("last_seen_id",0))
            new_items: List[Dict[str,Any]] = []
            page=1
            while page<=MAX_PAGES:
                items = cli.list_inbox_page(page, per_page=20, include_cc_all=True)
                nitems = cli.list_notice_page(page, per_page=20)
                any_items = False
                for src in (items, nitems):
                    if not src: 
                        continue
                    any_items = True
                    for it in src:
                        t,i = sid_key(it)
                        if last_ts and (t<last_ts or (t==last_ts and i<=last_id)):
                            continue
                        new_items.append(it)
                if not any_items:
                    break
                page+=1
            # 去重、排序（舊→新）
            seen=set(); uniq=[]
            for it in new_items:
                sid=str(it.get("_sid"))
                if sid in seen: continue
                seen.add(sid); uniq.append(it)
            uniq.sort(key=sid_key)
            for it in uniq:
                ok = send_item(tg, it)
                t,i = sid_key(it)
                if (t>last_ts) or (t==last_ts and i>last_id):
                    last_ts, last_id = t,i
                log(f"推送 sid={it.get('_sid')} ok={ok}")
            if uniq:
                st["last_seen_ts"], st["last_seen_id"] = last_ts, last_id
                save_state(st)
            time.sleep(POLL_SECONDS)
        except KeyboardInterrupt:
            log("收到中斷，退出"); break
        except Exception as e:
            log(f"輪詢異常：{e}"); time.sleep(min(POLL_SECONDS,60))

if __name__=="__main__":
    main()
PY

# 以當前環境變量啟動 Python 應用（前台）
export SEIUE_USERNAME SEIUE_PASSWORD TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
export X_SCHOOL_ID X_ROLE POLL_SECONDS MAX_PAGES SKIP_HISTORY_ON_FIRST_RUN TRACE_HTTP
exec "${PY}" "${APP_DIR}/app.py"