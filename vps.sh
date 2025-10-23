#!/bin/bash
# ===== Sentinel 安装/更新脚本 (生产优化版) =====
# 适用于包括超低内存VPS在内的所有环境，可重复执行。
# 已移除硬编码的 Telegram Secret，改为交互式安全设置。

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# --- 辅助函数：获取并验证 Telegram 配置 ---
function _setup_telegram_config() {
  # 快速通道：如果环境变量已存在，直接使用，跳过所有交互
  if [[ -n "${TELE_TOKEN:-}" && -n "${TELE_CHAT_ID:-}" ]]; then
    echo ">>> [INFO] Using TELE_TOKEN and TELE_CHAT_ID from environment. Skipping interactive setup."
    export TELE_TOKEN TELE_CHAT_ID
    return 0
  fi
  
  # 如果配置文件存在且包含有效配置，则跳过
  if [[ -f /etc/sentinel/sentinel.env ]]; then
    set -a
    . /etc/sentinel/sentinel.env
    set +a
    if [[ -n "${TELE_TOKEN:-}" && -n "${TELE_CHAT_ID:-}" ]]; then
      echo ">>> [INFO] Found existing Telegram configuration in /etc/sentinel/sentinel.env. Skipping interactive setup."
      return 0
    fi
  fi

  echo "--- Telegram Bot Setup ---"
  while true; do
    read -p "Please enter your Telegram Bot Token: " -s TELE_TOKEN
    echo ""
    if [[ -z "$TELE_TOKEN" ]]; then
      echo "Token cannot be empty. Please try again."
    elif [[ ! "$TELE_TOKEN" =~ ^[0-9]+:[a-zA-Z0-9_-]+$ ]]; then
      echo "Invalid Token format. It should look like '123456:ABC-DEF1234...'. Please try again."
    else
      break
    fi
  done

  echo "Token received. Now, let's get your Chat ID."
  echo ""
  echo ">>> Please open your Telegram app and send a message (e.g., /start) to your bot."
  read -p ">>> After sending the message, press [Enter] here to continue..."

  echo "Fetching your Chat ID from Telegram API..."
  API_RESPONSE=$(curl -s -m 15 "https://api.telegram.org/bot${TELE_TOKEN}/getUpdates")
  TELE_CHAT_ID=$(echo "$API_RESPONSE" | grep -o '"chat":{"id":[^,]*' | tail -n 1 | sed 's/.*"id"://')

  if [[ -z "$TELE_CHAT_ID" ]]; then
    echo ""
    echo "!!! ERROR: Could not automatically detect your Chat ID." >&2
    echo "Please make sure you sent a message to the bot AFTER the script prompted you to." >&2
    echo "You may need to run this script again." >&2
    exit 1
  fi

  echo "✅ Success! Your Chat ID is: ${TELE_CHAT_ID}"
  export TELE_TOKEN TELE_CHAT_ID
}

echo ">>> [1/5] Installing dependencies..."
apt-get update -qq
# 已加入 openssl 依赖，用于本地证书检查
apt-get install -yq python3 ca-certificates curl iproute2 iputils-ping openssl procps
# 确保不会因 needrestart 卡住；若不存在 needrestart 则忽略
if command -v needrestart >/dev/null 2>&1; then
  needrestart -r a || true
fi

echo ">>> [2/5] Creating directories and handling configuration..."
mkdir -p /etc/sentinel /var/lib/sentinel

_setup_telegram_config

# === 配置 ===
cat >/etc/sentinel/sentinel.env <<EOF
# === Telegram (由脚本自动填充或从现有配置加载) ===
TELE_TOKEN=${TELE_TOKEN}
TELE_CHAT_ID=${TELE_CHAT_ID}

# === 可选 Nginx 日志监控 ===
# 注意: 日志格式需匹配 sentinel.py 中的 LOG_RE 正则表达式，通常是类似 "host ip req status size ua" 的组合格式。
NGINX_ACCESS_LOG=/var/log/nginx/access.log

# === 主动网络探测 (超低内存优化) ===
PING_TARGETS=1.1.1.1,cloudflare.com
PING_INTERVAL_SEC=60
PING_TIMEOUT_MS=1500
PING_ENGINE=tcp
PING_TCP_PORT=443
PING_ROUND_ROBIN=1
LOSS_WINDOW=20
LOSS_ALERT_PCT=60
LATENCY_ALERT_MS=400
JITTER_ALERT_MS=150
FLAP_SUPPRESS_SEC=300

# === 通用窗口与冷却 ===
COOLDOWN_SEC=600

# === 内存/Swap ===
MEM_AVAIL_PCT_MIN=10
SWAP_USED_PCT_MAX=50
SWAPIN_PPS_MAX=1000

# === CPU/Load ===
LOAD1_PER_CORE_MAX=1.5
CPU_IOWAIT_PCT_MAX=50

# === 网卡总量（排除虚拟网卡）===
NET_RX_BPS_ALERT=5242880
NET_TX_BPS_ALERT=5242880
NET_RX_PPS_ALERT=2000
NET_TX_PPS_ALERT=2000

# === 磁盘 ===
ROOT_FS_PCT_MAX=90

