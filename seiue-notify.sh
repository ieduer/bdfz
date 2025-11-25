#!/usr/bin/env bash
# Seiue Notification → Telegram - 安裝/升級腳本
# 版本：v2.5.9-assessment
set -euo pipefail

SIDE_VERSION="v2.5.9-assessment"

C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'
info(){ echo -e "${C_BLUE}INFO:${C_RESET} $1"; }
success(){ echo -e "${C_GREEN}SUCCESS:${C_RESET} $1"; }
warn(){ echo -e "${C_YELLOW}WARNING:${C_RESET} $1"; }
error(){ echo -e "${C_RED}ERROR:${C_RESET} $1" >&2; }

echo
echo "==============================================="
echo "  Seiue → Telegram Installer ${SIDE_VERSION}"
echo "  $(date '+%F %T')"
echo "==============================================="
echo

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
    if command -v yum >/dev/null; then yum install -y python3 python3-pip || true; fi
  fi
  need_cmd python3 || { error "仍未找到 python3"; exit 1; }
  PY_VER=$(python3 -V 2>&1 || true)
  info "使用 Python: ${PY_VER}"
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

# 拉取通知/消息
NOTIFY_POLL_SECONDS=${POLL}
MAX_LIST_PAGES=1
READ_FILTER=unread
FAST_FORWARD_ON_START=1
INCLUDE_CC=true
NOTICE_EXCLUDE_NOISE=0
SEND_TEST_ON_START=1

# 去重/時限
SOFT_DUP_WINDOW_SECS=900
HARD_CUTOFF_MINUTES=1440

# OSS/參考域名
OSS_HOST=https://oss-seiue-attachment.seiue.com
SEIUE_REFERER=https://chalk-c3.seiue.com/

# 下載頭像時用這個 processor
PHOTO_PROCESSOR=image/resize,w_2048/quality,q_90

# 下載約談附件開關
CHAT_DOWNLOAD_ATTACH=1

SIDE_VERSION=${SIDE_VERSION}
EOF
  chmod 600 "$ENV_FILE"
}

