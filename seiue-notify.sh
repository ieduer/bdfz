cat >/root/seiue-notify.sh <<'SH'
#!/usr/bin/env bash
# Seiue Notification → Telegram - Zero-Arg Installer/Runner
# v2.4.4-fix + notice 分派增強版（修正 systemd 反斜線）
# 變更重點：
# - 100% 強制覆寫 systemd unit（去掉舊版的 "|| true"；用 '-' 前綴忽略不存在進程）
# - 維持「三斬」：雙 pkill + 禁用 run.sh + 清鎖
# - 服務固定使用 /root/.seiue-notify 路徑與 User=root，避免大小寫/家目錄差異
# - 默認「防歷史」：FAST_FORWARD + HARD_CUTOFF + SOFT_DUP；READ_FILTER=unread
# - 【請假】可根據 flow_id/absence_id 打 API 做卡片化
# - 【考勤】guardian 異常通知專門格式化
# - 附件/圖片跟發
# - 啟動時發🧪驗證且不回刷

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
  # 原來這裡是 'python.*seiue_notify\.py'，systemd 會念反斜線，我們 bash 這裡也順便拿掉
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

# 反歷史 + 去重策略（可改）：
FAST_FORWARD_ON_START=1
HARD_CUTOFF_MINUTES=360
SOFT_DUP_WINDOW_SECS=1800
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
    import fcntl as _fcntl
    _fcntl.flock(fd, _fcntl.LOCK_EX|_fcntl.LOCK_NB); os.ftruncate(fd,0); os.write(fd, str(os.getpid()).encode()); return fd
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
        import re as _re
        m = _re.search(r'"access_token"\s*:\s*"([^"]+)"', txt)
        n = _re.search(r'"active_reflection_id"\s*:\s*"?(\d+)"?', txt)
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

  # 通用 API + 請假相關
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
    url = f"https://api.seiue.com/form/workflow/flows/{flow_id}?expand=initiator,nodes,nodes.stages,nodes.stages.reflection"
    return self._get_api(url)

  def get_absence_by_id(self, absence_id: int) -> Optional[dict]:
    url = f"https://api.seiue.com/sams/absence/absences/{absence_id}?expand=reflections,reflections.guardians,reflections.grade"
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

def classify(title:str, body_html:str)->Tuple[str,str]:
  z=(title or "")+"\n"+(body_html or "")
  PAIRS=[("leave","【請假】",["請假","请假","銷假","销假"]),
         ("attendance","【考勤】",["考勤","出勤","打卡","遲到","迟到","早退","缺勤","曠課","旷课"]),
         ("evaluation","【評價】",["評價","评价","德育","已發布評價","已发布评价"]),
         ("notice","【通知】",["通知","公告","告知","提醒"])]
  for key, tag, kws in PAIRS:
    for k in kws:
      if k in z: return key, tag
  return "message","【消息】"

def is_leave(title: str, body_html: str) -> bool:
  z = (title or "") + "\n" + (body_html or "")
  return any(k in z for k in ("請假","请假","銷假","销假"))

def extract_leave_details(text: str) -> dict:
  import html as _html
  tx = _html.unescape(re.sub(r"<[^>]+>", "", text or ""))
  d = {}
  m = re.search(r"(?:申請人|申请人|学生|學生|家長|家长)[:：]\s*([^\s，,。]+)", tx)
  if m: d["applicant"] = m.group(1)
  m = re.search(r"(?:請假時間|请假时间|時間|时间)[:：]\s*([0-9/\- :]{5,})\s*(?:至|到|—|-)\s*([0-9/\- :]{5,})", tx)
  if m: d["from"], d["to"] = m.group(1), m.group(2)
  m = re.search(r"(?:事由|原因|请假事由|請假事由)[:：]\s*(.+?)(?:\n|$)", tx)
  if m: d["reason"] = m.group(1).strip()
  m = re.search(r"(?:狀態|状态)[:：]\s*([^\s，,。]+)", tx)
  if m: d["status"] = m.group(1)
  return d

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
  m = re.search(r"(?:班級|班级|班|課程|课程|科目|教學班|教学班)[:：]?\s*([^\s，,。]+)", body_txt)
  if m: lines.insert(0, f"班級/課程：{esc(m.group(1))}")
  m = re.search(r"(\d{4}-\d{1,2}-\d{1,2}\s*\d{1,2}:\d{2})\s*(?:至|到|—|-)\s*(\d{1,2}:\d{2}|\d{4}-\d{1,2}-\d{1,2}\s*\d{1,2}:\d{2})", body_txt)
  if m: lines.insert(1, f"時段：{esc(m.group(1))} ～ {esc(m.group(2))}")
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

