cat >/root/seiue-notify.sh <<'SH'
#!/usr/bin/env bash
# Seiue Notification → Telegram - Zero-Arg Installer/Runner
# v2.4.4-fix + notice 分派增強版 + 2025-11-05 請假/考勤補全版
# 變更重點（本版）：
# - 保留你現有的三斬策略＋systemd 覆寫
# - Python 內部補上：
#   1) 考勤通知自動抓學生頭像 (attributes.photo) → Tele
#   2) 請假抄送根據 flow_id + school_plugin_id 拉兩個 API，跟 web 顯示一致
#   3) flow 裡的 absence_attachments 也會自動下載後丟到 Tele
# - 仍然走 unread、防歷史、去重
#
# 用法：直接執行本檔案即可安裝/覆寫當前版本
# --------------------------------------------------

set -euo pipefail
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'
info(){ echo -e "${C_BLUE}INFO:${C_RESET} $1"; }
success(){ echo -e "${C_GREEN}SUCCESS:${C_RESET} $1"; }
warn(){ echo -e "${C_YELLOW}WARNING:${C_RESET} $1"; }
error(){ echo -e "${C_RED}ERROR:${C_RESET} $1" >&2; }

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "需要 root 權限。使用 sudo 重新執行…"
  exec sudo -E bash "$0" "$@"
fi

INSTALL_DIR="/root/.seiue-notify"
VENV_DIR="${INSTALL_DIR}/venv"
PY_SCRIPT="${INSTALL_DIR}/seiue_notify.py"
ENV_FILE="${INSTALL_DIR}/.env"
LOG_DIR="${INSTALL_DIR}/logs"
OUT_LOG="${LOG_DIR}/notify.out.log"
ERR_LOG="${LOG_DIR}/notify.err.log"
UNIT_FILE="/etc/systemd/system/seiue-notify.service"

need_cmd(){ command -v "$1" >/dev/null 2>&1; }
ensure_dirs(){ mkdir -p "$INSTALL_DIR" "$LOG_DIR"; }

preflight(){
  info "環境預檢…"
  if ! need_cmd python3; then
    warn "未發現 python3，嘗試安裝…"
    if command -v apt-get >/dev/null; then apt-get update -y && apt-get install -y python3 python3-venv python3-pip || true; fi
    if command -v yum >/dev/null;     then yum install -y python3 python3-pip || true; fi
  fi
  need_cmd python3 || { error "仍未找到 python3"; exit 1; }
  success "預檢通過。"
}

cleanup_legacy(){
  info "清理歷史殘留進程/鎖/腳本（三斬）…"
  systemctl stop seiue-notify 2>/dev/null || true
  pkill -TERM -f 'python.*seiue_notify.py' 2>/dev/null || true
  sleep 0.2
  pkill -KILL -f 'python.*seiue_notify.py' 2>/dev/null || true
  pkill -f 'run.sh' 2>/dev/null || true
  [ -f "${INSTALL_DIR}/run.sh" ] && mv -f "${INSTALL_DIR}/run.sh" "${INSTALL_DIR}/run.sh.disabled.$(date +%s)" || true
  printf '#!/usr/bin/env bash\necho "seiue-notify: run.sh disabled; use systemd"\n' > "${INSTALL_DIR}/run.sh"
  chmod +x "${INSTALL_DIR}/run.sh"
  rm -f "${INSTALL_DIR}/.notify.lock"
}

collect_env_if_needed(){
  if [ -f "$ENV_FILE" ]; then
    info "檢測到現有 .env，跳過交互式輸入。"
    return
  fi
  info "首次配置：寫入 $ENV_FILE（600）"
  read -p "Seiue 用戶名: " SEIUE_USERNAME
  read -s -p "Seiue 密碼: " SEIUE_PASSWORD; echo
  read -p "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
  read -p "Telegram Chat ID: " TELEGRAM_CHAT_ID
  read -p "輪詢間隔秒(默認90): " POLL; POLL="${POLL:-90}"
  cat >"$ENV_FILE" <<EOF
SEIUE_USERNAME=${SEIUE_USERNAME}
SEIUE_PASSWORD=${SEIUE_PASSWORD}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}

# 可選項（均有合理默認）：
NOTIFY_POLL_SECONDS=${POLL}
MAX_LIST_PAGES=10
READ_FILTER=unread
INCLUDE_CC=true
SKIP_HISTORY_ON_FIRST_RUN=1
TELEGRAM_MIN_INTERVAL_SECS=1.5
NOTICE_EXCLUDE_NOISE=0
SEND_TEST_ON_START=1
OSS_HOST=https://oss-seiue-attachment.seiue.com

# 反歷史 + 去重策略（可改）：
FAST_FORWARD_ON_START=1
HARD_CUTOFF_MINUTES=360
SOFT_DUP_WINDOW_SECS=1800

# 安裝版本標記（會體現在 Tele 推送裡）：
SIDE_VERSION=seiue-notify v2.4.4-fix+leave-tele+attendance-avatar
EOF
  chmod 600 "$ENV_FILE"
}