ensure_env_defaults(){
  [ -f "$ENV_FILE" ] || return 0
  _set_if_missing(){ grep -qE "^$1=" "$ENV_FILE" || printf "%s=%s\n" "$1" "$2" >>"$ENV_FILE"; }
  _set_if_missing READ_FILTER unread
  _set_if_missing FAST_FORWARD_ON_START 1
  _set_if_missing HARD_CUTOFF_MINUTES 1440
  _set_if_missing SOFT_DUP_WINDOW_SECS 900
  _set_if_missing INCLUDE_CC true
  _set_if_missing NOTICE_EXCLUDE_NOISE 0
  _set_if_missing SEND_TEST_ON_START 1
  _set_if_missing OSS_HOST https://oss-seiue-attachment.seiue.com
  _set_if_missing SEIUE_REFERER https://chalk-c3.seiue.com/
  _set_if_missing PHOTO_PROCESSOR image/resize,w_2048/quality,q_90
  _set_if_missing CHAT_DOWNLOAD_ATTACH 1
  _set_if_missing SIDE_VERSION ${SIDE_VERSION}
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
"""
Seiue → Telegram notifier
版本: v2.5.9-assessment

這版在 v2.5.8-chat-form 的基礎上多做了：
1. 增加「德育/評價已發布」的專門分支，會根據通知帶過來的 assessment_id / item_id / owner_id
   去 /vnas/common/... 把真正的評價內容拉回來；
2. 沒帶齊參數就回退到原來的兜底文本。
"""
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
X_SCHOOL_ID    = os.getenv("X_SCHOOL_ID","3")
X_ROLE         = os.getenv("X_ROLE","teacher")
SEIUE_REFERER  = os.getenv("SEIUE_REFERER","https://chalk-c3.seiue.com/")
OSS_HOST       = os.getenv("OSS_HOST","https://oss-seiue-attachment.seiue.com")
PHOTO_PROCESSOR= os.getenv("PHOTO_PROCESSOR","image/resize,w_2048/quality,q_90")
CHAT_DOWNLOAD_ATTACH = os.getenv("CHAT_DOWNLOAD_ATTACH","1").strip().lower() in ("1","true","yes","on")

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN","")
TELEGRAM_CHAT_ID   = os.getenv("TELEGRAM_CHAT_ID","")

POLL_SECONDS = int(os.getenv("NOTIFY_POLL_SECONDS","90") or "90")
MAX_LIST_PAGES = max(1, min(int(os.getenv("MAX_LIST_PAGES","10") or "10"), 20))
READ_FILTER = (os.getenv("READ_FILTER","unread").strip().lower())
INCLUDE_CC = os.getenv("INCLUDE_CC","true").strip().lower() in ("1","true","yes","on")
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
  for fmt in ("%Y-%m-%d %H:%M:%S","%Y-%m-%dT%H:%M:%S%z","%Y-%m-%dT%H:%M:%S","%Y-%m-%dT%H:%M:%S.%fZ"):
    try: return datetime.strptime(s, fmt).timestamp()
    except: pass
  return 0.0

def fmt_time(s:str)->str:
  if not s: return ""
  for fmt in ("%Y-%m-%d %H:%M:%S","%Y-%m-%dT%H:%M:%S%z","%Y-%m-%dT%H:%M:%S","%Y-%m-%dT%H:%M:%S.%fZ"):
    try:
      dt = datetime.strptime(s, fmt)
      if not dt.tzinfo:
        dt = dt.replace(tzinfo=BEIJING_TZ)
      return dt.strftime("%Y-%m-%d %H:%M")
    except: continue
  return s

def load_state()->Dict[str,Any]:
  if not os.path.exists(STATE_FILE):
    return {"seen_global":{}, "watermark":{"system":{"ts":0.0,"id":0}, "notice":{"ts":0.0,"id":0}}}
  try:
    with open(STATE_FILE,"r",encoding="utf-8") as f: st=json.load(f)
    st.setdefault("seen_global",{})
    st.setdefault("watermark",{"system":{"ts":0.0,"id":0}, "notice":{"ts":0.0,"id":0}})
    for ch in ("system","notice"):
      st["watermark"].setdefault(ch,{"ts":0.0,"id":0})
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
    fcntl.flock(fd, fcntl.LOCK_EX|fcntl.LOCK_NB)
    os.ftruncate(fd,0); os.write(fd, str(os.getpid()).encode()); return fd
  except OSError:
    logging.error("已有實例運行，本實例退出。")
    sys.exit(0)

def global_key(it: dict) -> str:
  nid = str(it.get("id") or it.get("_id") or "")
  if nid: return f"id:{nid}"
  title = it.get("title") or ""
  t = it.get("published_at") or it.get("created_at") or ""
  src = (it.get("sender_reflection") or {}).get("id") or ""
  content = it.get("content") or ""
  h = hashlib.sha1(f"{title}|{t}|{src}|{content}".encode("utf-8", "ignore")).hexdigest()[:16]
  return f"h:{h}"

def sender_name(it:Dict[str,Any])->str:
  sr=it.get("sender_reflection") or it.get("sender") or {}
  return sr.get("name") or sr.get("nickname") or "系統"

class Telegram:
  def __init__(self, token:str, chat_id:str):
    self.base=f"https://api.telegram.org/bot{token}"; self.chat_id=chat_id
    self.s=requests.Session()
    self.s.mount("https://", HTTPAdapter(max_retries=Retry(total=4, backoff_factor=1.3, status_forcelist=(429,500,502,503,504))))
    self._last=0.0
  def _pace(self):
    delta=time.time()-self._last
    if delta<1.5: time.sleep(1.5-delta)
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
          time.sleep(delay+1); continue
        if 500<=r.status_code<600:
          time.sleep(back); back=min(back*2,15); continue
        return False
      except requests.RequestException:
        time.sleep(back); back=min(back*2,15)
    return False
  def send(self, html_text:str)->bool:
    return self._post("sendMessage", {"chat_id":self.chat_id,"text":html_text,"parse_mode":"HTML","disable_web_page_preview":True}, None, 60)
  def send_photo(self, data:bytes, cap:str="")->bool:
    if len(cap)>1024: cap=cap[:1000]+"…"
    return self._post("sendPhoto", {"chat_id":self.chat_id,"caption":cap,"parse_mode":"HTML"}, {"photo":("image.jpg",data)}, 90)
  def send_doc(self, data:bytes, name:str, cap:str="")->bool:
    if len(cap)>1024: cap=cap[:1000]+"…"
    return self._post("sendDocument", {"chat_id":self.chat_id,"caption":cap,"parse_mode":"HTML"}, {"document":(name,data)}, 180)

class Seiue:
  def __init__(self, user:str, pwd:str):
    self.u=user; self.p=pwd
    self.s=requests.Session()
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
      j = r.json()
      tok = j.get("access_token"); rid = str(j.get("active_reflection_id") or "")
      if not tok or not rid:
        logging.error("authorize missing token/reflection_id")
        return False
      self.reflection = rid
      self.s.headers.update({"Authorization":f"Bearer {tok}","x-school-id":X_SCHOOL_ID,"x-role":X_ROLE,"x-reflection-id":rid})
      logging.info("Auth OK, reflection_id=%s", rid)
      return True
    except Exception as e:
      logging.error("login error: %s", e, exc_info=True); return False

  def get_student_detail(self, sid:int)->Optional[dict]:
    try:
      url=f"https://api.seiue.com/chalk/reflection/students/{sid}/rid/{self.reflection}?expand=guardians,grade,user"
      r=self.s.get(url, timeout=30)
      if r.status_code==200:
        return r.json()
    except Exception as e:
      logging.warning("get_student_detail(%s) failed: %s", sid, e)
    return None

  def _search_student_by_name(self, name: str) -> Optional[int]:
    try:
      semester_id = os.getenv("SEIUE_SEMESTER_ID", "61564")
      url = "https://api.seiue.com/chalk/search/items"
      params = {
        "biz_type_in": "student,reflection,student_user,owner,pupil",
        "keyword": name,
        "semester_id": semester_id,
      }
      r = self.s.get(url, params=params, timeout=20)
      if r.status_code != 200: return None
      data = r.json()
      items = data if isinstance(data, list) else data.get("items", [])
      if not items: return None
      name = name.strip()
      for it in items:
        if it.get("biz_type") == "student" and (it.get("label") or "").strip() == name:
          return int(it["biz_id"])
      for it in items:
        if it.get("biz_type") == "student":
          return int(it["biz_id"])
    except Exception as e:
      logging.warning("_search_student_by_name(%r) failed: %s", name, e)
    return None

  def get_student_by_name(self, name: str) -> Optional[dict]:
    sid = self._search_student_by_name(name)
    if not sid: return None
    return self.get_student_detail(sid)

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

  def download_file_by_id(self, fid:str, processor:str="", download:bool=False)->Tuple[bytes,str]:
    from urllib.parse import quote
    qs=[]
    if processor: qs.append("processor="+quote(processor, safe=""))
    if download: qs.append("download=true")
    q = ("?"+"&".join(qs)) if qs else ""
    candidates = [
      f"https://api.seiue.com/chalk/netdisk/files/{fid}/url{q}",
      f"https://api.seiue.com/chalk/netdisk/files/{fid}.jpg/url{q}",
    ]
    for url in candidates:
      try:
        r = self.s.head(url, allow_redirects=False, timeout=20)
      except requests.RequestException:
        continue
      loc = r.headers.get("Location") or r.headers.get("location")
      logging.info("HEAD %s -> %s loc=%s", url, r.status_code, bool(loc))
      if loc:
        data,name = self.download(loc)
        if data:
          return data, name or (fid + ".bin")
    return b"", ""

  def download_student_photo_like_client(self, photo_key:str)->Tuple[bytes,str]:
    key=(photo_key or "").strip()
    if key.startswith("http://") or key.startswith("https://"):
      return self.download(key)
    base_key = key.replace(".jpg","").replace(".jpeg","")
    if len(base_key)==32 and all(c in "0123456789abcdef" for c in base_key):
      data, name = self.download_file_by_id(base_key, PHOTO_PROCESSOR, False)
      if data: return data, name
    a = base_key[0:2]; b=base_key[2:4]
    for u in (
      f"{OSS_HOST}/user/{a}/{b}/{base_key}.jpg",
      f"{OSS_HOST}/attachment/{a}/{b}/{base_key}.jpg",
      f"{OSS_HOST}/attachment/{base_key}.jpg",
    ):
      data,name = self.download(u)
      if data: return data, name
    return b"",""

  def get_chat(self, chat_id:int, instance_id:Optional[int]=None)->Optional[dict]:
    if instance_id:
      url = f"https://api.seiue.com/chalk/chat/instances/{instance_id}/chats/{chat_id}?expand=members,owner,discussion,members.reflection,members.reflection.pupil"
      r = self.s.get(url, timeout=30)
      if r.status_code == 200:
        return r.json()
    return None

  def get_chat_schedule_section(self, chat_id:int)->Optional[dict]:
    url = f"https://api.seiue.com/chalk/chat/chats/{chat_id}/schedule-section?expand=section_members,schedule,schedule.compere,section_members.reflection"
    r = self.s.get(url, timeout=30)
    if r.status_code==200:
      return r.json()
    return None

  def get_chat_form_answers(self, chat_id:int)->Optional[list]:
    url = f"https://api.seiue.com/form/chat/chat-form/{chat_id}/answers?paginated=0"
    r = self.s.get(url, timeout=30)
    if r.status_code==200:
      try: return r.json()
      except: return None
    return None

  def get_chat_form_template(self, template_id:int, instance_id:Optional[int]=None)->Optional[dict]:
    base = f"https://api.seiue.com/form/chat/chat-form-template?expand=form_template_fields&id={template_id}"
    if instance_id:
      base += f"&instance_id={instance_id}"
    r = self.s.get(base, timeout=30)
    if r.status_code==200:
      return r.json()
    return None

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
    if READ_FILTER=="unread": base["readed"]="false"
    return self._collect(base, pages)

  def _collect(self, base:dict, pages:int)->List[Dict[str,Any]]:
    items=[]
    for p in range(1, pages+1):
      q=dict(base, **{"page":str(p),"per_page":"20"})
      r=self._get_me(q)
      if r.status_code!=200: break
      try: j=r.json()
      except Exception: break
      arr=j["items"] if isinstance(j,dict) and "items" in j else (j if isinstance(j,list) else [])
      if not arr: break
      items.extend(arr)
    return items

def render_content(raw_json:str)->Tuple[str,List[Dict[str,Any]]]:
  try: raw=json.loads(raw_json or "{}")
  except: raw={}
  blocks=raw.get("blocks") or []; entity_map=raw.get("entityMap") or {}
  ents={}
  for k,v in (entity_map.items() if isinstance(entity_map,dict) else []):
    try: ents[int(k)]=v
    except: pass
  lines=[]; attachments=[]
  for blk in blocks:
    t=blk.get("text","") or ""
    line=esc(t)
    for er in blk.get("entityRanges") or []:
      key=er.get("key"); ent=ents.get(int(key)) if key is not None else None
      if not ent: continue
      et=(ent.get("type") or "").upper(); dat=(ent.get("data") or {})
      if et=="FILE":  attachments.append({"type":"file","name":dat.get("name") or "附件","size":dat.get("size") or "","url":dat.get("url") or ""})
      if et=="IMAGE": attachments.append({"type":"image","name":"image.jpg","size":"","url":dat.get("src") or ""})
    lines.append(line)
  while lines and not lines[-1].strip(): lines.pop()
  html_txt="\n\n".join([ln if ln.strip() else "​" for ln in lines])
  return html_txt, attachments

def classify(title:str, body_html:str)->Tuple[str,str]:
  z=(title or "")+"\n"+(body_html or "")
  PAIRS=[("leave","【請假】",["請假","请假","銷假","销假"]),
         ("attendance","【考勤】",["考勤","出勤","打卡","遲到","迟到","早退","缺勤","曠課","旷课"]),
         ("notice","【通知】",["通知","公告","告知","提醒"]),
         ("chat","【約談】",["約談","约谈","辅导","談話","谈话"])]
  for key, tag, kws in PAIRS:
    for k in kws:
      if k in z: return key, tag
  return "message","【消息】"

def _extract_flow_attachments(flow_data: Optional[dict]) -> List[Dict[str,str]]:
  atts = []
  if not flow_data:
    return atts
  for fv in flow_data.get("field_values") or []:
    fn = fv.get("field_name") or ""
    if "attachment" in fn:
      val = fv.get("value")
      if isinstance(val, list):
        for item in val:
          h = item.get("hash"); name = item.get("name") or "附件"
          if h: atts.append({"hash":h,"name":name})
  return atts

def _send_flow_attachments_download_first(tg:"Telegram", cli:"Seiue", flow_atts:List[Dict[str,str]]):
  for a in flow_atts:
    h = a["hash"]; name = a["name"]
    data, realname = cli.download_file_by_id(h, "quality-Q-75", True)
    if data:
      tg.send_doc(data, realname or name, f"請假附件：{esc(name)}")
    else:
      p1,p2=h[0:2],h[2:4]
      url = f"{OSS_HOST}/attachment/{p1}/{p2}/{h}.jpg"
      tg.send(f"📎 請假附件：{esc(name)}\n{url}")

def _send_attachments_from_content(tg:"Telegram", cli:"Seiue", it:Dict[str,Any])->None:
  _, atts = render_content(it.get("content") or "")
  for a in atts:
    url=a.get("url") or ""
    if not url: continue
    data,name = cli.download(url)
    if not data: continue
    if (a.get("type") or "").lower()=="image":
      tg.send_photo(data, "")
    else:
      tg.send_doc(data, a.get("name") or name, esc(a.get("name") or name))

def _maybe_download_attendance_avatar(tg:"Telegram", cli:"Seiue", attrs:dict):
  for key in ("student_id","pupil_id","owner_id","reflection_id"):
    v = attrs.get(key)
    if v and str(v).isdigit():
      stu = cli.get_student_detail(int(v))
      if stu:
        ph = stu.get("photo") or stu.get("avatar")
        if ph:
          data,name = cli.download_student_photo_like_client(ph)
          if data:
            tg.send_photo(data, "學生頭像")
            return
  name_str = attrs.get("student_name") or attrs.get("name") or ""
  if name_str:
    stu = cli.get_student_by_name(name_str.strip())
    if stu and (stu.get("photo") or stu.get("avatar")):
      data,name = cli.download_student_photo_like_client(stu.get("photo") or stu.get("avatar"))
      if data:
        tg.send_photo(data, "學生頭像")

def _format_detailed_leave_message(original: dict,
                                   flow_data: Optional[dict],
                                   absence_data: Optional[dict],
                                   flow_attachments: Optional[List[dict]] = None) -> str:
  title = original.get("title") or "收到一條請假抄送"
  student_name = "N/A"
  student_class = "N/A"
  student_ids: List[int] = []

  if absence_data:
    refs = absence_data.get("reflections") or []
    if refs:
      student_name = refs[0].get("name") or student_name
      sid = refs[0].get("id")
      if sid:
        student_ids.append(int(sid))
      cls = refs[0].get("admin_classes") or []
      if cls:
        student_class = cls[0]

  leave_type = (absence_data or {}).get("type") or "未知類型"
  raw_status = (absence_data or {}).get("status") or (flow_data or {}).get("status") or ""
  status_map = {"approved":"✅ 已批准","pending":"⏳ 審批中","rejected":"❌ 已駁回","revoked":"↩️ 已撤銷"}
  status = status_map.get(raw_status, raw_status or "—")

  time_lines = []
  if absence_data and (absence_data.get("ranges") or []):
    for r in absence_data.get("ranges") or []:
      s = r.get("start") or r.get("from") or ""
      e = r.get("end") or r.get("to") or ""
      if s or e:
        time_lines.append(f"{s} → {e}")
  time_block = "\n".join(time_lines) if time_lines else "—"
  duration = (absence_data or {}).get("formatted_minutes") or ""

  flow_lines = []
  if flow_data:
    nodes = flow_data.get("nodes") or []
    initiator = (flow_data.get("initiator") or {}).get("name") or "未知發起人"
    for node in nodes:
      label = node.get("node_label") or "節點"
      stg = node.get("stages") or []
      if not stg: continue
      st = stg[0]
      actor = (st.get("reflection") or {}).get("name") or "系統"
      st_status = st.get("status") or ""
      icon = {"approved":"✅","rejected":"❌","pending":"⏳"}.get(st_status, "➡️")
      reviewed_at = st.get("reviewed_at") or ""
      line = f"{icon} <b>{esc(label)}</b>: {esc(actor)}"
      if reviewed_at:
        line += f" ({fmt_time(reviewed_at)})"
      flow_lines.append(line)
    if flow_lines:
      flow_lines.insert(0, f"<b>審批流程</b>（由 {esc(initiator)} 發起）:")

  pub = fmt_time(original.get("published_at") or original.get("created_at") or "")

  msg = (
    f"📝 <b>{esc(title)}</b>\n\n"
    f"<b>學生</b>：{esc(student_name)}（{esc(student_class)}）\n"
    f"<b>類型</b>：{esc(leave_type)}　<b>狀態</b>：{esc(status)}\n"
    f"<b>時長</b>：{esc(duration)}\n"
    f"<b>時間</b>：\n{esc(time_block)}\n\n"
    f"{'\n'.join(flow_lines) if flow_lines else ''}\n\n"
    f"— 抄送於 {pub}"
  )
  if flow_attachments:
    msg += "\n<b>附件</b>："
    for a in flow_attachments:
      msg += f"\n• {esc(a.get('name') or '附件')}"
  original.setdefault("_extracted_student_ids", student_ids)
  return msg

def _send_fallback(tg:"Telegram", cli:"Seiue", it:Dict[str,Any], ch:str, prefix:str="", reason:str="")->bool:
  title = (it.get("title") or "") + reason
  content = it.get("content") or ""
  body, _ = render_content(content)
  attrs = it.get("attributes") or {}
  kind, tag = classify(title, body)
  src = sender_name(it)
  hdr = f"📩 <b>{'通知中心' if ch=='notice' else '系統消息'}</b>｜<b>{esc(src)}</b>\n"
  t = it.get("published_at") or it.get("created_at") or ""
  extra_lines=[]
  if (not body.strip()) and isinstance(attrs, dict) and attrs:
    pretty_keys=("course_name","lesson_name","student_name","class_name","semester_name","teacher_name","score","comment")
    for k in pretty_keys:
      v=attrs.get(k)
      if v: extra_lines.append(f"<b>{esc(k)}</b>：{esc(str(v))}")
    if not extra_lines:
      for i,(k,v) in enumerate(attrs.items()):
        if i>=5: break
        extra_lines.append(f"<b>{esc(str(k))}</b>：{esc(str(v))}")
  full_body = body
  if extra_lines:
    full_body = (body + "\n\n" if body else "") + "\n".join(extra_lines)
  msg = f"{hdr}\n{prefix}{tag}<b>{esc(title)}</b>\n\n{full_body}".rstrip()
  msg += f"\n\n— 發佈於 {fmt_time(t)}"
  ok = tg.send(msg)
  _send_attachments_from_content(tg, cli, it)
  return ok

def _send_chat_message(tg:"Telegram", cli:"Seiue", it:Dict[str,Any], ch:str, prefix:str="")->bool:
  attrs = it.get("attributes") or {}
  chat_id = attrs.get("chat_id") or attrs.get("id") or attrs.get("biz_id")
  instance_id = attrs.get("chat_instance_id") or attrs.get("instance_id") or attrs.get("biz_id")
  if not chat_id:
    return _send_fallback(tg, cli, it, ch, prefix, reason="")
  try: chat_id = int(str(chat_id))
  except: return _send_fallback(tg, cli, it, ch, prefix, reason="")
  sec = cli.get_chat_schedule_section(chat_id)
  answers = cli.get_chat_form_answers(chat_id) or []
  template = None
  if answers:
    template_id = None
    for ans in answers:
      tid = ans.get("form_template_id")
      if tid:
        template_id = tid; break
    if template_id:
      template = cli.get_chat_form_template(int(template_id), instance_id=instance_id)
  title = it.get("title") or (sec.get("title") if isinstance(sec, dict) else "") or "約談記錄"
  pub = fmt_time(it.get("published_at") or it.get("created_at") or "")
  student_name = ""
  student_id = 0
  place = ""
  time_span = ""
  raw_start = ""
  raw_end = ""
  raw_title = ""
  raw_content = ""
  raw_attachments = []
  raw_place_id = None
  raw_place_name = ""
  raw_pupil = None
  raw_members_wo_teacher = []
  if isinstance(sec, dict):
    schedule = sec.get("schedule") or {}
    place = sec.get("place_name") or schedule.get("place_name") or ""
    raw_place_name = place
    raw_place_id = sec.get("place_id") or schedule.get("place_id")

    st = sec.get("start_time") or schedule.get("start_time") or ""
    ed = sec.get("end_time") or schedule.get("end_time") or ""
    raw_start = st
    raw_end = ed
    time_span = f"{st} → {ed}" if st or ed else ""

    raw_title = sec.get("title") or schedule.get("title") or ""
    raw_content = sec.get("content") or schedule.get("content") or ""
    raw_attachments = sec.get("attachments") or schedule.get("attachments") or []
    raw_pupil = sec.get("pupil") or schedule.get("pupil")
    raw_members_wo_teacher = sec.get("members_without_teacher") or schedule.get("members_without_teacher") or []

    for m in (sec.get("section_members") or []):
      ref = m.get("reflection") or {}
      if (ref.get("role")=="student") or (ref.get("id") and ref.get("id") != cli.reflection):
        student_name = ref.get("name") or student_name
        student_id = ref.get("id") or student_id
        break
  answer_lines=[]
  attachment_hashes=[]
  if answers:
    for ans in answers:
      label = ans.get("label") or ""
      if label:
        answer_lines.append(f"<b>{esc(label)}</b>")
      attrs2 = ans.get("attributes")
      if attrs2 and isinstance(attrs2, dict):
        files = attrs2.get("files") or attrs2.get("attachments") or []
        if isinstance(files, list):
          for f in files:
            h = f.get("hash") or f.get("file_id")
            nm = f.get("name") or "附件"
            if h:
              attachment_hashes.append((h,nm))
  parts = []
  parts.append(f"🟠 <b>{esc(title)}</b>")
  if student_name:
    parts.append(f"<b>學生</b>：{esc(student_name)}")
  if time_span:
    parts.append(f"<b>時間</b>：{esc(time_span)}")
  if place:
    parts.append(f"<b>地點</b>：{esc(place)}")

  # ---- 補充原始約談字段（按需展示）----
  if raw_start or raw_end:
    parts.append(f"\"start_time\": \"{esc(raw_start)}\",")
    parts.append(f"\"end_time\": \"{esc(raw_end)}\",")
  if raw_title:
    parts.append(f"\"title\": \"{esc(raw_title)}\",")
  if raw_content is not None and str(raw_content).strip() != "":
    parts.append(f"\"content\": \"{esc(str(raw_content))}\",")

  try:
    parts.append(f"\"attachments\": {esc(json.dumps(raw_attachments, ensure_ascii=False))},")
  except Exception:
    parts.append(f"\"attachments\": [],")

  try:
    parts.append(f"\"place_id\": {esc(json.dumps(raw_place_id, ensure_ascii=False))},")
  except Exception:
    parts.append(f"\"place_id\": null,")

  if raw_place_name:
    parts.append(f"\"place_name\": \"{esc(raw_place_name)}\",")

  if raw_pupil is not None:
    try:
      parts.append(f"\"pupil\": {esc(json.dumps(raw_pupil, ensure_ascii=False))},")
    except Exception:
      parts.append(f"\"pupil\": {{}},")

  if raw_members_wo_teacher:
    try:
      parts.append(f"\"members_without_teacher\": {esc(json.dumps(raw_members_wo_teacher, ensure_ascii=False))},")
    except Exception:
      parts.append(f"\"members_without_teacher\": [],")

  if answer_lines:
    parts.append("\n".join(answer_lines))
  parts.append(f"— 約談於 {pub}")
  msg = "\n".join(parts)
  if prefix:
    msg = f"{prefix}\n{msg}"
  ok = tg.send(msg)
  if student_id:
    stu = cli.get_student_detail(int(student_id))
    if stu:
      key = stu.get("photo") or stu.get("avatar")
      if key:
        data,name = cli.download_student_photo_like_client(key)
        if data:
          tg.send_photo(data, "學生頭像")
  if CHAT_DOWNLOAD_ATTACH and attachment_hashes:
    for h, nm in attachment_hashes:
      data, realname = cli.download_file_by_id(h, "quality-Q-75", True)
      if data:
        tg.send_doc(data, realname or nm, f"約談附件：{esc(nm)}")
      else:
        p1,p2=h[0:2],h[2:4]
        url = f"{OSS_HOST}/attachment/{p1}/{p2}/{h}.jpg"
        tg.send(f"📎 約談附件：{esc(nm)}\n{url}")
  return ok

# ========== 新增：德育/評價通知處理 ==========
def _send_assessment_message(tg:"Telegram", cli:"Seiue", it:Dict[str,Any], ch:str, prefix:str="") -> bool:
  attrs = it.get("attributes") or {}
  assessment_id = (
      attrs.get("assessment_id")
      or attrs.get("vnas_assessment_id")
      or attrs.get("assessmentId")
  )
  item_id = (
      attrs.get("item_id")
      or attrs.get("vnas_item_id")
      or attrs.get("itemId")
  )
  owner_id = (
      attrs.get("owner_id")
      or attrs.get("reflection_id")
      or attrs.get("student_id")
      or attrs.get("ownerId")
  )
  op_type = attrs.get("operation_type") or "moral"

  if not (assessment_id and item_id and owner_id):
    return _send_fallback(tg, cli, it, ch, prefix, reason="")

  assessment = None
  try:
    url_ass = f"https://api.seiue.com/vnas/common/assessments/{assessment_id}?expand=items,plan&operation_type={op_type}&policy=evaluated"
    r = cli.s.get(url_ass, timeout=30)
    if r.status_code == 200:
      assessment = r.json()
  except Exception as e:
    logging.warning("fetch assessment %s failed: %s", assessment_id, e)

  score_detail = []
  try:
    url_item = (
      f"https://api.seiue.com/vnas/common/items/{item_id}/score-details"
      f"?expand=item,evaluator&operation_type={op_type}"
      f"&owner_id={owner_id}&paginated=0&policy=evaluated"
    )
    r2 = cli.s.get(url_item, timeout=30)
    if r2.status_code == 200:
      score_detail = r2.json()
  except Exception as e:
    logging.warning("fetch score details failed: %s", e)

  latest = None
  if isinstance(score_detail, list) and score_detail:
    latest = max(
      score_detail,
      key=lambda d: d.get("created_at") or d.get("updated_at") or ""
    )

  student_name = ""
  student_class = ""
  try:
    if str(owner_id).isdigit():
      stu = cli.get_student_detail(int(owner_id))
      if stu:
        student_name = stu.get("name") or ""
        ac = stu.get("admin_classes") or []
        if isinstance(ac, list) and ac:
          student_class = ac[0]
  except Exception:
    pass

  title = it.get("title") or "评价已发布"
  pub = fmt_time(it.get("published_at") or it.get("created_at") or "")
  assess_name = (assessment or {}).get("name") or ""
  item_name = ""
  item_desc = ""
  if latest and latest.get("item"):
    item_name = latest["item"].get("name") or ""
    item_desc = latest["item"].get("description") or ""
  score_val = ""
  tag_val = ""
  evaluator_name = ""
  if latest:
    score_val = latest.get("score") or latest.get("gained_score") or ""
    tag_val = latest.get("tag") or ""
    ev = latest.get("evaluator") or {}
    evaluator_name = ev.get("name") or ""

  parts = []
  parts.append(f"🟡 <b>{esc(title)}</b>")
  if assess_name:
    parts.append(f"<b>評價標題</b>：{esc(assess_name)}")
  if item_name:
    parts.append(f"<b>評價項目</b>：{esc(item_name)}")
  if student_name:
    if student_class:
      parts.append(f"<b>對象</b>：{esc(student_name)}（{esc(student_class)}）")
    else:
      parts.append(f"<b>對象</b>：{esc(student_name)}")
  if score_val:
    parts.append(f"<b>得分/變動</b>：{esc(str(score_val))}")
  if tag_val:
    parts.append(f"<b>標籤</b>：{esc(tag_val)}")
  if evaluator_name:
    parts.append(f"<b>評價人</b>：{esc(evaluator_name)}")
  if item_desc:
    short_desc = item_desc.strip()
    if len(short_desc) > 200:
      short_desc = short_desc[:200] + "…"
    parts.append(f"<b>說明</b>：{esc(short_desc)}")

  parts.append(f"— 發佈於 {pub}")

  msg = "\n".join(parts)
  if prefix:
    msg = f"{prefix}\n{msg}"

  ok = tg.send(msg)

  if str(owner_id).isdigit():
    stu = cli.get_student_detail(int(owner_id))
    if stu:
      key = stu.get("photo") or stu.get("avatar")
      if key:
        data, _ = cli.download_student_photo_like_client(key)
        if data:
          tg.send_photo(data, "學生頭像")

  return ok

def send_one(tg:"Telegram", cli:"Seiue", it:Dict[str,Any], ch:str, prefix:str="")->bool:
  domain = it.get("domain") or ""
  msg_type = it.get("type") or ""
  attrs = it.get("attributes") or {}
  title = it.get("title") or ""

  # 請假
  if domain == "leave_flow" and msg_type == "absence.flow_cc_node":
    flow_id = attrs.get("flow_id")
    absence_id = attrs.get("absence_id")
    try:
      flow_data = cli.s.get(f"https://api.seiue.com/form/workflow/flows/{flow_id}?expand=initiator,nodes,nodes.stages,nodes.stages.reflection,field_values", timeout=30).json() if flow_id else None
    except Exception:
      flow_data = None
    try:
      abs_data = cli.s.get(f"https://api.seiue.com/sams/absence/absences/{absence_id}?expand=reflections,reflections.guardians,reflections.grade", timeout=30).json() if absence_id else None
    except Exception:
      abs_data = None
    flow_atts = _extract_flow_attachments(flow_data)
    html_msg = _format_detailed_leave_message(it, flow_data, abs_data, flow_atts)
    if prefix: html_msg = f"{prefix}\n{html_msg}"
    ok = tg.send(html_msg)
    if flow_atts:
      _send_flow_attachments_download_first(tg, cli, flow_atts)
    student_ids = it.get("_extracted_student_ids") or []
    if isinstance(student_ids, list) and student_ids:
      for sid in student_ids:
        stu = cli.get_student_detail(int(sid))
        if stu:
          key = stu.get("photo") or stu.get("avatar") or ""
          if key:
            data,name = cli.download_student_photo_like_client(key)
            if data:
              tg.send_photo(data, "學生頭像")
              break
    return ok

  # 考勤
  if domain == "attendance" and msg_type == "abnormal_attendance.guardian":
    html_msg = (
      f"🟣 <b>{esc(it.get('title') or '考勤結果')}</b>\n\n"
      f"{esc((it.get('content') or '')[:180])}\n\n"
      f"— 通知於 {fmt_time(it.get('published_at') or it.get('created_at') or '')}"
    )
    if prefix: html_msg = f"{prefix}\n{html_msg}"
    ok = tg.send(html_msg)
    _maybe_download_attendance_avatar(tg, cli, attrs)
    _send_attachments_from_content(tg, cli, it)
    return ok

  # 約談 / chat
  if domain == "chat" or "chat" in (msg_type or "") or any(k in attrs for k in ("chat_id","chat_instance_id")):
    return _send_chat_message(tg, cli, it, ch, prefix)

  # 德育/評價已發布
  if (
    "评价已发布" in title
    or "评价已發布" in title
    or attrs.get("operation_type") == "moral"
    or ("assessment_id" in attrs and "item_id" in attrs)
  ):
    return _send_assessment_message(tg, cli, it, ch, prefix)

  # 其他走兜底
  return _send_fallback(tg, cli, it, ch, prefix)

def latest_of_channel(cli:"Seiue", ch:str)->Optional[Dict[str,Any]]:
  arr = cli.list_notice(1) if ch=="notice" else cli.list_system(1)
  return arr[0] if arr else None

def ensure_startup_watermark(cli:"Seiue"):
  st=load_state(); changed=False
  for ch in ("system","notice"):
    w=st["watermark"][ch]; last_ts=float(w.get("ts") or 0.0)
    if FAST_FORWARD_ON_START or last_ts==0.0:
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

def list_increment_dual(cli:"Seiue")->List[Tuple[str,Dict[str,Any],float,int]]:
  st=load_state(); pending=[]
  for ch in ("system","notice"):
    w=st["watermark"][ch]
    last_ts=float(w.get("ts") or 0.0); last_id=int(w.get("id") or 0)
    arr = cli.list_system(MAX_LIST_PAGES) if ch=="system" else cli.list_notice(MAX_LIST_PAGES)
    for it in arr:
      t=it.get("published_at") or it.get("created_at") or ""
      ts=parse_ts(t) if t else 0.0
      try: nid=int(str(it.get("id") or it.get("_id") or "0").strip())
      except: nid=0
      if last_ts and (ts<last_ts or (ts==last_ts and nid<=last_id)):
        continue
      pending.append((ch,it,ts,nid))
  pending.sort(key=lambda x:(x[2], x[3])); return pending

def main_loop():
  if not (SEIUE_USERNAME and SEIUE_PASSWORD and TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID):
    print("缺少必要環境變量。", file=sys.stderr); sys.exit(1)
  _lock=acquire_lock_or_exit()
  tg=Telegram(TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID)
  cli=Seiue(SEIUE_USERNAME, SEIUE_PASSWORD)
  if not cli.login(): print("Seiue 登錄失敗", file=sys.stderr); sys.exit(2)
  ensure_startup_watermark(cli)

  if SEND_TEST_ON_START:
    tg.send(f"🧪 安裝驗證｜{os.getenv('SIDE_VERSION','v2.5.9-assessment')}｜啟動完成。")

  print(f"{datetime.now().strftime('%F %T')} 開始輪詢（notice+system），每 {POLL_SECONDS}s，頁數<= {MAX_LIST_PAGES}，版本={os.getenv('SIDE_VERSION','v2.5.9-assessment')}")
  while True:
    try:
      st=load_state()
      pending=list_increment_dual(cli)
      for ch,it,ts,nid in pending:
        gkey = global_key(it)
        if gkey in st["seen_global"]:
          continue
        if ts < HARD_CUTOFF_TS:
          st["seen_global"][gkey]=ts
          wm=st["watermark"][ch]
          if ts>wm["ts"] or (ts==wm["ts"] and nid>wm["id"]): wm["ts"]=ts; wm["id"]=nid
          save_state(st); continue
        sDup = f"soft:{sender_name(it)}|{it.get('title') or ''}|{int(ts//SOFT_DUP_WINDOW_SECS)}"
        if sDup in st["seen_global"]:
          continue
        ok=send_one(tg, cli, it, ch)
        if ok:
          st["seen_global"][gkey]=ts
          st["seen_global"][sDup]=ts
          if len(st["seen_global"]) > 24000:
            oldest = sorted(st["seen_global"].items(), key=lambda kv: kv[1])[:6000]
            for k,_ in oldest: st["seen_global"].pop(k, None)
          wm=st["watermark"][ch]
          if ts>wm["ts"] or (ts==wm["ts"] and nid>wm["id"]): wm["ts"]=ts; wm["id"]=nid
          save_state(st)
      time.sleep(POLL_SECONDS)
    except KeyboardInterrupt:
      print(f"{datetime.now().strftime('%F %T')} 收到中斷，退出"); break
    except Exception as e:
      logging.error("loop error: %s", e, exc_info=True); time.sleep(3)

if __name__=="__main__":
  os.environ["SIDE_VERSION"] = "v2.5.9-assessment"
  main_loop()
PY
  chmod 755 "$PY_SCRIPT"
}