def list_increment_dual(cli:"Seiue")->List[Tuple[str,Dict[str,Any],float,int]]:
  st=load_state(); pending=[]
  for ch in ("system","notice"):
    w=st["watermark"][ch]; last_ts=float(w.get("ts") or 0.0); last_id=int(w.get("id") or 0)
    arr = cli.list_system(MAX_LIST_PAGES) if ch=="system" else cli.list_notice(MAX_LIST_PAGES)
    for it in arr:
      t=it.get("published_at") or it.get("created_at") or ""; ts=parse_ts(t) if t else 0.0
      try: nid=int(str(it.get("id") or "0"))
      except: nid=0
      if last_ts and (ts<last_ts or (ts==last_ts and nid<=last_id)):
        continue
      pending.append((ch,it,ts,nid))
  pending.sort(key=lambda x:(x[2], x[3])); return pending

def _format_detailed_leave_message(original: dict,
                                   flow_data: Optional[dict],
                                   absence_data: Optional[dict]) -> str:
  title = original.get("title") or "收到一條請假抄送"
  student_name = "N/A"
  student_class = "N/A"
  if absence_data:
    refs = absence_data.get("reflections") or []
    if refs:
      student_name = refs[0].get("name") or student_name
      cls = refs[0].get("admin_classes") or []
      if cls: student_class = cls[0]
  leave_type = (absence_data or {}).get("type") or "未知類型"
  raw_status = (absence_data or {}).get("status") or ""
  status_map = {"approved":"✅ 已批准","pending":"⏳ 審批中","rejected":"❌ 已駁回","revoked":"↩️ 已撤銷"}
  status = status_map.get(raw_status, raw_status or "—")
  reason = (absence_data or {}).get("reason") or "未填寫事由"

  time_lines = []
  for r in (absence_data or {}).get("ranges") or []:
    s = r.get("start") or r.get("from") or r.get("begin_at") or ""
    e = r.get("end")   or r.get("to")   or r.get("end_at")   or ""
    if s or e:
      time_lines.append(f"{s} → {e}")
  time_block = "\n".join(time_lines) if time_lines else "—"
  duration = (absence_data or {}).get("formatted_minutes") or ""

  flow_lines = []
  flow_hdr = ""
  if flow_data:
    initiator = (flow_data.get("initiator") or {}).get("name") or "未知發起人"
    nodes = flow_data.get("nodes") or []
    for node in nodes:
      label = node.get("node_label") or "節點"
      stages = node.get("stages") or []
      if stages:
        st = stages[0]
        actor = (st.get("reflection") or {}).get("name") or "系統"
        st_status = st.get("status") or ""
        icon = {"approved":"✅","rejected":"❌","pending":"⏳"}.get(st_status, "➡️")
        reviewed_at = st.get("reviewed_at") or ""
        line = f"{icon} <b>{esc(label)}</b>: {esc(actor)}"
        if reviewed_at:
          line += f" <i>({fmt_time(reviewed_at)})</i>"
        flow_lines.append(line)
    flow_hdr = f"<b>審批流程</b>（由 {esc(initiator)} 發起）:\n" if flow_lines else ""

  pub = fmt_time(original.get("published_at") or original.get("created_at") or "")

  msg = (
    f"📝 <b>{esc(title)}</b>\n\n"
    f"<b>學生</b>：{esc(student_name)}（{esc(student_class)}）\n"
    f"<b>類型</b>：{esc(leave_type)}　<b>狀態</b>：{esc(status)}\n"
    f"<b>時長</b>：{esc(duration)}\n"
    f"<b>時間</b>：\n{esc(time_block)}\n\n"
    f"<b>事由</b>：\n{esc(reason)}\n\n"
    f"{flow_hdr}{'\n'.join(flow_lines) if flow_lines else ''}\n\n"
    f"— 抄送於 {pub}"
  )
  return msg

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
  lesson_name = attrs.get("lesson_name") or attrs.get("class_full_name") or ""
  result = attrs.get("result") or ""
  pub = fmt_time(original.get("published_at") or original.get("created_at") or "")
  title = original.get("title") or "考勤結果通知"
  return (
    f"🟣 <b>{esc(title)}</b>\n\n"
    f"<b>學生</b>：{esc(name)} {esc(grade)} {esc(klass)}\n"
    f"<b>日期/節次</b>：{esc(lesson_date)} {esc(lesson_name)}\n"
    f"<b>結果</b>：{esc(result)}\n\n"
    f"— 通知於 {pub}"
  )

