#!/usr/bin/env bash
# Seiue Notification → Telegram - One-click Installer / Manager
# v1.9.0 sidecar (me/received-messages only; at-most-once; per-type confirm)
# 零参数=自动安装/升级并重启服务；支持 Linux(systemd) 与 macOS(launchd)
set -euo pipefail

# ------------ pretty ------------
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'
info()    { echo -e "${C_BLUE}INFO:${C_RESET} $1"; }
success() { echo -e "${C_GREEN}SUCCESS:${C_RESET} $1"; }
warn()    { echo -e "${C_YELLOW}WARNING:${C_RESET} $1"; }
error()   { echo -e "${C_RED}ERROR:${C_RESET} $1" >&2; }

# ------------ env / paths ------------
OS="$(uname -s || true)"
IS_LINUX=0; IS_DARWIN=0
[ "$OS" = "Linux" ] && IS_LINUX=1
[ "$OS" = "Darwin" ] && IS_DARWIN=1

# 提权仅用于安装/写系统服务
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  if [ "${1:-}" = "install" ] || [ "${1:-}" = "" ] || [ "${1:-}" = "upgrade" ] || [ "${1:-}" = "start" ] || [ "${1:-}" = "restart" ] || [ "${1:-}" = "stop" ] || [ "${1:-}" = "status" ] || [ "${1:-}" = "confirm-once" ] || [ "${1:-}" = "confirm-per-type" ] ; then
    echo "需要 root（写入依赖/服务）。使用 sudo 继续..."
    exec sudo -E bash "$0" "$@"
  fi
fi

REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo ~"$REAL_USER")
INSTALL_DIR="${REAL_HOME}/.seiue-notify"
VENV_DIR="${INSTALL_DIR}/venv"
PY_SCRIPT="${INSTALL_DIR}/seiue_notify.py"
RUNNER="${INSTALL_DIR}/run.sh"
ENV_FILE="${INSTALL_DIR}/.env"
STATE_FILE="${INSTALL_DIR}/notify_state.json"
LOG_DIR="${INSTALL_DIR}/logs"
OUT_LOG="${LOG_DIR}/notify.out.log"
ERR_LOG="${LOG_DIR}/notify.err.log"
UNIT_NAME="seiue-notify"

# 代理透传
PROXY_ENV="$(env | grep -i -E '^(http_proxy|https_proxy|no_proxy|HTTP_PROXY|HTTPS_PROXY|NO_PROXY)=' || true)"

run_as_user() {
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$REAL_USER" -- "$@"
  else
    sudo -u "$REAL_USER" -- "$@"
  fi
}

# ------------ helpers ------------
need_cmd() { command -v "$1" >/dev/null 2>&1; }
ensure_dirs() {
  mkdir -p "$INSTALL_DIR" "$LOG_DIR"
  chown -R "$REAL_USER:$(id -gn "$REAL_USER")" "$INSTALL_DIR"
}

preflight() {
  info "--- 环境预检 ---"
  local ok=1
  if ! curl -fsS --head --connect-timeout 8 "https://passport.seiue.com/login?school_id=3" >/dev/null 2>&1; then
    error "无法连通 https://passport.seiue.com（网络/防火墙/代理？）"
    ok=0
  fi
  if ! need_cmd python3; then
    warn "未找到 python3，尝试安装（apt/yum/homebrew）..."
    if need_cmd apt-get; then apt-get update -y && apt-get install -y python3 python3-venv python3-pip || true; fi
    if need_cmd yum; then yum install -y python3 python3-pip || true; fi
    if [ $IS_DARWIN -eq 1 ] && need_cmd brew; then brew install python || true; fi
  fi
  if ! need_cmd python3; then error "仍未找到 python3"; ok=0; fi
  if [ $ok -eq 0 ]; then exit 1; fi
  success "预检通过。"
}

write_runner() {
  cat >"$RUNNER" <<'EOSH'
#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$BASE_DIR/venv/bin/activate"
# 清旧锁，避免崩溃后卡住
rm -f "$BASE_DIR/.notify.lock" || true
exec python3 "$BASE_DIR/seiue_notify.py" --loop
EOSH
  chmod +x "$RUNNER"
  chown "$REAL_USER:$(id -gn "$REAL_USER")" "$RUNNER"
}

