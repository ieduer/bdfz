#!/bin/bash
# sbg.sh — sing-box Game Accelerator (Server-side installer for Hysteria2/TUIC)
# Author: you + ChatGPT
# Purpose: build a clean, game-focused UDP accelerator node (Hysteria2/TUIC) with ACME cert + strict UFW
# OS: Ubuntu only
# Note: This script installs to /etc/sbg and uses systemd service name "sbg"

export LANG=en_US.UTF-8

SBG_VERSION="v0.1.1-game-accel"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;36m'
bblue='\033[0;34m'
plain='\033[0m'

UPDATE_URL="https://raw.githubusercontent.com/ieduer/bdfz/main/sbg.sh"

_red(){ echo -e "\033[31m\033[01m$1\033[0m"; }
_green(){ echo -e "\033[32m\033[01m$1\033[0m"; }
_yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }
_blue(){ echo -e "\033[36m\033[01m$1\033[0m"; }
_white(){ echo -e "\033[37m\033[01m$1\033[0m"; }
readp(){ read -p "$(_yellow "$1")" "$2"; }

# ---- constants ----
SBG_DIR="/etc/sbg"
SBG_BIN="${SBG_DIR}/sing-box"
SBG_CONF="${SBG_DIR}/sbg.json"
SBG_DOMAIN_LOG="${SBG_DIR}/domain.log"
SBG_CERT="${SBG_DIR}/cert.crt"
SBG_KEY="${SBG_DIR}/private.key"
SBG_SUBTXT="${SBG_DIR}/sub.txt"
SBG_PUBLIC_INFO="${SBG_DIR}/public.info"

# Internal call
sbg(){
  bash "$0"
  exit 0
}

# ---- privilege ----
if [[ $EUID -ne 0 ]]; then
  _yellow "Please run as root."
  exit 1
fi

# ---- OS check (Ubuntu only) ----
if [[ -f /etc/issue ]] && grep -qi "ubuntu" /etc/issue; then
  release="Ubuntu"
elif [[ -f /proc/version ]] && grep -qi "ubuntu" /proc/version; then
  release="Ubuntu"
else
  _red "This script only supports Ubuntu."
  exit 1
fi

# ---- arch ----
case "$(uname -m)" in
  armv7l) cpu=armv7 ;;
  aarch64) cpu=arm64 ;;
  x86_64) cpu=amd64 ;;
  *) _red "Unsupported arch: $(uname -m)" ; exit 1 ;;
esac

hostname="$(hostname)"

# ---- helpers ----
enable_bbr(){
  if ! grep -q "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.conf 2>/dev/null; then
    _green "Enabling BBR..."
    {
      echo "net.core.default_qdisc = fq"
      echo "net.ipv4.tcp_congestion_control = bbr"
    } >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
  fi
}

install_depend(){
  if [[ ! -f "${SBG_DIR}/.deps_ok" ]]; then
    _green "Installing dependencies..."
    apt update -y
    apt install -y jq openssl iproute2 iputils-ping coreutils grep util-linux curl wget tar socat cron ufw ca-certificates
    mkdir -p "${SBG_DIR}"
    touch "${SBG_DIR}/.deps_ok"
  fi
}

v4v6(){
  v4="$(curl -s4m6 icanhazip.com -k | tr -d '\r\n ')" || true
  v6="$(curl -s6m6 icanhazip.com -k | tr -d '\r\n ')" || true
}

rand_str(){
  # 32 chars A-Za-z0-9
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
}

is_udp_port_free(){
  local p="$1"
  # returns 0 if free
  if ss -u -l -n -p 2>/dev/null | awk '{print $5}' | sed 's/.*://g' | grep -qw "$p"; then
    return 1
  fi
  return 0
}

pick_udp_port(){
  # args: preferred_port
  local preferred="$1"
  if [[ -n "$preferred" ]] && is_udp_port_free "$preferred"; then
    echo "$preferred"
    return 0
  fi
  local p=""
  while true; do
    p="$(shuf -i 10000-65535 -n 1)"
    if is_udp_port_free "$p"; then
      echo "$p"
      return 0
    fi
  done
}

