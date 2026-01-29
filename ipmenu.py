#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
IP Menu - Enhanced macOS Network Monitor
Version 2.0.1-hardened

Changes vs 2.0:
- Fix: IP history records the initial IP (not only changes)
- Fix: Avoid updating rumps UI from background threads (quality monitor)
- Perf: Reduce redundant update_title/update_info_lines calls per tick
- Fix: More robust local menu item removal
- Fix: Export history works even if file doesn't exist yet (forces save)
"""

import rumps, os, json, time, subprocess, re, ipaddress, io, gzip, fcntl, atexit, hashlib
from pathlib import Path
from datetime import datetime
from collections import deque
import netifaces, requests
import threading
from threading import Lock, Event
from bisect import bisect_right
from dataclasses import dataclass, asdict
from typing import Optional, Dict, List
import statistics

APP_NAME = "IP Menu Pro"
APP_VERSION = "2.0.1-hardened"
APP_DIR  = Path(__file__).resolve().parent
CFG_DIR  = APP_DIR / ".config" / "ipmenu"
CFG_FILE = CFG_DIR / "config.json"
HISTORY_FILE = CFG_DIR / "ip_history.json"
STATS_FILE = CFG_DIR / "network_stats.json"

SAPDB_DIR = APP_DIR / "sapdb"
LA_PLIST = Path.home() / "Library" / "LaunchAgents" / "com.ipmenu.app.plist"

DEFAULT_CFG = {
    # Display
    "public_mode": "ipv4",
    "country_format": "code",
    "ipv4_format": "first_last",
    "show_public": True,
    "show_network_quality": True,
    "compact_mode": False,

    # Refresh & Notifications
    "refresh_interval_sec": 300,
    "notify_on_change": True,
    "play_sound": True,
    "start_at_login": False,

    # Display Filters
    "show_tunnels": False,
    "show_linklocal_v6": False,

    # ASN/ISP
    "asn_source": "online",
    "ipinfo_token": "",
    "sapdb_auto_update_days": 30,

    # Enhanced Features
    "fast_probe_when_singbox": True,
    "enable_ping_monitor": False,
    "ping_target": "8.8.8.8",
    "ping_interval_sec": 30,
    "enable_speed_test": False,
    "dns_leak_check": False,
    "track_ip_history": True,
    "max_history_entries": 100,
    "show_connection_time": True,
}

PUBLIC_TTL_SEC = 30
LAN_CHECK_SEC  = 2
FAST_PROBE_SEC = 3

GITHUB_URL = "https://github.com/ieduer/ipmenu"
TITLE_PREFIX = os.environ.get("IPMENU_PREFIX", "")

_SAP_NOTIFY_MIN = 6 * 3600
_sap_last_info_ts = 0
_sap_last_fail_ts = 0
_sap_lock = Lock()

QUALITY_EXCELLENT = "🟢"
QUALITY_GOOD = "🟡"
QUALITY_POOR = "🔴"
QUALITY_UNKNOWN = "⚪"

@dataclass
class NetworkStats:
    timestamp: float
    latency_ms: Optional[float] = None
    jitter_ms: Optional[float] = None
    packet_loss: Optional[float] = None
    download_mbps: Optional[float] = None
    upload_mbps: Optional[float] = None

@dataclass
class IPHistoryEntry:
    timestamp: float
    ip: str
    country: Optional[str] = None
    asn: Optional[str] = None
    isp: Optional[str] = None
    connection_type: str = "unknown"

class NetworkQualityMonitor:
    def __init__(self, target="8.8.8.8", samples=10):
        self.target = target
        self.samples = samples
        self.latencies = deque(maxlen=samples)
        self.lock = Lock()
        self._last_check = 0

    def ping(self) -> Optional[float]:
        try:
            result = subprocess.run(
                ["/sbin/ping", "-c", "1", "-W", "1000", self.target],
                capture_output=True, text=True, timeout=2
            )
            if result.returncode == 0:
                match = re.search(r'time=(\d+\.?\d*)', result.stdout)
                if match:
                    return float(match.group(1))
        except Exception:
            pass
        return None

    def update(self) -> bool:
        if time.time() - self._last_check < 1:
            return False
        self._last_check = time.time()

        latency = self.ping()
        if latency is not None:
            with self.lock:
                self.latencies.append(latency)
            return True
        return False

    def get_stats(self) -> Dict:
        with self.lock:
            if not self.latencies:
                return {"quality": "unknown", "latency": None, "jitter": None, "samples": 0}

            avg_latency = statistics.mean(self.latencies)
            jitter = statistics.stdev(self.latencies) if len(self.latencies) > 1 else 0

            if avg_latency < 30:
                quality = "excellent"
            elif avg_latency < 100:
                quality = "good"
            else:
                quality = "poor"

            return {
                "quality": quality,
                "latency": round(avg_latency, 1),
                "jitter": round(jitter, 1),
                "samples": len(self.latencies)
            }

    def get_indicator(self) -> str:
        stats = self.get_stats()
        quality_map = {
            "excellent": QUALITY_EXCELLENT,
            "good": QUALITY_GOOD,
            "poor": QUALITY_POOR,
            "unknown": QUALITY_UNKNOWN
        }
        return quality_map.get(stats.get("quality", "unknown"), QUALITY_UNKNOWN)

class IPHistoryTracker:
    def __init__(self, max_entries=100):
        self.max_entries = max_entries
        self.history: List[IPHistoryEntry] = []
        self.lock = Lock()
        self.load()

    def load(self):
        if not HISTORY_FILE.exists():
            return
        try:
            with self.lock:
                data = json.loads(HISTORY_FILE.read_text())
                self.history = [IPHistoryEntry(**entry) for entry in data[-self.max_entries:]]
        except Exception:
            pass

    def save(self):
        try:
            ensure_dir(CFG_DIR)
            with self.lock:
                data = [asdict(entry) for entry in self.history[-self.max_entries:]]
                HISTORY_FILE.write_text(json.dumps(data, indent=2))
        except Exception:
            pass

    def add_entry(self, ip: str, country: Optional[str] = None,
                  asn: Optional[str] = None, isp: Optional[str] = None,
                  connection_type: str = "unknown"):
        with self.lock:
            if self.history and self.history[-1].ip == ip:
                return

            entry = IPHistoryEntry(
                timestamp=time.time(),
                ip=ip,
                country=country,
                asn=asn,
                isp=isp,
                connection_type=connection_type
            )
            self.history.append(entry)

            if len(self.history) > self.max_entries:
                self.history = self.history[-self.max_entries:]

        self.save()

    def get_recent(self, limit=10) -> List[IPHistoryEntry]:
        with self.lock:
            return list(reversed(self.history[-limit:]))

    def get_connection_duration(self) -> Optional[float]:
        with self.lock:
            if not self.history:
                return None
            return time.time() - self.history[-1].timestamp

    def get_stats(self) -> Dict:
        with self.lock:
            if not self.history:
                return {"total_changes": 0, "unique_ips": 0, "countries": []}

            unique_ips = len(set(e.ip for e in self.history))
            countries = list(set(e.country for e in self.history if e.country))

            return {
                "total_changes": len(self.history),
                "unique_ips": unique_ips,
                "countries": countries,
                "oldest_entry": datetime.fromtimestamp(self.history[0].timestamp).isoformat()
            }

def is_singbox_running():
    try:
        subprocess.check_call(["/usr/bin/pgrep", "-lf", "[s]ing-box"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception:
        try:
            subprocess.check_call(["/usr/bin/pgrep", "-lf", "[s]ingbox"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except Exception:
            return False

def detect_connection_type() -> str:
    if is_singbox_running():
        return "vpn"

    try:
        ifaces = netifaces.interfaces()
        for iface in ifaces:
            if any(x in iface.lower() for x in ['tun', 'tap', 'ppp', 'ipsec', 'utun']):
                addrs = netifaces.ifaddresses(iface)
                if netifaces.AF_INET in addrs or netifaces.AF_INET6 in addrs:
                    return "vpn"
    except Exception:
        pass

    try:
        iface = default_iface()
        if iface:
            if 'en0' in iface or 'wi' in iface.lower():
                return "wifi"
            elif 'en' in iface:
                return "ethernet"
    except Exception:
        pass

    return "unknown"

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
            except Exception:
                pass
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

def check_dns_leaks() -> Dict:
    try:
        result = subprocess.run(
            ["/usr/sbin/scutil", "--dns"],
            capture_output=True, text=True, timeout=2
        )
        dns_servers = re.findall(r'nameserver\[\d+\]\s*:\s*([\d\.:a-f]+)', result.stdout)

        suspicious = False
        if dns_servers:
            public_dns = ['8.8.8.8', '8.8.4.4', '1.1.1.1', '1.0.0.1']
            suspicious = any(dns in public_dns for dns in dns_servers)

        return {
            "dns_servers": dns_servers[:5],
            "leak_detected": suspicious,
            "checked_at": time.time()
        }
    except Exception:
        return {"dns_servers": [], "leak_detected": False, "error": True}

def online_whois(ip, token=""):
    try:
        params = {}
        headers = {"User-Agent": f"IPMenu/{APP_VERSION}"}
        if token:
            params["token"] = token
            headers["Authorization"] = f"Bearer {token}"
        r = requests.get(f"https://ipinfo.io/{ip}/json", headers=headers,
                         params=params, timeout=4)
        r.raise_for_status()
        j = r.json()
        org = j.get("org") or ""
        asn_num, asn_org = None, None
        if org.upper().startswith("AS"):
            parts = org.split(" ", 1)
            asn_num = parts[0][2:] if parts else None
            asn_org = parts[1] if len(parts) > 1 else None
        return {
            "ok": True,
            "country": (j.get("country") or None),
            "country_name": j.get("country_name"),
            "asn": asn_num,
            "asname": asn_org,
            "isp": j.get("org") or asn_org,
            "city": j.get("city"),
            "region": j.get("region"),
            "timezone": j.get("timezone"),
        }
    except Exception:
        pass

    try:
        base_urls = [
            f"https://ip-api.com/json/{ip}?fields=status,country,countryCode,city,regionName,as,asname,org,isp,query,timezone",
            f"http://ip-api.com/json/{ip}?fields=status,country,countryCode,city,regionName,as,asname,org,isp,query,timezone",
        ]
        j = None
        for url in base_urls:
            try:
                r = requests.get(url, timeout=4)
                if r.status_code == 200:
                    j = r.json()
                    break
            except Exception:
                continue
        if j and j.get("status") == "success":
            asn = None
            as_field = j.get("as") or ""
            if as_field.upper().startswith("AS"):
                asn = as_field[2:].split()[0]
            return {
                "ok": True,
                "country": j.get("countryCode"),
                "country_name": j.get("country"),
                "asn": asn,
                "asname": j.get("asname") or None,
                "isp": j.get("isp") or j.get("org"),
                "city": j.get("city"),
                "region": j.get("regionName"),
                "timezone": j.get("timezone"),
            }
    except Exception:
        pass
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
    if not existing:
        return True
    mt = min(p.stat().st_mtime for p in existing)
    return (time.time() - mt) >= days * 86400

def _head_first(relname, timeout=8):
    for base in SAP_BASES:
        try:
            r = requests.head(base + relname, timeout=timeout, allow_redirects=True)
            if r.status_code == 200:
                return r.headers
        except Exception:
            continue
    return {}

def _validate_tsv(path: Path, min_lines: int = 500):
    try:
        with path.open("r", encoding="utf-8", errors="ignore") as f:
            for i, _ in enumerate(f, 1):
                if i >= min_lines:
                    return True
        return False
    except Exception:
        return False

def _download_with_fallbacks(relname, timeout=15, retries=2):
    last = None
    for base in SAP_BASES:
        url = base + relname
        for i in range(retries):
            try:
                r = requests.get(url, timeout=timeout)
                r.raise_for_status()
                return r.content
            except Exception as e:
                last = e
                time.sleep(0.6 + 0.6 * i)
            try:
                data = subprocess.check_output(
                    ["/usr/bin/curl", "-L", "-sS", "--connect-timeout", "5", "--max-time", str(timeout), url],
                    stderr=subprocess.DEVNULL
                )
                if data:
                    return data
            except Exception as e2:
                last = e2
    if last:
        raise last
    raise RuntimeError("download failed")

def ensure_sapdb(days):
    SAPDB_DIR.mkdir(parents=True, exist_ok=True)
    if not _sap_lock.acquire(blocking=False):
        return
    try:
        if not need_sapdb_update(days):
            return

        try:
            headers = _head_first(SAP_COMBINED_GZ)
            cl = int(headers.get("Content-Length", "0"))
            local_gz = SAPDB_DIR / SAP_COMBINED_GZ
            if local_gz.exists() and cl > 0 and local_gz.stat().st_size == cl:
                import gzip as _gz
                if not (SAPDB_DIR / "ip2asn-combined.tsv").exists():
                    with _gz.open(local_gz, "rb") as f:
                        (SAPDB_DIR / "ip2asn-combined.tsv").write_bytes(f.read())
                if _validate_tsv(SAPDB_DIR / "ip2asn-combined.tsv"):
                    return
        except Exception:
            pass

        global _sap_last_info_ts
        if time.time() - _sap_last_info_ts > _SAP_NOTIFY_MIN:
            try:
                rumps.notification(APP_NAME, "Updating offline ASN DB", "Downloading from sapics/ip-location-db…")
            except Exception:
                pass
            _sap_last_info_ts = time.time()

        try:
            data = _download_with_fallbacks(SAP_COMBINED_GZ)
            (SAPDB_DIR / SAP_COMBINED_GZ).write_bytes(data)
            import gzip as _gz, io as _io
            with _gz.open(_io.BytesIO(data), "rb") as f:
                content = f.read()
            (SAPDB_DIR / "ip2asn-combined.tsv").write_bytes(content)
            if not _validate_tsv(SAPDB_DIR / "ip2asn-combined.tsv"):
                try:
                    (SAPDB_DIR / "ip2asn-combined.tsv").unlink()
                except Exception:
                    pass
                raise RuntimeError("combined TSV validation failed")
            for p in ["ip2asn-v4.tsv", "ip2asn-v6.tsv"]:
                fp = SAPDB_DIR / p
                if fp.exists():
                    try:
                        fp.unlink()
                    except Exception:
                        pass
            try:
                rumps.notification(APP_NAME, "Offline ASN DB ready", "ip2asn-combined.tsv updated")
            except Exception:
                pass
            return
        except Exception:
            pass

        try:
            d4 = _download_with_fallbacks(SAP_V4_GZ)
            (SAPDB_DIR / SAP_V4_GZ).write_bytes(d4)
            import gzip as _gz, io as _io
            with _gz.open(_io.BytesIO(d4), "rb") as f:
                (SAPDB_DIR / "ip2asn-v4.tsv").write_bytes(f.read())
            if not _validate_tsv(SAPDB_DIR / "ip2asn-v4.tsv"):
                try:
                    (SAPDB_DIR / "ip2asn-v4.tsv").unlink()
                except Exception:
                    pass
            else:
                try:
                    rumps.notification(APP_NAME, "Offline ASN DB ready", "ip2asn-v4.tsv updated")
                except Exception:
                    pass
        except Exception:
            pass

        try:
            d6 = _download_with_fallbacks(SAP_V6_GZ)
            (SAPDB_DIR / SAP_V6_GZ).write_bytes(d6)
            import gzip as _gz, io as _io
            with _gz.open(_io.BytesIO(d6), "rb") as f:
                (SAPDB_DIR / "ip2asn-v6.tsv").write_bytes(f.read())
            if not _validate_tsv(SAPDB_DIR / "ip2asn-v6.tsv"):
                try:
                    (SAPDB_DIR / "ip2asn-v6.tsv").unlink()
                except Exception:
                    pass
            else:
                try:
                    rumps.notification(APP_NAME, "Offline ASN DB ready", "ip2asn-v6.tsv updated")
                except Exception:
                    pass
        except Exception:
            pass

        if not any((SAPDB_DIR / p).exists() for p in ("ip2asn-combined.tsv", "ip2asn-v4.tsv", "ip2asn-v6.tsv")):
            global _sap_last_fail_ts
            if time.time() - _sap_last_fail_ts > _SAP_NOTIFY_MIN:
                try:
                    rumps.notification(APP_NAME, "Offline ASN DB failed", "Could not prepare sapics database")
                except Exception:
                    pass
                _sap_last_fail_ts = time.time()
        else:
            return
    finally:
        try:
            _sap_lock.release()
        except Exception:
            pass

class SapASNDB:
    def __init__(self):
        self.v4 = []
        self.v4_keys = []
        self.v6 = []
        self.v6_keys = []
        self.loaded = False

    def _add_range(self, fam, start_ip, end_ip, asn, cc, name):
        if fam == 4:
            s = int(ipaddress.IPv4Address(start_ip)); e = int(ipaddress.IPv4Address(end_ip))
            self.v4.append((s, e, asn, name, cc))
        else:
            s = int(ipaddress.IPv6Address(start_ip)); e = int(ipaddress.IPv6Address(end_ip))
            self.v6.append((s, e, asn, name, cc))

    def load(self):
        path_comb = SAPDB_DIR / "ip2asn-combined.tsv"
        if path_comb.exists():
            self._load_tsv(path_comb, combined=True)
        else:
            p4, p6 = SAPDB_DIR / "ip2asn-v4.tsv", SAPDB_DIR / "ip2asn-v6.tsv"
            if p4.exists():
                self._load_tsv(p4, combined=False, fam=4)
            if p6.exists():
                self._load_tsv(p6, combined=False, fam=6)
        self.v4.sort(key=lambda x: x[0]); self.v4_keys = [x[0] for x in self.v4]
        self.v6.sort(key=lambda x: x[0]); self.v6_keys = [x[0] for x in self.v6]
        self.loaded = True

    def _load_tsv(self, path: Path, combined=True, fam=None):
        with path.open("r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if not line or line.startswith("#"):
                    continue
                parts = line.strip().split("\t")
                if len(parts) < 6:
                    continue
                start_ip, end_ip, asn, _rir, cc, asname = parts[:6]
                if asn == "0" or asn == "AS0":
                    asn = None
                family = 6 if ":" in start_ip else 4
                if not combined and fam and family != fam:
                    continue
                self._add_range(family, start_ip, end_ip, asn, cc or None, asname or None)

    def lookup(self, ip_str: str):
        if not self.loaded:
            return None
        if _is_ipv4(ip_str):
            x = int(ipaddress.IPv4Address(ip_str))
            idx = bisect_right(self.v4_keys, x) - 1
            if 0 <= idx < len(self.v4):
                s, e, asn, asname, cc = self.v4[idx]
                if s <= x <= e:
                    return {"asn": asn, "asname": asname, "country": cc}
        elif _is_ipv6(ip_str):
            x = int(ipaddress.IPv6Address(ip_str))
            idx = bisect_right(self.v6_keys, x) - 1
            if 0 <= idx < len(self.v6):
                s, e, asn, asname, cc = self.v6[idx]
                if s <= x <= e:
                    return {"asn": asn, "asname": asname, "country": cc}
        return None

ASNDB = SapASNDB()

def _curl_ip(flags):
    try:
        out = subprocess.check_output(
            ["/usr/bin/curl", "-sS", "-m", "3"] + flags,
            stderr=subprocess.DEVNULL
        ).decode("utf-8", "ignore").strip()
        return out if out else None
    except Exception:
        return None

def get_public_ipv4():
    for u in ["https://ifconfig.co/ip", "https://ip.sb", "https://ipv4.icanhazip.com"]:
        ip = _curl_ip(["-4", u])
        if _is_ipv4(ip):
            return ip
    for u in ["https://checkip.amazonaws.com", "https://api.ipify.org"]:
        try:
            t = requests.get(u, timeout=3).text.strip()
            if _is_ipv4(t):
                return t
        except Exception:
            pass
    try:
        out = subprocess.check_output(
            ["/usr/bin/dig", "+short", "myip.opendns.com", "@resolver1.opendns.com"],
            timeout=3, stderr=subprocess.DEVNULL
        ).decode("utf-8", "ignore").strip()
        if _is_ipv4(out):
            return out
    except Exception:
        pass
    return "—"

def get_public_ipv6():
    ip = _curl_ip(["-6", "https://ifconfig.co/ip"])
    if _is_ipv6(ip):
        return ip
    ip = _curl_ip(["-6", "https://ipv6.icanhazip.com"])
    if _is_ipv6(ip):
        return ip
    try:
        t = requests.get("https://api6.ipify.org", timeout=3).text.strip()
        if _is_ipv6(t):
            return t
    except Exception:
        pass
    return "—"

def _is_ipv4(s):
    try:
        ipaddress.IPv4Address(s)
        return True
    except Exception:
        return False

def _is_ipv6(s):
    try:
        ipaddress.IPv6Address(s)
        return True
    except Exception:
        return False

def nwi_fingerprint():
    try:
        out = subprocess.check_output(["/usr/sbin/scutil", "--nwi"], timeout=2).decode("utf-8", "ignore")
        return hashlib.sha1(out.encode("utf-8", "ignore")).hexdigest()
    except Exception:
        return None

def default_iface():
    try:
        out = subprocess.check_output(
            ["/sbin/route", "-n", "get", "1.1.1.1"],
            stderr=subprocess.STDOUT
        ).decode("utf-8", "ignore")
        m = re.search(r"interface:\s+(\w+)", out)
        if m:
            return m.group(1)
    except Exception:
        pass
    for iface in netifaces.interfaces():
        if iface.startswith("lo"):
            continue
        a4 = netifaces.ifaddresses(iface).get(netifaces.AF_INET, [])
        a6 = netifaces.ifaddresses(iface).get(netifaces.AF_INET6, [])
        if a4 or a6:
            return iface
    return None

def iface_ips():
    res = {}
    for iface in netifaces.interfaces():
        v4s, v6s = [], []
        a4 = netifaces.ifaddresses(iface).get(netifaces.AF_INET, [])
        for a in a4:
            ip = a.get("addr") or ""
            if ip and not ip.startswith("127.") and not ip.startswith("169.254."):
                v4s.append(ip)
        a6 = netifaces.ifaddresses(iface).get(netifaces.AF_INET6, [])
        for a in a6:
            ip = a.get("addr") or ""
            if not ip or ip.startswith("::1"):
                continue
            ip = ip.split("%")[0]
            v6s.append(ipaddress.IPv6Address(ip).compressed)
        if v4s or v6s:
            res[iface] = {"v4": v4s, "v6": v6s}
    return res

def fmt_ipv4(ip, mode):
    if not _is_ipv4(ip):
        return ip
    a, b, c, d = ip.split(".")
    if mode == "first2":
        return f"{a}.{b}. …"
    if mode in ("first_last", "first_last_octet"):
        return f"{a}. … .{d}"
    if mode == "last2":
        return f"… .{c}.{d}"
    return ip

def _agent_loaded(label: str) -> bool:
    try:
        uid = os.getuid()
        ret = subprocess.call(["launchctl", "print", f"gui/{uid}/{label}"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return ret == 0
    except Exception:
        return False

def set_start_at_login(enable: bool, python_exec: str, script_path: str):
    label = "com.ipmenu.app"
    wd = os.path.dirname(os.path.abspath(script_path))
    if enable:
        content = f"""<?xml version="1.0" encoding="UTF-8"?>
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
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>{wd}/launchd.out.log</string>
  <key>StandardErrorPath</key><string>{wd}/launchd.err.log</string>