write_service(){
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Seiue → Telegram notifier (${SIDE_VERSION})
After=network-online.target
Wants=network-online.target

[Service]
User=root
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
Environment=PYTHONUNBUFFERED=1
Environment=SIDE_VERSION=${SIDE_VERSION}
ExecStartPre=-/usr/bin/pkill -TERM -f seiue_notify.py
ExecStartPre=-/usr/bin/pkill -KILL -f seiue_notify.py
ExecStartPre=-/usr/bin/rm -f ${INSTALL_DIR}/.notify.lock
ExecStart=${VENV_DIR}/bin/python3 -u ${PY_SCRIPT}
Restart=always
RestartSec=5s
StandardOutput=append:${OUT_LOG}
StandardError=append:${ERR_LOG}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

start_service(){
  mkdir -p "$LOG_DIR"; touch "$OUT_LOG" "$ERR_LOG"
  systemctl enable --now seiue-notify
}

info "開始安裝 ${SIDE_VERSION} …"
preflight
ensure_dirs
cleanup_legacy
collect_env_if_needed
ensure_env_defaults
setup_venv
write_python
write_service
info "重啟服務…"
systemctl restart seiue-notify || true
success "已安裝/升級為 ${SIDE_VERSION}"

echo
echo "=== systemctl status（前30行） ==="
systemctl status seiue-notify --no-pager -l | sed -n '1,30p' || true

echo
echo "=== 最近日誌（120行） ==="
journalctl -u seiue-notify -n 120 --no-pager -l || true

echo
echo "完成。現在到 Telegram 看有沒有一條「🧪 安裝驗證｜${SIDE_VERSION}｜…」的消息。"