detect_ssh_port(){
  local ssh_port=""
  if command -v sshd >/dev/null 2>&1; then
    ssh_port="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')"
  fi
  if [[ -z "$ssh_port" ]]; then
    ssh_port="$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | tail -n 1 | awk '{print $2}')"
  fi
  [[ -z "$ssh_port" ]] && ssh_port="22"
  echo "$ssh_port"
}

# ---- sing-box install ----
inssb(){
  _green "Installing sing-box core..."
  mkdir -p "${SBG_DIR}"

  local sbcore=""
  sbcore="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r '.tag_name' 2>/dev/null | sed 's/^v//' || true)"
  if [[ -z "$sbcore" || "$sbcore" == "null" ]]; then
    # fallback to a known stable version (no guessing future versions)
    sbcore="1.12.4"
    _yellow "GitHub API failed. Fallback to sing-box v${sbcore}."
  fi

  local sbname="sing-box-${sbcore}-linux-${cpu}"
  local sburl="https://github.com/SagerNet/sing-box/releases/download/v${sbcore}/${sbname}.tar.gz"

  _green "Downloading: v${sbcore} (${sbname})"
  curl -fL -o "${SBG_DIR}/sing-box.tar.gz" -# --retry 2 "${sburl}" || {
    _red "Failed to download sing-box from GitHub."
    exit 1
  }

  tar xzf "${SBG_DIR}/sing-box.tar.gz" -C "${SBG_DIR}" 2>/dev/null || {
    _red "Failed to extract sing-box tarball."
    rm -f "${SBG_DIR}/sing-box.tar.gz"
    exit 1
  }

  if [[ ! -x "${SBG_DIR}/${sbname}/sing-box" ]]; then
    _red "sing-box binary not found after extracting."
    exit 1
  fi

  mv "${SBG_DIR}/${sbname}/sing-box" "${SBG_BIN}"
  rm -rf "${SBG_DIR}/${sbname}" "${SBG_DIR}/sing-box.tar.gz"
  chown root:root "${SBG_BIN}"
  chmod +x "${SBG_BIN}"

  _green "sing-box installed: $(${SBG_BIN} version 2>/dev/null | head -n 1)"
}

# ---- ACME cert (acme.sh, Let's Encrypt) ----
apply_acme(){
  v4v6
  _red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  _green "ACME certificate required (Let's Encrypt)."
  _green "Your domain must resolve to this server IP:"
  _green "IPv4: ${v4:-<none>}"
  _green "IPv6: ${v6:-<none>}"
  readp "Enter your domain (e.g. example.com): " domain_name

  if [[ -z "$domain_name" ]]; then
    _red "Domain cannot be empty."
    exit 1
  fi

  mkdir -p "${SBG_DIR}"

  _green "Installing/Upgrading acme.sh..."
  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    curl https://get.acme.sh | sh
  fi

  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  /root/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1 || true

  acme_install_existing(){
    local d="$1"
    # ECC first
    /root/.acme.sh/acme.sh --installcert -d "$d" \
      --fullchainpath "${SBG_CERT}" \
      --keypath "${SBG_KEY}" \
      --ecc >/dev/null 2>&1 && return 0
    # RSA
    /root/.acme.sh/acme.sh --installcert -d "$d" \
      --fullchainpath "${SBG_CERT}" \
      --keypath "${SBG_KEY}" \
      >/dev/null 2>&1 && return 0
    return 1
  }

  # If already issued, just install.
  if acme_install_existing "$domain_name"; then
    _green "Existing cert found in acme.sh, installed to ${SBG_DIR}."
  else
    # Standalone needs :80 free
    if ss -tulnp 2>/dev/null | awk '{print $5}' | grep -qE '(:|])80$'; then
      _red "Port 80 is in use. Standalone ACME needs port 80 temporarily."
      _red "Stop your web server (nginx/apache/caddy) or pre-issue cert in acme.sh first."
      exit 1
    fi

    # If UFW enabled, allow 80 temporarily.
    ufw allow 80/tcp >/dev/null 2>&1 || true

    _green "Issuing cert via standalone (Let's Encrypt, ECC)..."
    /root/.acme.sh/acme.sh --register-account -m "admin@${domain_name}" --server letsencrypt >/dev/null 2>&1 || true
    /root/.acme.sh/acme.sh --issue -d "$domain_name" --standalone -k ec-256 --server letsencrypt
    issue_rc=$?

    if [[ $issue_rc -ne 0 ]]; then
      if acme_install_existing "$domain_name"; then
        _yellow "acme.sh --issue returned non-zero (maybe skipping), but cert exists. Continue."
      else
        _red "ACME issue failed. Check DNS A record, port 80 reachability, firewall/security group."
        exit 1
      fi
    else
      if ! acme_install_existing "$domain_name"; then
        _red "Issued but installcert failed."
        exit 1
      fi
    fi

    # Close port 80 back (best-effort).
    ufw delete allow 80/tcp >/dev/null 2>&1 || true
  fi

  if [[ ! -s "${SBG_CERT}" || ! -s "${SBG_KEY}" ]]; then
    _red "Cert install failed: missing ${SBG_CERT} or ${SBG_KEY}."
    exit 1
  fi

  /root/.acme.sh/acme.sh --install-cronjob >/dev/null 2>&1 || true
  _green "acme.sh cron for renew installed/updated."

  echo "$domain_name" > "${SBG_DOMAIN_LOG}"
  _green "Domain saved: ${domain_name}"
}