</dict></plist>"""
        LA_PLIST.write_text(content)
        if not _agent_loaded(label):
            uid = os.getuid()
            subprocess.call(["launchctl", "bootstrap", f"gui/{uid}", str(LA_PLIST)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.call(["launchctl", "enable", f"gui/{uid}/{label}"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.call(["launchctl", "kickstart", "-k", f"gui/{uid}/{label}"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        if _agent_loaded(label):
            uid = os.getuid()
            subprocess.call(["launchctl", "bootout", f"gui/{uid}/{label}"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            LA_PLIST.unlink()
        except Exception:
            pass

def ensure_dir(p: Path):
    p.mkdir(parents=True, exist_ok=True)

def load_cfg():
    ensure_dir(CFG_DIR)
    seed = dict(DEFAULT_CFG)
    env_token = os.environ.get("IPINFO_TOKEN", "").strip()
    if env_token:
        seed["ipinfo_token"] = env_token
    if CFG_FILE.exists():
        try:
            loaded = json.loads(CFG_FILE.read_text())
            seed.update(loaded)
        except Exception:
            pass
    if seed.get("ipv4_format") == "first_last_octet":
        seed["ipv4_format"] = "first_last"
    for key in DEFAULT_CFG:
        seed.setdefault(key, DEFAULT_CFG[key])
    CFG_FILE.write_text(json.dumps(seed, indent=2))
    return seed

def save_cfg(cfg):
    ensure_dir(CFG_DIR)
    CFG_FILE.write_text(json.dumps(cfg, indent=2))

def format_duration(seconds: float) -> str:
    if seconds < 60:
        return f"{int(seconds)}s"
    elif seconds < 3600:
        return f"{int(seconds/60)}m"
    elif seconds < 86400:
        hours = int(seconds / 3600)
        mins = int((seconds % 3600) / 60)
        return f"{hours}h {mins}m"
    else:
        days = int(seconds / 86400)
        hours = int((seconds % 86400) / 3600)
        return f"{days}d {hours}h"

class IPMenuApp(rumps.App):
    def __init__(self, cfg):
        super(IPMenuApp, self).__init__(APP_NAME, quit_button=None)
        self.title = f"{TITLE_PREFIX}—"
        self.cfg = cfg

        self.last_public_v4 = None
        self.last_public_v6 = None
        self.last_fetch_ts = 0
        self.public = "—"
        self.country = None
        self.country_name = None
        self.asn = None
        self.asname = None
        self.isp = None
        self.city = None
        self.region = None

        self._last_lan_key = None
        self._last_lan_notify_ts = 0
        self._nwi_fp = nwi_fingerprint()

        self.quality_monitor = NetworkQualityMonitor(
            target=cfg.get("ping_target", "8.8.8.8")
        ) if cfg.get("enable_ping_monitor") else None

        self.ip_history = IPHistoryTracker(
            max_entries=cfg.get("max_history_entries", 100)
        ) if cfg.get("track_ip_history") else None

        # Hardened: thread -> shared stats -> main thread updates UI
        self._quality_dirty = Event()
        self._quality_last_stats = None
        self._quality_lock = Lock()

        self.item_public = rumps.MenuItem("Public: —", callback=self.copy_public)
        self.item_asn    = rumps.MenuItem("ASN/ISP: —", callback=self.copy_asn)
        self.item_location = rumps.MenuItem("Location: —", callback=None)
        self.item_connection = rumps.MenuItem("Connection: —", callback=None)
        self.item_quality = rumps.MenuItem("Quality: —", callback=None)
        self.item_refresh= rumps.MenuItem("Refresh now", callback=self.refresh_now)
        self.item_reload = rumps.MenuItem("Reload", callback=self.reload_app)
        self.item_sep1   = rumps.separator

        self.sub_public_mode = rumps.MenuItem("Public mode")
        for mode in ["off","ipv4","ipv6","auto"]:
            self.sub_public_mode.add(rumps.MenuItem(mode, callback=lambda _, m=mode: self.set_public_mode(m)))

        self.sub_asn_src = rumps.MenuItem("ASN source")
        for mode in ["online","offline","auto"]:
            self.sub_asn_src.add(rumps.MenuItem(mode, callback=lambda _, m=mode: self.set_asn_source(m)))

        self.sub_country = rumps.MenuItem("Country format")
        self.sub_country.add(rumps.MenuItem("off", callback=self.set_country_off))
        self.sub_country.add(rumps.MenuItem("code", callback=self.set_country_code))
        self.sub_country.add(rumps.MenuItem("name", callback=self.set_country_name))

        self.sub_ipv4 = rumps.MenuItem("IPv4 format")
        self.sub_ipv4.add(rumps.MenuItem("full",         callback=lambda _, m="full": self.set_ipv4_format(m)))
        self.sub_ipv4.add(rumps.MenuItem("first 2",      callback=lambda _, m="first2": self.set_ipv4_format(m)))
        self.sub_ipv4.add(rumps.MenuItem("first + last", callback=lambda _, m="first_last": self.set_ipv4_format(m)))
        self.sub_ipv4.add(rumps.MenuItem("last 2",       callback=lambda _, m="last2": self.set_ipv4_format(m)))

        self.sub_interval = rumps.MenuItem("IP refresh interval")
        for sec, label in [(0,"Off"), (60,"1 min"), (300,"5 min"), (900,"15 min")]:
            self.sub_interval.add(rumps.MenuItem(label, callback=lambda _, s=sec: self.set_interval(s)))

        self.item_show_tunnels   = rumps.MenuItem("Show tunnel interfaces", callback=self.toggle_show_tunnels)
        self.item_show_linklocal = rumps.MenuItem("Show link-local IPv6", callback=self.toggle_linklocal)
        self.item_notify = rumps.MenuItem("Notify on IP change", callback=self.toggle_notify)
        self.item_sound  = rumps.MenuItem("Play sound", callback=self.toggle_sound)
        self.item_start  = rumps.MenuItem("Start at login", callback=self.toggle_start)
        self.item_showpub= rumps.MenuItem("Show public IP in menubar", callback=self.toggle_show_public)
        self.item_quality_toggle = rumps.MenuItem("Monitor network quality", callback=self.toggle_quality_monitor)
        self.item_history_toggle = rumps.MenuItem("Track IP history", callback=self.toggle_ip_history)
        self.item_dns_check = rumps.MenuItem("Check DNS leaks now", callback=self.check_dns_now)

        self.sub_history = rumps.MenuItem("IP History")
        self.item_view_history = rumps.MenuItem("View recent changes", callback=self.view_history)
        self.item_export_history = rumps.MenuItem("Export history", callback=self.export_history)
        self.item_clear_history = rumps.MenuItem("Clear history", callback=self.clear_history)
        self.sub_history.add(self.item_view_history)
        self.sub_history.add(self.item_export_history)
        self.sub_history.add(self.item_clear_history)

        self.sub_settings = rumps.MenuItem("Settings")
        self.item_set_ipinfo = rumps.MenuItem("Set IPinfo token…", callback=self.set_ipinfo_token)
        self.item_set_ping_target = rumps.MenuItem("Set ping target…", callback=self.set_ping_target)
        self.item_export_settings = rumps.MenuItem("Export settings…", callback=self.export_settings)
        self.item_import_settings = rumps.MenuItem("Import settings…", callback=self.import_settings)
        self.sub_settings.add(self.item_set_ipinfo)
        self.sub_settings.add(self.item_set_ping_target)
        self.sub_settings.add(rumps.separator)
        self.sub_settings.add(self.item_export_settings)
        self.sub_settings.add(self.item_import_settings)

        self.item_sep2 = rumps.separator
        self.item_local_header = rumps.MenuItem("Local Interfaces:", callback=None)
        self.local_items = []
        self.item_sep3 = rumps.separator
        self.item_about = rumps.MenuItem(f"About v{APP_VERSION}", callback=self.about)
        self.item_open_github = rumps.MenuItem("GitHub", callback=lambda _: subprocess.call(["open", GITHUB_URL]))
        self.item_quit  = rumps.MenuItem("Quit", callback=rumps.quit_application)

        self.menu = [
            self.item_public, self.item_asn, self.item_location,
            self.item_connection, self.item_quality,
            self.item_refresh, self.item_reload, self.item_sep1,
            self.sub_public_mode, self.sub_asn_src, self.sub_country,
            self.sub_ipv4, self.sub_interval,
            self.item_show_tunnels, self.item_show_linklocal,
            self.item_notify, self.item_sound, self.item_start, self.item_showpub,
            self.item_quality_toggle, self.item_history_toggle, self.item_dns_check,
            self.sub_history, self.sub_settings,
            self.item_sep2, self.item_local_header,
            self.item_sep3, self.item_open_github, self.item_about, self.item_quit
        ]

        self.sync_checkmarks()
        self._refresh_toggle_titles()

        self._sapdb_once = rumps.Timer(self._sapdb_kick, 1.0)
        self._sapdb_once.start()

        self.update_local_section()
        self.refresh_now(None)

        try:
            rumps.notification(APP_NAME, f"Started v{APP_VERSION}", "Enhanced network monitoring active")
        except Exception:
            pass

        self.timer = rumps.Timer(self.on_tick, LAN_CHECK_SEC)
        self.timer.start()

        if self.quality_monitor:
            self.quality_timer = rumps.Timer(self.on_quality_tick, cfg.get("ping_interval_sec", 30))
            self.quality_timer.start()

        self.sapdb_timer = rumps.Timer(self.on_sapdb_maint, 6 * 3600)
        self.sapdb_timer.start()

    def _sapdb_kick(self, _):
        try:
            self._sapdb_once.stop()
        except Exception:
            pass
        threading.Thread(target=self._sapdb_bg, daemon=True).start()

    def _sapdb_bg(self):
        try:
            ensure_sapdb(self.cfg.get("sapdb_auto_update_days", 30))
        except Exception:
            pass

    def toggle_quality_monitor(self, _):
        self.cfg["enable_ping_monitor"] = not self.cfg.get("enable_ping_monitor", False)
        save_cfg(self.cfg)
        self.sync_checkmarks()

        if self.cfg["enable_ping_monitor"] and not self.quality_monitor:
            self.quality_monitor = NetworkQualityMonitor(target=self.cfg.get("ping_target", "8.8.8.8"))
            self.quality_timer = rumps.Timer(self.on_quality_tick, self.cfg.get("ping_interval_sec", 30))
            self.quality_timer.start()
            rumps.notification(APP_NAME, "Quality Monitor", "Network quality monitoring enabled")
        elif not self.cfg["enable_ping_monitor"] and self.quality_monitor:
            try:
                self.quality_timer.stop()
            except Exception:
                pass
            self.quality_monitor = None
            self.item_quality.title = "Quality: —"

    def toggle_ip_history(self, _):
        self.cfg["track_ip_history"] = not self.cfg.get("track_ip_history", True)
        save_cfg(self.cfg)
        self.sync_checkmarks()

        if self.cfg["track_ip_history"] and not self.ip_history:
            self.ip_history = IPHistoryTracker(max_entries=self.cfg.get("max_history_entries", 100))
            rumps.notification(APP_NAME, "IP History", "IP history tracking enabled")
        elif not self.cfg["track_ip_history"]:
            self.ip_history = None

    def check_dns_now(self, _):
        result = check_dns_leaks()
        servers = result.get("dns_servers", [])
        leak = result.get("leak_detected", False)

        if result.get("error"):
            rumps.alert("DNS Check", "Could not check DNS servers")
            return

        msg = f"DNS Servers: {', '.join(servers[:3]) if servers else 'None found'}\n"
        if leak:
            msg += "\n⚠️ Suspicious DNS (potential leak / non-VPN DNS)."
        else:
            msg += "\n✓ No obvious DNS issues (heuristic)."

        rumps.alert("DNS Leak Check", msg)

    def set_ping_target(self, _):
        cur = self.cfg.get("ping_target", "8.8.8.8")
        w = rumps.Window(title="Ping Target", default_text=cur, message="Enter IP or hostname to ping")
        resp = w.run()
        if resp.clicked and resp.text.strip():
            self.cfg["ping_target"] = resp.text.strip()
            save_cfg(self.cfg)
            if self.quality_monitor:
                self.quality_monitor.target = self.cfg["ping_target"]

    def view_history(self, _):
        if not self.ip_history:
            rumps.alert("IP History", "History tracking is disabled")
            return

        recent = self.ip_history.get_recent(10)
        if not recent:
            rumps.alert("IP History", "No history entries yet")
            return

        lines = []
        for entry in recent:
            dt = datetime.fromtimestamp(entry.timestamp).strftime("%Y-%m-%d %H:%M")
            info = f"{dt}: {entry.ip}"
            if entry.country:
                info += f" ({entry.country})"
            if entry.isp:
                info += f" - {entry.isp[:30]}"
            lines.append(info)

        msg = "\n".join(lines)
        stats = self.ip_history.get_stats()
        msg += f"\n\nTotal entries: {stats['total_changes']}"
        msg += f"\nUnique IPs: {stats['unique_ips']}"

        rumps.alert("Recent IP History", msg)

    def export_history(self, _):
        if not self.ip_history:
            rumps.alert("Export History", "History tracking is disabled")
            return
        try:
            # ensure latest is saved
            self.ip_history.save()
            export_file = Path.home() / "Downloads" / f"ipmenu_history_{int(time.time())}.json"
            if HISTORY_FILE.exists():
                export_file.write_text(HISTORY_FILE.read_text())
            else:
                export_file.write_text(json.dumps([asdict(e) for e in self.ip_history.history], indent=2))
            rumps.notification(APP_NAME, "History Exported", f"Saved to {export_file.name}")
        except Exception as e:
            rumps.alert("Export Failed", str(e))

    def clear_history(self, _):
        if not self.ip_history:
            return
        response = rumps.alert("Clear History", "This will delete all IP history. Continue?",
                               ok="Clear", cancel="Cancel")
        if response == 1:
            with self.ip_history.lock:
                self.ip_history.history = []
            self.ip_history.save()
            rumps.notification(APP_NAME, "History Cleared", "All history entries deleted")

    def export_settings(self, _):
        try:
            export_file = Path.home() / "Downloads" / f"ipmenu_config_{int(time.time())}.json"
            export_file.write_text(json.dumps(self.cfg, indent=2))
            rumps.notification(APP_NAME, "Settings Exported", f"Saved to {export_file.name}")
            subprocess.call(["open", "-R", str(export_file)])
        except Exception as e:
            rumps.alert("Export Failed", str(e))

    def import_settings(self, _):
        response = rumps.alert("Import Settings",
                               "Select a config JSON file to import.",
                               ok="Select File", cancel="Cancel")
        if response == 1:
            try:
                result = subprocess.run(
                    ["osascript", "-e",
                     'set theFile to choose file with prompt "Select config file" of type {"json"}',
                     "-e", 'POSIX path of theFile'],
                    capture_output=True, text=True, timeout=30
                )
                if result.returncode == 0:
                    file_path = Path(result.stdout.strip())
                    if file_path.exists():
                        new_cfg = json.loads(file_path.read_text())
                        self.cfg.update(new_cfg)
                        save_cfg(self.cfg)
                        self.sync_checkmarks()
                        self._refresh_toggle_titles()
                        # apply runtime effects
                        if self.cfg.get("enable_ping_monitor") and not self.quality_monitor:
                            self.toggle_quality_monitor(None)
                        if not self.cfg.get("enable_ping_monitor") and self.quality_monitor:
                            self.toggle_quality_monitor(None)
                        if self.cfg.get("track_ip_history") and not self.ip_history:
                            self.toggle_ip_history(None)
                        if not self.cfg.get("track_ip_history") and self.ip_history:
                            self.toggle_ip_history(None)
                        rumps.notification(APP_NAME, "Settings Imported", "Configuration updated successfully")
                        self.refresh_now(None)
            except Exception as e:
                rumps.alert("Import Failed", str(e))

    def on_quality_tick(self, _):
        if not self.quality_monitor:
            return
        # background ping; DO NOT touch UI here
        threading.Thread(target=self._quality_probe_bg, daemon=True).start()

    def _quality_probe_bg(self):
        try:
            if self.quality_monitor and self.quality_monitor.update():
                stats = self.quality_monitor.get_stats()
                with self._quality_lock:
                    self._quality_last_stats = stats
                self._quality_dirty.set()
        except Exception:
            pass

    def update_quality_display(self, stats):
        if not stats or stats.get("quality") == "unknown":
            self.item_quality.title = "Quality: —"
        else:
            indicator = self.quality_monitor.get_indicator() if self.quality_monitor else QUALITY_UNKNOWN
            lat = stats.get("latency", 0)
            jit = stats.get("jitter", 0)
            self.item_quality.title = f"Quality: {indicator} {lat}ms (±{jit}ms)"

    def reload_app(self, _):
        try:
            rumps.notification(APP_NAME, "Reloading…", "Restarting application")
        except Exception:
            pass
        try:
            uid = os.getuid()
            subprocess.check_call(
                ["/bin/launchctl", "kickstart", "-k", f"gui/{uid}/com.ipmenu.app"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            rumps.quit_application()
            return
        except Exception:
            py = os.sys.executable
            script = os.path.abspath(__file__)
            os.execv(py, [py, script])

    def set_public_mode(self, mode):
        self.cfg["public_mode"] = mode
        save_cfg(self.cfg)
        self.sync_checkmarks()
        self.refresh_now(None)

    def set_asn_source(self, mode):
        self.cfg["asn_source"] = mode
        save_cfg(self.cfg)
        self.sync_checkmarks()
        self.refresh_now(None)

    def set_country_off(self, _): self._set_country("off")
    def set_country_code(self, _): self._set_country("code")
    def set_country_name(self, _): self._set_country("name")

    def _set_country(self, mode):
        self.cfg["country_format"] = mode
        save_cfg(self.cfg)
        self.sync_checkmarks()
        self.update_title()
        self.update_info_lines()

    def set_ipv4_format(self, mode):
        self.cfg["ipv4_format"] = mode
        save_cfg(self.cfg)
        self.sync_checkmarks()
        self.update_title()
        self.update_info_lines()

    def set_interval(self, sec):
        self.cfg["refresh_interval_sec"] = int(sec)
        save_cfg(self.cfg)
        self.sync_checkmarks()

    def toggle_show_tunnels(self, _):
        self.cfg["show_tunnels"] = not self.cfg["show_tunnels"]
        save_cfg(self.cfg)
        self.sync_checkmarks()
        self._refresh_toggle_titles()
        self.update_local_section()

    def toggle_linklocal(self, _):
        self.cfg["show_linklocal_v6"] = not self.cfg["show_linklocal_v6"]
        save_cfg(self.cfg)
        self.sync_checkmarks()
        self._refresh_toggle_titles()
        self.update_local_section()

    def toggle_notify(self, _):
        self.cfg["notify_on_change"] = not self.cfg["notify_on_change"]
        save_cfg(self.cfg)
        self.sync_checkmarks()

    def toggle_sound(self, _):
        self.cfg["play_sound"] = not self.cfg["play_sound"]
        save_cfg(self.cfg)
        self.sync_checkmarks()

    def toggle_start(self, _):
        self.cfg["start_at_login"] = not self.cfg["start_at_login"]
        save_cfg(self.cfg)
        self.sync_checkmarks()
        set_start_at_login(self.cfg["start_at_login"], os.sys.executable, os.path.abspath(__file__))

    def toggle_show_public(self, _):
        self.cfg["show_public"] = not self.cfg["show_public"]
        save_cfg(self.cfg)
        self.sync_checkmarks()
        self.update_title()

    def set_ipinfo_token(self, _):
        cur = self.cfg.get("ipinfo_token", "")
        w = rumps.Window(title="IPinfo Token", default_text=cur,
                         message="Leave empty to use env IPINFO_TOKEN")
        resp = w.run()
        if resp.clicked:
            self.cfg["ipinfo_token"] = resp.text.strip()
            save_cfg(self.cfg)

    def copy_public(self, _):
        copy_to_clipboard(self.public or "—")
        rumps.notification(APP_NAME, "Copied", self.public or "—")

    def copy_asn(self, _):
        line = self.item_asn.title.replace("ASN/ISP: ", "")
        copy_to_clipboard(line)
        rumps.notification(APP_NAME, "Copied", line)

    def refresh_now(self, _):
        self.fetch_public(force=True)
        self.update_title()
        self.update_info_lines()
        if self.quality_monitor:
            # kick one probe
            threading.Thread(target=self._quality_probe_bg, daemon=True).start()

    def about(self, _):
        msg = f"""IP Menu Pro v{APP_VERSION}