ensure_env_defaults(){
  [ -f "$ENV_FILE" ] || return 0
  _set_if_missing(){ grep -qE "^$1=" "$ENV_FILE" || printf "%s=%s\n" "$1" "$2" >>"$ENV_FILE"; }
  _set_if_missing READ_FILTER unread
  _set_if_missing FAST_FORWARD_ON_START 1
  _set_if_missing HARD_CUTOFF_MINUTES 360
  _set_if_missing SOFT_DUP_WINDOW_SECS 1800
  _set_if_missing INCLUDE_CC true
  _set_if_missing NOTICE_EXCLUDE_NOISE 0
  _set_if_missing SEND_TEST_ON_START 1
  _set_if_missing OSS_HOST "https://oss-seiue-attachment.seiue.com"
  _set_if_missing SIDE_VERSION "seiue-notify v2.4.4-fix+leave-tele+attendance-avatar"
}

setup_venv(){
  ensure_dirs
  if ! python3 -c 'import ensurepip' >/dev/null 2>&1; then
    if command -v apt-get >/dev/null; then apt-get update -y && apt-get install -y python3-venv || true; fi
  fi
  python3 -m venv "$VENV_DIR" || true
  "$VENV_DIR/bin/python" -m pip install -U pip >/dev/null 2>&1 || true
  info "安裝/升級依賴…"
  "$VENV_DIR/bin/python" -m pip install -q requests pytz urllib3
}