ensure_domain_and_cert(){
  if [[ -s "${SBG_CERT}" && -s "${SBG_KEY}" && -s "${SBG_DOMAIN_LOG}" ]]; then
    domain_name="$(head -n1 "${SBG_DOMAIN_LOG}" | tr -d '\r\n ')"
    _green "Found existing cert + domain: ${domain_name}. Skip ACME."
  else
    apply_acme
    domain_name="$(head -n1 "${SBG_DOMAIN_LOG}" | tr -d '\r\n ')"
  fi
}

# ---- firewall ----
setup_firewall(){
  local ssh_port
  ssh_port="$(detect_ssh_port)"

  _green "Configuring UFW (strict game-accelerator ports only)..."
  echo "y" | ufw reset >/dev/null 2>&1 || true
  ufw default deny incoming
  ufw default allow outgoing

  ufw allow "${ssh_port}/tcp" comment "SSH" >/dev/null 2>&1 || true
  ufw allow "${PORT_HY2}/udp" comment "Hysteria2-UDP" >/dev/null 2>&1 || true

  if [[ "${ENABLE_TUIC}" == "1" ]]; then
    ufw allow "${PORT_TUIC}/udp" comment "TUIC-UDP" >/dev/null 2>&1 || true
  fi

  echo "y" | ufw enable >/dev/null 2>&1 || true
  _green "UFW enabled. Allowed: SSH(${ssh_port}/tcp), HY2(${PORT_HY2}/udp)$( [[ "${ENABLE_TUIC}" == "1" ]] && echo ", TUIC(${PORT_TUIC}/udp)" )."
}

