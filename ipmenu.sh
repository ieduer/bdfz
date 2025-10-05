#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ============ 基本變數 ============
APP_NAME="IP Menu"
APP_DIR="${HOME}/ip_menu"
VENV_DIR="${HOME}/.venvs/menubar-ip"
PY_FILE="${APP_DIR}/ip_menu.py"
LABEL="com.ipmenu.app"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_OUT="${APP_DIR}/launchd.out.log"
LOG_ERR="${APP_DIR}/launchd.err.log"

# env 覆蓋（可選）
: "${IPINFO_TOKEN:=}"   # 你的 token（可被外部環境覆蓋）
: "${IPMENU_PREFIX:=}"                # 狀態列前綴；預設空字串

# ============ 工具函數 ============
say() { printf "\033[1;32m==>\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[err]\033[0m  %s\n" "$*"; }

_have() { command -v "$1" >/dev/null 2>&1; }

brew_prefix() {
  if [[ -d "/opt/homebrew" ]]; then echo "/opt/homebrew";
  elif [[ -d "/usr/local/Homebrew" ]]; then echo "/usr/local";
  else echo ""; fi
}

ensure_brew_and_python() {
  if ! _have brew; then
    err "Homebrew 未安裝，請先安裝： https://brew.sh/"
    exit 1
  fi
  if ! _have python3; then
    say "安裝 python3…"
    brew install python
  fi
}

ensure_venv() {
  mkdir -p "${APP_DIR}"
  if [[ ! -d "${VENV_DIR}" ]]; then
    say "建立 venv：${VENV_DIR}"
    python3 -m venv "${VENV_DIR}"
  fi
  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  python -m pip install --upgrade pip wheel >/dev/null
  # rumps + requests + netifaces + pyobjc（GUI/通知必備）
  python -m pip install --upgrade rumps requests netifaces pyobjc-core pyobjc-framework-Cocoa >/dev/null
}