write_python(){
  cat >"$PY_SCRIPT" <<'PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, sys, time, json, html, fcntl, logging, hashlib, re
from typing import Dict, Any, List, Tuple, Optional
from datetime import datetime
import requests, pytz
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

BASE = os.path.dirname(os.path.abspath(__file__))
LOG_DIR = os.path.join(BASE, "logs"); os.makedirs(LOG_DIR, exist_ok=True)
STATE_FILE = os.path.join(BASE, "notify_state.json")
LOCK_FILE  = os.path.join(BASE, ".notify.lock")
LOG_FILE   = os.path.join(LOG_DIR, "notify.log")

SEIUE_USERNAME = os.getenv("SEIUE_USERNAME","")
SEIUE_PASSWORD = os.getenv("SEIUE_PASSWORD","")
X_SCHOOL_ID = os.getenv("X_SCHOOL_ID","3")
X_ROLE = os.getenv("X_ROLE","teacher")
TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN","")
TELEGRAM_CHAT_ID   = os.getenv("TELEGRAM_CHAT_ID","")
SIDE_VERSION = os.getenv("SIDE_VERSION","seiue-notify v2.4.4-fix+leave-tele+attendance-avatar")
OSS_HOST = os.getenv("OSS_HOST","https://oss-seiue-attachment.seiue.com")

POLL_SECONDS = int(os.getenv("NOTIFY_POLL_SECONDS","90") or "90")
MAX_LIST_PAGES = max(1, min(int(os.getenv("MAX_LIST_PAGES","10") or "10"), 20))
READ_FILTER = (os.getenv("READ_FILTER","unread").strip().lower())
INCLUDE_CC = os.getenv("INCLUDE_CC","true").strip().lower() in ("1","true","yes","on")
SKIP_HISTORY_ON_FIRST_RUN = os.getenv("SKIP_HISTORY_ON_FIRST_RUN","1").strip().lower() in ("1","true","yes","on")
TELEGRAM_MIN_INTERVAL = float(os.getenv("TELEGRAM_MIN_INTERVAL_SECS","1.5") or "1.5")
NOTICE_EXCLUDE_NOISE = os.getenv("NOTICE_EXCLUDE_NOISE","0").strip().lower() in ("1","true","yes","on")
SEND_TEST_ON_START = os.getenv("SEND_TEST_ON_START","1").strip().lower() in ("1","true","yes","on")

FAST_FORWARD_ON_START = os.getenv("FAST_FORWARD_ON_START","1").strip().lower() in ("1","true","yes","on")
HARD_CUTOFF_MINUTES  = int(os.getenv("HARD_CUTOFF_MINUTES","360") or "360")
SOFT_DUP_WINDOW_SECS = int(os.getenv("SOFT_DUP_WINDOW_SECS","1800") or "1800")

BEIJING_TZ = pytz.timezone("Asia/Shanghai")
START_TS = time.time()
HARD_CUTOFF_TS = START_TS - HARD_CUTOFF_MINUTES*60

logging.basicConfig(
  level=logging.INFO,
  format="%(asctime)s.%(msecs)03d - %(levelname)s - %(message)s",
  datefmt="%Y-%m-%d %H:%M:%S",
  handlers=[logging.FileHandler(LOG_FILE, encoding="utf-8", mode="a"), logging.StreamHandler(sys.stdout)],
)

def esc(s:str)->str: return html.escape(s or "", quote=False)

def parse_ts(s:str)->float:
  for fmt in ("%Y-%m-%d %H:%M:%S","%Y-%m-%dT%H:%M:%S%z","%Y-%m-%dT%H:%M:%S"):
    try: return datetime.strptime(s, fmt).timestamp()
    except: pass
  return 0.0

def fmt_time(s:str)->str:
  if not s: return ""
  for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%S.%fZ"):
    try:
      dt = datetime.strptime(s, fmt)
      if not dt.tzinfo:
        dt = dt.replace(tzinfo=BEIJING_TZ)
      return dt.strftime("%Y-%m-%d %H:%M")
    except:
      continue
  return s

def load_state()->Dict[str,Any]:
  if not os.path.exists(STATE_FILE):
    return {"seen_global":{}, "watermark":{"system":{"ts":0.0,"id":0}, "notice":{"ts":0.0,"id":0}}}
  try:
    with open(STATE_FILE,"r",encoding="utf-8") as f: st=json.load(f)
    st.setdefault("seen_global",{})
    st.setdefault("watermark",{"system":{"ts":0.0,"id":0}, "notice":{"ts":0.0,"id":0}})
    for k in ("system","notice"): st["watermark"].setdefault(k,{"ts":0.0,"id":0})
    return st
  except:
    return {"seen_global":{}, "watermark":{"system":{"ts":0.0,"id":0}, "notice":{"ts":0.0,"id":0}}}

def save_state(st:Dict[str,Any])->None:
  tmp=STATE_FILE+".tmp"
  with open(tmp,"w",encoding="utf-8") as f:
    json.dump(st,f,ensure_ascii=False,indent=2); f.flush(); os.fsync(f.fileno())
  os.replace(tmp,STATE_FILE)

def acquire_lock_or_exit():
  fd=os.open(LOCK_FILE, os.O_CREAT|os.O_RDWR, 0o644)
  try:
    fcntl.flock(fd, fcntl.LOCK_EX|fcntl.LOCK_NB); os.ftruncate(fd,0); os.write(fd, str(os.getpid()).encode()); return fd
  except OSError:
    logging.error("已有實例運行，本實例退出。"); sys.exit(0)

def global_key(it: dict) -> str:
  nid = str(it.get("id") or "")
  if nid: return f"id:{nid}"
  title = it.get("title") or ""
  t = it.get("published_at") or it.get("created_at") or ""
  src = (it.get("sender_reflection") or {}).get("id") or ""
  content = it.get("content") or ""
  h = hashlib.sha1(f"{title}|{t}|{src}|{content}".encode("utf-8", "ignore")).hexdigest()[:16]
  return f"h:{h}"

def sender_name(it:Dict[str,Any])->str:
  sr=it.get("sender_reflection") or {}
  return sr.get("name") or sr.get("nickname") or "系統"

class Telegram:
  def __init__(self, token:str, chat_id:str):
    self.base=f"https://api.telegram.org/bot{token}"; self.chat_id=chat_id
    self.s=requests.Session()
    self.s.mount("https://", HTTPAdapter(max_retries=Retry(total=4, backoff_factor=1.3, status_forcelist=(429,500,502,503,504))))
    self._last=0.0
  def _pace(self):
    delta=time.time()-self._last
    if delta<TELEGRAM_MIN_INTERVAL: time.sleep(TELEGRAM_MIN_INTERVAL-delta)
  def _post(self, ep:str, data:dict, files:dict=None, timeout:int=60)->bool:
    back=1.0
    for _ in range(6):
      try:
        self._pace()
        r=self.s.post(f"{self.base}/{ep}", data=data, files=files, timeout=timeout); self._last=time.time()
        if r.status_code==200: return True
        if r.status_code==429:
          try: delay=int(r.json().get("parameters",{}).get("retry_after",3))
          except: delay=3
          time.sleep(max(1,min(delay+1,60))); continue
        if 500<=r.status_code<600: time.sleep(back); back=min(back*2,15); continue
        return False
      except requests.RequestException:
        time.sleep(back); back=min(back*2,15)
    return False
  def send(self, html_text:str)->bool:
    if len(html_text)<=4096:
      return self._post("sendMessage", {"chat_id":self.chat_id,"text":html_text,"parse_mode":"HTML","disable_web_page_preview":True}, None, 30)
    # split
    safe=4032; parts=[]; buf=""
    for para in html_text.split("\n\n"):
      add=(("\n\n" if buf else "")+para)
      if len(add)>safe:
        for ln in para.split("\n"):
          t=(buf+("\n" if buf else "")+ln)
          if len(t)>safe:
            if buf: parts.append(buf); buf=ln
            else:
              i=0
              while i<len(ln): parts.append(ln[i:i+safe]); i+=safe
              buf=""
          else: buf=t
      else:
        t=buf+add
        if len(t)>safe: parts.append(buf); buf=para
        else: buf=t
    if buf: parts.append(buf)
    ok=True; total=len(parts)
    for i,p in enumerate(parts,1):
      ok=self._post("sendMessage", {"chat_id":self.chat_id,"text":f"(Part {i}/{total})\n{p}","parse_mode":"HTML","disable_web_page_preview":True}, None, 30) and ok
    return ok
  def send_photo(self, data:bytes, cap:str="")->bool:
    if len(cap)>1024: cap=cap[:1008]+"…"
    return self._post("sendPhoto", {"chat_id":self.chat_id,"caption":cap,"parse_mode":"HTML"}, {"photo":("image.jpg",data)}, 90)
  def send_doc(self, data:bytes, name:str, cap:str="")->bool:
    if len(cap)>1024: cap=cap[:1008]+"…"
    return self._post("sendDocument", {"chat_id":self.chat_id,"caption":cap,"parse_mode":"HTML"}, {"document":(name,data)}, 180)

class Seiue:
  def __init__(self, user:str, pwd:str):
    self.u=user; self.p=pwd; self.s=requests.Session()
    self.s.mount("https://", HTTPAdapter(max_retries=Retry(total=5, backoff_factor=1.6, status_forcelist=(429,500,502,503,504))))
    self.reflection=None
  def login(self)->bool:
    try:
      self.s.post("https://passport.seiue.com/login?school_id=3",
                  headers={"Content-Type":"application/x-www-form-urlencoded","Origin":"https://passport.seiue.com"},
                  data={"email":self.u,"password":self.p}, timeout=30)
      r = self.s.post("https://passport.seiue.com/authorize",
                      headers={"Content-Type":"application/x-www-form-urlencoded",
                               "X-Requested-With":"XMLHttpRequest",
                               "Origin":"https://chalk-c3.seiue.com",
                               "Referer":"https://chalk-c3.seiue.com/"},
                      data={"client_id":"GpxvnjhVKt56qTmnPWH1sA","response_type":"token"}, timeout=30)
      try:
        j = r.json()
      except Exception:
        txt = r.text or ""
        m = re.search(r'"access_token"\s*:\s*"([^"]+)"', txt)
        n = re.search(r'"active_reflection_id"\s*:\s*"?(\d+)"?', txt)
        j = {"access_token": m.group(1) if m else None,
             "active_reflection_id": n.group(1) if n else None}
      tok = j.get("access_token"); rid = str(j.get("active_reflection_id") or "")
      if not tok or not rid:
        logging.error("authorize missing token/reflection_id; status=%s body_prefix=%r", r.status_code, (r.text or "")[:180])
        return False
      self.reflection = rid
      self.s.headers.update({"Authorization":f"Bearer {tok}","x-school-id":X_SCHOOL_ID,"x-role":X_ROLE,"x-reflection-id":rid})
      logging.info("Auth OK, reflection_id=%s", rid); return True
    except Exception as e:
      logging.error("login error: %s", e, exc_info=True); return False

  def _get_me(self, params:dict):
    url="https://api.seiue.com/chalk/me/received-messages"
    r=self.s.get(url, params=params, timeout=30)
    if r.status_code in (401,403):
      if self.login(): r=self.s.get(url, params=params, timeout=30)
    return r

  def list_system(self, pages:int)->List[Dict[str,Any]]:
    base={"expand":"sender_reflection","owner.id":self.reflection,"type":"message","paginated":"1","sort":"-published_at,-created_at"}
    if READ_FILTER=="unread": base["readed"]="false"
    if not INCLUDE_CC: base["is_cc"]="false"
    return self._collect(base, pages)

  def list_notice(self, pages:int)->List[Dict[str,Any]]:
    base={"expand":"sender_reflection,aggregated_messages","owner.id":self.reflection,"paginated":"1","sort":"-published_at,-created_at","notice":"true"}
    if NOTICE_EXCLUDE_NOISE:
      base["type_not_in"]="exam.schedule_result_for_examinee,exam.schedule_result_for_examiner,exam.stats_received,exam.published_for_adminclass_teacher,exam.published_for_examinee,exam.published_scoring_for_examinee,exam.published_for_teacher,exam.published_for_mentor,schcal.holiday_created,schcal.holiday_deleted,schcal.holiday_updated,schcal.makeup_created,schcal.makeup_deleted"
    if READ_FILTER=="unread": base["readed"]="false"
    return self._collect(base, pages)

  def _collect(self, base:dict, pages:int)->List[Dict[str,Any]]:
    items=[]
    for p in range(1, pages+1):
      q=dict(base, **{"page":str(p),"per_page":"20"})
      r=self._get_me(q)
      if r.status_code!=200: break
      try:
        j=r.json()
      except Exception:
        logging.error("list decode error; status=%s body_prefix=%r", r.status_code, (r.text or "")[:160]); break
      arr=j["items"] if isinstance(j,dict) and "items" in j else (j if isinstance(j,list) else [])
      if not arr: break
      items.extend(arr)
    return items

  def download(self, url:str)->Tuple[bytes,str]:
    r=self.s.get(url, timeout=60, stream=True)
    if r.status_code!=200: return b"","attachment.bin"
    name="attachment.bin"
    cd=r.headers.get("Content-Disposition") or ""
    if "filename=" in cd:
      name=cd.split("filename=",1)[1].strip('"; ')
    else:
      from urllib.parse import urlparse, unquote
      try: name=unquote(urlparse(r.url).path.rsplit('/',1)[-1]) or name
      except: pass
    return r.content, name

  def _get_api(self, url: str) -> Optional[dict]:
    try:
      r = self.s.get(url, timeout=30)
      if r.status_code in (401, 403):
        if self.login():
          r = self.s.get(url, timeout=30)
      if r.status_code == 200:
        return r.json()
      logging.warning("API GET %s -> %s", url, r.status_code)
    except Exception as e:
      logging.error("API GET exception %s: %s", url, e)
    return None

  def get_flow_details(self, flow_id: int) -> Optional[dict]:
    # 帶上你 curl 裡面的 expand，讓 nodes/stages/reflection 都有
    url = (
      f"https://api.seiue.com/form/workflow/flows/{flow_id}"
      "?expand=initiator,tags,nodes,nodes.comments,nodes.comments.reflection,"
      "nodes.stages,nodes.stages.reflection,nodes.stages.returned_reflections,"
      "nodes.stages.forwarded_reflection,initiator.pupil"
    )
    return self._get_api(url)

  def get_absence_range_stats(self, plugin_id: int, flow_id: int) -> Optional[list]:
    url = f"https://api.seiue.com/sams/absence/school-plugins/{plugin_id}/flows/{flow_id}/absence-range-stats"
    return self._get_api(url)

def render_content(raw_json:str)->Tuple[str,List[Dict[str,Any]]]:
  try: raw=json.loads(raw_json or "{}")
  except: raw={}
  blocks=raw.get("blocks") or []; entity_map=raw.get("entityMap") or {}
  ents={}
  for k,v in (entity_map.items() if isinstance(entity_map,dict) else []):
    try: ents[int(k)]=v
    except: pass
  lines=[]; attachments=[]
  def decorate(text, ranges):
    prefix=""
    for r in ranges or []:
      s=r.get("style") or ""
      if s=="BOLD": text=f"<b>{esc(text)}</b>"
      elif s.startswith("color_"):
        if "red" in s: prefix="❗"+prefix
        elif "orange" in s: prefix="⚠️"+prefix
        elif "theme" in s: prefix="⭐"+prefix
    if not text.startswith("<b>"): text=esc(text)
    return prefix+text
  for blk in blocks:
    t=blk.get("text","") or ""; line=decorate(t, blk.get("inlineStyleRanges") or [])
    for er in blk.get("entityRanges") or []:
      key=er.get("key"); ent=ents.get(int(key)) if key is not None else None
      if not ent: continue
      et=(ent.get("type") or "").upper(); dat=(ent.get("data") or {})
      if et=="FILE":  attachments.append({"type":"file","name":dat.get("name") or "附件","size":dat.get("size") or "","url":dat.get("url") or ""})
      if et=="IMAGE": attachments.append({"type":"image","name":"image.jpg","size":"","url":dat.get("src") or ""})
    if (blk.get("data") or {}).get("align")=="align_right" and line.strip(): line="—— "+line
    lines.append(line)
  while lines and not lines[-1].strip(): lines.pop()
  html_txt="\n\n".join([ln if ln.strip() else "​" for ln in lines])
  return html_txt, attachments

def extract_attendance_summary(it:Dict[str,Any]) -> str:
  lines=[]
  for m in (it.get("aggregated_messages") or [])[:10]:
    t = (m.get("title") or "").strip()
    b, _ = render_content(m.get("content") or "")
    one = (t if t else b).strip()
    if one:
      one = re.sub(r"\n{3,}", "\n\n", one)
      if len(one) > 200: one = one[:200] + "…"
      lines.append(f"• {esc(one)}")
  body_html, _ = render_content(it.get("content") or "")
  body_txt = re.sub(r"<[^>]+>", "", body_html)
  stat_map={"出勤": r"(?:出勤|到勤|簽到|签到)\s*[:：]?\s*(\d+)",
            "請假": r"(?:請假|请假)\s*[:：]?\s*(\d+)",
            "遲到": r"(?:遲到|迟到)\s*[:：]?\s*(\d+)",
            "缺勤": r"(?:缺勤|曠課|旷课)\s*[:：]?\s*(\d+)"}
  stats=[]
  for k, rx in stat_map.items():
    m = re.search(rx, body_txt)
    if m: stats.append(f"{k} {m.group(1)}")
  if stats: lines.append("統計：" + "，".join(stats))
  if not lines and body_txt.strip():
    sample = body_txt.strip()
    if len(sample) > 200: sample = sample[:200] + "…"
    lines.append(esc(sample))
  return "\n".join(lines[:8])

def soft_dup_key(it:Dict[str,Any], ts:float) -> str:
  title = it.get("title") or ""
  src = sender_name(it)
  return f"soft:{src}|{title}|{int(ts//SOFT_DUP_WINDOW_SECS)}"

def latest_of_channel(cli:"Seiue", ch:str)->Optional[Dict[str,Any]]:
  arr = cli.list_notice(1) if ch=="notice" else cli.list_system(1)
  return arr[0] if arr else None

def ensure_startup_watermark(cli:"Seiue"):
  st=load_state(); changed=False
  for ch in ("system","notice"):
    w=st["watermark"][ch]; last_ts=float(w.get("ts") or 0.0)
    if FAST_FORWARD_ON_START or last_ts < (START_TS - 86400*365) or last_ts==0.0:
      it=latest_of_channel(cli, ch)
      if it:
        ts=parse_ts(it.get("published_at") or it.get("created_at") or "") or START_TS
        try: mid=int(str(it.get("id") or "0"))
        except: mid=0
      else:
        ts=START_TS; mid=0
      st["watermark"][ch]={"ts":ts,"id":mid}; changed=True
  if changed:
    save_state(st)
    logging.info("fast-forward watermarks: %s", st["watermark"])

def translate_absence_type(raw: str) -> str:
  return {
    "option1": "事假",
    "option2": "病假",
    "option3": "公假",
    "option4": "其他",
  }.get(raw, "未知類型")

def format_leave_card(flow_data: dict, range_data: Optional[list]) -> Tuple[str, List[Dict[str,str]]]:
  initiator = flow_data.get("initiator") or {}
  initiator_name = initiator.get("name") or "未知"
  initiator_usin = initiator.get("usin") or "N/A"
  flow_id = flow_data.get("id") or 0
  status = flow_data.get("status") or "approved"
  status_cn = "已通過" if status == "approved" else status

  field_values = flow_data.get("field_values") or []
  fv = {f.get("field_name"): f.get("value") for f in field_values}
  absence_type_raw = fv.get("absence_type") or ""
  absence_type = translate_absence_type(absence_type_raw)
  absence_reason = fv.get("absence_reason") or "未填寫事由"
  attachments = fv.get("absence_attachments") or []
  weekday_minutes = flow_data.get("weekday_minutes", 0)
  leave_hours = f"{weekday_minutes}分鐘" if weekday_minutes else "不明"

  date_str = ""
  weekday = ""
  time_ranges = ""
  lesson_blocks = []
  lesson_count = 0
  if range_data and isinstance(range_data, list) and range_data:
    first = range_data[0]
    date_str = first.get("date") or ""
    weekday = first.get("week_day") or ""
    trs = []
    for r in first.get("ranges") or []:
      s = (r.get("start_at") or "")[11:16]
      e = (r.get("end_at") or "")[11:16]
      if s and e:
        trs.append(f"{s}-{e}")
      cls = r.get("class") or {}
      cname = cls.get("name") or ""
      cclass = cls.get("class_name") or ""
      lessons = r.get("lessons") or []
      if lessons:
        lesson_count += len(lessons)
        names = []
        for l in lessons:
          ln = l.get("lesson_name") or ""
          if ln: names.append(ln)
        if cclass:
          lesson_blocks.append(f"{cname} {cclass} 課節：{', '.join(names)}")
        else:
          lesson_blocks.append(f"{cname} 課節：{', '.join(names)}")
    time_ranges = "、".join(trs)

  flow_lines = []
  for node in flow_data.get("nodes") or []:
    label = node.get("node_label") or node.get("node_name") or "節點"
    stages = node.get("stages") or []
    if not stages:
      continue
    stg = stages[0]
    actor = (stg.get("reflection") or {}).get("name") or "系統"
    st_status = stg.get("status") or ""
    icon = {"approved":"✅","rejected":"❌","pending":"⏳"}.get(st_status, "➡️")
    reviewed_at = stg.get("reviewed_at") or ""
    line = f"{icon} {esc(label)}: {esc(actor)}"
    if reviewed_at:
      line += f" ({fmt_time(reviewed_at)})"
    flow_lines.append(line)

  msg = (
    f"📝 收到一条请假抄送\n\n"
    f"【請假信息】\n"
    f"請假人：{esc(initiator_name)}（{esc(initiator_usin)}）\n"
    f"請假類型：{esc(absence_type)}\n"
  )
  if date_str or weekday:
    msg += f"日期：{esc(date_str)} {esc(weekday)}\n"
  if time_ranges:
    msg += f"時間：{esc(time_ranges)}\n"
  for b in lesson_blocks:
    msg += f"{esc(b)}\n"
  msg += (
    f"課節數：{lesson_count} 節\n"
    f"請假時長：{leave_hours}\n"
    f"事由：{esc(absence_reason)}\n"
  )
  if attachments:
    msg += "表單中有附件，已嘗試提取。\n"
  else:
    msg += "表單中無附件。\n"
  msg += "\n【審批信息】\n"
  msg += f"審批編號：{flow_id}\n"
  msg += f"審批狀態：{esc(status_cn)}\n"
  if flow_lines:
    msg += "審批流程（由 " + esc(initiator_name) + " 發起）：\n" + "\n".join(flow_lines) + "\n"
  msg += f"\n版本：{esc(SIDE_VERSION)}"
  return msg, attachments

def _format_discussion_notice(original: dict) -> str:
  attrs = original.get("attributes") or {}
  title = original.get("title") or "你在討論中收到了新回復"
  task_snip = re.sub(r"<[^>]+>", "", html.unescape(original.get("content") or ""))[:180]
  pub = fmt_time(original.get("published_at") or original.get("created_at") or "")
  return (
    f"💬 <b>{esc(title)}</b>\n\n"
    f"{esc(task_snip)}\n\n"
    f"discussion_id={attrs.get('discussion_id')} / topic_id={attrs.get('topic_id')} / message_id={attrs.get('message_id')}\n"
    f"— 通知於 {pub}"
  )

def _format_attendance_notice(original: dict) -> str:
  attrs = original.get("attributes") or {}
  name = attrs.get("name") or "學生"
  grade = attrs.get("grade_name") or ""
  klass = attrs.get("admin_class_names") or ""
  lesson_date = attrs.get("lesson_date") or ""
  lesson_name = attrs.get("lesson_name") or ""
  course = attrs.get("class_full_name") or ""
  result = attrs.get("result") or ""
  pub = fmt_time(original.get("published_at") or original.get("created_at") or "")
  title = original.get("title") or "考勤结果通知"
  return (
    f"🟣 <b>{esc(title)}</b>\n\n"
    f"<b>學生</b>：{esc(name)} {esc(grade)} {esc(klass)}\n"
    f"<b>日期/節次</b>：{esc(lesson_date)} {esc(lesson_name)}\n"
    f"<b>課程/班級</b>：{esc(course)}\n"
    f"<b>結果</b>：{esc(result)}\n"
    f"\n— 通知於 {pub}"
  )

# === 這裡是本次新增的兩個 helper ====================================

def _attendance_avatar_url(original: dict) -> str:
  """從考勤通知裡把學生頭像的 OSS 路徑還原出來。"""
  attrs = original.get("attributes") or {}
  photo_name = attrs.get("photo") or ""
  if not photo_name:
    return ""
  p1 = photo_name[:2]
  p2 = photo_name[2:4]
  return f"{OSS_HOST}/user/{p1}/{p2}/{photo_name}"

def _absence_attachments_from_flow(flow_data: dict) -> list:
  """從請假 flow 的 field_values 裡把真正的附件列出來，變成 [{url,name}, ...]"""
  res = []
  if not flow_data:
    return res
  for fv in flow_data.get("field_values") or []:
    if fv.get("field_name") == "absence_attachments":
      vals = fv.get("value") or []
      for att in vals:
        h = att.get("hash")
        if not h:
          continue
        mime = att.get("mime") or "image/jpeg"
        ext = mime.split("/")[-1]
        p1 = h[:2]
        p2 = h[2:4]
        url = f"{OSS_HOST}/attachment/{p1}/{p2}/{h}.{ext}"
        res.append({
          "url": url,
          "name": att.get("name") or f"附件.{ext}",
        })
  return res

# =====================================================================

def mark_seen(state:dict, key:str, ts:float):
  state["seen_global"][key] = {"ts": ts}

def should_skip_soft(state:dict, soft_key:str)->bool:
  return soft_key in state["seen_global"]

def handle_one_notice(it:dict, tg:Telegram, seiue:Seiue, state:dict):
  mtype = it.get("type") or ""
  domain = it.get("domain") or ""
  pub_ts = parse_ts(it.get("published_at") or it.get("created_at") or "") or time.time()
  gkey = global_key(it)
  skey = soft_dup_key(it, pub_ts)
  if pub_ts < HARD_CUTOFF_TS:
    logging.info("skip by hard-cutoff: %s", gkey)
    return
  if should_skip_soft(state, skey):
    logging.info("skip by soft-dup: %s", skey)
    return

  # 分類處理
  if mtype == "absence.flow_cc_node":
    attrs = it.get("attributes") or {}
    flow_id = attrs.get("flow_id")
    if not flow_id:
      # fallback: 就發原始內容
      body, atts = render_content(it.get("content") or "")
      tg.send(f"📝 收到一条请假抄送\n\n{body}")
      for a in atts:
        url = a.get("url") or ""
        if not url:
          continue
        data, fname = seiue.download(url)
        if data:
          tg.send_doc(data, fname, "請假附件")
    else:
      flow_data = seiue.get_flow_details(int(flow_id))
      ranges = None
      if flow_data:
        plugin_id = flow_data.get("school_plugin_id")
        if plugin_id:
          ranges = seiue.get_absence_range_stats(int(plugin_id), int(flow_id))
      msg_html, form_atts = format_leave_card(flow_data or {}, ranges or [])
      tg.send(msg_html)
      # 表單附件
      extra_atts = _absence_attachments_from_flow(flow_data or {})
      for att in extra_atts:
        try:
          data, fname = seiue.download(att["url"])
          if data:
            tg.send_photo(data, att.get("name") or "請假附件")
        except Exception as e:
          logging.warning("send leave attachment fail: %s", e)
  elif domain == "attendance" or mtype == "abnormal_attendance.guardian":
    text = _format_attendance_notice(it)
    tg.send(text)
    avatar_url = _attendance_avatar_url(it)
    if avatar_url:
      try:
        data, fname = seiue.download(avatar_url)
        if data:
          tg.send_photo(data, "考勤學生頭像")
      except Exception as e:
        logging.warning("send attendance avatar fail: %s", e)
  elif mtype == "task.discussion_replied":
    tg.send(_format_discussion_notice(it))
  else:
    body_html, atts = render_content(it.get("content") or "")
    title = it.get("title") or "通知"
    pub = fmt_time(it.get("published_at") or it.get("created_at") or "")
    msg = f"📣 <b>{esc(title)}</b>\n\n{body_html}\n\n— 通知於 {pub}"
    tg.send(msg)
    for a in atts:
      url = a.get("url") or ""
      if not url:
        continue
      data, fname = seiue.download(url)
      if data:
        if a.get("type") == "image":
          tg.send_photo(data, fname)
        else:
          tg.send_doc(data, fname, "附件")

  mark_seen(state, gkey, pub_ts)
  mark_seen(state, skey, pub_ts)

def handle_one_system(it:dict, tg:Telegram, seiue:Seiue, state:dict):
  # 目前系統消息不多做，維持原來邏輯：渲染 content
  body_html, atts = render_content(it.get("content") or "")
  title = it.get("title") or "消息"
  pub = fmt_time(it.get("published_at") or it.get("created_at") or "")
  msg = f"💡 <b>{esc(title)}</b>\n\n{body_html}\n\n— 收到於 {pub}"
  tg.send(msg)
  for a in atts:
    url = a.get("url") or ""
    if not url:
      continue
    data, fname = seiue.download(url)
    if data:
      if a.get("type") == "image":
        tg.send_photo(data, fname)
      else:
        tg.send_doc(data, fname, "附件")
  pub_ts = parse_ts(it.get("published_at") or it.get("created_at") or "") or time.time()
  gkey = global_key(it)
  skey = soft_dup_key(it, pub_ts)
  mark_seen(state, gkey, pub_ts)
  mark_seen(state, skey, pub_ts)

def main_loop():
  if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
    logging.error("缺少 TELEGRAM_BOT_TOKEN 或 TELEGRAM_CHAT_ID，退出。")
    sys.exit(1)
  if not SEIUE_USERNAME or not SEIUE_PASSWORD:
    logging.error("缺少 SEIUE_USERNAME 或 SEIUE_PASSWORD，退出。")
    sys.exit(1)

  lock_fd = acquire_lock_or_exit()
  tg = Telegram(TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID)
  seiue = Seiue(SEIUE_USERNAME, SEIUE_PASSWORD)
  if not seiue.login():
    logging.error("初次登入失敗，退出")
    sys.exit(1)

  ensure_startup_watermark(seiue)

  if SEND_TEST_ON_START:
    tg.send(f"🤖 Seiue 通知監聽已啟動。\n版本：{esc(SIDE_VERSION)}")

  while True:
    try:
      st = load_state()
      # NOTICE
      notice_items = seiue.list_notice(MAX_LIST_PAGES)
      notice_items.sort(key=lambda x: parse_ts(x.get("published_at") or x.get("created_at") or ""), reverse=False)
      for it in notice_items:
        pub_ts = parse_ts(it.get("published_at") or it.get("created_at") or "") or time.time()
        # 只處理新於水位線的
        w = st["watermark"]["notice"]
        if pub_ts+0.001 <= w["ts"]:
          continue
        handle_one_notice(it, tg, seiue, st)
        st["watermark"]["notice"] = {"ts": pub_ts, "id": it.get("id") or 0}

      # SYSTEM
      sys_items = seiue.list_system(2)
      sys_items.sort(key=lambda x: parse_ts(x.get("published_at") or x.get("created_at") or ""), reverse=False)
      for it in sys_items:
        pub_ts = parse_ts(it.get("published_at") or it.get("created_at") or "") or time.time()
        w = st["watermark"]["system"]
        if pub_ts+0.001 <= w["ts"]:
          continue
        handle_one_system(it, tg, seiue, st)
        st["watermark"]["system"] = {"ts": pub_ts, "id": it.get("id") or 0}

      save_state(st)

    except Exception as e:
      logging.error("主循環錯誤: %s", e, exc_info=True)
    time.sleep(POLL_SECONDS)

if __name__ == "__main__":
  main_loop()
PY
  chmod +x "$PY_SCRIPT"
}

write_unit(){
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Seiue -> Telegram notifier
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$VENV_DIR/bin/python $PY_SCRIPT
Restart=always
RestartSec=5
StandardOutput=append:$OUT_LOG
StandardError=append:$ERR_LOG
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF
}

enable_service(){
  info "重載 systemd…"
  systemctl daemon-reload
  systemctl enable seiue-notify.service >/dev/null 2>&1 || true
  systemctl restart seiue-notify.service || true
  success "seiue-notify 已啟動（systemd）"
}

main(){
  preflight
  ensure_dirs
  cleanup_legacy
  collect_env_if_needed
  ensure_env_defaults
  setup_venv
  write_python
  write_unit
  enable_service
  success "安裝完成，版本：seiue-notify v2.4.4-fix+leave-tele+attendance-avatar"
  echo "日誌：$OUT_LOG / $ERR_LOG"
}

main "$@"
SH