# ---- config generation ----
gen_server_config(){
  mkdir -p "${SBG_DIR}"

  local hy2_pass tuic_uuid tuic_pass
  hy2_pass="$(rand_str)"
  tuic_uuid="$(${SBG_BIN} generate uuid 2>/dev/null || true)"
  [[ -z "$tuic_uuid" ]] && tuic_uuid="$(rand_str)"
  tuic_pass="$(rand_str)"

  # Pick IP strategy based on v4 availability
  v4v6
  local ipv
  if [[ -n "${v4}" ]]; then
    ipv="prefer_ipv4"
  else
    ipv="prefer_ipv6"
  fi

  # Save public info (credentials you will use on client)
  cat > "${SBG_PUBLIC_INFO}" <<EOF
DOMAIN=${domain_name}
PORT_HY2=${PORT_HY2}
HY2_PASSWORD=${hy2_pass}
ENABLE_TUIC=${ENABLE_TUIC}
PORT_TUIC=${PORT_TUIC:-}
TUIC_UUID=${tuic_uuid}
TUIC_PASSWORD=${tuic_pass}
EOF
  chmod 600 "${SBG_PUBLIC_INFO}"

  # Build JSON config via python to avoid heredoc-templating pitfalls
  DOMAIN_NAME="${domain_name}" \
  PORT_HY2="${PORT_HY2}" \
  HY2_PASS="${hy2_pass}" \
  ENABLE_TUIC="${ENABLE_TUIC}" \
  PORT_TUIC="${PORT_TUIC}" \
  TUIC_UUID="${tuic_uuid}" \
  TUIC_PASS="${tuic_pass}" \
  SBG_CERT="${SBG_CERT}" \
  SBG_KEY="${SBG_KEY}" \
  IPV_STRATEGY="${ipv}" \
  python3 - <<'PY'
import json, os

domain = os.environ.get("DOMAIN_NAME", "")
port_hy2 = int(os.environ.get("PORT_HY2", "0") or 0)
hy2_pass = os.environ.get("HY2_PASS", "")
enable_tuic = os.environ.get("ENABLE_TUIC", "0") == "1"
port_tuic = int(os.environ.get("PORT_TUIC", "0") or 0)
tuic_uuid = os.environ.get("TUIC_UUID", "")
tuic_pass = os.environ.get("TUIC_PASS", "")
cert = os.environ.get("SBG_CERT", "/etc/sbg/cert.crt")
key = os.environ.get("SBG_KEY", "/etc/sbg/private.key")
ipv = os.environ.get("IPV_STRATEGY", "prefer_ipv4")

conf = {
  "log": {"disabled": False, "level": "info", "timestamp": True},
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": port_hy2,
      "users": [{"password": hy2_pass}],
      "tls": {
        "enabled": True,
        "alpn": ["h3"],
        "certificate_path": cert,
        "key_path": key,
      },
      "masquerade": {
        "type": "proxy",
        "proxy": {
          "url": "https://www.cloudflare.com/",
          "rewrite_host": True,
        },
      },
    }
  ],
  "outbounds": [
    {"type": "direct", "tag": "direct", "domain_strategy": ipv},
    {"type": "block", "tag": "block"},
  ],
}

if enable_tuic:
  conf["inbounds"].append(
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": port_tuic,
      "users": [{"uuid": tuic_uuid, "password": tuic_pass}],
      "congestion_control": "bbr",
      "tls": {
        "enabled": True,
        "alpn": ["h3"],
        "certificate_path": cert,
        "key_path": key,
      },
    }
  )

path = "/etc/sbg/sbg.json"
with open(path, "w", encoding="utf-8") as f:
  json.dump(conf, f, indent=2)
PY

  chmod 600 "${SBG_CONF}"
  _green "Server config generated: ${SBG_CONF}"
}

# ---- regenerate config from public.info ----
regen_server_config_from_public_info(){
  if [[ ! -s "${SBG_PUBLIC_INFO}" || ! -s "${SBG_DOMAIN_LOG}" ]]; then
    _red "Missing ${SBG_PUBLIC_INFO} or ${SBG_DOMAIN_LOG}. Cannot regenerate config."
    return 1
  fi

  # shellcheck disable=SC1090
  source "${SBG_PUBLIC_INFO}"
  domain_name="$(head -n1 "${SBG_DOMAIN_LOG}" | tr -d '\r\n ')"

  # Pick IP strategy based on v4 availability
  v4v6
  local ipv
  if [[ -n "${v4}" ]]; then
    ipv="prefer_ipv4"
  else
    ipv="prefer_ipv6"
  fi

  # Rebuild config using stored credentials (no changes to passwords/UUID)
  DOMAIN_NAME="${DOMAIN}" \
  PORT_HY2="${PORT_HY2}" \
  HY2_PASS="${HY2_PASSWORD}" \
  ENABLE_TUIC="${ENABLE_TUIC}" \
  PORT_TUIC="${PORT_TUIC:-0}" \
  TUIC_UUID="${TUIC_UUID}" \
  TUIC_PASS="${TUIC_PASSWORD}" \
  SBG_CERT="${SBG_CERT}" \
  SBG_KEY="${SBG_KEY}" \
  IPV_STRATEGY="${ipv}" \
  python3 - <<'PY'
import json, os

domain = os.environ.get("DOMAIN_NAME", "")
port_hy2 = int(os.environ.get("PORT_HY2", "0") or 0)
hy2_pass = os.environ.get("HY2_PASS", "")
enable_tuic = os.environ.get("ENABLE_TUIC", "0") == "1"
port_tuic = int(os.environ.get("PORT_TUIC", "0") or 0)
tuic_uuid = os.environ.get("TUIC_UUID", "")
tuic_pass = os.environ.get("TUIC_PASS", "")
cert = os.environ.get("SBG_CERT", "/etc/sbg/cert.crt")
key = os.environ.get("SBG_KEY", "/etc/sbg/private.key")
ipv = os.environ.get("IPV_STRATEGY", "prefer_ipv4")

conf = {
  "log": {"disabled": False, "level": "info", "timestamp": True},
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": port_hy2,
      "users": [{"password": hy2_pass}],
      "tls": {
        "enabled": True,
        "alpn": ["h3"],
        "certificate_path": cert,
        "key_path": key,
      },
      "masquerade": {
        "type": "proxy",
        "proxy": {
          "url": "https://www.cloudflare.com/",
          "rewrite_host": True,
        },
      },
    }
  ],
  "outbounds": [
    {"type": "direct", "tag": "direct", "domain_strategy": ipv},
    {"type": "block", "tag": "block"},
  ],
}