# === Web 扫描特征 ===
SCAN_SIGS='/(?:\.env(?:\.|/|$)|wp-admin|wp-login|phpmyadmin|manager/html|hudson|actuator(?:/|$)|solr/admin|HNAP1|vendor/phpunit|\.git/|etc/passwd|boaform|shell|config\.php|id_rsa)'

# === 心跳与进程看护 ===
HEARTBEAT_HOURS=24
WATCH_PROCS=auto
WATCH_PROCS_REQUIRE_ENABLED=1

# === 每天北京时间12点快照 ===
DAILY_BJ_SNAPSHOT_HOUR=12

# === TLS 证书到期提醒 ===
CERT_CHECK_DOMAINS=
CERT_MIN_DAYS=3
CERT_AUTO_DISCOVER=1
CERT_SEARCH_GLOBS=/etc/letsencrypt/live/*/fullchain.pem,/var/discourse/shared/standalone/ssl/*,/etc/nginx/ssl/*/*.pem

# === SSH 暴力破解监控 ===
AUTH_LOG_PATH=/var/log/auth.log
AUTH_FAIL_COUNT=30
AUTH_FAIL_WINDOW_MIN=10

# === 日志静默（0 打印异常到 journalctl；1 静默）===
LOG_SILENT=0

# === 月度流量统计 ===
TRAFFIC_REPORT_EVERY_DAYS=10
TRAFFIC_TRACK_IF=""
EOF
chmod 600 /etc/sentinel/sentinel.env

# === tmsg (Telegram 1-shot) ===
cat >/usr/local/bin/tmsg <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# 从 sentinel 配置文件加载变量
if [[ -f /etc/sentinel/sentinel.env ]]; then
  set -a
  source /etc/sentinel/sentinel.env
  set +a
fi
: "${TELE_TOKEN:?TELE_TOKEN is not set. Check /etc/sentinel/sentinel.env}"
: "${TELE_CHAT_ID:?TELE_CHAT_ID is not set. Check /etc/sentinel/sentinel.env}"
curl -sS -m 10 -X POST "https://api.telegram.org/bot${TELE_TOKEN}/sendMessage" \
  -d "chat_id=${TELE_CHAT_ID}" \
  --data-urlencode "text=${1}" >/dev/null || true
EOF
chmod +x /usr/local/bin/tmsg

echo ">>> [3/5] Writing sentinel daemon script..."
cat >/usr/local/bin/sentinel.py <<'PY'
#!/usr/bin/env python3
import os, re, time, subprocess, socket, threading, statistics, json, sys, traceback, tempfile, calendar, shlex, ssl, glob
from collections import deque, defaultdict
from datetime import date, datetime, timedelta

# ===== Env & Constants =====
E=lambda k,d=None: os.getenv(k,d)
TELE_TOKEN, TELE_CHAT_ID = E("TELE_TOKEN"), E("TELE_CHAT_ID")

# --- sanitize numeric envs ---
def _strip_inline_comment(v):
    if v is None: return None
    return v.split('#', 1)[0].strip()

def _clean_env_numbers(keys):
    for k in keys:
        v = os.getenv(k)
        if v is not None:
            os.environ[k] = _strip_inline_comment(v)
_clean_env_numbers([
    "COOLDOWN_SEC","PING_INTERVAL_SEC","PING_TIMEOUT_MS","LOSS_WINDOW",
    "LOSS_ALERT_PCT","LATENCY_ALERT_MS","JITTER_ALERT_MS","FLAP_SUPPRESS_SEC",
    "MEM_AVAIL_PCT_MIN","SWAP_USED_PCT_MAX","SWAPIN_PPS_MAX",
    "LOAD1_PER_CORE_MAX","CPU_IOWAIT_PCT_MAX",
    "NET_RX_BPS_ALERT","NET_TX_BPS_ALERT","NET_RX_PPS_ALERT","NET_TX_PPS_ALERT",
    "ROOT_FS_PCT_MAX","HEARTBEAT_HOURS","TRAFFIC_REPORT_EVERY_DAYS",
    "CERT_MIN_DAYS","AUTH_FAIL_COUNT","AUTH_FAIL_WINDOW_MIN","DAILY_BJ_SNAPSHOT_HOUR",
    "PING_TCP_PORT"
])

COOL = int(E("COOLDOWN_SEC","600"))
LOG_SILENT = E("LOG_SILENT", "0") == "1"
STATE_DIR = "/var/lib/sentinel"
STATE_FILE = os.path.join(STATE_DIR, "state.json")

# Probe settings
PING_TARGETS = [x.strip() for x in (E("PING_TARGETS","1.1.1.1,cloudflare.com").split(",")) if x.strip()]
PING_INTERVAL = float(E("PING_INTERVAL_SEC","60"))
PING_TIMEOUT_MS = int(E("PING_TIMEOUT_MS","1500"))
PING_ENGINE = E("PING_ENGINE","tcp").lower()
PING_TCP_PORT = int(E("PING_TCP_PORT","443"))
PING_RR = E("PING_ROUND_ROBIN","1") == "1"
LOSS_WINDOW = int(E("LOSS_WINDOW","20"))
LOSS_ALERT_PCT = float(E("LOSS_ALERT_PCT","60"))
LATENCY_ALERT_MS = float(E("LATENCY_ALERT_MS","400"))
JITTER_ALERT_MS = float(E("JITTER_ALERT_MS","150"))
FLAP_SUPPRESS = int(E("FLAP_SUPPRESS_SEC","300"))

