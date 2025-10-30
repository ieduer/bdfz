# 寫入並執行（Linux/macOS 皆可；需 root）
cat >/root/seiue-notify.sh <<'SH'
#!/usr/bin/env bash
# Seiue Notification → Telegram - Zero-Arg Installer/Runner
# v2.2.1  (dual-channel: notice + system; push-all; watermark + global dedup; send test-on-start)
# Usage: sudo bash ./seiue-notify.sh
set -euo pipefail

# ---------- pretty ----------
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'
info(){ echo -e "${C_BLUE}INFO:${C_RESET} $1"; }
success(){ echo -e "${C_GREEN}SUCCESS:${C_RESET} $1"; }
warn(){ echo -e "${C_YELLOW}WARNING:${C_RESET} $1"; }
error(){ echo -e "${C_RED}ERROR:${C_RESET} $1" >&2; }

# ---------- platform ----------
OS="$(uname -s || true)"; IS_LINUX=0; IS_DARWIN=0
[ "$OS" = "Linux" ] && IS_LINUX=1
[ "$OS" = "Darwin" ] && IS_DARWIN=1
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "需要 root 權限。使用 sudo 重新執行…"
  exec sudo -E bash "$0" "$@"
fi

REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo ~"$REAL_USER")
INSTALL_DIR="${REAL_HOME}/.seiue-notify"
VENV_DIR="${INSTALL_DIR}/venv"
PY_SCRIPT="${INSTALL_DIR}/seiue_notify.py"
ENV_FILE="${INSTALL_DIR}/.env"
LOG_DIR="${INSTALL_DIR}/logs"
OUT_LOG="${LOG_DIR}/notify.out.log"
ERR_LOG="${LOG_DIR}/notify.err.log"
UNIT_NAME="seiue-notify"

# 代理透傳（如需）
PROXY_ENV="$(env | grep -i -E '^(http_proxy|https_proxy|no_proxy|HTTP_PROXY|HTTPS_PROXY|NO_PROXY)=' || true)"

need_cmd(){ command -v "$1" >/dev/null 2>&1; }
ensure_dirs(){ mkdir -p "$INSTALL_DIR" "$LOG_DIR"; chown -R "$REAL_USER:$(id -gn "$REAL_USER")" "$INSTALL_DIR"; }

preflight(){
  info "環境預檢…"
  if ! need_cmd python3; then
    warn "未發現 python3，嘗試安裝…"
    if need_cmd apt-get; then apt-get update -y && apt-get install -y python3 python3-venv python3-pip || true; fi
    if need_cmd yum; then yum install -y python3 python3-pip || true; fi
    if [ $IS_DARWIN -eq 1 ] && need_cmd brew; then brew install python || true; fi
  fi
  need_cmd python3 || { error "仍未找到 python3"; exit 1; }
  success "預檢通過。"
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
READ_FILTER=all           # all|unread
INCLUDE_CC=false          # 是否包含抄送
SKIP_HISTORY_ON_FIRST_RUN=1
TELEGRAM_MIN_INTERVAL_SECS=1.5
NOTICE_EXCLUDE_NOISE=0    # 0=不排除任何類型，通知中心“全量直推”
SEND_TEST_ON_START=1      # 啟動後各通道自發最新1條作為安裝驗證
EOF
  chmod 600 "$ENV_FILE"; chown "$REAL_USER:$(id -gn "$REAL_USER")" "$ENV_FILE"
}

setup_venv(){
  ensure_dirs
  local PYBIN="$(command -v python3)"
  if ! "$PYBIN" -c 'import ensurepip' >/dev/null 2>&1; then
    if need_cmd apt-get; then apt-get update -y && apt-get install -y python3-venv || true; fi
  fi
  su - "$REAL_USER" -c "$PYBIN -m venv '$VENV_DIR'" || true
  su - "$REAL_USER" -c "env ${PROXY_ENV} '$VENV_DIR/bin/python' -m pip install -U pip >/dev/null 2>&1" || true
  info "安裝/升級依賴…"
  su - "$REAL_USER" -c "env ${PROXY_ENV} '$VENV_DIR/bin/python' -m pip install -q requests pytz urllib3"
}