if enable_tuic:
  conf["inbounds"].append(
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": port_tuic,
      "users": [{"uuid": tuic_uuid, "password": tuic_pass}],
      "congestion_control": "bbr",
      "tls": {
        "enabled": True,
        "alpn": ["h3"],
        "certificate_path": cert,
        "key_path": key,
      },
    }
  )

path = "/etc/sbg/sbg.json"
with open(path, "w", encoding="utf-8") as f:
  json.dump(conf, f, indent=2)
PY

  chmod 600 "${SBG_CONF}"
  _green "Regenerated server config: ${SBG_CONF}"
  return 0
}

# ---- systemd service ----
sbg_service_install(){
  cat > /etc/systemd/system/sbg.service <<EOF
[Unit]
Description=sing-box game accelerator (Hysteria2/TUIC)
After=network.target nss-lookup.target
Wants=network-online.target
After=network-online.target

[Service]
User=root
WorkingDirectory=/root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=${SBG_BIN} run -c ${SBG_CONF}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=2
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable sbg >/dev/null 2>&1 || true
  systemctl restart sbg
  sleep 1
  if systemctl is-active --quiet sbg; then
    _green "Service started: sbg"
  else
    _red "Service failed to start. Check: systemctl status sbg -l && journalctl -u sbg -n 200 --no-pager"
    exit 1
  fi
}

view_log(){
  if command -v journalctl >/dev/null 2>&1; then
    _green "Last 120 lines of sbg logs:"
    journalctl -u sbg --no-pager -n 120 2>/dev/null || _red "No logs found (service may not exist)."
  else
    _red "journalctl not available."
  fi
}

restart_sbg(){
  _green "Restarting sbg..."
  systemctl restart sbg 2>/dev/null || { _red "Restart failed. Is sbg installed?"; return; }
  sleep 1
  systemctl is-active --quiet sbg && _green "sbg restarted OK." || _red "sbg status abnormal."
}

update_core(){
  _green "Updating sing-box core..."
  systemctl stop sbg 2>/dev/null || true
  inssb
  systemctl restart sbg 2>/dev/null || { _yellow "Core updated but restart failed. Check systemctl status sbg -l"; return; }
  _green "Core updated & service restarted."
}

# ---- self update ----
lnsbg(){
  rm -f /usr/bin/sbg
  curl -L -o /usr/bin/sbg -# --retry 2 --insecure "${UPDATE_URL}" || {
    _red "Failed to download update script from: ${UPDATE_URL}"
    exit 1
  }
  chmod +x /usr/bin/sbg
}

upsbg(){
  lnsbg
  _green "Script updated. Run: sbg"
  exit 0
}