# Thresholds
MEM_AVAIL_MIN = float(E("MEM_AVAIL_PCT_MIN","10"))
SWAP_USED_MAX = float(E("SWAP_USED_PCT_MAX","50"))
SWAPIN_PPS_MAX = float(E("SWAPIN_PPS_MAX","1000"))
LOAD1_PER_CORE_MAX = float(E("LOAD1_PER_CORE_MAX","1.5"))
CPU_IOWAIT_PCT_MAX = float(E("CPU_IOWAIT_PCT_MAX","50"))
NET_RX_BPS_ALERT = int(E("NET_RX_BPS_ALERT","5242880"))
NET_TX_BPS_ALERT = int(E("NET_TX_BPS_ALERT","5242880"))
NET_RX_PPS_ALERT = int(E("NET_RX_PPS_ALERT","2000"))
NET_TX_PPS_ALERT = int(E("NET_TX_PPS_ALERT","2000"))
ROOT_FS_PCT_MAX = int(E("ROOT_FS_PCT_MAX","90"))
HEARTBEAT_HOURS = float(E("HEARTBEAT_HOURS","24"))

# Others
NGINX_ACCESS = E("NGINX_ACCESS_LOG","/var/log/nginx/access.log")
_scan_sigs_raw = E("SCAN_SIGS", "").strip()
if _scan_sigs_raw:
    _pat = _scan_sigs_raw.strip("'\"")
    SCAN_SIGS = re.compile(_pat, re.I)
else:
    SCAN_SIGS = re.compile(
        r'/(?:\.env(?:\.|/|$)|wp-admin|wp-login|phpmyadmin|manager/html|'
        r'hudson|actuator(?:/|$)|solr/admin|HNAP1|vendor/phpunit|\.git/|'
        r'etc/passwd|boaform|shell|config\.php|id_rsa)', re.I
    )

_raw_watch = _strip_inline_comment(E("WATCH_PROCS","")) or ""
_raw_watch = _raw_watch.strip().strip('"').strip("'")
WATCH_PROCS = [x.strip() for x in _raw_watch.split(',') if x.strip()]
TRAFFIC_REPORT_EVERY_DAYS = int(E("TRAFFIC_REPORT_EVERY_DAYS","10"))
TRAFFIC_TRACK_IF = E("TRAFFIC_TRACK_IF","").strip()
_raw_req = (_strip_inline_comment(E("WATCH_PROCS_REQUIRE_ENABLED","1") or "1") or "").strip().strip('"').strip("'").lower()
WATCH_PROCS_REQUIRE_ENABLED = _raw_req in ("1","true","yes","on")
DAILY_BJ_SNAPSHOT_HOUR = int(E("DAILY_BJ_SNAPSHOT_HOUR","12"))

# TLS cert check
CERT_CHECK_DOMAINS = [x.strip() for x in (E("CERT_CHECK_DOMAINS","").split(",")) if x.strip()]
CERT_MIN_DAYS = int(E("CERT_MIN_DAYS","3"))
CERT_AUTO_DISCOVER = (E("CERT_AUTO_DISCOVER","1") == "1")
CERT_SEARCH_GLOBS = [x.strip() for x in (E("CERT_SEARCH_GLOBS","/etc/letsencrypt/live/*/fullchain.pem,/var/discourse/shared/standalone/ssl/*").split(",")) if x.strip()]

# SSH brute-force detection
AUTH_LOG_PATH = E("AUTH_LOG_PATH","/var/log/auth.log")
AUTH_FAIL_COUNT = int(E("AUTH_FAIL_COUNT","30"))
AUTH_FAIL_WINDOW_MIN = int(E("AUTH_FAIL_WINDOW_MIN","10"))

def _log_ex():
    if not LOG_SILENT: traceback.print_exc(file=sys.stderr)

class State:
    def __init__(self, path):
        self.path = path
        self.data = {"last_alert": {}, "last_beat": 0, "traffic": {}, "last_daily": ""}
        os.makedirs(os.path.dirname(path), exist_ok=True)
        try:
            with open(path, "r") as f: self.data.update(json.load(f))
        except Exception: pass
    def _save(self):
        try:
            with tempfile.NamedTemporaryFile("w", dir=os.path.dirname(self.path), delete=False) as tf:
                json.dump(self.data, tf)
                os.replace(tf.name, self.path)
        except Exception: _log_ex()
    def get(self, k, d=None): return self.data.get(k, d)
    def set(self, k, v): self.data[k] = v; self._save()
    def cooldown(self, key):
        now = time.time()
        last = self.data.setdefault("last_alert", {})
        if now - last.get(key, 0) < COOL: return True
        last[key] = now; self._save()
        return False

state = State(STATE_FILE)
HOST = socket.getfqdn() or socket.gethostname()

def esc(s): return re.sub(r'([_*\[\]()~`>#+\-={}|.!])', r'\\\1', str(s))

def _tg_send(txt, parse_mode=None):
    try:
        args = ["curl","-sS","-m","10","-X","POST",
                f"https://api.telegram.org/bot{TELE_TOKEN}/sendMessage",
                "-d", f"chat_id={TELE_CHAT_ID}",
                "--data-urlencode", f"text={txt}"]
        if parse_mode: args += ["-d", f"parse_mode={parse_mode}"]
        proc = subprocess.run(args, capture_output=True, text=True)
        ok = (proc.returncode == 0) and (
            ('"ok":true' in (proc.stdout or '')) or
            ('"ok": true' in (proc.stdout or ''))
        )
        return ok, (proc.stdout or '').strip()
    except Exception:
        _log_ex()
        return False, ""