def _send_attachments(tg:"Telegram", cli:"Seiue", it:Dict[str,Any])->None:
  _, atts = render_content(it.get("content") or "")
  imgs = [a for a in atts if a.get("type")=="image" and a.get("url")]
  fils = [a for a in atts if a.get("type")=="file" and a.get("url")]
  for a in imgs:
    data,_ = cli.download(a["url"])
    if data: tg.send_photo(data, "")
  for a in fils:
    data,name = cli.download(a["url"])
    if data:
      cap = f"📎 <b>{esc(a.get('name') or name)}</b>"
      if a.get("size"): cap += f"（{esc(a['size'])}）"
      tg.send_doc(data, (a.get("name") or name), cap)

def _send_fallback(tg:"Telegram", cli:"Seiue", it:Dict[str,Any], ch:str, prefix:str="", reason:str="")->bool:
  title = (it.get("title") or "") + reason
  content = it.get("content") or ""
  body, _ = render_content(content)
  kind, tag = classify(title, body)
  src = sender_name(it)

  summary = ""
  custom_prefix = ""
  if ch == "system" and is_leave(title, body) and (bool(it.get("is_cc")) or str(it.get("is_cc")).lower()=="true"):
    det = extract_leave_details(body)
    parts=[]
    if det.get("applicant"): parts.append(f"申請人：{esc(det['applicant'])}")
    if det.get("from") and det.get("to"): parts.append(f"時段：{esc(det['from'])} ～ {esc(det['to'])}")
    if det.get("reason"): parts.append(f"事由：{esc(det['reason'])}")
    if det.get("status"): parts.append(f"狀態：{esc(det['status'])}")
    if parts:
      summary = "\n".join(parts) + "\n\n"
      custom_prefix = "【請假】收到一條請假抄送\n"

  if kind == "attendance":
    att = extract_attendance_summary(it)
    if att: summary = att + "\n\n" + summary

  hdr = f"📩 <b>{'通知中心' if ch=='notice' else '系統消息'}</b>｜<b>{esc(src)}</b>\n"
  t = it.get("published_at") or it.get("created_at") or ""
  prefix_text = custom_prefix if custom_prefix else tag
  msg = f"{hdr}\n{prefix}{prefix_text}<b>{esc(title)}</b>\n\n{summary}{body}".rstrip()
  msg += f"\n\n— 發佈於 {fmt_time(t)}"

  ok = tg.send(msg)
  _send_attachments(tg, cli, it)
  return ok

def send_one(tg:"Telegram", cli:"Seiue", it:Dict[str,Any], ch:str, prefix:str="")->bool:
  domain = it.get("domain") or ""
  msg_type = it.get("type") or ""
  attrs = it.get("attributes") or {}

  if domain == "leave_flow" and msg_type == "absence.flow_cc_node":
    flow_id = attrs.get("flow_id")
    absence_id = attrs.get("absence_id")
    try:
      flow_data = cli.get_flow_details(int(flow_id)) if flow_id else None
      abs_data = cli.get_absence_by_id(int(absence_id)) if absence_id else None
      if flow_data or abs_data:
        html_msg = _format_detailed_leave_message(it, flow_data, abs_data)
        if prefix: html_msg = f"{prefix}\n{html_msg}"
        ok = tg.send(html_msg)
        _send_attachments(tg, cli, it)
        return ok
    except Exception as e:
      logging.error("leave_flow enhanced failed: %s", e, exc_info=True)
      return _send_fallback(tg, cli, it, ch, prefix, " (請假詳情失敗)")

  if domain == "task" and msg_type == "task.discussion_replied":
    html_msg = _format_discussion_notice(it)
    if prefix: html_msg = f"{prefix}\n{html_msg}"
    ok = tg.send(html_msg)
    _send_attachments(tg, cli, it)
    return ok

  if domain == "attendance" and msg_type == "abnormal_attendance.guardian":
    html_msg = _format_attendance_notice(it)
    if prefix: html_msg = f"{prefix}\n{html_msg}"
    ok = tg.send(html_msg)
    _send_attachments(tg, cli, it)
    return ok

  return _send_fallback(tg, cli, it, ch, prefix)