# ---- share links + client config ----
sbgshare(){
  if [[ ! -s "${SBG_PUBLIC_INFO}" || ! -s "${SBG_DOMAIN_LOG}" ]]; then
    _red "Missing ${SBG_PUBLIC_INFO} or ${SBG_DOMAIN_LOG}. Install first."
    return
  fi

  # shellcheck disable=SC1090
  source "${SBG_PUBLIC_INFO}"
  domain="$(head -n1 "${SBG_DOMAIN_LOG}" | tr -d '\r\n ')"

  v4v6
  host="${domain}"
  if [[ -n "${v4}" ]]; then
    host="${v4}"
  fi

  # Build URIs
  hy_link="hysteria2://${HY2_PASSWORD}@${host}:${PORT_HY2}?security=tls&alpn=h3&sni=${domain}#HY2-GAME-${hostname}"
  tu_link=""
  if [[ "${ENABLE_TUIC}" == "1" ]]; then
    tu_link="tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${host}:${PORT_TUIC}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${domain}&allow_insecure=0#TUIC-GAME-${hostname}"
  fi

  mkdir -p "${SBG_DIR}"
  : > "${SBG_SUBTXT}"
  echo "${hy_link}" >> "${SBG_SUBTXT}"
  [[ -n "${tu_link}" ]] && echo "${tu_link}" >> "${SBG_SUBTXT}"

  sub_base64="$(base64 -w 0 < "${SBG_SUBTXT}" 2>/dev/null || base64 < "${SBG_SUBTXT}" | tr -d '\n')"

  echo
  _white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo -e "Domain: ${green}${domain}${plain}"
  echo -e "Host (preferred): ${green}${host}${plain}"
  echo
  echo -e "Hysteria2 (UDP) Port: ${yellow}${PORT_HY2}${plain}"
  [[ "${ENABLE_TUIC}" == "1" ]] && echo -e "TUIC (UDP) Port:      ${yellow}${PORT_TUIC}${plain}"
  echo
  _red "🚀 Base64 Subscription:"
  echo -e "${yellow}${sub_base64}${plain}"
  _white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
}

client_conf(){
  if [[ ! -s "${SBG_PUBLIC_INFO}" || ! -s "${SBG_DOMAIN_LOG}" ]]; then
    _red "Missing ${SBG_PUBLIC_INFO} or ${SBG_DOMAIN_LOG}. Install first."
    return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    _red "jq not found."
    return
  fi

  # shellcheck disable=SC1090
  source "${SBG_PUBLIC_INFO}"
  domain="$(head -n1 "${SBG_DOMAIN_LOG}" | tr -d '\r\n ')"

  v4v6
  host="${domain}"
  if [[ -n "${v4}" ]]; then
    host="${v4}"
  fi

  _green "Game-only sing-box client config (TUN)."
  _yellow "Default behavior: ONLY route known game domains via proxy; everything else DIRECT."
  _yellow "If a game uses pure IP/UDP with no domain, it may not match. In that case, switch to GLOBAL by setting route.final to \"proxy\"."
  echo

  # NOTE:
  # - Use MetaCubeX remote ruleset "category-games" for game domains.
  # - Keep cn direct; games -> proxy; final -> direct.
  # - DNS: game -> proxydns, cn -> localdns, final -> localdns.
  cat <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "localdns",
        "address": "223.5.5.5",
        "detour": "direct"
      },
      {
        "tag": "proxydns",
        "address": "tls://1.1.1.1/dns-query",
        "detour": "proxy"
      }
    ],
    "rules": [
      {
        "rule_set": "geosite-cn",
        "server": "localdns"
      },
      {
        "rule_set": "geosite-category-games",
        "server": "proxydns"
      }
    ],
    "final": "localdns"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": [
        "172.19.0.1/30",
        "fd00::1/126"
      ],
      "auto_route": true,
      "strict_route": true,
      "sniff": true,
      "sniff_override_destination": true,
      "mtu": 1500
    }
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "proxy",
      "server": "${host}",
      "server_port": ${PORT_HY2},
      "password": "${HY2_PASSWORD}",
      "tls": {
        "enabled": true,
        "server_name": "${domain}",
        "insecure": false,
        "alpn": ["h3"]
      }
    }$( [[ "${ENABLE_TUIC}" == "1" ]] && cat <<EOF_TUIC
,
    {
      "type": "tuic",
      "tag": "proxy-tuic",
      "server": "${host}",
      "server_port": ${PORT_TUIC},
      "uuid": "${TUIC_UUID}",
      "password": "${TUIC_PASSWORD}",
      "congestion_control": "bbr",
      "udp_relay_mode": "native",
      "udp_over_stream": false,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "server_name": "${domain}",
        "insecure": false,
        "alpn": ["h3"]
      }
    }
EOF_TUIC
 )