def send(title, lines, icon="🔔"):
    if not TELE_TOKEN or not TELE_CHAT_ID: return
    ip = get_primary_ip()
    head=f"{icon} *{esc(HOST)}*\n`{esc(ip)}`\n*{esc(title)}*"
    body="\n".join(f"• {esc(x)}" for x in lines)
    _tg_send(f"{head}\n{body}", "MarkdownV2")

def get_primary_ip():
    try:
        r = subprocess.run(["ip","-o","route","get","1.1.1.1"], capture_output=True, text=True, timeout=2)
        m = re.search(r"\bsrc\s+(\d+\.\d+\.\d+\.\d+)", r.stdout or "")
        if m: return m.group(1)
    except Exception: pass
    return "0.0.0.0"

def systemd_active(unit):
    try:
        r = subprocess.run(["systemctl","is-active",unit], capture_output=True, text=True)
        return r.returncode == 0 and r.stdout.strip() == "active"
    except Exception:
        return False

def process_exists(pattern):
    try:
        r = subprocess.run(["pgrep","-f",pattern], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return r.returncode == 0
    except Exception:
        return False

def compute_watch_procs_auto():
    procs = []
    try:
        if systemd_active("nginx") or process_exists("nginx"):
            procs.append("nginx")
    except Exception: pass
    try:
        if systemd_active("docker") or process_exists("dockerd"):
            procs.append("dockerd")
    except Exception: pass
    return procs

def effective_watch_list():
    procs = WATCH_PROCS[:]
    auto_mode = (len(procs) == 0) or (len(procs) == 1 and procs[0].lower() == "auto")
    if auto_mode:
        return compute_watch_procs_auto()
    if WATCH_PROCS_REQUIRE_ENABLED:
        filtered = []
        for p in procs:
            alias = "dockerd" if p.strip().lower() == "docker" else p.strip()
            if systemd_active(alias) or process_exists(alias):
                filtered.append(alias)
        return filtered
    return [("dockerd" if p.strip().lower() == "docker" else p.strip()) for p in procs]

def _default_dev_via_proc():
    try:
        with open("/proc/net/route") as f:
            for ln in f:
                parts = ln.strip().split()
                if len(parts) >= 8 and parts[1] == "00000000" and parts[7] == "00000000":
                    return parts[0]
    except Exception: pass
    return None

def route_sig():
    try:
        r = subprocess.run(["ip","-o","route","get","1.1.1.1"], capture_output=True, text=True, timeout=2)
        out = r.stdout or ""
        m_dev = re.search(r" dev (\S+)", out)
        m_via = re.search(r" via (\S+)", out)
        m_src = re.search(r" src (\S+)", out)
        dev = m_dev.group(1) if m_dev else None
        via = m_via.group(1) if m_via else "direct"
        src = m_src.group(1) if m_src else None

        if not dev or not src:
            r2 = subprocess.run(["ip","-o","route","show","default"], capture_output=True, text=True, timeout=2)
            out2 = r2.stdout or ""
            if not dev:
                m2 = re.search(r" dev (\S+)", out2)
                if m2: dev = m2.group(1)
            if src is None:
                m2s = re.search(r" src (\S+)", out2)
                if m2s: src = m2s.group(1)

        if not dev:
            dev = _default_dev_via_proc()
        if not src:
            src = get_primary_ip()
        return dev or "?", via or "direct", src or get_primary_ip()
    except Exception:
        return "?", "direct", get_primary_ip()

def _delta(new, old): return (new - old) if new >= old else (2**64 - old + new)

# ==== Metrics ====
vm_prev, stat_prev, last_net = None, None, None
_excl = re.compile(r"^(lo|docker\d*|veth|br-|tun|tap|kube|wg|tailscale)")

def mem_swap_metrics():
    global vm_prev
    m={}
    with open("/proc/meminfo") as f:
        for ln in f:
            k,rest=ln.split(":",1); v=int(rest.strip().split()[0]); m[k]=v*1024
    total, avail = m.get("MemTotal",1), m.get("MemAvailable",0)
    st, sf = m.get("SwapTotal",0), m.get("SwapFree",0); su=max(0, st-sf)
    pin=0.0
    try:
        with open("/proc/vmstat") as f:
            cur={k:int(v) for k,v in (x.split() for x in f)}
        now=time.time()
        if not vm_prev: vm_prev=(now, cur.get("pswpin",0))
        t0,pin0=vm_prev; dt=max(1e-3, now-t0); pin=(cur.get("pswpin",0)-pin0)/dt
        vm_prev=(now, cur.get("pswpin",0))
    except Exception: pass
    return total, avail, st, su, pin

def iowait_pct():
    global stat_prev
    with open("/proc/stat") as f: a=f.readline().split()
    curd=dict(zip("user nice system idle iowait irq softirq steal guest guest_nice".split(), map(int,a[1:])))
    if not stat_prev: stat_prev=(time.time(),curd); return 0.0
    d={k:curd[k]-stat_prev[1][k] for k in curd}; total=sum(d.values()) or 1
    stat_prev=(time.time(),curd)
    return 100.0*d.get("iowait",0)/total

def load1_over():
    cores=os.cpu_count() or 1
    with open("/proc/loadavg") as f: l1=float(f.read().split()[0])
    return l1, (l1>cores*LOAD1_PER_CORE_MAX), cores

def get_net_bytes():
    data = {}
    try: # Prioritize 64-bit sysfs counters
        for name in os.listdir("/sys/class/net"):
            if _excl.match(name): continue
            p = f"/sys/class/net/{name}/statistics"
            try:
                with open(f"{p}/rx_bytes") as f: rx=int(f.read())
                with open(f"{p}/rx_packets") as f: rxp=int(f.read())
                with open(f"{p}/tx_bytes") as f: tx=int(f.read())
                with open(f"{p}/tx_packets") as f: txp=int(f.read())
                data[name] = (rx, rxp, tx, txp)
            except Exception: continue
        if data: return data
    except Exception: pass
    # Fallback to /proc/net/dev
    data={}
    try:
        with open("/proc/net/dev") as f:
            for ln in f:
                if ":" not in ln: continue
                name,rest=[x.strip() for x in ln.split(":",1)]
                if _excl.match(name): continue
                cols=rest.split(); rxB,rxP,txB,txP=int(cols[0]),int(cols[1]),int(cols[8]),int(cols[9])
                data[name]=(rxB,rxP,txB,txP)
    except Exception: pass
    return data

def net_rates():
    global last_net
    now, data = time.time(), get_net_bytes()
    if not last_net: last_net=(now,data); return {}
    t0, old_data = last_net; dt=max(1e-3, now-t0); rates={}
    for k, v_new in data.items():
        if k in old_data:
            v_old = old_data[k]
            rates[k] = tuple(_delta(v_new[i], v_old[i]) / dt for i in range(4))
    last_net=(now,data); return rates

def root_usage_pct():
    st=os.statvfs("/"); used=(st.f_blocks-st.f_bfree)*st.f_frsize; total=st.f_blocks*st.f_frsize or 1
    return int(used*100/total)

# ==== Log Watch (optional) ====
# 支援兩種常見格式：
# 1) 自定義："host" ip "req" status size ... "ua"
# 2) combined：ip - - [ts] "req" status size "ref" "ua"
LOG_RE_Q = re.compile(r'^"(?P<host>[^"]+)"\s+(?P<ip>[0-9a-fA-F\.:]+)\s+"(?P<req>[^"]+)"\s+(?P<st>\d{3})\s+(?P<sz>\S+).+"(?P<ua>[^"]*)"$')
LOG_RE_COMBINED = re.compile(r'^(?P<ip>\S+)\s+\S+\s+\S+\s+\[[^\]]+\]\s+"(?P<req>[^"]+)"\s+(?P<st>\d{3})\s+(?P<sz>\S+)\s+"[^"]*"\s+"(?P<ua>[^"]*)"')
def log_watch():
    path = NGINX_ACCESS.strip()
    if not path: return
    p = None
    try:
        if path.startswith("container:"):
            _, spec = path.split("container:", 1); name, cpath = spec.split(":", 1)
            p = subprocess.Popen(["docker","exec","-i",name,"bash","-lc",f"tail -n0 -F {shlex.quote(cpath)}"], stdout=subprocess.PIPE, text=True, bufsize=1)
        elif os.path.exists(path):
            p = subprocess.Popen(["tail","-n0","-F",path], stdout=subprocess.PIPE, text=True, bufsize=1)
        if not p: return
        for line in p.stdout:
            s = line.strip()
            m = LOG_RE_Q.match(s)
            host = "-"
            if not m:
                m = LOG_RE_COMBINED.match(s)
                if not m: continue
            else:
                host = m["host"]
            ip, req, ua = m["ip"], m["req"], m["ua"]
            try:
                path_part = req.split(" ", 2)[1]
            except Exception:
                continue
            if SCAN_SIGS.search(path_part) and not state.cooldown(f"scan_{ip}"):
                send("🚨 Scan signature", [f"src {ip}", f"Host {host}", f"Path {path_part}", f"UA {ua[:120]}"])
    except FileNotFoundError:
        pass
    except Exception:
        _log_ex()

# ==== Net Probe ====
def _tcp_probe(host, port=443, timeout=0.9):
    start = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True, (time.monotonic() - start) * 1000
    except Exception: return False, None

class NetProbe:
    def __init__(self, targets):
        self.targets = targets or ["1.1.1.1"]; self.idx = 0
        self.hist={t: deque(maxlen=LOSS_WINDOW) for t in self.targets}
        self.last_down, self.last_up, self.last_route = None, 0, route_sig()
    def ping1(self, target):
        if PING_ENGINE == "tcp":
            return _tcp_probe(target, PING_TCP_PORT, timeout=PING_TIMEOUT_MS/1000.0)
        try:
            to=max(1,int((PING_TIMEOUT_MS+999)//1000))
            r=subprocess.run(["ping","-n","-c","1","-W",str(to),target],capture_output=True,text=True, timeout=to+1)
            ok=(r.returncode==0); rtt=None
            m=re.search(r"time=(\d+\.?\d*) ms", r.stdout or "")
            if m: rtt=float(m.group(1))
            return ok, rtt
        except Exception: return False, None
    def step(self):
        targets = [self.targets[self.idx % len(self.targets)]] if PING_RR else self.targets; self.idx+=1
        for t in targets:
            ok,rtt = self.ping1(t); self.hist.setdefault(t, deque(maxlen=LOSS_WINDOW)).append((ok,rtt))
        if all(h and not any(x[0] for x in list(h)[-3:]) for h in self.hist.values()):
            if self.last_down is None and not state.cooldown("net_down"): self.last_down=time.time(); send("Network down", [f"targets {', '.join(self.targets)}"], icon="🛑")
        elif self.last_down is not None and (time.time()-self.last_up)>FLAP_SUPPRESS:
            dur=time.time()-self.last_down; self.last_up=time.time(); self.last_down=None
            if not state.cooldown("net_up"): send("Network recovered", [f"duration {dur:.0f}s"], icon="✅")
        wins, losses, samples = [], 0, 0
        for h in self.hist.values():
            wins.extend([x[1] for x in h if x[0] and x[1] is not None]); losses+=sum(1 for x in h if not x[0]); samples+=len(h)
        if samples>=max(5, LOSS_WINDOW//2) and 100.0*losses/max(1,samples)>=LOSS_ALERT_PCT and not state.cooldown("loss_high"): send("Packet loss high", [f"loss {100.0*losses/samples:.0f}% over {samples} probes"], icon="🌐")
        if len(wins) > 3:
            try:
                med=statistics.median(wins); q=statistics.quantiles(wins, n=4); jitter=q[2]-q[0]
                if med>=LATENCY_ALERT_MS and not state.cooldown("rtt_high"): send("High latency", [f"median {med:.0f} ms (n={len(wins)})"], icon="⌛")
                if jitter>=JITTER_ALERT_MS and not state.cooldown("jitter_high"): send("High jitter", [f"IQR {jitter:.0f} ms (n={len(wins)})"], icon="〰️")
            except statistics.StatisticsError: pass
        rs=route_sig()
        if rs!=self.last_route and not state.cooldown("route_change"): self.last_route=rs; send("Route changed", [f"dev {rs[0]}", f"via {rs[1]}", f"src {rs[2]}"], icon="🔀")

# ==== SSH brute force (tail auth.log) ====
def ssh_watch():
    path = AUTH_LOG_PATH
    if not os.path.exists(path): return
    patt = re.compile(r"(?:Failed password|Invalid user).+ from ([0-9.]+)")
    buckets = defaultdict(deque)  # ip -> timestamps
    win = AUTH_FAIL_WINDOW_MIN * 60
    try:
        p = subprocess.Popen(["tail","-n","0","-F",path], stdout=subprocess.PIPE, text=True, bufsize=1)
        for line in p.stdout:
            m = patt.search(line)
            if not m: continue
            ip = m.group(1)
            now = time.time()
            dq = buckets[ip]
            dq.append(now)
            while dq and now - dq[0] > win: dq.popleft()
            if len(dq) >= AUTH_FAIL_COUNT and not state.cooldown(f"ssh_bruteforce_{ip}"):
                send("🛡️ SSH brute-force", [f"src {ip}", f"fails ≥ {AUTH_FAIL_COUNT} in {AUTH_FAIL_WINDOW_MIN} min"])
    except Exception: _log_ex()

# ==== TLS certificate checks ====
def cert_days_from_file(p):
    try:
        out = subprocess.check_output(["openssl","x509","-enddate","-noout","-in",p], text=True, stderr=subprocess.DEVNULL).strip()
        m = re.search(r"notAfter=(.+)", out)
        if not m: return None
        exp = datetime.strptime(m.group(1), "%b %d %H:%M:%S %Y %Z")
        return (exp - datetime.utcnow()).days
    except Exception:
        return None

def cert_days_from_domain(host, port=443):
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((host, port), timeout=3) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as ssock:
                cert = ssock.getpeercert()
        notAfter = cert.get('notAfter')
        if not notAfter: return None
        exp = datetime.strptime(notAfter, "%b %d %H:%M:%S %Y %Z")
        return (exp - datetime.utcnow()).days
    except Exception:
        return None

def discover_nginx_certs():
    paths = set()
    try:
        r = subprocess.run(["nginx","-T"], capture_output=True, text=True, timeout=5, stderr=subprocess.DEVNULL)
        if r.returncode == 0:
            for line in (r.stdout or "").splitlines():
                m = re.search(r"^\s*ssl_certificate\s+([^;#\s]+)", line)
                if m:
                    p = m.group(1).strip().strip("'\"")
                    if os.path.exists(p):
                        paths.add(p)
    except FileNotFoundError: pass
    except Exception: _log_ex()
    return paths

def cert_check_loop():
    last_check = 0
    while True:
        try:
            if time.time() - last_check < 6*3600:
                time.sleep(60); continue
            last_check = time.time()
            alerts = []
            paths_to_check = set()

            if CERT_AUTO_DISCOVER:
                for pat in CERT_SEARCH_GLOBS:
                    for p in glob.glob(pat):
                        if os.path.exists(p): paths_to_check.add(p)
                paths_to_check.update(discover_nginx_certs())
            
            for p in sorted(list(paths_to_check)):
                d = cert_days_from_file(p)
                if d is not None and d <= CERT_MIN_DAYS:
                    alerts.append(f"local {p} expires in {d}d")

            for host in CERT_CHECK_DOMAINS:
                d = cert_days_from_domain(host)
                if d is not None and d <= CERT_MIN_DAYS:
                    alerts.append(f"{host} expires in {d}d")

            if alerts and not state.cooldown("cert_expire"):
                send("🔐 TLS certificate expiring", alerts)
        except Exception:
            _log_ex()
        time.sleep(60)

# ==== Beijing-time daily snapshot ====
def bj_now():
    return datetime.utcnow() + timedelta(hours=8)

def try_daily_snapshot():
    try:
        bj = bj_now()
        if bj.hour != DAILY_BJ_SNAPSHOT_HOUR or bj.minute > 5: return
        key = bj.strftime("%Y-%m-%d")
        if state.get("last_daily","") == key: return

        l1,_,cores=load1_over(); rp=root_usage_pct(); mt,ma,st,su,pin=mem_swap_metrics(); ap=ma*100.0/max(1,mt)
        rates=net_rates(); rxB=txB=rxP=txP=0
        if rates:
            rxB=sum(v[0] for v in rates.values()); rxP=sum(v[1] for v in rates.values())
            txB=sum(v[2] for v in rates.values()); txP=sum(v[3] for v in rates.values())
        nets = get_net_bytes()
        if TRAFFIC_TRACK_IF and TRAFFIC_TRACK_IF in nets:
            rx_tot, tx_tot = nets[TRAFFIC_TRACK_IF][0], nets[TRAFFIC_TRACK_IF][2]
        else:
            rx_tot, tx_tot = sum(v[0] for v in nets.values()), sum(v[2] for v in nets.values())
        d = state.get("traffic", {}); month = d.get("month", bj.strftime("%Y-%m"))
        used_rx = _delta(rx_tot, d.get("start_rx", rx_tot))
        used_tx = _delta(tx_tot, d.get("start_tx", tx_tot))
        dev, via, src = route_sig()
        send("Daily Snapshot", [
            f"Beijing {bj.strftime('%Y-%m-%d %H:%M')}",
            f"Load {l1:.2f}/{cores}",
            f"Mem avail {ap:.1f}% | swap {(su*100.0/max(1,st)) if st>0 else 0:.0f}% | swapin {pin:.0f} p/s",
            f"IOwait {iowait_pct():.0f}%",
            f"Net rx {rxB/1048576:.1f} MB/s {int(rxP)}pps | tx {txB/1048576:.1f} MB/s {int(txP)}pps",
            f"/ usage {rp}%",
            f"Traffic {month} ↓{used_rx/(1024**3):.2f} GB ↑{used_tx/(1024**3):.2f} GB Σ{(used_rx+used_tx)/(1024**3):.2f} GB",
            f"Route dev {dev} via {via} src {src}",
        ], icon="🕛")
        state.set("last_daily", key)
    except Exception: _log_ex()

# ==== Monthly traffic (last-month summary then reset) ====
def check_monthly_traffic():
    nets = get_net_bytes()
    if TRAFFIC_TRACK_IF and TRAFFIC_TRACK_IF in nets:
        rx, tx = nets[TRAFFIC_TRACK_IF][0], nets[TRAFFIC_TRACK_IF][2]
    else:
        rx, tx = sum(v[0] for v in nets.values()), sum(v[2] for v in nets.values())

    today = date.today()
    month_key = today.strftime("%Y-%m")
    d = state.get("traffic", {})

    if not d or d.get("month") != month_key:
        if d: # Only report if there was a previous month's data
            used_rx = _delta(rx, d.get("start_rx", rx))
            used_tx = _delta(tx, d.get("start_tx", tx))
            total   = used_rx + used_tx
            send("📦 Last Month Traffic", [
                f"Period: {d.get('month','unknown')}",
                f"Down:  {used_rx/(1024**3):.2f} GB",
                f"Up:    {used_tx/(1024**3):.2f} GB",
                f"Total: {total/(1024**3):.2f} GB",
            ], icon="📦")
        
        d_new = {"month": month_key, "start_rx": rx, "start_tx": tx, "last_report_day": 0}
        state.set("traffic", d_new)
        if not d: # First run
             send("📊 Traffic Counter Initialized", [f"Tracking from {month_key}"], icon="🔄")
        else: # New month
             send("🔄 Traffic Counter Reset", [f"New cycle {month_key}"], icon="🔄")
        return

    used_rx = _delta(rx, d.get("start_rx", rx))
    used_tx = _delta(tx, d.get("start_tx", tx))
    total   = used_rx + used_tx

    day, last_day = today.day, calendar.monthrange(today.year, today.month)[1]
    report_days = set()
    if TRAFFIC_REPORT_EVERY_DAYS > 0:
        report_days = {dd for dd in range(1, last_day+1) if dd % TRAFFIC_REPORT_EVERY_DAYS == 0}
    report_days.add(last_day)

    if day in report_days and d.get("last_report_day") != day:
        send("🗓️ Monthly Traffic", [
            f"Period: {month_key}",
            f"Down:  {used_rx/(1024**3):.2f} GB",
            f"Up:    {used_tx/(1024**3):.2f} GB",
            f"Total: {total/(1024**3):.2f} GB",
        ], icon="🗓️")
        d["last_report_day"] = day
        state.set("traffic", d)

# ==== Main metrics loop ====
def metrics_loop():
    while True:
        try:
            if HEARTBEAT_HOURS>0 and time.time()-state.get("last_beat",0)>HEARTBEAT_HOURS*3600:
                l1,_,cores=load1_over(); rp=root_usage_pct(); mt,ma,_,_,_=mem_swap_metrics(); ap=ma*100.0/max(1,mt)
                send("System OK", [f"Load {l1:.2f}/{cores}", f"Mem avail {ap:.1f}%", f"/ usage {rp}%"], icon="✅")
                state.set("last_beat", time.time())

            mt,ma,st,su,pin=mem_swap_metrics(); avail_pct=ma*100.0/max(1,mt); swap_pct=(su*100.0/max(1,st)) if st>0 else 0.0
            if avail_pct<=MEM_AVAIL_MIN and not state.cooldown("mem_low"): send("Memory low", [f"avail {avail_pct:.1f}%"], icon="🧠")
            if swap_pct>=SWAP_USED_MAX and not state.cooldown("swap_high"): send("Swap high", [f"swap {swap_pct:.0f}%"], icon="🧠")
            if pin>=SWAPIN_PPS_MAX and not state.cooldown("swap_thrash"): send("Swap thrash", [f"swapin {pin:.0f} p/s"], icon="🧠")

            l1,over,cores=load1_over()
            if over and not state.cooldown("load_high"): send("Load high", [f"load1 {l1:.2f} cores {cores}"], icon="🔥")
            iow=iowait_pct()
            if iow>=CPU_IOWAIT_PCT_MAX and not state.cooldown("iowait_high"): send("IO wait high", [f"iowait {iow:.0f}%"], icon="💿")

            rates=net_rates()
            if rates:
                rxB=sum(v[0] for v in rates.values()); rxP=sum(v[1] for v in rates.values()); txB=sum(v[2] for v in rates.values()); txP=sum(v[3] for v in rates.values())
                if (rxB>=NET_RX_BPS_ALERT or rxP>=NET_RX_PPS_ALERT) and not state.cooldown("net_rx"): send("RX spike", [f"rx {rxB/1048576:.1f} MB/s {int(rxP)}pps"], icon="🌐")
                if (txB>=NET_TX_BPS_ALERT or txP>=NET_TX_PPS_ALERT) and not state.cooldown("net_tx"): send("TX spike", [f"tx {txB/1048576:.1f} MB/s {int(txP)}pps"], icon="🌐")

            if (rpct:=root_usage_pct())>=ROOT_FS_PCT_MAX and not state.cooldown("disk_full"): send("Root FS high", [f"/ usage {rpct}%"], icon="🧱")

            for p in effective_watch_list():
                try: subprocess.run(["pgrep","-f",p], check=True, stdout=subprocess.DEVNULL)
                except subprocess.CalledProcessError:
                    if not state.cooldown(f"proc_down_{p}"): send("Process down", [f"{p} not running"], icon="💀")

            check_monthly_traffic()
            try_daily_snapshot()

        except Exception: _log_ex()
        time.sleep(10)

def probe_thread():
    if not PING_TARGETS: return
    p=NetProbe(PING_TARGETS)
    while True:
        try: p.step()
        except Exception: _log_ex()
        time.sleep(PING_INTERVAL)

if __name__=="__main__":
    for target in (log_watch, probe_thread, ssh_watch, cert_check_loop):
        threading.Thread(target=target, daemon=True).start()
    
    if not state.cooldown("startup_beacon"):
        watch_list = effective_watch_list()
        send("Sentinel started", ["service up and watching", f"watching: {','.join(watch_list) if watch_list else 'auto'}"], icon="🚀")
    
    metrics_loop()
PY
chmod +x /usr/local/bin/sentinel.py

# ---- systemd 服务 ----
echo ">>> [4/5] Installing systemd unit..."
cat >/etc/systemd/system/sentinel.service <<'EOF'
[Unit]
Description=Sentinel - Lightweight Host Watcher
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/sentinel/sentinel.env
ExecStart=/usr/bin/python3 /usr/local/bin/sentinel.py
Restart=always
RestartSec=5
Nice=10
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
# 资源保护
MemoryMax=150M
TasksMax=64

[Install]
WantedBy=multi-user.target
EOF

echo ">>> [5/5] Enabling & starting service..."
systemctl daemon-reload
systemctl enable --now sentinel.service

# 自检通知
(
  set -a
  . /etc/sentinel/sentinel.env
  set +a
  hostip="$(ip -o route get 1.1.1.1 | sed -n 's/.* src \([0-9.]\+\).*/\1/p' || echo 'N/A')"
  TEXT="✅ Sentinel on $(hostname -f) (${hostip}) has been installed/updated successfully."
  # 使用 tmsg 工具发送，更简洁
  /usr/local/bin/tmsg "$TEXT"
)

echo ""
echo "========================================================"
echo " Sentinel has been successfully installed and started."
echo "========================================================"
echo "-> To view live logs: journalctl -u sentinel.service -f"
echo "-> To check status:   systemctl status sentinel.service --no-pager"
echo "-> Configuration:     /etc/sentinel/sentinel.env"
echo "-> Persistent State:  /var/lib/sentinel/state.json"
echo "========================================================"