write_python(){
  cat >"$PY_SCRIPT" <<'PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, sys, time, json, html, fcntl, logging
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

# 環境變量
SEIUE_USERNAME = os.getenv("SEIUE_USERNAME","")
SEIUE_PASSWORD = os.getenv("SEIUE_PASSWORD","")
X_SCHOOL_ID = os.getenv("X_SCHOOL_ID","3")
X_ROLE = os.getenv("X_ROLE","teacher")
TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN","")
TELEGRAM_CHAT_ID   = os.getenv("TELEGRAM_CHAT_ID","")
POLL_SECONDS = int(os.getenv("NOTIFY_POLL_SECONDS","90") or "90")
MAX_LIST_PAGES = max(1, min(int(os.getenv("MAX_LIST_PAGES","10") or "10"), 20))
READ_FILTER = (os.getenv("READ_FILTER","all").strip().lower())
INCLUDE_CC = os.getenv("INCLUDE_CC","false").strip().lower() in ("1","true","yes","on")
SKIP_HISTORY_ON_FIRST_RUN = os.getenv("SKIP_HISTORY_ON_FIRST_RUN","1").strip().lower() in ("1","true","yes","on")
TELEGRAM_MIN_INTERVAL = float(os.getenv("TELEGRAM_MIN_INTERVAL_SECS","1.5") or "1.5")
NOTICE_EXCLUDE_NOISE = os.getenv("NOTICE_EXCLUDE_NOISE","0").strip().lower() in ("1","true","yes","on")
SEND_TEST_ON_START = os.getenv("SEND_TEST_ON_START","1").strip().lower() in ("1","true","yes","on")

BEIJING_TZ = pytz.timezone("Asia/Shanghai")

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
  try:
    dt=datetime.strptime(s,"%Y-%m-%d %H:%M:%S").replace(tzinfo=BEIJING_TZ)
    return dt.strftime("%Y-%m-%d %H:%M")
  except: return s or ""

def load_state()->Dict[str,Any]:
  if not os.path.exists(STATE_FILE):
    return {"seen":{}, "watermark":{"system":{"ts":0.0,"id":0}, "notice":{"ts":0.0,"id":0}}}
  try:
    with open(STATE_FILE,"r",encoding="utf-8") as f: st=json.load(f)
    st.setdefault("seen",{}); st.setdefault("watermark",{"system":{"ts":0.0,"id":0}, "notice":{"ts":0.0,"id":0}})
    for k in ("system","notice"): st["watermark"].setdefault(k,{"ts":0.0,"id":0})
    return st
  except:
    return {"seen":{}, "watermark":{"system":{"ts":0.0,"id":0}, "notice":{"ts":0.0,"id":0}}}

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
    # 分片
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
      j=self.s.post("https://passport.seiue.com/authorize",
                    headers={"Content-Type":"application/x-www-form-urlencoded","X-Requested-With":"XMLHttpRequest","Origin":"https://chalk-c3.seiue.com"},
                    data={"client_id":"GpxvnjhVKt56qTmnPWH1sA","response_type":"token"}, timeout=30).json()
      tok=j.get("access_token"); rid=str(j.get("active_reflection_id") or "")
      if not tok or not rid: return False
      self.reflection=rid
      self.s.headers.update({"Authorization":f"Bearer {tok}","x-school-id":X_SCHOOL_ID,"x-role":X_ROLE,"x-reflection-id":rid})
      logging.info("Auth OK, reflection_id=%s", rid); return True
    except Exception as e:
      logging.error("login error: %s", e); return False

  def _get_me(self, params:dict):
    url="https://api.seiue.com/chalk/me/received-messages"
    r=self.s.get(url, params=params, timeout=30)
    if r.status_code in (401,403):
      if self.login(): r=self.s.get(url, params=params, timeout=30)
    return r

  def list_system(self, pages:int)->List[Dict[str,Any]]:
    # 系統消息（無關鍵詞過濾，全部直推）
    base={"expand":"sender_reflection","owner.id":self.reflection,"type":"message","paginated":"1","sort":"-published_at,-created_at"}
    if READ_FILTER=="unread": base["readed"]="false"
    if not INCLUDE_CC: base["is_cc"]="false"
    return self._collect(base, pages)

  def list_notice(self, pages:int)->List[Dict[str,Any]]:
    # 通知中心（全量；是否排除噪音由 NOTICE_EXCLUDE_NOISE 控制，默認 0=不排除）
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
      j=r.json(); arr=j["items"] if isinstance(j,dict) and "items" in j else (j if isinstance(j,list) else [])
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

def render_content(raw_json:str)->Tuple[str,List[Dict[str,Any]]]:
  # Draft.js 風格
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
      et=(ent.get("type") or "").upper(); dat=ent.get("data") or {}
      if et=="FILE":  attachments.append({"type":"file","name":dat.get("name") or "附件","size":dat.get("size") or "","url":dat.get("url") or ""})
      if et=="IMAGE": attachments.append({"type":"image","name":"image.jpg","size":"","url":dat.get("src") or ""})
    if (blk.get("data") or {}).get("align")=="align_right" and line.strip(): line="—— "+line
    lines.append(line)
  while lines and not lines[-1].strip(): lines.pop()
  html_txt="\n\n".join([ln if ln.strip() else "​" for ln in lines])
  return html_txt, attachments

def classify(title:str, body_html:str)->Tuple[str,str]:
  # 僅用於標籤裝飾；不影響是否推送
  z=(title or "")+"\n"+(body_html or "")
  PAIRS=[("leave","【請假】",["請假","请假","銷假","销假"]),
         ("attendance","【考勤】",["考勤","出勤","打卡","遲到","迟到","早退","缺勤","曠課","旷课"]),
         ("evaluation","【評價】",["評價","评价","德育","已發布評價","已发布评价"]),
         ("notice","【通知】",["通知","公告","告知","提醒"])]
  for key, tag, kws in PAIRS:
    for k in kws:
      if k in z: return key, tag
  return "message","【消息】"

def sender_name(it:Dict[str,Any])->str:
  sr=it.get("sender_reflection") or {}
  return sr.get("name") or sr.get("nickname") or "系統"

def send_one(tg:"Telegram", cli:"Seiue", it:Dict[str,Any], ch:str, prefix:str="")->bool:
  title=it.get("title") or ""
  content=it.get("content") or ""
  body, atts=render_content(content)
  _, tag = classify(title, body)   # 只裝飾
  src = sender_name(it)
  hdr = f"📩 <b>{ '通知中心' if ch=='notice' else '系統消息' }</b>｜<b>{esc(src)}</b>\n"
  t = it.get("published_at") or it.get("created_at") or ""
  msg=f"{hdr}\n{prefix}{tag}<b>{esc(title)}</b>\n\n{body}\n\n— 發佈於 {fmt_time(t)}"
  ok=tg.send(msg)
  imgs=[a for a in atts if a.get("type")=="image" and a.get("url")]
  fils=[a for a in atts if a.get("type")=="file"  and a.get("url")]
  for a in imgs:
    data,_=cli.download(a["url"])
    if data: ok=tg.send_photo(data,"") and ok
  for a in fils:
    data,name=cli.download(a["url"])
    if data:
      cap=f"📎 <b>{esc(a.get('name') or name)}</b>"
      if a.get("size"): cap+=f"（{esc(a['size'])}）"
      ok=tg.send_doc(data, (a.get("name") or name), cap) and ok
  return ok

def latest_of_channel(cli:"Seiue", ch:str)->Optional[Dict[str,Any]]:
  arr = cli.list_notice(1) if ch=="notice" else cli.list_system(1)
  return arr[0] if arr else None

def ensure_startup_watermark(cli:"Seiue"):
  st=load_state()
  if st["watermark"]["system"]["ts"]>0.0 and st["watermark"]["notice"]["ts"]>0.0: return
  if not SKIP_HISTORY_ON_FIRST_RUN: return
  for ch in ("system","notice"):
    it=latest_of_channel(cli, ch)
    if it:
      ts=parse_ts(it.get("published_at") or it.get("created_at") or "") or time.time()
      try: mid=int(str(it.get("id"))); 
      except: mid=0
    else:
      ts=time.time(); mid=0
    st["watermark"][ch]={"ts":ts,"id":mid}
  save_state(st); logging.info("啟動設置水位完成：%s", st["watermark"])

def list_increment_dual(cli:"Seiue")->List[Tuple[str,Dict[str,Any],float,int]]:
  st=load_state(); pending=[]
  for ch in ("system","notice"):
    w=st["watermark"][ch]; last_ts=float(w.get("ts") or 0.0); last_id=int(w.get("id") or 0)
    arr = cli.list_system(MAX_LIST_PAGES) if ch=="system" else cli.list_notice(MAX_LIST_PAGES)
    for it in arr:
      t=it.get("published_at") or it.get("created_at") or ""; ts=parse_ts(t) if t else 0.0
      try: nid=int(str(it.get("id"))); 
      except: nid=0
      if last_ts and (ts<last_ts or (ts==last_ts and nid<=last_id)): continue
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
  # 安裝/啟動驗證：各通道各發最新1條（不改水位/seen）
  if SEND_TEST_ON_START:
    for ch in ("system","notice"):
      it=latest_of_channel(cli, ch)
      if it:
        try: send_one(tg, cli, it, ch, prefix="🧪 <b>安裝驗證</b>｜")
        except Exception as e: logging.error("test send error(%s): %s", ch, e)
  print(f"{datetime.now().strftime('%F %T')} 開始輪詢（notice+system，全量直推），每 {POLL_SECONDS}s，頁數<= {MAX_LIST_PAGES}")
  while True:
    try:
      st=load_state()
      pending=list_increment_dual(cli)
      for ch,it,ts,nid in pending:
        key=f"{ch}:{nid}"
        if key in st["seen"]: continue
        ok=send_one(tg, cli, it, ch)
        if ok:
          st["seen"][key]=ts
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
  chown "$REAL_USER:$(id -gn "$REAL_USER")" "$PY_SCRIPT"
}