,
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],
  "route": {
    "rule_set": [
      {
        "tag": "geosite-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/geolocation-cn.srs",
        "download_detour": "direct",
        "update_interval": "1d"
      },
      {
        "tag": "geoip-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/cn.srs",
        "download_detour": "direct",
        "update_interval": "1d"
      },
      {
        "tag": "geosite-category-games",
        "type": "remote",
        "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/category-games.srs",
        "download_detour": "direct",
        "update_interval": "1d"
      }
    ],
    "auto_detect_interface": true,
    "final": "direct",
    "rules": [
      { "protocol": "dns", "outbound": "dns-out" },
      { "ip_is_private": true, "outbound": "direct" },

      { "rule_set": "geoip-cn", "outbound": "direct" },
      { "rule_set": "geosite-cn", "outbound": "direct" },

      { "rule_set": "geosite-category-games", "outbound": "proxy" }
    ]
  }
}
EOF
  echo
  _yellow "macOS run (example): sudo sing-box run -c ./game.json"
}

# ---- uninstall ----
unins(){
  _yellow "Uninstalling sbg..."
  systemctl stop sbg 2>/dev/null || true
  systemctl disable sbg 2>/dev/null || true
  rm -f /etc/systemd/system/sbg.service
  systemctl daemon-reload >/dev/null 2>&1 || true

  rm -rf "${SBG_DIR}"
  rm -f /usr/bin/sbg

  _green "Uninstalled. (UFW rules not reset automatically; if needed: ufw status / ufw reset)"
}

# ---- install flow ----
install_sbg(){
  if [[ -f /etc/systemd/system/sbg.service ]]; then
    _red "sbg is already installed. Please uninstall first."
    exit 1
  fi

  install_depend
  enable_bbr
  inssb

  _green "UDP port selection (recommended for game accel):"
  _green "1) Use 443/udp for Hysteria2 (best compatibility)"
  _green "2) Random high UDP port"
  readp "Choose [1/2] (default 1): " port_choice
  [[ -z "$port_choice" ]] && port_choice="1"

  if [[ "$port_choice" == "1" ]]; then
    PORT_HY2="$(pick_udp_port 443)"
    if [[ "${PORT_HY2}" != "443" ]]; then
      _yellow "UDP 443 is not free, picked: ${PORT_HY2}/udp"
    fi
  else
    PORT_HY2="$(pick_udp_port "")"
  fi

  _green "Enable TUIC as a second UDP option?"
  _green "1) Yes"
  _green "2) No (default)"
  readp "Choose [1/2] (default 2): " tuic_choice
  [[ -z "$tuic_choice" ]] && tuic_choice="2"
  if [[ "$tuic_choice" == "1" ]]; then
    ENABLE_TUIC="1"
    # Prefer 8443 if free; else random
    PORT_TUIC="$(pick_udp_port 8443)"
    if [[ "${PORT_TUIC}" != "8443" ]]; then
      _yellow "UDP 8443 is not free, picked: ${PORT_TUIC}/udp"
    fi
  else
    ENABLE_TUIC="0"
    PORT_TUIC=""
  fi

  ensure_domain_and_cert
  setup_firewall
  gen_server_config || { _red "Failed to generate config."; exit 1; }
  sbg_service_install
  lnsbg

  # Optional keepalive restart (lightweight)
  (crontab -l 2>/dev/null | grep -v "systemctl restart sbg" ; echo "0 4 * * * systemctl restart sbg >/dev/null 2>&1") | crontab -

  _green "Install complete!"
  sbgshare
}

# ---- UI ----
clear
_white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
_white "sbg — Sing-box Game Accelerator (Hysteria2/TUIC)  |  ${SBG_VERSION}"
_white "Shortcut command: sbg"
_red   "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
_green " 1. Install (domain + ACME cert required)"
_green " 2. Uninstall"
_green " 3. Show subscription (Base64)"
_green " 4. Update script"
_green " 5. View logs"
_green " 6. Restart service"
_green " 7. Update sing-box core"
_green " 8. Show game-only client config (TUN)"
_green " 9. Regenerate server config (fix broken JSON)"
_red   "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

readp "Select: " Input
case "$Input" in
  1) install_sbg ;;
  2) unins ;;
  3) sbgshare ;;
  4) upsbg ;;
  5) view_log ;;
  6) restart_sbg ;;
  7) update_core ;;
  8) client_conf ;;
  9) regen_server_config_from_public_info && restart_sbg ;;
  *) exit 0 ;;
esac