write_python() {
  mkdir -p "${APP_DIR}"
  # 將 Python 內的 IPINFO_TOKEN / 前綴交給環境變數，程式也有預設
  cat > "${PY_FILE}" <<'PYCODE'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import rumps, os, json, time, subprocess, re, ipaddress, io, gzip, fcntl, atexit, hashlib
from pathlib import Path
import netifaces, requests
import threading
from threading import Lock
from bisect import bisect_right

APP_NAME = "IP Menu"
APP_DIR  = Path(__file__).resolve().parent
CFG_DIR  = APP_DIR / ".config" / "ipmenu"
CFG_FILE = CFG_DIR / "config.json"

# sapics 離線資料放在專案資料夾
SAPDB_DIR = APP_DIR / "sapdb"

LA_PLIST = Path.home() / "Library" / "LaunchAgents" / "com.ipmenu.app.plist"

DEFAULT_CFG = {
    "public_mode": "ipv4",          # off | ipv4 | ipv6 | auto
    "country_format": "code",       # off | code | name
    "ipv4_format": "first_last",    # full | first2 | first_last | last2
    "show_public": True,
    "refresh_interval_sec": 300,
    "notify_on_change": True,
    "play_sound": True,
    "start_at_login": False,
    "show_tunnels": False,
    "show_linklocal_v6": False,
    "asn_source": "online",         # online | offline | auto
    "ipinfo_token": "f93dcc5e89b06f",
    "sapdb_auto_update_days": 30,
    "fast_probe_when_singbox": True
}

PUBLIC_TTL_SEC = 30
LAN_CHECK_SEC  = 2
FAST_PROBE_SEC = 3

GITHUB_URL = "https://github.com/ieduer"
TITLE_PREFIX = os.environ.get("IPMENU_PREFIX", "")

_SAP_NOTIFY_MIN = 6 * 3600
_sap_last_info_ts = 0
_sap_last_fail_ts = 0
_sap_lock = Lock()

def is_singbox_running():
    try:
        subprocess.check_call(["/usr/bin/pgrep", "-lf", "[s]ing-box"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); return True
    except Exception:
        try:
            subprocess.check_call(["/usr/bin/pgrep", "-lf", "[s]ingbox"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); return True
        except Exception:
            return False

_LOCK_FD = None
def acquire_single_instance_lock():
    global _LOCK_FD
    lock_path = "/tmp/ipmenu.lock"
    _LOCK_FD = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(_LOCK_FD, fcntl.LOCK_EX | fcntl.LOCK_NB)
        @atexit.register
        def _cleanup():
            try:
                fcntl.flock(_LOCK_FD, fcntl.LOCK_UN)
                os.close(_LOCK_FD)
            except Exception: pass
        return True
    except BlockingIOError:
        return False

def copy_to_clipboard(text: str):
    try:
        from AppKit import NSPasteboard
        pb = NSPasteboard.generalPasteboard()
        pb.clearContents()
        pb.setString_forType_(text, "public.utf8-plain-text")
        return True
    except Exception:
        return False

def online_whois(ip, token=""):
    try:
        headers = {}
        if token: headers["Authorization"] = f"Bearer {token}"
        j = requests.get(f"https://ipinfo.io/{ip}/json", headers=headers, timeout=3.5).json()
        org = j.get("org") or ""
        asn_num, asn_org = None, None
        if org.startswith("AS"):
            parts = org.split(" ", 1)
            asn_num = parts[0][2:] if len(parts) > 0 else None
            asn_org = parts[1] if len(parts) > 1 else None
        return {"ok": True, "country": j.get("country"), "country_name": None,
                "asn": asn_num, "asname": asn_org, "isp": j.get("org") or asn_org}
    except Exception: pass
    try:
        url = f"http://ip-api.com/json/{ip}?fields=status,country,countryCode,as,asname,org,isp,query"
        j = requests.get(url, timeout=3.5).json()
        if j.get("status") == "success":
            asn = None
            as_field = j.get("as") or ""
            if as_field.startswith("AS"):
                asn = as_field[2:].split()[0]
            return {"ok": True, "country": j.get("countryCode"), "country_name": j.get("country"),
                    "asn": asn, "asname": j.get("asname"), "isp": j.get("isp") or j.get("org")}
    except Exception: pass
    return {"ok": False}

SAP_COMBINED_GZ = "ip2asn-combined.tsv.gz"
SAP_V4_GZ = "ip2asn-v4.tsv.gz"
SAP_V6_GZ = "ip2asn-v6.tsv.gz"
SAP_BASES = [
    "https://raw.githubusercontent.com/sapics/ip-location-db/main/ip2asn/",
    "https://cdn.jsdelivr.net/gh/sapics/ip-location-db@latest/ip2asn/",
    "https://fastly.jsdelivr.net/gh/sapics/ip-location-db@latest/ip2asn/"
]

def need_sapdb_update(days=30):
    paths = [SAPDB_DIR / "ip2asn-combined.tsv", SAPDB_DIR / "ip2asn-v4.tsv", SAPDB_DIR / "ip2asn-v6.tsv"]
    existing = [p for p in paths if p.exists()]
    if not existing: return True
    mt = min(p.stat().st_mtime for p in existing)
    return (time.time() - mt) >= days * 86400

def _head_first(relname, timeout=8):
    for base in SAP_BASES:
        try:
            r = requests.head(base + relname, timeout=timeout, allow_redirects=True)
            if r.status_code == 200: return r.headers
        except Exception: continue
    return {}

def _validate_tsv(path: Path, min_lines: int = 500):
    try:
        with path.open("r", encoding="utf-8", errors="ignore") as f:
            for i, _ in enumerate(f, 1):
                if i >= min_lines: return True
        return False
    except Exception: return False

def _download_with_fallbacks(relname, timeout=15, retries=2):
    last = None
    for base in SAP_BASES:
        url = base + relname
        for i in range(retries):
            try:
                r = requests.get(url, timeout=timeout); r.raise_for_status()
                return r.content
            except Exception as e:
                last = e; time.sleep(0.6 + 0.6*i)
            try:
                data = subprocess.check_output(
                    ["/usr/bin/curl","-L","-sS","--connect-timeout","5","--max-time",str(timeout),url],
                    stderr=subprocess.DEVNULL)
                if data: return data
            except Exception as e2:
                last = e2
    if last: raise last
    raise RuntimeError("download failed")

def ensure_sapdb(days):
    SAPDB_DIR.mkdir(parents=True, exist_ok=True)
    if not _sap_lock.acquire(blocking=False): return
    try:
        if not need_sapdb_update(days): return
        try:
            headers = _head_first(SAP_COMBINED_GZ)
            cl = int(headers.get("Content-Length","0"))
            local_gz = SAPDB_DIR / SAP_COMBINED_GZ
            if local_gz.exists() and cl>0 and local_gz.stat().st_size==cl:
                import gzip as _gz
                if not (SAPDB_DIR/"ip2asn-combined.tsv").exists():
                    with _gz.open(local_gz,"rb") as f:
                        (SAPDB_DIR/"ip2asn-combined.tsv").write_bytes(f.read())
                if _validate_tsv(SAPDB_DIR/"ip2asn-combined.tsv"): return
        except Exception: pass

        global _sap_last_info_ts
        if time.time() - _sap_last_info_ts > _SAP_NOTIFY_MIN:
            try: rumps.notification(APP_NAME,"Updating offline ASN DB","Downloading from sapics/ip-location-db…")
            except Exception: pass
            _sap_last_info_ts = time.time()

        try:
            data = _download_with_fallbacks(SAP_COMBINED_GZ)
            (SAPDB_DIR/SAP_COMBINED_GZ).write_bytes(data)
            import gzip as _gz, io as _io
            with _gz.open(_io.BytesIO(data),"rb") as f: content=f.read()
            (SAPDB_DIR/"ip2asn-combined.tsv").write_bytes(content)
            if not _validate_tsv(SAPDB_DIR/"ip2asn-combined.tsv"):
                try: (SAPDB_DIR/"ip2asn-combined.tsv").unlink()
                except Exception: pass
                raise RuntimeError("combined TSV validation failed")
            for p in ["ip2asn-v4.tsv","ip2asn-v6.tsv"]:
                fp=SAPDB_DIR/p
                if fp.exists():
                    try: fp.unlink()
                    except Exception: pass
            try: rumps.notification(APP_NAME,"Offline ASN DB ready","ip2asn-combined.tsv updated")
            except Exception: pass
            return
        except Exception: pass

        try:
            d4=_download_with_fallbacks(SAP_V4_GZ)
            (SAPDB_DIR/SAP_V4_GZ).write_bytes(d4)
            import gzip as _gz, io as _io
            with _gz.open(_io.BytesIO(d4),"rb") as f:
                (SAPDB_DIR/"ip2asn-v4.tsv").write_bytes(f.read())
            if not _validate_tsv(SAPDB_DIR/"ip2asn-v4.tsv"):
                try: (SAPDB_DIR/"ip2asn-v4.tsv").unlink()
                except Exception: pass
            else:
                try: rumps.notification(APP_NAME,"Offline ASN DB ready","ip2asn-v4.tsv updated")
                except Exception: pass
        except Exception: pass

        try:
            d6=_download_with_fallbacks(SAP_V6_GZ)
            (SAPDB_DIR/SAP_V6_GZ).write_bytes(d6)
            import gzip as _gz, io as _io
            with _gz.open(_io.BytesIO(d6),"rb") as f:
                (SAPDB_DIR/"ip2asn-v6.tsv").write_bytes(f.read())
            if not _validate_tsv(SAPDB_DIR/"ip2asn-v6.tsv"):
                try: (SAPDB_DIR/"ip2asn-v6.tsv").unlink()
                except Exception: pass
            else:
                try: rumps.notification(APP_NAME,"Offline ASN DB ready","ip2asn-v6.tsv updated")
                except Exception: pass
        except Exception: pass

        if not any((SAPDB_DIR/p).exists() for p in ("ip2asn-combined.tsv","ip2asn-v4.tsv","ip2asn-v6.tsv")):
            global _sap_last_fail_ts
            if time.time()-_sap_last_fail_ts > _SAP_NOTIFY_MIN:
                try: rumps.notification(APP_NAME,"Offline ASN DB failed","Could not prepare sapics database")
                except Exception: pass
                _sap_last_fail_ts=time.time()
        else:
            return
    finally:
        try: _sap_lock.release()
        except Exception: pass

class SapASNDB:
    def __init__(self):
        self.v4=[]; self.v4_keys=[]
        self.v6=[]; self.v6_keys=[]
        self.loaded=False
    def _add_range(self, fam, start_ip, end_ip, asn, cc, name):
        if fam==4:
            s=int(ipaddress.IPv4Address(start_ip)); e=int(ipaddress.IPv4Address(end_ip))
            self.v4.append((s,e,asn,name,cc))
        else:
            s=int(ipaddress.IPv6Address(start_ip)); e=int(ipaddress.IPv6Address(end_ip))
            self.v6.append((s,e,asn,name,cc))
    def load(self):
        path_comb=SAPDB_DIR/"ip2asn-combined.tsv"
        if path_comb.exists(): self._load_tsv(path_comb, combined=True)
        else:
            p4, p6 = SAPDB_DIR/"ip2asn-v4.tsv", SAPDB_DIR/"ip2asn-v6.tsv"
            if p4.exists(): self._load_tsv(p4, combined=False, fam=4)
            if p6.exists(): self._load_tsv(p6, combined=False, fam=6)
        self.v4.sort(key=lambda x:x[0]); self.v4_keys=[x[0] for x in self.v4]
        self.v6.sort(key=lambda x:x[0]); self.v6_keys=[x[0] for x in self.v6]
        self.loaded=True
    def _load_tsv(self, path: Path, combined=True, fam=None):
        with path.open("r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if not line or line.startswith("#"): continue
                parts=line.strip().split("\t")
                if len(parts)<6: continue
                start_ip,end_ip,asn,_rir,cc,asname=parts[:6]
                if asn=="0" or asn=="AS0": asn=None
                family=6 if ":" in start_ip else 4
                if not combined and fam and family!=fam: continue
                self._add_range(family,start_ip,end_ip,asn,cc or None, asname or None)
    def lookup(self, ip_str: str):
        if not self.loaded: return None
        if _is_ipv4(ip_str):
            x=int(ipaddress.IPv4Address(ip_str)); idx=bisect_right(self.v4_keys,x)-1
            if 0<=idx<len(self.v4):
                s,e,asn,asname,cc=self.v4[idx]
                if s<=x<=e: return {"asn":asn,"asname":asname,"country":cc}
        elif _is_ipv6(ip_str):
            x=int(ipaddress.IPv6Address(ip_str)); idx=bisect_right(self.v6_keys,x)-1
            if 0<=idx<len(self.v6):
                s,e,asn,asname,cc=self.v6[idx]
                if s<=x<=e: return {"asn":asn,"asname":asname,"country":cc}
        return None

ASNDB = SapASNDB()

def _curl_ip(flags):
    try:
        out = subprocess.check_output(["/usr/bin/curl","-sS","-m","3"]+flags,
                                      stderr=subprocess.DEVNULL).decode("utf-8","ignore").strip()
        return out if out else None
    except Exception: return None

def get_public_ipv4():
    for u in ["https://ifconfig.co/ip","https://ip.sb","https://ipv4.icanhazip.com"]:
        ip=_curl_ip(["-4",u]); if _is_ipv4(ip): return ip
    for u in ["https://checkip.amazonaws.com","https://api.ipify.org"]:
        try:
            t=requests.get(u,timeout=3).text.strip()
            if _is_ipv4(t): return t
        except Exception: pass
    try:
        out=subprocess.check_output(
            ["/usr/bin/dig","+short","myip.opendns.com","@resolver1.opendns.com"],
            timeout=3, stderr=subprocess.DEVNULL).decode("utf-8","ignore").strip()
        if _is_ipv4(out): return out
    except Exception: pass
    return "—"

def get_public_ipv6():
    ip=_curl_ip(["-6","https://ifconfig.co/ip"]);  if _is_ipv6(ip): return ip
    ip=_curl_ip(["-6","https://ipv6.icanhazip.com"]); if _is_ipv6(ip): return ip
    try:
        t=requests.get("https://api6.ipify.org",timeout=3).text.strip()
        if _is_ipv6(t): return t
    except Exception: pass
    return "—"

def _is_ipv4(s):
    try: ipaddress.IPv4Address(s); return True
    except Exception: return False
def _is_ipv6(s):
    try: ipaddress.IPv6Address(s); return True
    except Exception: return False

def nwi_fingerprint():
    try:
        out=subprocess.check_output(["/usr/sbin/scutil","--nwi"],timeout=2).decode("utf-8","ignore")
        return hashlib.sha1(out.encode("utf-8","ignore")).hexdigest()
    except Exception: return None

def default_iface():
    try:
        out=subprocess.check_output(["/sbin/route","-n","get","1.1.1.1"],stderr=subprocess.STDOUT)\
            .decode("utf-8","ignore")
        m=re.search(r"interface:\s+(\w+)",out)
        if m: return m.group(1)
    except Exception: pass
    for iface in netifaces.interfaces():
        if iface.startswith("lo"): continue
        a4=netifaces.ifaddresses(iface).get(netifaces.AF_INET,[])
        a6=netifaces.ifaddresses(iface).get(netifaces.AF_INET6,[])
        if a4 or a6: return iface
    return None

def iface_ips():
    res={}
    for iface in netifaces.interfaces():
        v4s,v6s=[],[]
        a4=netifaces.ifaddresses(iface).get(netifaces.AF_INET,[])
        for a in a4:
            ip=a.get("addr") or ""
            if ip and not ip.startswith("127.") and not ip.startswith("169.254."):
                v4s.append(ip)
        a6=netifaces.ifaddresses(iface).get(netifaces.AF_INET6,[])
        for a in a6:
            ip=a.get("addr") or ""
            if not ip or ip.startswith("::1"): continue
            ip=ip.split("%")[0]
            v6s.append(ipaddress.IPv6Address(ip).compressed)
        if v4s or v6s:
            res[iface]={"v4":v4s,"v6":v6s}
    return res

def fmt_ipv4(ip,mode):
    if not _is_ipv4(ip): return ip
    a,b,c,d=ip.split(".")
    if mode=="first2": return f"{a}.{b}. …"
    if mode in ("first_last","first_last_octet"): return f"{a}. … .{d}"
    if mode=="last2": return f"… .{c}.{d}"
    return ip

def _agent_loaded(label: str) -> bool:
    try:
        uid=os.getuid()
        ret=subprocess.call(["launchctl","print",f"gui/{uid}/{label}"],
                            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        return ret==0
    except Exception: return False

def set_start_at_login(enable: bool, python_exec: str, script_path: str):
    label="com.ipmenu.app"
    wd=os.path.dirname(os.path.abspath(script_path))
    if enable:
        content=f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{python_exec}</string>
    <string>{script_path}</string>
  </array>
  <key>WorkingDirectory</key><string>{wd}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>IPINFO_TOKEN</key><string>{os.environ.get("IPINFO_TOKEN","")}</string>
    <key>IPMENU_PREFIX</key><string>{os.environ.get("IPMENU_PREFIX","")}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>{wd}/launchd.out.log</string>
  <key>StandardErrorPath</key><string>{wd}/launchd.err.log</string>
</dict></plist>"""
        Path.home().joinpath("Library/LaunchAgents").mkdir(parents=True, exist_ok=True)
        (Path.home()/f"Library/LaunchAgents/{label}.plist").write_text(content)
        if not _agent_loaded(label):
            uid=os.getuid()
            subprocess.call(["launchctl","bootstrap",f"gui/{uid}",str(Path.home()/f"Library/LaunchAgents/{label}.plist")],
                            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            subprocess.call(["launchctl","enable",f"gui/{uid}/{label}"],
                            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            subprocess.call(["launchctl","kickstart","-k",f"gui/{uid}/{label}"],
                            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    else:
        if _agent_loaded(label):
            uid=os.getuid()
            subprocess.call(["launchctl","bootout",f"gui/{uid}/{label}"],
                            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try: (Path.home()/f"Library/LaunchAgents/{label}.plist").unlink()
        except Exception: pass

def ensure_dir(p: Path): p.mkdir(parents=True, exist_ok=True)

def load_cfg():
    ensure_dir(CFG_DIR)
    seed=dict(DEFAULT_CFG)
    env_token=os.environ.get("IPINFO_TOKEN","").strip()
    if env_token: seed["ipinfo_token"]=env_token
    if CFG_FILE.exists():
        try: seed.update(json.loads(CFG_FILE.read_text()))
        except Exception: pass
    if seed.get("ipv4_format")=="first_last_octet": seed["ipv4_format"]="first_last"
    seed.setdefault("fast_probe_when_singbox", True)
    CFG_FILE.write_text(json.dumps(seed, indent=2))
    return seed

def save_cfg(cfg):
    ensure_dir(CFG_DIR); CFG_FILE.write_text(json.dumps(cfg, indent=2))

class IPMenuApp(rumps.App):
    def __init__(self, cfg):
        super(IPMenuApp,self).__init__(APP_NAME, quit_button=None)
        self.title=f"{TITLE_PREFIX}—"
        self.cfg=cfg
        self.last_public_v4=None; self.last_public_v6=None; self.last_fetch_ts=0
        self.public="—"; self.country=None; self.country_name=None
        self.asn=None; self.asname=None; self.isp=None
        self._last_lan_key=None; self._last_lan_notify_ts=0; self._nwi_fp=nwi_fingerprint()

        self.item_public=rumps.MenuItem("Public: —",callback=self.copy_public)
        self.item_asn   =rumps.MenuItem("ASN/ISP: —",callback=self.copy_asn)
        self.item_refresh=rumps.MenuItem("Refresh now",callback=self.refresh_now)
        self.item_reload=rumps.MenuItem("Reload (apply latest code)",callback=self.reload_app)
        self.item_sep1=rumps.separator

        self.sub_public_mode=rumps.MenuItem("Public mode")
        for mode in ["off","ipv4","ipv6","auto"]:
            self.sub_public_mode.add(rumps.MenuItem(mode,callback=lambda _,m=mode:self.set_public_mode(m)))

        self.sub_asn_src=rumps.MenuItem("ASN source")
        for mode in ["online","offline","auto"]:
            self.sub_asn_src.add(rumps.MenuItem(mode,callback=lambda _,m=mode:self.set_asn_source(m)))

        self.sub_country=rumps.MenuItem("Country format")
        self.sub_country.add(rumps.MenuItem("off",callback=self.set_country_off))
        self.sub_country.add(rumps.MenuItem("code",callback=self.set_country_code))
        self.sub_country.add(rumps.MenuItem("name",callback=self.set_country_name))

        self.sub_ipv4=rumps.MenuItem("IPv4 format")
        self.sub_ipv4.add(rumps.MenuItem("full",        callback=lambda _,m="full":self.set_ipv4_format(m)))
        self.sub_ipv4.add(rumps.MenuItem("first 2",     callback=lambda _,m="first2":self.set_ipv4_format(m)))
        self.sub_ipv4.add(rumps.MenuItem("first + last",callback=lambda _,m="first_last":self.set_ipv4_format(m)))
        self.sub_ipv4.add(rumps.MenuItem("last 2",      callback=lambda _,m="last2":self.set_ipv4_format(m)))

        self.sub_interval=rumps.MenuItem("IP refresh interval")
        for sec,label in [(0,"Off"),(60,"1 min"),(300,"5 min"),(900,"15 min")]:
            self.sub_interval.add(rumps.MenuItem(label,callback=lambda _,s=sec:self.set_interval(s)))

        self.item_show_tunnels=rumps.MenuItem("Show tunnel interfaces (utun*)",callback=self.toggle_show_tunnels)
        self.item_show_linklocal=rumps.MenuItem("Show link-local IPv6 (fe80::/10)",callback=self.toggle_linklocal)

        self.item_notify=rumps.MenuItem("Notify when public IP changes",callback=self.toggle_notify)
        self.item_sound =rumps.MenuItem("Play sound for notifications",callback=self.toggle_sound)
        self.item_start =rumps.MenuItem("Start at login",callback=self.toggle_start)
        self.item_showpub=rumps.MenuItem("Show public IP in menubar",callback=self.toggle_show_public)

        self.item_set_ipinfo=rumps.MenuItem("Set IPinfo token…",callback=self.set_ipinfo_token)
        self.item_sep2=rumps.separator
        self.item_local_header=rumps.MenuItem("Local:",callback=None)
        self.local_items=[]
        self.item_sep3=rumps.separator
        self.item_about=rumps.MenuItem("About",callback=self.about)
        self.item_open_github=rumps.MenuItem("Open GitHub…",callback=lambda _:subprocess.call(["open","https://github.com/ieduer"]))
        self.item_quit=rumps.MenuItem("Quit",callback=rumps.quit_application)

        self.menu=[self.item_public,self.item_asn,self.item_refresh,self.item_reload,self.item_sep1,
                   self.sub_public_mode,self.sub_asn_src,self.sub_country,self.sub_ipv4,self.sub_interval,
                   self.item_show_tunnels,self.item_show_linklocal,
                   self.item_notify,self.item_sound,self.item_start,self.item_showpub,self.item_set_ipinfo,
                   self.item_sep2,self.item_local_header,
                   self.item_sep3,self.item_open_github,self.item_about,self.item_quit]

        self.sync_checkmarks(); self._refresh_toggle_titles()

        self._sapdb_once=rumps.Timer(self._sapdb_kick,1.0); self._sapdb_once.start()
        self.update_local_section(); self.refresh_now(None)
        try: rumps.notification(APP_NAME,"Started","IP Menu is running")
        except Exception: pass

        self.timer=rumps.Timer(self.on_tick,2); self.timer.start()
        self.sapdb_timer=rumps.Timer(self.on_sapdb_maint,6*3600); self.sapdb_timer.start()

    def _sapdb_kick(self,_):
        try: self._sapdb_once.stop()
        except Exception: pass
        threading.Thread(target=self._sapdb_bg,daemon=True).start()
    def _sapdb_bg(self):
        try: ensure_sapdb(self.cfg.get("sapdb_auto_update_days",30))
        except Exception: pass

    def reload_app(self,_):
        try: rumps.notification(APP_NAME,"Reloading…","Restarting via launchctl")
        except Exception: pass
        try:
            uid=os.getuid()
            subprocess.check_call(["/bin/launchctl","kickstart","-k",f"gui/{uid}/com.ipmenu.app"],
                                  stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            rumps.quit_application(); return
        except Exception:
            try: rumps.notification(APP_NAME,"Reloading…","Applying latest code")
            except Exception: pass
            py=os.sys.executable; script=os.path.abspath(__file__)
            os.execv(py,[py,script])

    def set_public_mode(self,mode):
        self.cfg["public_mode"]=mode; save_cfg(self.cfg); self.sync_checkmarks(); self.refresh_now(None)
    def set_asn_source(self,mode):
        self.cfg["asn_source"]=mode; save_cfg(self.cfg); self.sync_checkmarks(); self.refresh_now(None)

    def set_country_off(self,_): self._set_country("off")
    def set_country_code(self,_): self._set_country("code")
    def set_country_name(self,_): self._set_country("name")
    def _set_country(self,mode):
        self.cfg["country_format"]=mode; save_cfg(self.cfg); self.sync_checkmarks(); self.update_title(); self.update_public_line()

    def set_ipv4_format(self,mode):
        self.cfg["ipv4_format"]=mode; save_cfg(self.cfg); self.sync_checkmarks(); self.update_title(); self.update_public_line()
    def set_interval(self,sec):
        self.cfg["refresh_interval_sec"]=int(sec); save_cfg(self.cfg); self.sync_checkmarks()

    def toggle_show_tunnels(self,_):
        self.cfg["show_tunnels"]=not self.cfg.get("show_tunnels",False)
        save_cfg(self.cfg); self.sync_checkmarks(); self._refresh_toggle_titles(); self.update_local_section()
    def toggle_linklocal(self,_):
        self.cfg["show_linklocal_v6"]=not self.cfg.get("show_linklocal_v6",False)
        save_cfg(self.cfg); self.sync_checkmarks(); self._refresh_toggle_titles(); self.update_local_section()
    def toggle_notify(self,_):
        self.cfg["notify_on_change"]=not self.cfg.get("notify_on_change",True); save_cfg(self.cfg); self.sync_checkmarks()
    def toggle_sound(self,_):
        self.cfg["play_sound"]=not self.cfg.get("play_sound",True); save_cfg(self.cfg); self.sync_checkmarks()
    def toggle_start(self,_):
        self.cfg["start_at_login"]=not self.cfg.get("start_at_login",False); save_cfg(self.cfg); self.sync_checkmarks()
        set_start_at_login(self.cfg["start_at_login"], os.sys.executable, os.path.abspath(__file__))
    def toggle_show_public(self,_):
        self.cfg["show_public"]=not self.cfg.get("show_public",True); save_cfg(self.cfg); self.sync_checkmarks(); self.update_title()

    def set_ipinfo_token(self,_):
        cur=self.cfg.get("ipinfo_token","")
        w=rumps.Window(title="IPinfo Token",default_text=cur,message="Leave empty to use env IPINFO_TOKEN")
        resp=w.run()
        if resp.clicked:
            self.cfg["ipinfo_token"]=resp.text.strip(); save_cfg(self.cfg)

    def copy_public(self,_):
        copy_to_clipboard(self.public or "—"); rumps.notification(APP_NAME,"Copied public IP",self.public or "—")
    def copy_asn(self,_):
        line=self.item_asn.title.replace("ASN/ISP: ",""); copy_to_clipboard(line)
        rumps.notification(APP_NAME,"Copied ASN/ISP",line)

    def refresh_now(self,_):
        self.fetch_public(force=True); self.update_title(); self.update_public_line()
    def about(self,_):
        rumps.alert(APP_NAME,"by suen")

    def _refresh_toggle_titles(self):
        self.item_show_tunnels.title=("Hide tunnel interfaces (utun*)" if self.cfg.get("show_tunnels",False)
                                      else "Show tunnel interfaces (utun*)")
        self.item_show_linklocal.title=("Hide link-local IPv6 (fe80::/10)" if self.cfg.get("show_linklocal_v6",False)
                                        else "Show link-local IPv6 (fe80::/10)")

    def sync_checkmarks(self):
        for k in self.sub_public_mode.values(): k.state=False
        self.sub_public_mode[self.cfg.get("public_mode","ipv4")].state=True
        for k in self.sub_asn_src.values(): k.state=False
        self.sub_asn_src[self.cfg.get("asn_source","online")].state=True
        for k in self.sub_country.values(): k.state=False
        m=self.cfg.get("country_format","off")
        self.sub_country[{"off":"off","code":"code","name":"name"}[m]].state=True
        for k in self.sub_ipv4.values(): k.state=False
        mode=self.cfg.get("ipv4_format","full")
        label_by_mode={"full":"full","first2":"first 2","first_last":"first + last","last2":"last 2"}
        self.sub_ipv4[label_by_mode.get(mode,"full")].state=True
        for k in self.sub_interval.values(): k.state=False
        sec=int(self.cfg.get("refresh_interval_sec",0)); label={0:"Off",60:"1 min",300:"5 min",900:"15 min"}.get(sec,"Off")
        self.sub_interval[label].state=True
        self.item_notify.state=self.cfg.get("notify_on_change",True)
        self.item_sound.state=self.cfg.get("play_sound",True)
        self.item_start.state=self.cfg.get("start_at_login",False)
        self.item_showpub.state=self.cfg.get("show_public",True)

    def on_tick(self,_):
        new_fp=nwi_fingerprint()
        if new_fp and new_fp!=getattr(self,"_nwi_fp",None):
            self._nwi_fp=new_fp
            self.fetch_public(force=True); self.update_title(); self.update_public_line()

        iface=default_iface() or "—"; mapping=iface_ips()
        v4=mapping.get(iface,{}).get("v4",[]); v6=mapping.get(iface,{}).get("v6",[])
        if not self.cfg.get("show_linklocal_v6",False): v6=[x for x in v6 if not x.startswith("fe80:")]
        lan_key=f"{iface}|{(v4[0] if v4 else '-') }|{(v6[0] if v6 else '-')}"
        if lan_key!=self._last_lan_key:
            self._last_lan_key=lan_key
            if time.time()-self._last_lan_notify_ts>1:
                rumps.notification(APP_NAME,"Local IP changed",lan_key)
                self._last_lan_notify_ts=time.time()
                self.fetch_public(force=True); self.update_title(); self.update_public_line()

        self.update_local_section()

        if int(self.cfg.get("refresh_interval_sec",0))>0:
            if time.time()-self.last_fetch_ts>=max(10,int(self.cfg["refresh_interval_sec"])):
                self.fetch_public(force=True)

        if self.cfg.get("fast_probe_when_singbox",True) and is_singbox_running():
            if time.time()-self.last_fetch_ts>=3:
                self.fetch_public(force=True); self.update_title(); self.update_public_line()

        self.update_title(); self.update_public_line()

    def fetch_public(self,force=False):
        if not force and (time.time()-self.last_fetch_ts)<30: return
        self.last_fetch_ts=time.time()

        mode=self.cfg.get("public_mode","ipv4"); new_ip="—"
        if mode=="off":
            self.public="—"; self.country=self.country_name=self.asn=self.asname=self.isp=None; return
        if mode in ("ipv4","auto"):
            ip4=get_public_ipv4()
            if ip4!="—": new_ip=ip4
        if mode=="ipv6":
            new_ip=get_public_ipv6()
        elif mode=="auto" and new_ip=="—":
            v6=get_public_ipv6()
            if v6!="—": new_ip=v6

        country=None; country_name=None; asn=None; asname=None; isp=None
        asn_src=self.cfg.get("asn_source","online")
        token=(self.cfg.get("ipinfo_token") or os.environ.get("IPINFO_TOKEN","")).strip()

        def try_online():
            nonlocal country,country_name,asn,asname,isp
            o=online_whois(new_ip,token)
            if o.get("ok"):
                country,country_name=o.get("country"),o.get("country_name")
                asn,asname,isp=o.get("asn"),o.get("asname"),o.get("isp")
                return True
            return False
        def try_offline():
            nonlocal country,country_name,asn,asname,isp
            if not ASNDB.loaded:
                try: ensure_sapdb(self.cfg.get("sapdb_auto_update_days",30))
                except Exception: pass
                try: ASNDB.load()
                except Exception: return False
            hit=ASNDB.lookup(new_ip)
            if not hit: return False
            country,asn,asname,isp=hit.get("country"),hit.get("asn"),hit.get("asname"),hit.get("asname")
            return True

        if new_ip!="—":
            if asn_src=="online": ok=try_online()
            elif asn_src=="offline": ok=try_offline()
            else: ok=try_online() or try_offline()

            changed=False
            if _is_ipv4(new_ip):
                changed=(self.last_public_v4 is not None and new_ip!=self.last_public_v4); self.last_public_v4=new_ip
            elif _is_ipv6(new_ip):
                changed=(self.last_public_v6 is not None and new_ip!=self.last_public_v6); self.last_public_v6=new_ip
            if changed and self.cfg.get("notify_on_change",True):
                rumps.notification(APP_NAME,"Public IP changed",new_ip)
                if self.cfg.get("play_sound",True):
                    try:
                        from AppKit import NSSound
                        s=NSSound.soundNamed_("Glass"); s and s.play()
                    except Exception: pass

        self.public=new_ip; self.country,self.country_name=country,country_name
        self.asn,self.asname,self.isp=asn,asname,isp

    def country_suffix(self):
        mode=self.cfg.get("country_format","off")
        if mode=="off": return ""
        code=self.country; name=self.country_name
        if mode=="code" and code: return f" {code}"
        if mode=="name" and (name or code): return f" {name or code}"
        return ""

    def update_title(self):
        if not self.cfg.get("show_public",True):
            iface=default_iface() or "—"
            mapping=iface_ips()
            v4=mapping.get(iface,{}).get("v4",[]); v6=mapping.get(iface,{}).get("v6",[])
            if not self.cfg.get("show_linklocal_v6",False): v6=[x for x in v6 if not x.startswith("fe80:")]
            shown=(v4[0] if v4 else (v6[0] if v6 else "—"))
            if _is_ipv4(shown): shown=fmt_ipv4(shown,self.cfg.get("ipv4_format"))
            self.title=f"{TITLE_PREFIX}{shown}"; return
        pub=self.public or "—"
        if pub=="—":
            iface=default_iface() or "—"
            mapping=iface_ips()
            v4=mapping.get(iface,{}).get("v4",[]); v6=mapping.get(iface,{}).get("v6",[])
            if not self.cfg.get("show_linklocal_v6",False): v6=[x for x in v6 if not x.startswith("fe80:")]
            shown=(v4[0] if v4 else (v6[0] if v6 else "—"))
            if _is_ipv4(shown): shown=fmt_ipv4(shown,self.cfg.get("ipv4_format"))
            self.title=f"{TITLE_PREFIX}{shown}"; return
        pub_disp=fmt_ipv4(pub,self.cfg.get("ipv4_format")) if _is_ipv4(pub) else pub
        self.title=f"{TITLE_PREFIX}{pub_disp}{self.country_suffix()}"

    def update_public_line(self):
        txt=f"Public: {self.public}"
        suf=self.country_suffix()
        if suf: txt+=f"  [{suf.strip()}]"
        asline="—"
        if self.asn or self.asname or self.isp:
            parts=[]; 
            if self.asn: parts.append(f"AS{self.asn}")
            if self.asname: parts.append(self.asname)
            elif self.isp: parts.append(self.isp)
            asline=" ".join(parts) if parts else "—"
        self.item_public.title=txt
        self.item_asn.title=f"ASN/ISP: {asline}"

    def update_local_section(self):
        for it in getattr(self,"local_items",[]):
            try: del self.menu[it.title]
            except Exception:
                try: self.menu.pop(it)
                except Exception: pass
        self.local_items=[]
        mapping=iface_ips()
        if not mapping:
            it=rumps.MenuItem("  —",callback=None)
            self.menu.insert_before("About",it); self.local_items.append(it); return
        pref=default_iface()
        keys=list(mapping.keys())
        if not self.cfg.get("show_tunnels",False):
            keys=[k for k in keys if not k.startswith("utun")]
        if pref in keys:
            keys.remove(pref); keys.insert(0,pref)
        for k in keys:
            v4_list=mapping[k]["v4"]; v6_list=mapping[k]["v6"]
            if not self.cfg.get("show_linklocal_v6",False):
                v6_list=[x for x in v6_list if not x.startswith("fe80:")]
            v4=", ".join(v4_list) if v4_list else "—"
            v6=", ".join(v6_list) if v6_list else "—"
            text=f"{k}: v4[{v4}] v6[{v6}]"
            it=rumps.MenuItem(f"  {text}",callback=lambda _,t=text: copy_to_clipboard(t))
            self.menu.insert_before("About",it); self.local_items.append(it)

    def on_sapdb_maint(self,_):
        try:
            if need_sapdb_update(self.cfg.get("sapdb_auto_update_days",30)):
                ensure_sapdb(self.cfg.get("sapdb_auto_update_days",30))
                if ASNDB.loaded: ASNDB.loaded=False
        except Exception:
            try: rumps.notification(APP_NAME,"Offline ASN DB update failed","Will retry later")
            except Exception: pass

if __name__=="__main__":
    if not acquire_single_instance_lock(): raise SystemExit(0)
    cfg=load_cfg()
    try:
        if cfg.get("start_at_login",False):
            set_start_at_login(True, os.sys.executable, os.path.abspath(__file__))
    except Exception: pass

    app=IPMenuApp(cfg)
    try:
        from AppKit import NSApplication, NSApp, NSApplicationActivationPolicyProhibited
        NSApplication.sharedApplication()
        NSApp.setActivationPolicy_(NSApplicationActivationPolicyProhibited)
    except Exception: pass
    app.run()
PYCODE
  chmod +x "${PY_FILE}"
}

write_plist() {
  mkdir -p "${HOME}/Library/LaunchAgents"
  cat > "${PLIST}" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${VENV_DIR}/bin/python3</string>
    <string>${PY_FILE}</string>
  </array>
  <key>WorkingDirectory</key><string>${APP_DIR}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$(brew_prefix)/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>IPINFO_TOKEN</key><string>${IPINFO_TOKEN}</string>
    <key>IPMENU_PREFIX</key><string>${IPMENU_PREFIX}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>${LOG_OUT}</string>
  <key>StandardErrorPath</key><string>${LOG_ERR}</string>
</dict></plist>
PL
}

start_agent() {
  local uid; uid="$(id -u)"
  launchctl bootstrap "gui/${uid}" "${PLIST}" 2>/dev/null || true
  launchctl enable "gui/${uid}/${LABEL}" 2>/dev/null || true
  launchctl kickstart -k "gui/${uid}/${LABEL}" 2>/dev/null || true
}

stop_agent() {
  local uid; uid="$(id -u)"
  launchctl bootout "gui/${uid}/${LABEL}" 2>/dev/null || true
}

status_agent() {
  local uid; uid="$(id -u)"
  launchctl print "gui/${uid}/${LABEL}" 2>/dev/null | egrep 'state =|pid =|path =|last exit status' || {
    echo "not loaded"
  }
}

# ============ 子命令 ============
cmd_install() {
  ensure_brew_and_python
  ensure_venv
  write_python
  write_plist
  start_agent
  say "完成安裝並啟動。狀態："
  status_agent
}

cmd_update() {
  ensure_brew_and_python
  ensure_venv
  write_python
  write_plist
  start_agent
  say "已更新並重啟。"
}

cmd_reload() { start_agent; say "已重載（kickstart）。"; }
cmd_start()  { start_agent; say "已啟動。"; }
cmd_stop()   { stop_agent;  say "已停止。"; }
cmd_status() { status_agent; }
cmd_logs()   { echo "== ${LOG_ERR}"; tail -n 80 "${LOG_ERR}" 2>/dev/null || true; echo; echo "== ${LOG_OUT}"; tail -n 40 "${LOG_OUT}" 2>/dev/null || true; }
cmd_uninstall() {
  stop_agent
  rm -f "${PLIST}"
  rm -rf "${APP_DIR}"
  say "已解除安裝（保留 venv：${VENV_DIR}；如需可手動移除）。"
}

usage() {
  cat <<USG
Usage: $0 [install|update|reload|start|stop|status|logs|uninstall]
  install    安裝/更新並啟動（預設）
  update     更新程式與依賴並重啟
  reload     重新載入（kickstart）
  start      啟動
  stop       停止
  status     查看狀態
  logs       顯示最近日誌
  uninstall  解除安裝（移除 LaunchAgent 與程式檔）
USG
}

# ============ 入口 ============
cmd="${1:-install}"
case "${cmd}" in
  install)   cmd_install ;;
  update)    cmd_update  ;;
  reload)    cmd_reload  ;;
  start)     cmd_start   ;;
  stop)      cmd_stop    ;;
  status)    cmd_status  ;;
  logs)      cmd_logs    ;;
  uninstall) cmd_uninstall ;;
  *) usage; exit 1 ;;
esac