def main_loop():
  if not (SEIUE_USERNAME and SEIUE_PASSWORD and TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID):
    print("缺少必要環境變量。", file=sys.stderr); sys.exit(1)
  _lock=acquire_lock_or_exit()
  tg=Telegram(TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID)
  cli=Seiue(SEIUE_USERNAME, SEIUE_PASSWORD)
  if not cli.login(): print("Seiue 登錄失敗", file=sys.stderr); sys.exit(2)
  ensure_startup_watermark(cli)

  if SEND_TEST_ON_START:
    st = load_state()
    for ch in ("system","notice"):
      it=latest_of_channel(cli, ch)
      if it:
        try: send_one(tg, cli, it, ch, prefix="🧪 <b>安裝驗證</b>｜")
        except Exception as e: logging.error("test send error(%s): %s", ch, e)
        t = it.get("published_at") or it.get("created_at") or ""
        st["seen_global"][global_key(it)] = parse_ts(t) or time.time()
    save_state(st)

  print(f"{datetime.now().strftime('%F %T')} 開始輪詢（notice+system，全量直推），每 {POLL_SECONDS}s，頁數<= {MAX_LIST_PAGES}")
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
          save_state(st)
          continue
        sKey = soft_dup_key(it, ts)
        if sKey in st["seen_global"]:
          continue

        ok=send_one(tg, cli, it, ch)
        if ok:
          st["seen_global"][gkey]=ts
          st["seen_global"][sKey]=ts
          if len(st["seen_global"]) > 22000:
            oldest = sorted(st["seen_global"].items(), key=lambda kv: kv[1])[:6000]
            for k, _ in oldest: st["seen_global"].pop(k, None)
          wm=st["watermark"][ch]
          if ts>wm["ts"] or (ts==wm["ts"] and nid>wm["id"]): wm["ts"]=ts; wm["id"]=nid
          save_state(st)
      time.sleep(POLL_SECONDS)
    except KeyboardInterrupt:
      print(f"{datetime.now().strftime('%F %T')} 收到中斷，退出"); break
    except Exception as e:
      logging.error("loop error: %s", e); time.sleep(3)

if __name__=="__main__": main_loop()
PY
  chmod 755 "$PY_SCRIPT"
}

write_service(){
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Seiue → Telegram notifier (dual-channel; global dedup; single-instance)
After=network-online.target
Wants=network-online.target

[Service]
User=root
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
Environment=PYTHONUNBUFFERED=1

# —— 三斬（正確 systemd 寫法；用 '-' 忽略失敗）——
# 注意：這裡全部拿掉反斜線，systemd 就不會再說 Ignoring unknown escape sequences
ExecStartPre=-/usr/bin/pkill -TERM -f seiue_notify.py
ExecStartPre=-/usr/bin/pkill -KILL -f seiue_notify.py
ExecStartPre=-/usr/bin/pkill -f run.sh
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
  if grep -q "|| true" "$UNIT_FILE"; then
    echo "ERROR: unit 仍含 || true，請回報。"
    exit 17
  fi
}

start_service(){
  mkdir -p "$LOG_DIR"; touch "$OUT_LOG" "$ERR_LOG"
  systemctl enable --now seiue-notify
}

info "Seiue sidecar v2.4.4-fix（單實例“三斬”＋防歷史＋雙通道＋去重＋請假/討論/考勤分派）"
preflight
ensure_dirs
cleanup_legacy
collect_env_if_needed
ensure_env_defaults
setup_venv
write_python
write_service
systemctl restart seiue-notify || true
success "已安裝/升級並啟動。"

echo
echo "=== 快速驗證 ==="
echo "1) systemctl status："
systemctl status seiue-notify --no-pager -l | sed -n '1,25p' || true
echo
echo "2) 只允許單實例："
# 這裡也順手換成不帶反斜線的
pgrep -fa 'python.*seiue_notify.py' || echo '尚未啟動'
echo
echo "3) 關鍵日誌（Auth/水位/錯誤）："
journalctl -u seiue-notify -n 120 --no-pager -o cat | egrep -i 'Auth OK|fast-forward|loop error|send error|authorize missing|login error' || true
SH