write_service_linux() {
  local UNIT="/etc/systemd/system/${UNIT_NAME}.service"
  cat >"$UNIT" <<EOSVC
[Unit]
Description=Seiue → Telegram notifier (sidecar)
After=network-online.target
Wants=network-online.target

[Service]
User=${REAL_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
ExecStartPre=/bin/rm -f ${INSTALL_DIR}/.notify.lock
ExecStart=${VENV_DIR}/bin/python3 ${PY_SCRIPT} --loop
Restart=always
RestartSec=5s
StandardOutput=append:${OUT_LOG}
StandardError=append:${ERR_LOG}

[Install]
WantedBy=multi-user.target
EOSVC
  systemctl daemon-reload
}

write_service_darwin() {
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
    <string>--loop</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SEIUE_USERNAME</key><string>$(grep '^SEIUE_USERNAME=' "$ENV_FILE" | cut -d= -f2-)</string>
    <key>SEIUE_PASSWORD</key><string>$(grep '^SEIUE_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)</string>
    <key>TELEGRAM_BOT_TOKEN</key><string>$(grep '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" | cut -d= -f2-)</string>
    <key>TELEGRAM_CHAT_ID</key><string>$(grep '^TELEGRAM_CHAT_ID=' "$ENV_FILE" | cut -d= -f2-)</string>
  </dict>
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

collect_env_if_needed() {
  if [ -f "$ENV_FILE" ]; then
    info "检测到已有 .env，跳过交互式输入。"
    return
  fi
  info "收集配置（保存到 $ENV_FILE，权限 600）"
  read -p "Seiue 用户名: " SEIUE_USERNAME
  read -s -p "Seiue 密码: " SEIUE_PASSWORD; echo
  read -p "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
  read -p "Telegram Chat ID: " TELEGRAM_CHAT_ID
  read -p "轮询间隔秒（默认 90）: " POLL; POLL="${POLL:-90}"
  cat >"$ENV_FILE" <<EOFENV
SEIUE_USERNAME=${SEIUE_USERNAME}
SEIUE_PASSWORD=${SEIUE_PASSWORD}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
# 可选项：
NOTIFY_POLL_SECONDS=${POLL}
MAX_LIST_PAGES=10
READ_FILTER=all
INCLUDE_CC=false
SKIP_HISTORY_ON_FIRST_RUN=1
TELEGRAM_MIN_INTERVAL_SECS=1.5
EOFENV
  chmod 600 "$ENV_FILE"
  chown "$REAL_USER:$(id -gn "$REAL_USER")" "$ENV_FILE"
}

setup_venv() {
  ensure_dirs
  local PYBIN="$(command -v python3)"
  if ! "$PYBIN" -c 'import ensurepip' >/dev/null 2>&1; then
    if need_cmd apt-get; then apt-get update -y && apt-get install -y python3-venv || true; fi
  fi
  run_as_user "$PYBIN" -m venv "$VENV_DIR" || true
  run_as_user env ${PROXY_ENV} "$VENV_DIR/bin/python" -m pip install -U pip >/dev/null 2>&1 || true
  info "安装/升级依赖…"
  run_as_user env ${PROXY_ENV} "$VENV_DIR/bin/python" -m pip install -q requests pytz urllib3
}

write_python() {
  # 生成内嵌 Python（删减注释以控制体积）
  cat >"$PY_SCRIPT" <<'EOF_PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, sys, time, json, html, fcntl, argparse, logging
from typing import Dict, Any, List, Optional, Tuple
from datetime import datetime
import requests, pytz
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

# ---- env ----
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_DIR = os.path.join(BASE_DIR, "logs"); os.makedirs(LOG_DIR, exist_ok=True)
STATE_FILE = os.path.join(BASE_DIR, "notify_state.json")
LOCK_FILE = os.path.join(BASE_DIR, ".notify.lock")
LOG_FILE = os.path.join(LOG_DIR, "notify.log")

SEIUE_USERNAME = os.getenv("SEIUE_USERNAME", "")
SEIUE_PASSWORD = os.getenv("SEIUE_PASSWORD", "")
X_SCHOOL_ID = os.getenv("X_SCHOOL_ID", "3")
X_ROLE = os.getenv("X_ROLE", "teacher")
TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "")
POLL_SECONDS = int(os.getenv("NOTIFY_POLL_SECONDS", "90") or "90")
MAX_LIST_PAGES = max(1, min(int(os.getenv("MAX_LIST_PAGES", "10") or "10"), 20))
READ_FILTER = os.getenv("READ_FILTER", "all").strip().lower()
INCLUDE_CC = os.getenv("INCLUDE_CC", "false").strip().lower() in ("1","true","yes","on")
SKIP_HISTORY_ON_FIRST_RUN = os.getenv("SKIP_HISTORY_ON_FIRST_RUN","1").strip().lower() in ("1","true","yes","on")
TELEGRAM_MIN_INTERVAL = float(os.getenv("TELEGRAM_MIN_INTERVAL_SECS","1.5") or "1.5")

BEIJING_TZ = pytz.timezone("Asia/Shanghai")

logging.basicConfig(
  level=logging.INFO,
  format="%(asctime)s.%(msecs)03d - %(levelname)s - %(message)s",
  datefmt="%Y-%m-%d %H:%M:%S",
  handlers=[logging.FileHandler(LOG_FILE, encoding="utf-8", mode="a"), logging.StreamHandler(sys.stdout)],
)

def esc(s:str)->str: return html.escape(s or "", quote=False)
def parse_ts(s:str)->float:
  for f in ("%Y-%m-%d %H:%M:%S","%Y-%m-%dT%H:%M:%S%z","%Y-%m-%dT%H:%M:%S"):
    try: return datetime.strptime(s, f).timestamp()
    except: pass
  return 0.0

def load_state()->Dict[str,Any]:
  if not os.path.exists(STATE_FILE): return {"seen":{}, "last_seen_ts":None, "last_seen_id":0}
  try:
    with open(STATE_FILE,"r",encoding="utf-8") as f: st=json.load(f)
    st.setdefault("seen",{}); st.setdefault("last_seen_ts",None); st.setdefault("last_seen_id",0); return st
  except: return {"seen":{}, "last_seen_ts":None, "last_seen_id":0}

def save_state(st:Dict[str,Any])->None:
  tmp=STATE_FILE+".tmp"
  with open(tmp,"w",encoding="utf-8") as f: json.dump(st,f,ensure_ascii=False,indent=2); f.flush(); os.fsync(f.fileno())
  os.replace(tmp,STATE_FILE)

def acquire_lock_or_exit():
  fd=os.open(LOCK_FILE, os.O_CREAT|os.O_RDWR, 0o644)
  try:
    fcntl.flock(fd, fcntl.LOCK_EX|fcntl.LOCK_NB)
    os.ftruncate(fd,0); os.write(fd, str(os.getpid()).encode()); return fd
  except OSError:
    logging.error("另一实例运行中，本实例退出。"); sys.exit(0)

class Telegram:
  def __init__(self, token:str, chat_id:str):
    self.base=f"https://api.telegram.org/bot{token}"; self.chat_id=chat_id
    self.s=requests.Session()
    self.s.mount("https://", HTTPAdapter(max_retries=Retry(total=4, backoff_factor=1.3, status_forcelist=(429,500,502,503,504))))
    self._last=0.0
  def _pace(self):
    delta=time.time()-self._last
    if delta<TELEGRAM_MIN_INTERVAL: time.sleep(TELEGRAM_MIN_INTERVAL-delta)
  def _post(self, ep:str, data:dict, files:dict=None, label:str="sendMessage", timeout:int=60)->bool:
    back=1.0
    for _ in range(6):
      try:
        self._pace(); r=self.s.post(f"{self.base}/{ep}", data=data, files=files, timeout=timeout); self._last=time.time()
        if r.status_code==200: return True
        if r.status_code==429:
          try: delay=int(r.json().get("parameters",{}).get("retry_after",3))
          except: delay=3
          time.sleep(max(1,min(delay+1,60))); continue
        if 500<=r.status_code<600: time.sleep(back); back=min(back*2,15); continue
        return False
      except requests.RequestException: time.sleep(back); back=min(back*2,15)
    return False
  def send(self, html_text:str)->bool:
    if len(html_text)<=4096: return self._post("sendMessage", {"chat_id":self.chat_id,"text":html_text,"parse_mode":"HTML","disable_web_page_preview":True}, None, timeout=30)
    # 分片
    safe=4032; parts=[]; buf=""
    for para in (html_text.split("\n\n")):
      add=(("\n\n" if buf else "")+para)
      if len(add)>safe:
        lines=para.split("\n")
        for ln in lines:
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
    for i,p in enumerate(parts,1): ok=self._post("sendMessage", {"chat_id":self.chat_id,"text":f"(Part {i}/{total})\n{p}","parse_mode":"HTML","disable_web_page_preview":True}, None, timeout=30) and ok
    return ok
  def send_photo(self, data:bytes, cap:str="")->bool:
    if len(cap)>1024: cap=cap[:1008]+"…"
    return self._post("sendPhoto", {"chat_id":self.chat_id,"caption":cap,"parse_mode":"HTML"}, {"photo":("image.jpg",data)}, "sendPhoto", 90)
  def send_doc(self, data:bytes, name:str, cap:str="")->bool:
    if len(cap)>1024: cap=cap[:1008]+"…"
    return self._post("sendDocument", {"chat_id":self.chat_id,"caption":cap,"parse_mode":"HTML"}, {"document":(name,data)}, "sendDocument", 180)

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
  def _get(self, params:dict):
    url="https://api.seiue.com/chalk/me/received-messages"
    r=self.s.get(url, params=params, timeout=30)
    if r.status_code in (401,403):
      if self.login(): r=self.s.get(url, params=params, timeout=30)
    return r
  def latest_one(self)->Optional[Dict[str,Any]]:
    r=self._get({"expand":"sender_reflection","owner.id":self.reflection,"type":"message","paginated":"1","sort":"-published_at,-created_at","page":"1","per_page":"1"})
    if r.status_code!=200: logging.error("latest HTTP %s", r.status_code); return None
    j=r.json(); items=j["items"] if isinstance(j,dict) and "items" in j else (j if isinstance(j,list) else [])
    return items[0] if items else None
  def list_increment(self, pages:int=MAX_LIST_PAGES)->List[Dict[str,Any]]:
    st=load_state(); last_ts=float(st.get("last_seen_ts") or 0.0); last_id=int(st.get("last_seen_id") or 0)
    results=[]; newest_ts=last_ts; newest_id=last_id
    base={"expand":"sender_reflection","owner.id":self.reflection,"type":"message","paginated":"1","sort":"-published_at,-created_at"}
    if READ_FILTER=="unread": base["readed"]="false"
    if not INCLUDE_CC: base["is_cc"]="false"
    for page in range(1, pages+1):
      p=dict(base, **{"page":str(page),"per_page":"20"})
      r=self._get(p)
      if r.status_code!=200: break
      j=r.json(); items=j["items"] if isinstance(j,dict) and "items" in j else (j if isinstance(j,list) else [])
      if not items: break
      for it in items:
        t=it.get("published_at") or it.get("created_at") or ""
        ts=parse_ts(t) if t else 0.0
        try: nid=int(str(it.get("id"))); 
        except: nid=0
        if last_ts and (ts<last_ts or (ts==last_ts and nid<=last_id)): continue
        results.append(it)
        if (ts>newest_ts) or (ts==newest_ts and nid>newest_id): newest_ts, newest_id = ts, nid
    if (newest_ts and (newest_ts>last_ts or (newest_ts==last_ts and newest_id>last_id))):
      st["last_seen_ts"]=newest_ts; st["last_seen_id"]=newest_id; save_state(st)
    logging.info("list: fetched=%d pages_scanned<=%d", len(results), pages); return results
  def download(self, url:str)->Tuple[bytes,str]:
    r=self.s.get(url, timeout=60, stream=True)
    if r.status_code!=200: return b"","attachment.bin"
    name="attachment.bin"
    cd=r.headers.get("Content-Disposition") or ""
    if "filename=" in cd: name=cd.split("filename=",1)[1].strip('"; ')
    else:
      from urllib.parse import urlparse, unquote
      try: name=unquote(urlparse(r.url).path.rsplit('/',1)[-1]) or name
      except: pass
    return r.content, name

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
      style=r.get("style") or ""
      if style=="BOLD": text=f"<b>{esc(text)}</b>"
      elif style.startswith("color_"):
        if "red" in style: prefix="❗"+prefix
        elif "orange" in style: prefix="⚠️"+prefix
        elif "theme" in style: prefix="⭐"+prefix
    if not text.startswith("<b>"): text=esc(text)
    return prefix+text
  for blk in blocks:
    t=blk.get("text","") or ""; line=decorate(t, blk.get("inlineStyleRanges") or [])
    for er in blk.get("entityRanges") or []:
      key=er.get("key"); 
      if key is None: continue
      ent=ents.get(int(key)) or {}; et=(ent.get("type") or "").upper(); dat=ent.get("data") or {}
      if et=="FILE": attachments.append({"type":"file","name":dat.get("name") or "附件","size":dat.get("size") or "","url":dat.get("url") or ""})
      elif et=="IMAGE": attachments.append({"type":"image","name":"image.jpg","size":"","url":dat.get("src") or ""})
    if (blk.get("data") or {}).get("align")=="align_right" and line.strip(): line="—— "+line
    lines.append(line)
  while lines and not lines[-1].strip(): lines.pop()
  html_txt="\n\n".join([ln if ln.strip() else "​" for ln in lines])
  return html_txt, attachments

def build_header(sender_reflection)->str:
  name=""
  try: name=sender_reflection.get("name") or sender_reflection.get("realname") or ""
  except: pass
  return f"📩 <b>校內訊息</b>{(' · 來自 '+esc(name)) if name else ''}\n"

def fmt_time(s:str)->str:
  try:
    dt=datetime.strptime(s,"%Y-%m-%d %H:%M:%S").replace(tzinfo=BEIJING_TZ)
    return dt.strftime("%Y-%m-%d %H:%M")
  except: return s or ""

def classify(title:str, content:str)->str:
  z=(title or "")+"\n"+(content or "")
  kws=[("leave",["请假","請假","销假","銷假"]),
       ("attendance",["考勤","出勤","打卡","迟到","早退","缺勤","旷课","曠課"]),
       ("evaluation",["评价","評價","德育","已发布评价","已發佈評價"]),
       ("notice",["通知","公告","告知","提醒"])]
  for lab, arr in kws:
    for k in arr:
      if k in z: return lab
  return "message"

def ensure_startup_watermark(cli:"Seiue"):
  st=load_state()
  if st.get("last_seen_ts"): return
  if not SKIP_HISTORY_ON_FIRST_RUN: return
  newest_ts=0.0; newest_id=0
  it=cli.latest_one()
  if it:
    ts=it.get("published_at") or it.get("created_at") or ""
    newest_ts=parse_ts(ts) if ts else time.time()
    try: newest_id=int(str(it.get("id"))); 
    except: newest_id=0
  else: newest_ts=time.time()
  st["last_seen_ts"]=newest_ts; st["last_seen_id"]=newest_id; save_state(st)
  logging.info("啟動設置水位：ts=%s id=%s", newest_ts, newest_id)

def send_item(tg:"Telegram", cli:"Seiue", it:Dict[str,Any])->bool:
  title=it.get("title") or ""; content=it.get("content") or ""
  body, atts=render_content(content)
  hdr=build_header(it.get("sender_reflection") or {})
  t=it.get("published_at") or it.get("created_at") or ""
  msg=f"{hdr}\n<b>{esc(title)}</b>\n\n{body}\n\n— 發布於 {fmt_time(t)}"
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

def do_loop():
  if not (SEIUE_USERNAME and SEIUE_PASSWORD and TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID):
    print("缺少必要环境变量。", file=sys.stderr); sys.exit(1)
  _lock=acquire_lock_or_exit()
  tg=Telegram(TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID)
  cli=Seiue(SEIUE_USERNAME, SEIUE_PASSWORD)
  if not cli.login(): print("Seiue 登录失败", file=sys.stderr); sys.exit(2)
  ensure_startup_watermark(cli)
  print(f"{datetime.now().strftime('%F %T')} 开始轮询（收件箱），每 {POLL_SECONDS}s，页数<={MAX_LIST_PAGES}")
  try:
    while True:
      items=cli.list_increment(MAX_LIST_PAGES)
      for it in items: send_item(tg, cli, it)
      time.sleep(POLL_SECONDS)
  except KeyboardInterrupt:
    print(f"{datetime.now().strftime('%F %T')} 收到中断，退出")

def confirm_once():
  _lock=acquire_lock_or_exit()
  tg=Telegram(TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID)
  cli=Seiue(SEIUE_USERNAME, SEIUE_PASSWORD)
  if not cli.login(): sys.exit(2)
  it=cli.latest_one()
  if it:
    ok=send_item(tg, cli, it)
    ts=it.get("published_at") or it.get("created_at") or ""
    st=load_state(); st["last_seen_ts"]=parse_ts(ts) if ts else time.time()
    try: st["last_seen_id"]=int(str(it.get("id")))
    except: st["last_seen_id"]=0
    save_state(st)
    logging.info("confirm-once 完成，已提升水位")
    sys.exit(0 if ok else 3)
  else:
    logging.info("confirm-once：收件箱为空")
    sys.exit(0)

def confirm_per_type(pages:int=10):
  _lock=acquire_lock_or_exit()
  tg=Telegram(TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID)
  cli=Seiue(SEIUE_USERNAME, SEIUE_PASSWORD)
  if not cli.login(): sys.exit(2)
  seen_type=set(); newest_ts=0.0; newest_id=0
  for it in cli.list_increment(pages):
    title=it.get("title") or ""; content=it.get("content") or ""
    typ=classify(title, content)
    if typ in seen_type: continue
    ok=send_item(tg, cli, it)
    ts=it.get("published_at") or it.get("created_at") or ""
    pts=parse_ts(ts) if ts else 0.0
    try: nid=int(str(it.get("id"))); 
    except: nid=0
    if (pts>newest_ts) or (pts==newest_ts and nid>newest_id): newest_ts, newest_id = pts, nid
    logging.info("确认推送：%s sid=%s ok=%s", typ, it.get("id"), ok)
    seen_type.add(typ)
    if len(seen_type)==5: break
  if newest_ts:
    st=load_state(); st["last_seen_ts"]=newest_ts; st["last_seen_id"]=newest_id; save_state(st)
    logging.info("per-type 完成，水位 ts=%s id=%s", newest_ts, newest_id)

def discover(pages:int=10):
  _lock=acquire_lock_or_exit()
  cli=Seiue(SEIUE_USERNAME, SEIUE_PASSWORD)
  if not cli.login(): sys.exit(2)
  cnt={"leave":0,"attendance":0,"evaluation":0,"notice":0,"message":0}
  scanned=0
  for it in cli.list_increment(pages):
    cnt[classify(it.get("title") or "", it.get("content") or "")]+=1
    scanned+=1
  print(json.dumps({"scanned":scanned,"counts":cnt}, ensure_ascii=False, indent=2))

def main():
  ap=argparse.ArgumentParser(add_help=False)
  ap.add_argument("--loop", action="store_true")
  ap.add_argument("--confirm-once", action="store_true")
  ap.add_argument("--confirm-per-type", action="store_true")
  ap.add_argument("--discover", action="store_true")
  args=ap.parse_args()
  if args.loop: return do_loop()
  if args.confirm_once: return confirm_once()
  if args.confirm_per_type: return confirm_per_type()
  if args.discover: return discover()
  return do_loop()

if __name__=="__main__":
  main()
EOF_PY
  chmod 755 "$PY_SCRIPT"
  chown "$REAL_USER:$(id -gn "$REAL_USER")" "$PY_SCRIPT"
}

start_service() {
  mkdir -p "$LOG_DIR"; touch "$OUT_LOG" "$ERR_LOG"; chown -R "$REAL_USER:$(id -gn "$REAL_USER")" "$LOG_DIR"
  if [ $IS_LINUX -eq 1 ]; then
    systemctl enable --now "${UNIT_NAME}.service"
  else
    write_service_darwin
  fi
}

stop_service() {
  if [ $IS_LINUX -eq 1 ]; then
    systemctl stop "${UNIT_NAME}.service" || true
  else
    launchctl unload "/Library/LaunchDaemons/net.bdfz.${UNIT_NAME}.plist" 2>/dev/null || true
  fi
}

# ------------ commands ------------
cmd_install() {
  preflight
  ensure_dirs
  collect_env_if_needed
  setup_venv
  write_python
  write_runner
  if [ $IS_LINUX -eq 1 ]; then write_service_linux; fi
  # 安装确认：各类型各发一条（不阻塞太久）
  stop_service || true
  info "按类型各发 1 条到 Telegram（同时抬升水位）..."
  run_as_user env ${PROXY_ENV} SEIUE_USERNAME=$(grep '^SEIUE_USERNAME=' "$ENV_FILE" | cut -d= -f2-) \
    SEIUE_PASSWORD=$(grep '^SEIUE_PASSWORD=' "$ENV_FILE" | cut -d= -f2-) \
    TELEGRAM_BOT_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" | cut -d= -f2-) \
    TELEGRAM_CHAT_ID=$(grep '^TELEGRAM_CHAT_ID=' "$ENV_FILE" | cut -d= -f2-) \
    "$VENV_DIR/bin/python" "$PY_SCRIPT" --confirm-per-type || true
  start_service
  success "安装完成。服务：$UNIT_NAME"
  echo "状态：systemctl status $UNIT_NAME --no-pager   日志：$OUT_LOG / $ERR_LOG"
}

cmd_upgrade() {
  preflight
  ensure_dirs
  setup_venv
  write_python
  write_runner
  if [ $IS_LINUX -eq 1 ]; then write_service_linux; systemctl restart "${UNIT_NAME}.service" || true; else write_service_darwin; fi
  success "升级完成并已重启服务。日志：$OUT_LOG / $ERR_LOG"
}

cmd_reconfigure() {
  stop_service || true
  rm -f "$ENV_FILE"
  collect_env_if_needed
  start_service
  success "已重写 .env 并重启。"
}

cmd_run_fg() {
  ensure_dirs
  . "$ENV_FILE" 2>/dev/null || true
  "$VENV_DIR/bin/python" "$PY_SCRIPT" --loop
}

cmd_logs() {
  ensure_dirs
  echo "OUT: $OUT_LOG"
  echo "ERR: $ERR_LOG"
  tail -n 200 -F "$OUT_LOG" "$ERR_LOG"
}

cmd_confirm_once() {
  stop_service || true
  . "$ENV_FILE" 2>/dev/null || true
  "$VENV_DIR/bin/python" "$PY_SCRIPT" --confirm-once || true
  start_service
}

cmd_confirm_per_type() {
  stop_service || true
  . "$ENV_FILE" 2>/dev/null || true
  "$VENV_DIR/bin/python" "$PY_SCRIPT" --confirm-per-type || true
  start_service
}

cmd_discover() {
  . "$ENV_FILE" 2>/dev/null || true
  "$VENV_DIR/bin/python" "$PY_SCRIPT" --discover
}

cmd_state_reset() {
  rm -f "$STATE_FILE"
  success "已清空水位状态文件：$STATE_FILE"
}

cmd_start()  { start_service;  systemctl status "$UNIT_NAME" --no-pager || true; }
cmd_stop()   { stop_service;   success "服务已停止。"; }
cmd_restart(){ stop_service; start_service; systemctl status "$UNIT_NAME" --no-pager || true; }
cmd_status() {
  if [ $IS_LINUX -eq 1 ]; then systemctl status "$UNIT_NAME" --no-pager || true; else launchctl list | grep -i "$UNIT_NAME" || true; fi
  echo "日志：$OUT_LOG / $ERR_LOG"
}

cmd_env_edit() { ${EDITOR:-nano} "$ENV_FILE"; }

usage() {
cat <<'EOT'
Usage: seiue-notify.sh <command>

Commands:
  (默认空参)       自动安装/升级并重启服务
  install          首次安装（创建 venv / 写入程序与 .env / 写系统服务）
  reconfigure      仅重写 .env（凭证/参数），不改程序
  upgrade          升级内嵌 Python 与依赖，重启服务
  run              前台运行（读取 .env）
  start|stop|restart|status
  logs             实时查看日志（tail -F）
  confirm-once     推送最近 1 条并抬升水位（避免重复）
  confirm-per-type 按类型各发 1 条（随后抬升水位）
  discover         仅统计分类数量（不推送）
  state-reset      清空水位（谨慎）
  env-edit         编辑 .env
  help             显示本帮助
EOT
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    "" ) cmd_upgrade ;;
    install ) shift; cmd_install "$@" ;;
    reconfigure ) shift; cmd_reconfigure "$@" ;;
    run ) shift; cmd_run_fg "$@" ;;
    start ) shift; cmd_start "$@" ;;
    stop ) shift; cmd_stop "$@" ;;
    restart ) shift; cmd_restart "$@" ;;
    status ) shift; cmd_status "$@" ;;
    logs ) shift; cmd_logs "$@" ;;
    confirm-once ) shift; cmd_confirm_once "$@" ;;
    confirm-per-type ) shift; cmd_confirm_per_type "$@" ;;
    discover ) shift; cmd_discover "$@" ;;
    upgrade ) shift; cmd_upgrade "$@" ;;
    env-edit ) shift; cmd_env_edit "$@" ;;
    state-reset ) shift; cmd_state_reset "$@" ;;
    help|--help|-h ) usage ;;
    * ) usage; exit 2 ;;
  esac
}
main "$@"