Enhanced macOS network monitor with:
• Real-time IP tracking
• Network quality monitoring
• DNS leak detection (heuristic)
• IP history tracking
• ASN/ISP lookup (online & offline)

by suen | github.com/ieduer"""
        rumps.alert(APP_NAME, msg)

    def _refresh_toggle_titles(self):
        self.item_show_tunnels.title = "Hide tunnel interfaces" if self.cfg.get("show_tunnels", False) else "Show tunnel interfaces"
        self.item_show_linklocal.title = "Hide link-local IPv6" if self.cfg.get("show_linklocal_v6", False) else "Show link-local IPv6"

    def sync_checkmarks(self):
        for k in self.sub_public_mode.values():
            k.state = False
        self.sub_public_mode[self.cfg.get("public_mode", "ipv4")].state = True

        for k in self.sub_asn_src.values():
            k.state = False
        self.sub_asn_src[self.cfg.get("asn_source", "online")].state = True

        for k in self.sub_country.values():
            k.state = False
        m = self.cfg.get("country_format", "off")
        self.sub_country[{"off": "off", "code": "code", "name": "name"}[m]].state = True

        for k in self.sub_ipv4.values():
            k.state = False
        mode = self.cfg.get("ipv4_format", "full")
        label_by_mode = {"full": "full", "first2": "first 2", "first_last": "first + last", "last2": "last 2"}
        self.sub_ipv4[label_by_mode.get(mode, "full")].state = True

        for k in self.sub_interval.values():
            k.state = False
        sec = int(self.cfg.get("refresh_interval_sec", 0))
        label = {0: "Off", 60: "1 min", 300: "5 min", 900: "15 min"}.get(sec, "Off")
        self.sub_interval[label].state = True

        self.item_notify.state  = self.cfg.get("notify_on_change", True)
        self.item_sound.state   = self.cfg.get("play_sound", True)
        self.item_start.state   = self.cfg.get("start_at_login", False)
        self.item_showpub.state = self.cfg.get("show_public", True)
        self.item_quality_toggle.state = self.cfg.get("enable_ping_monitor", False)
        self.item_history_toggle.state = self.cfg.get("track_ip_history", True)

    def on_tick(self, _):
        ui_dirty = False

        # apply pending quality update on main thread
        if self._quality_dirty.is_set():
            self._quality_dirty.clear()
            with self._quality_lock:
                stats = self._quality_last_stats
            if self.quality_monitor:
                self.update_quality_display(stats)
                ui_dirty = True

        new_fp = nwi_fingerprint()
        if new_fp and new_fp != getattr(self, "_nwi_fp", None):
            self._nwi_fp = new_fp
            self.fetch_public(force=True)
            ui_dirty = True

        iface = default_iface() or "—"
        mapping = iface_ips()
        v4 = mapping.get(iface, {}).get("v4", [])
        v6 = mapping.get(iface, {}).get("v6", [])
        if not self.cfg.get("show_linklocal_v6", False):
            v6 = [x for x in v6 if not x.startswith("fe80:")]
        lan_key = f"{iface}|{(v4[0] if v4 else '-')}|{(v6[0] if v6 else '-')}"
        if lan_key != self._last_lan_key:
            self._last_lan_key = lan_key
            if time.time() - self._last_lan_notify_ts > 1:
                rumps.notification(APP_NAME, "Local IP changed", lan_key)
                self._last_lan_notify_ts = time.time()
                self.fetch_public(force=True)
                ui_dirty = True

        self.update_local_section()

        if int(self.cfg.get("refresh_interval_sec", 0)) > 0:
            if time.time() - self.last_fetch_ts >= max(10, int(self.cfg["refresh_interval_sec"])):
                self.fetch_public(force=True)
                ui_dirty = True

        if self.cfg.get("fast_probe_when_singbox", True) and is_singbox_running():
            if time.time() - self.last_fetch_ts >= FAST_PROBE_SEC:
                self.fetch_public(force=True)
                ui_dirty = True

        if ui_dirty:
            self.update_title()
            self.update_info_lines()

    def fetch_public(self, force=False):
        if not force and (time.time() - self.last_fetch_ts) < PUBLIC_TTL_SEC:
            return
        self.last_fetch_ts = time.time()

        mode = self.cfg.get("public_mode", "ipv4")
        new_ip = "—"
        if mode == "off":
            self.public = "—"
            self.country = self.country_name = self.asn = None
            self.asname = self.isp = self.city = self.region = None
            return

        if mode in ("ipv4", "auto"):
            ip4 = get_public_ipv4()
            if ip4 != "—":
                new_ip = ip4
        if mode == "ipv6":
            new_ip = get_public_ipv6()
        elif mode == "auto" and new_ip == "—":
            v6 = get_public_ipv6()
            if v6 != "—":
                new_ip = v6

        country = None; country_name = None; asn = None
        asname = None; isp = None; city = None; region = None
        asn_src = self.cfg.get("asn_source", "online")
        token = (self.cfg.get("ipinfo_token") or os.environ.get("IPINFO_TOKEN", "")).strip()

        def try_online():
            nonlocal country, country_name, asn, asname, isp, city, region
            o = online_whois(new_ip, token)
            if o.get("ok"):
                country = o.get("country")
                country_name = o.get("country_name")
                asn = o.get("asn")
                asname = o.get("asname")
                isp = o.get("isp")
                city = o.get("city")
                region = o.get("region")
                return True
            return False

        def try_offline():
            nonlocal country, asn, asname, isp
            if not ASNDB.loaded:
                try:
                    ensure_sapdb(self.cfg.get("sapdb_auto_update_days", 30))
                except Exception:
                    pass
                try:
                    ASNDB.load()
                except Exception:
                    return False
            hit = ASNDB.lookup(new_ip)
            if not hit:
                return False
            country = hit.get("country")
            asn = hit.get("asn")
            asname = hit.get("asname")
            isp = hit.get("asname")
            return True

        changed = False
        if new_ip != "—":
            if asn_src == "online":
                _ = try_online()
            elif asn_src == "offline":
                _ = try_offline()
            else:
                _ = try_online() or try_offline()

            if _is_ipv4(new_ip):
                changed = (self.last_public_v4 is not None and new_ip != self.last_public_v4)
                self.last_public_v4 = new_ip
            elif _is_ipv6(new_ip):
                changed = (self.last_public_v6 is not None and new_ip != self.last_public_v6)
                self.last_public_v6 = new_ip

            if changed and self.cfg.get("notify_on_change", True):
                rumps.notification(APP_NAME, "Public IP changed", new_ip)
                if self.cfg.get("play_sound", True):
                    try:
                        from AppKit import NSSound
                        s = NSSound.soundNamed_("Glass")
                        s and s.play()
                    except Exception:
                        pass

            # Hardened: record initial entry too (if history empty)
            if self.ip_history:
                need_record = changed
                try:
                    with self.ip_history.lock:
                        if not self.ip_history.history:
                            need_record = True
                except Exception:
                    pass
                if need_record:
                    conn_type = detect_connection_type()
                    self.ip_history.add_entry(new_ip, country, asn, isp, conn_type)

        self.public = new_ip
        self.country = country
        self.country_name = country_name
        self.asn = asn
        self.asname = asname
        self.isp = isp
        self.city = city
        self.region = region

    def country_suffix(self):
        mode = self.cfg.get("country_format", "off")
        if mode == "off":
            return ""
        code = self.country
        name = self.country_name
        if mode == "code" and code:
            return f" {code}"
        if mode == "name" and (name or code):
            return f" {name or code}"
        return ""

    def update_title(self):
        quality_indicator = ""
        if (self.cfg.get("show_network_quality") and self.quality_monitor):
            quality_indicator = self.quality_monitor.get_indicator() + " "

        if not self.cfg.get("show_public", True):
            iface = default_iface() or "—"
            mapping = iface_ips()
            v4 = mapping.get(iface, {}).get("v4", [])
            v6 = mapping.get(iface, {}).get("v6", [])
            if not self.cfg.get("show_linklocal_v6", False):
                v6 = [x for x in v6 if not x.startswith("fe80:")]
            shown = (v4[0] if v4 else (v6[0] if v6 else "—"))
            if _is_ipv4(shown):
                shown = fmt_ipv4(shown, self.cfg.get("ipv4_format"))
            self.title = f"{TITLE_PREFIX}{quality_indicator}{shown}"
            return

        pub = self.public or "—"
        if pub == "—":
            iface = default_iface() or "—"
            mapping = iface_ips()
            v4 = mapping.get(iface, {}).get("v4", [])
            v6 = mapping.get(iface, {}).get("v6", [])
            if not self.cfg.get("show_linklocal_v6", False):
                v6 = [x for x in v6 if not x.startswith("fe80:")]
            shown = (v4[0] if v4 else (v6[0] if v6 else "—"))
            if _is_ipv4(shown):
                shown = fmt_ipv4(shown, self.cfg.get("ipv4_format"))
            self.title = f"{TITLE_PREFIX}{quality_indicator}{shown}"
            return

        pub_disp = (fmt_ipv4(pub, self.cfg.get("ipv4_format")) if _is_ipv4(pub) else pub)
        self.title = f"{TITLE_PREFIX}{quality_indicator}{pub_disp}{self.country_suffix()}"

    def update_info_lines(self):
        txt = f"Public: {self.public}"
        suf = self.country_suffix()
        if suf:
            txt += f"  [{suf.strip()}]"
        self.item_public.title = txt

        asline = "—"
        if self.asn or self.asname or self.isp:
            parts = []
            if self.asn:
                parts.append(f"AS{self.asn}")
            if self.asname:
                parts.append(self.asname)
            elif self.isp:
                parts.append(self.isp)
            asline = " ".join(parts) if parts else "—"
        self.item_asn.title = f"ASN/ISP: {asline}"

        loc_parts = []
        if self.city:
            loc_parts.append(self.city)
        if self.region:
            loc_parts.append(self.region)
        if self.country_name:
            loc_parts.append(self.country_name)
        loc = ", ".join(loc_parts) if loc_parts else "—"
        self.item_location.title = f"Location: {loc}"

        conn_type = detect_connection_type()
        conn_icons = {"wifi": "📶", "ethernet": "🔌", "vpn": "🔒", "cellular": "📱", "unknown": "❓"}
        conn_display = f"{conn_icons.get(conn_type, '❓')} {conn_type.upper()}"

        if self.ip_history and self.cfg.get("show_connection_time"):
            duration = self.ip_history.get_connection_duration()
            if duration:
                conn_display += f" ({format_duration(duration)})"
        self.item_connection.title = f"Connection: {conn_display}"

    def update_local_section(self):
        for it in getattr(self, "local_items", []):
            try:
                del self.menu[it]  # preferred
            except Exception:
                try:
                    del self.menu[it.title]
                except Exception:
                    try:
                        self.menu.pop(it)
                    except Exception:
                        pass
        self.local_items = []

        mapping = iface_ips()
        if not mapping:
            it = rumps.MenuItem("  —", callback=None)
            self.menu.insert_before(f"About v{APP_VERSION}", it)
            self.local_items.append(it)
            return

        pref = default_iface()
        keys = list(mapping.keys())
        if not self.cfg.get("show_tunnels", False):
            keys = [k for k in keys if not k.startswith("utun")]
        if pref in keys:
            keys.remove(pref)
            keys.insert(0, pref)

        for k in keys:
            v4_list = mapping[k]["v4"]
            v6_list = mapping[k]["v6"]
            if not self.cfg.get("show_linklocal_v6", False):
                v6_list = [x for x in v6_list if not x.startswith("fe80:")]
            v4 = ", ".join(v4_list) if v4_list else "—"
            v6 = ", ".join(v6_list) if v6_list else "—"
            text = f"{k}: v4[{v4}] v6[{v6}]"
            it = rumps.MenuItem(f"  {text}", callback=lambda _, t=text: copy_to_clipboard(t))
            self.menu.insert_before(f"About v{APP_VERSION}", it)
            self.local_items.append(it)

    def on_sapdb_maint(self, _):
        try:
            if need_sapdb_update(self.cfg.get("sapdb_auto_update_days", 30)):
                ensure_sapdb(self.cfg.get("sapdb_auto_update_days", 30))
                if ASNDB.loaded:
                    ASNDB.loaded = False
        except Exception:
            try:
                rumps.notification(APP_NAME, "DB update failed", "Will retry later")
            except Exception:
                pass

if __name__ == "__main__":
    if not acquire_single_instance_lock():
        raise SystemExit(0)

    cfg = load_cfg()

    try:
        if cfg.get("start_at_login", False):
            set_start_at_login(True, os.sys.executable, os.path.abspath(__file__))
    except Exception:
        pass

    app = IPMenuApp(cfg)

    try:
        from AppKit import NSApplication, NSApp, NSApplicationActivationPolicyProhibited
        NSApplication.sharedApplication()
        NSApp.setActivationPolicy_(NSApplicationActivationPolicyProhibited)
    except Exception:
        pass

    app.run()