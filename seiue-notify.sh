#!/usr/bin/env bash
# Seiue Notification → Telegram - Sidecar (no subcommands, one-shot updater/runner)
# v1.9.1-lite (2025-10-30)
# 设计：一键执行，所有更新都在此脚本内完成；不新增命令接口。
# 要点：
#  - 仅扫描 /chalk/me/received-messages?owner.id=<reflection_id>
#  - 不更改已读状态（只 GET）
#  - at-most-once：singleton + (last_ts,last_id) 水位 + per-id seen
#  - 默认作为 systemd 服务运行；无 systemd 时前台运行
#  - 不提示输入：沿用现有 ~/.seiue-notify/.env；若不存在，写模板并退出（防误写）

set -euo pipefail

# ---------- 可调参数（保持最少） ----------
SERVICE_NAME="seiue-notify.service"

# ---------- 识别真实用户与路径 ----------
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo ~"$REAL_USER")
INSTALL_DIR="${REAL_HOME}/.seiue-notify"
VENV_DIR="${INSTALL_DIR}/venv"
PY_SCRIPT="${INSTALL_DIR}/seiue_notify.py"
ENV_FILE="${INSTALL_DIR}/.env"
LOG_DIR="${INSTALL_DIR}/logs"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}"

# 透传代理（如有）
PROXY_ENV="$(env | grep -i -E '^(http_proxy|https_proxy|no_proxy|HTTP_PROXY|HTTPS_PROXY|NO_PROXY)=' || true)"

# ---------- 函数 ----------
info()    { echo -e "\033[0;34mINFO:\033[0m $1"; }
success() { echo -e "\033[0;32mSUCCESS:\033[0m $1"; }
warn()    { echo -e "\033[0;33mWARN:\033[0m $1"; }
error()   { echo -e "\033[0;31mERROR:\033[0m $1" >&2; }

run_as_user() {
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$REAL_USER" -- "$@"
  else
    sudo -u "$REAL_USER" -- "$@"
  fi
}

ensure_paths() {
  mkdir -p "$INSTALL_DIR" "$LOG_DIR"
  chown -R "$REAL_USER:$(id -gn "$REAL_USER")" "$INSTALL_DIR"
}

need_root_actions() {
  # 写 systemd 需要 root；若不是 root，则提权重进
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "需要 root 以写入 systemd 与文件权限，正在 sudo 提权执行…"
    exec sudo -E bash "$0"
  fi
}

check_python() {
  local pybin=""
  if command -v python3 >/dev/null 2>&1; then pybin="$(command -v python3)"; fi
  if [ -z "$pybin" ]; then
    warn "未找到 python3，尝试安装（apt/yum）…"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y && apt-get install -y python3 python3-venv
    elif command -v yum >/dev/null 2>&1; then
      yum install -y python3 python3-venv || true
    fi
  fi
  command -v python3 >/dev/null 2>&1 || { error "仍未找到 python3"; exit 1; }
}

ensure_env_or_template() {
  if [ ! -f "$ENV_FILE" ]; then
    warn "未发现 ${ENV_FILE}，写入模板并退出（避免误填）"
    run_as_user bash -lc "cat > '$ENV_FILE'" <<'EOF'
# ===== .seiue-notify/.env (模板：请填好再重跑脚本) =====
SEIUE_USERNAME=
SEIUE_PASSWORD=
X_SCHOOL_ID=3
X_ROLE=teacher

TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=

# 轮询参数
NOTIFY_POLL_SECONDS=90
MAX_LIST_PAGES=10
READ_FILTER=all
INCLUDE_CC=true
SKIP_HISTORY_ON_FIRST_RUN=1
TELEGRAM_MIN_INTERVAL_SECS=1.5
EOF
    run_as_user chmod 600 "$ENV_FILE"
    echo "请编辑 ${ENV_FILE} 后，重新运行此脚本。"
    exit 0
  fi
  run_as_user chmod 600 "$ENV_FILE" || true
}

setup_venv() {
  if [ ! -d "$VENV_DIR" ]; then
    run_as_user python3 -m venv "$VENV_DIR"
  fi
  local vpy="${VENV_DIR}/bin/python"
  run_as_user "$vpy" -m ensurepip --upgrade || true
  info "安装/升级依赖…"
  run_as_user env ${PROXY_ENV} "$vpy" -m pip install -q --upgrade pip || true
  run_as_user env ${PROXY_ENV} "$vpy" -m pip install -q requests pytz urllib3
}