write_service_linux(){
  cat >/etc/systemd/system/${UNIT_NAME}.service <<EOF
[Unit]
Description=Seiue → Telegram notifier (dual-channel; no subcommands)
After=network-online.target
Wants=network-online.target

[Service]
User=${REAL_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${VENV_DIR}/bin/python3 ${PY_SCRIPT}
Restart=always
RestartSec=5s
StandardOutput=append:${OUT_LOG}
StandardError=append:${ERR_LOG}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

write_service_darwin(){
  local PLIST="/Library/LaunchDaemons/net.bdfz.${UNIT_NAME}.plist"
  cat >"$PLIST" <<EOPL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>net.bdfz.${UNIT_NAME}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${VENV_DIR}/bin/python3</string>
    <string>${PY_SCRIPT}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${OUT_LOG}</string>
  <key>StandardErrorPath</key><string>${ERR_LOG}</string>
  <key>WorkingDirectory</key><string>${INSTALL_DIR}</string>
</dict></plist>
EOPL
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
}

start_service(){
  mkdir -p "$LOG_DIR"; touch "$OUT_LOG" "$ERR_LOG"
  chown -R "$REAL_USER:$(id -gn "$REAL_USER")" "$LOG_DIR"
  if [ $IS_LINUX -eq 1 ]; then
    systemctl enable --now ${UNIT_NAME}.service
  else
    write_service_darwin
  fi
}

# -------- main (zero-arg only) --------
info "Seiue sidecar（零參數版，無子命令；雙通道全量推送）"
preflight
ensure_dirs
collect_env_if_needed
setup_venv
write_python
if [ $IS_LINUX -eq 1 ]; then
  write_service_linux
  systemctl restart ${UNIT_NAME}.service || true
else
  write_service_darwin
fi
success "已安裝/升級並啟動。"
echo "狀態：systemctl status ${UNIT_NAME} --no-pager   （macOS: launchctl list | grep ${UNIT_NAME})"
echo "日誌：journalctl -u ${UNIT_NAME} -f            或   tail -F ${OUT_LOG} ${ERR_LOG}"
SH

bash /root/seiue-notify.sh