write_python() {
  info "写入 Python 轮询器（ME inbox only；含请假/考勤分类；不改已读）…"
  local tmp="$(mktemp)"
  cat > "$tmp" <<'EOF_PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Seiue Notification → Telegram (ME inbox only, no CLI commands)
v1.9.1-lite — include leave_flow / attendance; read-only; at-most-once; watermark on first run.
"""
import os, sys, json, time, html, fcntl, logging
from typing import Dict, Any, List, Tuple, Optional
from datetime import datetime
import requests, pytz
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

# ---- env ----
SEIUE_USERNAME = os.getenv("SEIUE_USERNAME","")
SEIUE_PASSWORD = os.getenv("SEIUE_PASSWORD","")
X_SCHOOL_ID    = os.getenv("X_SCHOOL_ID","3")
X_ROLE         = os.getenv("X_ROLE","teacher")

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN","")
TELEGRAM_CHAT_ID   = os.getenv("TELEGRAM_CHAT_ID","")

POLL_SECONDS = int(os.getenv("NOTIFY_POLL_SECONDS", "90"))
MAX_LIST_PAGES = max(1, min(int(os.getenv("MAX_LIST_PAGES","10") or "10"), 30))
READ_FILTER = os.getenv("READ_FILTER","all").strip().lower()  # all | unread
INCLUDE_CC = os.getenv("INCLUDE_CC","true").strip().lower() in ("1","true","yes","on")
SKIP_HISTORY_ON_FIRST_RUN = os.getenv("SKIP_HISTORY_ON_FIRST_RUN","1").strip().lower() in ("1","true","yes","on")

TELEGRAM_MIN_INTERVAL = float(os.getenv("TELEGRAM_MIN_INTERVAL_SECS","1.5"))
TG_MSG_LIMIT = 4096; TG_MSG_SAFE = TG_MSG_LIMIT - 64
TG_CAPTION_LIMIT = 1024; TG_CAPTION_SAFE = TG_CAPTION_LIMIT - 16

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_DIR  = os.path.join(BASE_DIR, "logs")
os.makedirs(LOG_DIR, exist_ok=True)
STATE_FILE = os.path.join(BASE_DIR, "notify_state.json")
LOG_FILE   = os.path.join(LOG_DIR, "notify.log")
SINGLETON_LOCK_FILE = ".notify.lock"

BEIJING_TZ = pytz.timezone("Asia/Shanghai")

logging.basicConfig(
  level=logging.INFO,
  format="%(asctime)s.%(msecs)03d - %(levelname)s - %(message)s",
  datefmt="%Y-%m-%d %H:%M:%S",
  handlers=[logging.FileHandler(LOG_FILE, encoding="utf-8", mode="a"), logging.StreamHandler(sys.stdout)],
)

def now_cst_str():
  return datetime.now(BEIJING_TZ).strftime("%Y-%m-%d %H:%M:%S")

def escape_html(s: str) -> str:
  return html.escape(s or "", quote=False)

def acquire_singleton_lock_or_exit():
  path = os.path.join(BASE_DIR, SINGLETON_LOCK_FILE)
  try:
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    os.ftruncate(fd, 0); os.write(fd, str(os.getpid()).encode())
    return fd
  except OSError:
    logging.error("另一個實例正在運行，本實例退出。"); sys.exit(0)

def load_state()->Dict[str,Any]:
  if not os.path.exists(STATE_FILE):
    return {"seen":{}, "last_seen_ts":None, "last_seen_id":0}
  try:
    with open(STATE_FILE,"r",encoding="utf-8") as f: st=json.load(f)
    st.setdefault("seen",{}); st.setdefault("last_seen_ts",None); st.setdefault("last_seen_id",0)
    return st
  except Exception:
    return {"seen":{}, "last_seen_ts":None, "last_seen_id":0}

def save_state(st:Dict[str,Any]):
  try:
    tmp=STATE_FILE+".tmp"
    with open(tmp,"w",encoding="utf-8") as f:
      json.dump(st,f,ensure_ascii=False,indent=2); f.flush(); os.fsync(f.fileno())
    os.replace(tmp,STATE_FILE)
  except Exception as e:
    logging.warning(f"save_state failed: {e}")

# ---- Telegram ----
class Telegram:
  def __init__(self, token, chat_id):
    self.base=f"https://api.telegram.org/bot{token}"
    self.chat_id=chat_id
    self.s=requests.Session()
    self.s.mount("https://", HTTPAdapter(max_retries=Retry(total=3, backoff_factor=1.2, status_forcelist=(429,500,502,503,504))))
    self._last=0.0
  def _pace(self):
    d=time.time()-self._last
    if d<TELEGRAM_MIN_INTERVAL: time.sleep(TELEGRAM_MIN_INTERVAL-d)
  def _post(self, ep, data, files=None, label="sendMessage", timeout=60)->bool:
    back=1.0
    for i in range(1,7):
      try:
        self._pace()
        r=self.s.post(f"{self.base}/{ep}", data=data, files=files, timeout=timeout)
        self._last=time.time()
        if r.status_code==200: return True
        if r.status_code==429:
          retry=3
          try: retry=int(r.json().get("parameters",{}).get("retry_after",retry))
          except Exception: pass
          retry=max(1,min(retry+1,60)); logging.warning(f"{label} 429, sleep {retry}s ({i}/6)"); time.sleep(retry); continue
        if 500<=r.status_code<600:
          logging.warning(f"{label} {r.status_code}: {r.text[:200]} ({i}/6)"); time.sleep(back); back=min(back*2,15); continue
        logging.warning(f"{label} failed {r.status_code}: {r.text[:200]}"); return False
      except requests.RequestException as e:
        logging.warning(f"{label} net err: {e} ({i}/6)"); time.sleep(back); back=min(back*2,15)
    return False
  def send_message(self, html_text): return self._post("sendMessage", {"chat_id":self.chat_id,"text":html_text,"parse_mode":"HTML","disable_web_page_preview":True}, None, "sendMessage", 30)
  def send_message_safely(self, html_text):
    if len(html_text)<=TG_MSG_LIMIT: return self.send_message(html_text)
    parts=[]; buf=""
    for para in (html_text.split("\n\n")):
      add=(("\n\n" if buf else "")+para)
      if len(add)>TG_MSG_SAFE:
        for ln in para.split("\n"):
          t=buf+("\n" if buf else "")+ln
          if len(t)>TG_MSG_SAFE:
            if buf: parts.append(buf); buf=ln
            else:
              s=0
              while s<len(ln):
                parts.append(ln[s:s+TG_MSG_SAFE]); s+=TG_MSG_SAFE
              buf=""
          else: buf=t
      else:
        t=buf+add
        if len(t)>TG_MSG_SAFE: parts.append(buf); buf=para
        else: buf=t
    if buf: parts.append(buf)
    ok=True
    for i,chunk in enumerate(parts,1): ok=self.send_message(f"(Part {i}/{len(parts)})\n{chunk}") and ok
    return ok
  def send_photo_bytes(self, data, caption_html=""):
    if caption_html and len(caption_html)>TG_CAPTION_LIMIT: caption_html=caption_html[:TG_CAPTION_SAFE]+"…"
    return self._post("sendPhoto", {"chat_id":self.chat_id,"caption":caption_html,"parse_mode":"HTML"}, {"photo":("image.jpg",data)}, "sendPhoto", 90)
  def send_document_bytes(self, data, filename, caption_html=""):
    if caption_html and len(caption_html)>TG_CAPTION_LIMIT: caption_html=caption_html[:TG_CAPTION_SAFE]+"…"
    return self._post("sendDocument", {"chat_id":self.chat_id,"caption":caption_html,"parse_mode":"HTML"}, {"document":(filename,data)}, "sendDocument", 180)

# ---- Seiue client (ME inbox) ----
class SeiueClient:
  def __init__(self, username, password):
    self.username=username; self.password=password
    self.s=requests.Session()
    self.s.mount("https://", HTTPAdapter(max_retries=Retry(total=5, backoff_factor=1.7, status_forcelist=(429,500,502,503,504))))
    self.s.headers.update({"User-Agent":"Mozilla/5.0","Accept":"application/json, text/plain, */*","Origin":"https://chalk-c3.seiue.com","Referer":"https://chalk-c3.seiue.com/"})
    self.login_url="https://passport.seiue.com/login?school_id=3"
    self.authorize_url="https://passport.seiue.com/authorize"
    self.me_url="https://api.seiue.com/chalk/me/received-messages"
    self.bearer=None; self.reflection_id=None
  def login(self)->bool:
    try:
      self.s.post(self.login_url, headers={"Content-Type":"application/x-www-form-urlencoded","Origin":"https://passport.seiue.com"}, data={"email":self.username,"password":self.password}, timeout=30)
      a=self.s.post(self.authorize_url, headers={"Content-Type":"application/x-www-form-urlencoded","X-Requested-With":"XMLHttpRequest","Origin":"https://chalk-c3.seiue.com"}, data={"client_id":"GpxvnjhVKt56qTmnPWH1sA","response_type":"token"}, timeout=30)
      j=a.json()
      self.bearer=j.get("access_token"); self.reflection_id=str(j.get("active_reflection_id") or "")
      assert self.bearer and self.reflection_id
    except Exception as e:
      logging.error(f"Authorize/login failed: {e}"); return False
    self.s.headers.update({"Authorization":f"Bearer {self.bearer}","x-school-id":X_SCHOOL_ID,"x-role":X_ROLE,"x-reflection-id":self.reflection_id})
    logging.info(f"Auth OK, reflection_id={self.reflection_id}")
    return True
  def _retry(self, fn):
    r=fn()
    if getattr(r,"status_code",None) in (401,403):
      logging.warning("401/403，重登…"); 
      if self.login(): r=fn()
    return r
  @staticmethod
  def parse_ts(s:str)->float:
    fmts=("%Y-%m-%d %H:%M:%S","%Y-%m-%dT%H:%M:%S%z","%Y-%m-%dT%H:%M:%S")
    for f in fmts:
      try: return datetime.strptime(s,f).timestamp()
      except Exception: pass
    return 0.0
  def _json_items(self, r:requests.Response)->List[Dict[str,Any]]:
    try:
      d=r.json()
      if isinstance(d,dict) and isinstance(d.get("items"),list): return d["items"]
      if isinstance(d,list): return d
    except Exception as e:
      logging.error(f"JSON parse err: {e}")
    return []
  def list_incremental(self, pages:int)->List[Dict[str,Any]]:
    st=load_state(); last_ts=float(st.get("last_seen_ts") or 0.0); last_id=int(st.get("last_seen_id") or 0)
    newest_ts=last_ts; newest_id=last_id; out=[]
    base={"expand":"sender_reflection,aggregated_messages","owner.id":self.reflection_id,"paginated":"1","sort":"-published_at,-created_at"}
    if READ_FILTER=="unread": base["readed"]="false"
    if not INCLUDE_CC: base["is_cc"]="false"
    for page in range(1, pages+1):
      params=dict(base, **{"page":str(page),"per_page":"20"})
      r=self._retry(lambda: self.s.get(self.me_url, params=params, timeout=30))
      if r.status_code!=200: logging.error(f"me inbox HTTP {r.status_code}: {r.text[:300]}"); break
      items=self._json_items(r)
      if not items: break
      for it in items:
        ts_str=it.get("published_at") or it.get("created_at") or ""
        ts=self.parse_ts(ts_str) if ts_str else 0.0
        try: nid=int(str(it.get("id") or 0))
        except Exception: nid=0
        if last_ts and (ts<last_ts or (ts==last_ts and nid<=last_id)): continue
        out.append(it)
        if (ts>newest_ts) or (ts==newest_ts and nid>newest_id): newest_ts, newest_id = ts, nid
    if newest_ts and ((newest_ts>last_ts) or (newest_ts==last_ts and newest_id>last_id)):
      st["last_seen_ts"]=newest_ts; st["last_seen_id"]=newest_id; save_state(st)
    logging.info(f"list: fetched={len(out)}")
    return out

# ---- content render & classify ----
def render_draftjs(content_json:str):
  try: raw=json.loads(content_json or "{}")
  except Exception: raw={}
  blocks=raw.get("blocks") or []; entity_map=raw.get("entityMap") or {}
  ents={}
  for k,v in entity_map.items():
    try: ents[int(k)]=v
    except Exception: pass
  lines=[]; atts=[]
  def style_line(t, ranges):
    mark=""
    for r in (ranges or []):
      s=r.get("style") or ""
      if s=="BOLD": t=f"<b>{escape_html(t)}</b>"
      elif s.startswith("color_"):
        if "red" in s: mark="❗"+mark
        elif "orange" in s: mark="⚠️"+mark
        elif "theme" in s: mark="⭐"+mark
    if not t.startswith("<b>"): t=escape_html(t)
    return mark+t
  for b in blocks:
    t=b.get("text","") or ""; line=style_line(t, b.get("inlineStyleRanges") or [])
    for er in (b.get("entityRanges") or []):
      ent=ents.get(int(er.get("key"))) if er.get("key") is not None else None
      if not ent: continue
      tp=(ent.get("type") or "").upper(); data=ent.get("data") or {}
      if tp=="FILE":  atts.append({"type":"file","name":data.get("name") or "附件","size":data.get("size") or "","url":data.get("url") or ""})
      if tp=="IMAGE": atts.append({"type":"image","name":"image.jpg","url":data.get("src") or ""})
    if (b.get("data") or {}).get("align")=="align_right" and line.strip(): line="—— "+line
    lines.append(line)
  while lines and not lines[-1].strip(): lines.pop()
  html_text="\n\n".join([ln if ln.strip() else "​" for ln in lines])
  return html_text, atts

def extract_text_plain(item)->str:
  c=item.get("content")
  if not c: return ""
  try:
    txt,_=render_draftjs(c)
    return txt
  except Exception:
    return escape_html(str(c))

def format_time(ts:str)->str:
  try:
    dt=datetime.strptime(ts,"%Y-%m-%d %H:%M:%S").replace(tzinfo=BEIJING_TZ)
    return dt.strftime("%Y-%m-%d %H:%M")
  except Exception:
    return ts or ""

def classify(item:Dict[str,Any])->str:
  domain=(item.get("domain") or "").lower()
  tp=(item.get("type") or "").lower()
  title=(item.get("title") or "")
  content=(item.get("content") or "")
  Z=(title or "")+"\n"+(content or "")
  if domain.startswith("leave") or "absence" in tp or any(k in Z for k in ["请假","請假","销假","銷假","公假"]):
    return "leave"
  if domain.startswith("attendance") or "attendance" in tp or any(k in Z for k in ["考勤","出勤","缺席","遲到","早退","旷课","曠課"]):
    return "attendance"
  if "evaluation" in domain or "evaluation" in tp or any(k in Z for k in ["评价","評價"]):
    return "evaluation"
  if item.get("notice") is True: return "notice"
  return "message"

def header_from_sender(sender_reflection:Dict[str,Any])->str:
  name=""
  try: name=sender_reflection.get("name") or sender_reflection.get("realname") or ""
  except Exception: pass
  return f"📩 <b>校內訊息</b>{' · 來自 ' + escape_html(name) if name else ''}\n"

def download_with_auth(cli: 'SeiueClient', url:str)->Tuple[bytes,str]:
  try:
    r=cli._retry(lambda: cli.s.get(url, timeout=60, stream=True))
    if r.status_code!=200:
      logging.error(f"download HTTP {r.status_code}: {r.text[:200]}"); return b"","attachment.bin"
    data=r.content; name="attachment.bin"
    cd=r.headers.get("Content-Disposition") or ""
    if "filename=" in cd: name=cd.split("filename=",1)[1].strip('"; ')
    else:
      from urllib.parse import urlparse, unquote
      try: name=unquote(urlparse(r.url).path.rsplit('/',1)[-1]) or name
      except Exception: pass
    return data, name
  except requests.RequestException as e:
    logging.error(f"download failed: {e}"); return b"","attachment.bin"

def render_item(cli: 'SeiueClient', item:Dict[str,Any])->Tuple[str,List[Dict[str,Any]]]:
  title=item.get("title") or ""
  content=item.get("content") or ""
  try:
    body, atts = render_draftjs(content)
    if not body.strip(): body = extract_text_plain(item)
  except Exception:
    body = extract_text_plain(item); atts=[]
  created=item.get("published_at") or item.get("created_at") or ""
  lines=[
    header_from_sender(item.get("sender_reflection") or {}),
    f"<b>{escape_html(title)}</b>",
    "",
    body,
    "",
    f"— 發布於 {format_time(created)}"
  ]
  return "\n".join(lines), atts

def ensure_startup_watermark(cli:'SeiueClient'):
  st=load_state()
  if st.get("last_seen_ts"): return
  if not SKIP_HISTORY_ON_FIRST_RUN: return
  newest_ts=time.time(); newest_id=0
  try:
    base={"expand":"sender_reflection,aggregated_messages","owner.id":cli.reflection_id,"paginated":"1","sort":"-published_at,-created_at","page":"1","per_page":"1"}
    r=cli._retry(lambda: cli.s.get(cli.me_url, params=base, timeout=30))
    if r.status_code==200:
      it=(r.json().get("items") or [None])[0]
      if it:
        ts_str=it.get("published_at") or it.get("created_at") or ""
        newest_ts=SeiueClient.parse_ts(ts_str) if ts_str else newest_ts
        try: newest_id=int(str(it.get("id") or 0))
        except Exception: newest_id=0
  except Exception: pass
  st["last_seen_ts"]=newest_ts; st["last_seen_id"]=newest_id; save_state(st)
  logging.info("啟動水位設置完成。")

def send_one(tg:Telegram, cli:'SeiueClient', item:Dict[str,Any])->bool:
  html_text, atts = render_item(cli, item)
  ok=tg.send_message_safely(html_text)
  for a in (atts or []):
    url=a.get("url"); 
    if not url: continue
    data, fname = download_with_auth(cli, url)
    if not data: continue
    if a.get("type")=="image": ok = tg.send_photo_bytes(data, "") and ok
    else:
      cap=f"📎 <b>{(a.get('name') or fname)}</b>"
      if a.get("size"): cap+=f"（{a['size']}）"
      ok = tg.send_document_bytes(data, filename=(a.get('name') or fname), caption_html=cap) and ok
  return ok

def main():
  if not (SEIUE_USERNAME and SEIUE_PASSWORD and TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID):
    print("缺少环境变量：SEIUE_USERNAME / SEIUE_PASSWORD / TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID", file=sys.stderr); sys.exit(1)
  lock_fd=acquire_singleton_lock_or_exit()
  tg=Telegram(TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID)
  cli=SeiueClient(SEIUE_USERNAME, SEIUE_PASSWORD)
  if not cli.login(): print("Seiue 登入失败", file=sys.stderr); sys.exit(2)
  ensure_startup_watermark(cli)
  st=load_state(); seen=st.get("seen") or {}
  logging.info(f"开始轮询（每 {POLL_SECONDS}s；pages<= {MAX_LIST_PAGES}）…")
  while True:
    try:
      items=cli.list_incremental(MAX_LIST_PAGES)
      def key(it):
        ts=SeiueClient.parse_ts(it.get("published_at") or it.get("created_at") or "") or 0.0
        try: nid=int(str(it.get("id") or 0))
        except Exception: nid=0
        return (ts, nid)
      new=sorted([it for it in items if str(it.get("id") or "") not in seen], key=key)
      for it in new:
        nid=str(it.get("id"))
        seen[nid]={"pushed_at":datetime.now().isoformat(timespec="seconds")}
        st["seen"]=seen; save_state(st)
        send_one(tg, cli, it)
      time.sleep(POLL_SECONDS)
    except KeyboardInterrupt:
      logging.info("收到中断，退出。"); break
    except Exception as e:
      logging.exception(f"主循环异常：{e}"); time.sleep(min(POLL_SECONDS,60))

if __name__=="__main__":
  main()
EOF_PY
  install -m 0644 -o "$REAL_USER" -g "$(id -gn "$REAL_USER")" "$tmp" "$PY_SCRIPT"
  rm -f "$tmp"
  success "Python 轮询器已更新。"
}

write_systemd() {
  if command -v systemctl >/dev/null 2>&1; then
    info "写入 systemd 单元并重启服务…"
    cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Seiue Notification → Telegram (ME inbox sidecar)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${REAL_USER}
Group=$(id -gn "$REAL_USER")
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${VENV_DIR}/bin/python ${PY_SCRIPT}
Restart=always
RestartSec=5
StandardOutput=append:${LOG_DIR}/notify.out.log
StandardError=append:${LOG_DIR}/notify.err.log
$(env | grep -i -E '^(http_proxy|https_proxy|no_proxy|HTTP_PROXY|HTTPS_PROXY|NO_PROXY)=' | sed 's/^/Environment=/')

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME"
    success "systemd 服务已重启：$SERVICE_NAME"
  else
    warn "未检测到 systemd，改为前台运行（Ctrl+C 退出）"
    ( set -a; source "$ENV_FILE"; set +a; exec "$VENV_DIR/bin/python" "$PY_SCRIPT" )
  fi
}

# ---------- 主流程（无子命令，一执行就更新并跑） ----------
need_root_actions
ensure_paths
check_python
ensure_env_or_template   # 若首次无 .env，会写模板并退出（不做其它动作）
setup_venv
write_python
write_systemd

success "完成。日志：${LOG_DIR}/notify.out.log / notify.err.log；状态可用：systemctl status ${SERVICE_NAME}"