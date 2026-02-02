#!/bin/bash
export LANG=en_US.UTF-8

SBG_VERSION="v0.2.3-game-accel"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;36m'
plain='\033[0m'

_red(){ echo -e "${red}\033[01m$1${plain}"; }
_green(){ echo -e "${green}\033[01m$1${plain}"; }
_yellow(){ echo -e "${yellow}\033[01m$1${plain}"; }
_blue(){ echo -e "${blue}\033[01m$1${plain}"; }
readp(){ read -p "$(_yellow "$1")" "$2"; }

# Update link
UPDATE_URL="https://raw.githubusercontent.com/ieduer/bdfz/main/sbg.sh"

# Paths
SBG_DIR="/etc/sbg"
SBG_BIN="${SBG_DIR}/sing-box"
SBG_CONF="${SBG_DIR}/sbg.json"
SBG_DOMAIN_LOG="${SBG_DIR}/domain.log"
SBG_PUBLIC_INFO="${SBG_DIR}/public.info"
SBG_CERT="${SBG_DIR}/cert.crt"
SBG_KEY="${SBG_DIR}/private.key"
SBG_SUB_TXT="${SBG_DIR}/sub.txt"

# Reality keys (stored in public.info)
# REALITY_PRIVATE_KEY is NOT persisted in plain text elsewhere.

# Globals (runtime)
domain_name=""
hostname="$(hostname)"
v4=""
v6=""
cpu=""

# Ports (runtime)
PORT_HY2=""
ENABLE_TUIC="0"
PORT_TUIC=""

ENABLE_VLESS="1"
PORT_VLESS="443"         # TCP (can coexist with UDP 443)
REALITY_SNI="apple.com"  # SNI shown to client
REALITY_HS_SERVER="apple.com"
REALITY_HS_PORT="443"
REALITY_SHORT_ID=""

# TLS mode
TLS_MODE="selfsigned"     # selfsigned | acme
TLS_INSECURE_CLIENT="1"   # 1 for self-signed, 0 for valid CA

# Secrets (runtime)
HY2_PASS=""
HY2_OBFS=""
TUIC_UUID=""
TUIC_PASS=""
VLESS_UUID=""
REALITY_PRIV=""
REALITY_PUB=""

die(){ _red "$1"; exit 1; }

need_root(){
  [[ $EUID -ne 0 ]] && die "Please run as root."
}

only_ubuntu(){
  if [[ -f /etc/issue ]] && grep -qi ubuntu /etc/issue; then
    return 0
  elif [[ -f /proc/version ]] && grep -qi ubuntu /proc/version; then
    return 0
  fi
  die "This script supports Ubuntu only."
}

detect_arch(){
  case "$(uname -m)" in
    x86_64) cpu="amd64" ;;
    aarch64) cpu="arm64" ;;
    armv7l) cpu="armv7" ;;
    *) die "Unsupported arch: $(uname -m)" ;;
  esac
}

print_version(){
  echo "sbg — Sing-box Game Accelerator (HY2/TUIC + VLESS Reality)  |  ${SBG_VERSION}"
}

v4v6(){
  v4="$(curl -s4m5 -k icanhazip.com 2>/dev/null | tr -d ' \r\n' || true)"
  v6="$(curl -s6m5 -k icanhazip.com 2>/dev/null | tr -d ' \r\n' || true)"
}

rand_port_udp(){
  while true; do
    local p
    p="$(shuf -i 10000-65535 -n 1)"
    if ! ss -ulnp 2>/dev/null | awk '{print $5}' | sed 's/.*://g' | grep -qx "$p"; then
      echo "$p"
      return
    fi
  done
}

rand_port_tcp(){
  while true; do
    local p
    p="$(shuf -i 10000-65535 -n 1)"
    if ! ss -tlnp 2>/dev/null | awk '{print $4}' | sed 's/.*://g' | grep -qx "$p"; then
      echo "$p"
      return
    fi
  done
}

port_in_use(){
  local proto="$1" port="$2"
  if [[ "$proto" == "tcp" ]]; then
    ss -tlnp 2>/dev/null | awk '{print $4}' | sed 's/.*://g' | grep -qx "$port"
  else
    ss -ulnp 2>/dev/null | awk '{print $5}' | sed 's/.*://g' | grep -qx "$port"
  fi
}

rand_str(){
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

rand_hex(){
  # N bytes -> 2N hex chars
  local n="${1:-4}"
  openssl rand -hex "$n" 2>/dev/null | tr -d ' \r\n'
}

enable_bbr(){
  if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    _green "Enabling BBR + fq..."
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-sbg-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl --system >/dev/null 2>&1 || true
  fi
}

apt_update_best_effort(){
  for i in 1 2 3; do
    apt update -y && return 0
    _yellow "apt update failed (attempt $i/3). Mirror may be syncing. Retrying..."
    sleep 2
  done
  _yellow "apt update still failing. Continue with cached index (may still work)."
  return 0
}

install_deps(){
  mkdir -p "${SBG_DIR}"
  _green "Installing dependencies..."
  apt_update_best_effort
  DEBIAN_FRONTEND=noninteractive apt install -y \
    jq openssl iproute2 iputils-ping coreutils grep util-linux \
    curl wget tar socat cron ufw ca-certificates python3 \
    >/dev/null 2>&1 || die "Failed to install dependencies."
}

install_singbox_core(){
  _green "Installing sing-box core..."
  mkdir -p "${SBG_DIR}"

  local ver name url
  ver="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' 2>/dev/null | sed 's/^v//')"
  [[ -z "$ver" || "$ver" == "null" ]] && die "Cannot fetch sing-box latest version from GitHub API."

  name="sing-box-${ver}-linux-${cpu}"
  url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/${name}.tar.gz"

  curl -fL -o "${SBG_DIR}/sing-box.tar.gz" -# --retry 2 "$url" || die "Download sing-box failed."
  tar xzf "${SBG_DIR}/sing-box.tar.gz" -C "${SBG_DIR}" >/dev/null 2>&1 || die "Extract sing-box failed."
  [[ -x "${SBG_DIR}/${name}/sing-box" ]] || die "sing-box binary not found after extract."

  mv "${SBG_DIR}/${name}/sing-box" "${SBG_BIN}"
  rm -rf "${SBG_DIR:?}/${name}" "${SBG_DIR}/sing-box.tar.gz"
  chmod +x "${SBG_BIN}"
  chown root:root "${SBG_BIN}"

  "${SBG_BIN}" version || true
}

choose_ports(){
  _green "UDP port selection (recommended for game accel):"
  echo "1) Use 443/udp for Hysteria2 (best compatibility)"
  echo "2) Random high UDP port"
  readp "Choose [1/2] (default 1): " sel
  sel="${sel:-1}"

  if [[ "$sel" == "2" ]]; then
    PORT_HY2="$(rand_port_udp)"
  else
    PORT_HY2="443"
  fi

  # If 443/udp is already occupied, fall back automatically.
  if [[ "$PORT_HY2" == "443" ]] && port_in_use udp 443; then
    local p2
    p2="$(rand_port_udp)"
    _yellow "Port 443/udp is already in use on this server. Switching HY2 to ${p2}/udp."
    PORT_HY2="$p2"
  fi

  _green "Enable TUIC as a second UDP option?"
  echo "1) Yes"
  echo "2) No (default)"
  readp "Choose [1/2] (default 2): " tsel
  tsel="${tsel:-2}"

  if [[ "$tsel" == "1" ]]; then
    ENABLE_TUIC="1"
    if [[ "$PORT_HY2" == "443" ]]; then
      PORT_TUIC="8443"
    else
      PORT_TUIC="$(rand_port_udp)"
    fi

    # If chosen TUIC udp port is occupied, fall back automatically.
    if [[ -n "$PORT_TUIC" ]] && port_in_use udp "$PORT_TUIC"; then
      local p3
      p3="$(rand_port_udp)"
      _yellow "Port ${PORT_TUIC}/udp is already in use on this server. Switching TUIC to ${p3}/udp."
      PORT_TUIC="$p3"
    fi
  else
    ENABLE_TUIC="0"
    PORT_TUIC=""
  fi

  _green "VLESS Reality TCP fallback enabled (recommended)."
  ENABLE_VLESS="1"
  PORT_VLESS="443"

  # If 443/tcp is already occupied (common cause of service start failure), fall back.
  if port_in_use tcp 443; then
    local p4
    p4="8444"
    if port_in_use tcp "$p4"; then
      p4="$(rand_port_tcp)"
    fi
    _yellow "Port 443/tcp is already in use on this server. Switching VLESS Reality to ${p4}/tcp."
    PORT_VLESS="$p4"
  fi

  readp "Reality SNI (default apple.com): " REALITY_SNI
  REALITY_SNI="${REALITY_SNI:-apple.com}"
  readp "Reality handshake server (default apple.com): " REALITY_HS_SERVER
  REALITY_HS_SERVER="${REALITY_HS_SERVER:-apple.com}"
  readp "Reality handshake port (default 443): " REALITY_HS_PORT
  REALITY_HS_PORT="${REALITY_HS_PORT:-443}"

  REALITY_SHORT_ID="$(rand_hex 4)" # 8 hex chars
}

# -------------------- TLS helpers --------------------
get_saved_domain(){
  local d=""
  if [[ -s "${SBG_DOMAIN_LOG}" ]]; then
    d="$(head -n1 "${SBG_DOMAIN_LOG}" | tr -d '\r\n ' )"
  fi
  echo "$d"
}

has_tls_files(){
  [[ -s "${SBG_CERT}" && -s "${SBG_KEY}" ]]
}

load_previous_tls_info(){
  # Best effort: if a previous install wrote public.info, reuse those flags.
  if [[ -s "${SBG_PUBLIC_INFO}" ]]; then
    # shellcheck disable=SC1090
    source "${SBG_PUBLIC_INFO}" || true
    # Normalize the key vars
    if [[ -n "${DOMAIN:-}" ]]; then
      domain_name="${DOMAIN}"
    fi
    if [[ -n "${TLS_MODE:-}" ]]; then
      TLS_MODE="${TLS_MODE}"
    fi
    if [[ -n "${TLS_INSECURE_CLIENT:-}" ]]; then
      TLS_INSECURE_CLIENT="${TLS_INSECURE_CLIENT}"
    fi
  fi
}

# -------------------- TLS (self-signed) --------------------
make_selfsigned(){
  mkdir -p "${SBG_DIR}"
  if [[ -s "${SBG_CERT}" && -s "${SBG_KEY}" ]]; then
    _green "Found existing TLS files."
    return 0
  fi
  _green "Generating self-signed TLS cert (valid 10 years)..."
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${SBG_KEY}" \
    -out "${SBG_CERT}" \
    -days 3650 \
    -subj "/CN=${REALITY_SNI}" >/dev/null 2>&1 || die "Self-signed cert generation failed."
  chmod 600 "${SBG_KEY}"
  chmod 644 "${SBG_CERT}"
  return 0
}

# -------------------- ACME (optional) --------------------
acme_install_existing(){
  local d="$1"
  /root/.acme.sh/acme.sh --installcert -d "$d" \
    --fullchainpath "${SBG_CERT}" \
    --keypath "${SBG_KEY}" \
    --ecc >/dev/null 2>&1 && return 0
  /root/.acme.sh/acme.sh --installcert -d "$d" \
    --fullchainpath "${SBG_CERT}" \
    --keypath "${SBG_KEY}" \
    >/dev/null 2>&1 && return 0
  return 1
}

apply_acme(){
  v4v6
  _red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  _green "ACME certificate (Let's Encrypt)"
  _green "Your domain must resolve to this server IP:"
  echo -e "IPv4: ${v4:-<none>}"
  echo -e "IPv6: ${v6:-<none>}"

  local saved
  saved="$(get_saved_domain)"
  readp "Enter your domain (e.g. example.com) (default ${saved:-none}): " domain_name
  domain_name="${domain_name:-$saved}"

  domain_name="$(echo "$domain_name" | tr -d ' \r\n')"
  [[ -z "$domain_name" ]] && die "Domain cannot be empty."

  mkdir -p "${SBG_DIR}"

  _green "Installing/Upgrading acme.sh..."
  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    curl -fsSL https://get.acme.sh | sh || die "Install acme.sh failed."
  fi

  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  /root/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1 || true

  if acme_install_existing "$domain_name"; then
    _green "Existing cert found in acme.sh, installed to ${SBG_DIR}."
  else
    if ss -tulnp 2>/dev/null | awk '{print $5}' | grep -qE '(:|])80$'; then
      die "Port 80 is in use. Stop your web server or ensure cert already exists in acme.sh."
    fi

    ufw allow 80/tcp >/dev/null 2>&1 || true
    /root/.acme.sh/acme.sh --register-account -m "admin@${domain_name}" --server letsencrypt >/dev/null 2>&1 || true

    _green "Issuing cert (standalone, ec-256)..."
    /root/.acme.sh/acme.sh --issue -d "$domain_name" --standalone -k ec-256 --server letsencrypt
    local rc=$?
    if [[ $rc -ne 0 ]]; then
      if ! acme_install_existing "$domain_name"; then
        die "ACME issue failed. Check DNS A/AAAA, port 80 reachable, firewall/security-group."
      else
        _yellow "acme.sh issue returned non-zero, but cert exists; continuing."
      fi
    else
      acme_install_existing "$domain_name" || die "installcert failed after issue."
    fi

    ufw delete allow 80/tcp >/dev/null 2>&1 || true
  fi

  [[ -s "${SBG_CERT}" && -s "${SBG_KEY}" ]] || die "Cert/key missing under ${SBG_DIR}."
  /root/.acme.sh/acme.sh --install-cronjob >/dev/null 2>&1 || true

  echo "${domain_name}" > "${SBG_DOMAIN_LOG}"
  chmod 600 "${SBG_DOMAIN_LOG}"
  _green "Domain saved: ${domain_name}"
}

choose_tls_mode(){
  load_previous_tls_info

  local prev_domain
  prev_domain="$(get_saved_domain)"

  _green "TLS mode:"

  if has_tls_files; then
    local domain_hint=""
    [[ -n "${prev_domain}" ]] && domain_hint=" (saved domain: ${prev_domain})"
    echo "0) Use existing certificate/key under ${SBG_DIR}${domain_hint}"
  fi

  echo "1) Self-signed (game-only, no domain required)  [recommended for quick start]"
  echo "2) ACME / Let's Encrypt (needs domain + port 80 reachable)"
  readp "Choose [0/1/2] (default 1): " t
  t="${t:-1}"

  if [[ "$t" == "0" ]]; then
    # Reuse existing cert/key files.
    has_tls_files || die "No existing TLS files found under ${SBG_DIR}."

    # If we have previous public.info, keep its flags; otherwise assume ACME-like (trusted).
    if [[ -z "${TLS_MODE:-}" ]]; then
      TLS_MODE="acme"
    fi
    if [[ -z "${TLS_INSECURE_CLIENT:-}" ]]; then
      TLS_INSECURE_CLIENT="0"
    fi

    if [[ -n "$prev_domain" ]]; then
      domain_name="$prev_domain"
    elif [[ -z "${domain_name}" ]]; then
      domain_name="${REALITY_SNI}"
    fi

    chmod 644 "${SBG_CERT}" 2>/dev/null || true
    chmod 600 "${SBG_KEY}" 2>/dev/null || true

    _green "Reusing existing TLS files: ${SBG_CERT} + ${SBG_KEY}"
    echo "${domain_name}" > "${SBG_DOMAIN_LOG}"
    chmod 600 "${SBG_DOMAIN_LOG}" || true
    return 0
  fi

  if [[ "$t" == "2" ]]; then
    TLS_MODE="acme"
    TLS_INSECURE_CLIENT="0"
    apply_acme
    [[ -s "${SBG_DOMAIN_LOG}" ]] && domain_name="$(head -n1 "${SBG_DOMAIN_LOG}" | tr -d '\r\n ')"
    [[ -z "${domain_name}" ]] && domain_name="${REALITY_SNI}"
  else
    TLS_MODE="selfsigned"
    TLS_INSECURE_CLIENT="1"
    domain_name="${REALITY_SNI}"
    make_selfsigned
    echo "${domain_name}" > "${SBG_DOMAIN_LOG}"
    chmod 600 "${SBG_DOMAIN_LOG}"
  fi
}

setup_firewall_gameonly(){
  _green "Configuring UFW (game-only strict: SSH + proxy ports)..."

  local ssh_port
  ssh_port="22"
  if command -v sshd >/dev/null 2>&1; then
    local p
    p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
    [[ -n "$p" ]] && ssh_port="$p"
  fi

  # Do not reset rules; only enforce sane defaults if inactive.
  local ufw_active
  ufw_active="0"
  if ufw status 2>/dev/null | head -n1 | grep -qi "active"; then
    ufw_active="1"
  fi

  if [[ "$ufw_active" == "0" ]]; then
    ufw default deny incoming >/dev/null 2>&1 || true
    ufw default allow outgoing >/dev/null 2>&1 || true
  fi

  ufw allow "${ssh_port}"/tcp comment "SSH" >/dev/null 2>&1 || true

  # HY2 UDP
  ufw allow "${PORT_HY2}"/udp comment "HY2" >/dev/null 2>&1 || true

  # TUIC UDP
  if [[ "${ENABLE_TUIC}" == "1" && -n "${PORT_TUIC}" ]]; then
    ufw allow "${PORT_TUIC}"/udp comment "TUIC" >/dev/null 2>&1 || true
  fi

  # VLESS Reality TCP
  ufw allow "${PORT_VLESS}"/tcp comment "VLESS-REALITY" >/dev/null 2>&1 || true

  if [[ "$ufw_active" == "0" ]]; then
    echo "y" | ufw enable >/dev/null 2>&1 || true
  else
    ufw reload >/dev/null 2>&1 || true
  fi

  local tuic_suffix=""
  if [[ "${ENABLE_TUIC}" == "1" && -n "${PORT_TUIC}" ]]; then tuic_suffix=", TUIC(${PORT_TUIC}/udp)"; fi
  _green "UFW ready. Allowed: SSH(${ssh_port}/tcp), HY2(${PORT_HY2}/udp), VLESS(${PORT_VLESS}/tcp)${tuic_suffix}"
}

gen_ids_and_keys(){
  mkdir -p "${SBG_DIR}"

  HY2_PASS="$(rand_str)"
  HY2_OBFS="$(rand_str)"

  TUIC_UUID=""
  TUIC_PASS=""
  if [[ "${ENABLE_TUIC}" == "1" ]]; then
    TUIC_UUID="$(${SBG_BIN} generate uuid 2>/dev/null || true)"
    [[ -z "${TUIC_UUID}" ]] && TUIC_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "")"
    [[ -z "${TUIC_UUID}" ]] && TUIC_UUID="$(rand_str)"
    TUIC_PASS="$(rand_str)"
  fi

  VLESS_UUID="$(${SBG_BIN} generate uuid 2>/dev/null || true)"
  [[ -z "${VLESS_UUID}" ]] && VLESS_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "")"
  [[ -z "${VLESS_UUID}" ]] && VLESS_UUID="$(rand_str)"

  # Reality keypair
  local out
  out="$(${SBG_BIN} generate reality-keypair 2>/dev/null || true)"
  REALITY_PRIV="$(echo "$out" | awk -F': ' '/PrivateKey/{print $2}' | tr -d '\r' | tr -d ' ')"
  REALITY_PUB="$(echo "$out" | awk -F': ' '/PublicKey/{print $2}' | tr -d '\r' | tr -d ' ')"
  [[ -z "${REALITY_PRIV}" || -z "${REALITY_PUB}" ]] && die "Failed to generate Reality keypair. Output: ${out}"

  [[ -z "${REALITY_SHORT_ID}" ]] && REALITY_SHORT_ID="$(rand_hex 4)"
}

gen_server_config(){
  mkdir -p "${SBG_DIR}"
  [[ -s "${SBG_DOMAIN_LOG}" ]] && domain_name="$(head -n1 "${SBG_DOMAIN_LOG}" | tr -d '\r\n ')"
  [[ -z "${domain_name}" ]] && domain_name="${REALITY_SNI}"

  v4v6
  local ipv
  if [[ -n "${v4}" ]]; then
    ipv="prefer_ipv4"
  else
    ipv="prefer_ipv6"
  fi

  # Persist public info (client needs)
  cat > "${SBG_PUBLIC_INFO}" <<EOF
# ===== SBG public info (client needs) =====
TLS_MODE=${TLS_MODE}
TLS_INSECURE_CLIENT=${TLS_INSECURE_CLIENT}
DOMAIN=${domain_name}
IPV4=${v4}
IPV6=${v6}

# --- HY2 ---
PORT_HY2=${PORT_HY2}
HY2_PASSWORD=${HY2_PASS}
HY2_OBFS_TYPE=salamander
HY2_OBFS_PASSWORD=${HY2_OBFS}

# --- TUIC ---
ENABLE_TUIC=${ENABLE_TUIC}
PORT_TUIC=${PORT_TUIC}
TUIC_UUID=${TUIC_UUID}
TUIC_PASSWORD=${TUIC_PASS}

# --- VLESS Reality ---
PORT_VLESS=${PORT_VLESS}
VLESS_UUID=${VLESS_UUID}
REALITY_SNI=${REALITY_SNI}
REALITY_HANDSHAKE_SERVER=${REALITY_HS_SERVER}
REALITY_HANDSHAKE_PORT=${REALITY_HS_PORT}
REALITY_SHORT_ID=${REALITY_SHORT_ID}
REALITY_PUBLIC_KEY=${REALITY_PUB}
EOF
  chmod 600 "${SBG_PUBLIC_INFO}"

  # Build server config with python (clean, no side effects)
  DOMAIN_NAME="${domain_name}" \
  PORT_HY2="${PORT_HY2}" \
  HY2_PASS="${HY2_PASS}" \
  HY2_OBFS="${HY2_OBFS}" \
  ENABLE_TUIC="${ENABLE_TUIC}" \
  PORT_TUIC="${PORT_TUIC:-0}" \
  TUIC_UUID="${TUIC_UUID}" \
  TUIC_PASS="${TUIC_PASS}" \
  PORT_VLESS="${PORT_VLESS}" \
  VLESS_UUID="${VLESS_UUID}" \
  REALITY_SNI="${REALITY_SNI}" \
  REALITY_HS_SERVER="${REALITY_HS_SERVER}" \
  REALITY_HS_PORT="${REALITY_HS_PORT}" \
  REALITY_SHORT_ID="${REALITY_SHORT_ID}" \
  REALITY_PRIV="${REALITY_PRIV}" \
  SBG_CERT="${SBG_CERT}" \
  SBG_KEY="${SBG_KEY}" \
  IPV_STRATEGY="${ipv}" \
  python3 - <<'PY'
import json, os

domain = os.environ.get("DOMAIN_NAME", "")
port_hy2 = int(os.environ.get("PORT_HY2", "443"))
hy2_pass = os.environ.get("HY2_PASS", "")
hy2_obfs = os.environ.get("HY2_OBFS", "")

enable_tuic = os.environ.get("ENABLE_TUIC", "0") == "1"
port_tuic = int(os.environ.get("PORT_TUIC", "0") or 0)
tuic_uuid = os.environ.get("TUIC_UUID", "")
tuic_pass = os.environ.get("TUIC_PASS", "")

port_vless = int(os.environ.get("PORT_VLESS", "443"))
vless_uuid = os.environ.get("VLESS_UUID", "")

reality_sni = os.environ.get("REALITY_SNI", "apple.com")
reality_hs_server = os.environ.get("REALITY_HS_SERVER", "apple.com")
reality_hs_port = int(os.environ.get("REALITY_HS_PORT", "443"))
reality_short_id = os.environ.get("REALITY_SHORT_ID", "")
reality_priv = os.environ.get("REALITY_PRIV", "")

cert = os.environ.get("SBG_CERT", "/etc/sbg/cert.crt")
key  = os.environ.get("SBG_KEY", "/etc/sbg/private.key")
ipv  = os.environ.get("IPV_STRATEGY", "prefer_ipv4")

conf = {
  "log": {"disabled": False, "level": "info", "timestamp": True},
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": port_hy2,
      "users": [{"password": hy2_pass}],
      "obfs": {"type": "salamander", "password": hy2_obfs},
      "tls": {
        "enabled": True,
        "alpn": ["h3"],
        "certificate_path": cert,
        "key_path": key
      },
      "masquerade": {
        "type": "proxy",
        "url": "https://www.cloudflare.com/",
        "rewrite_host": True
      }
    }
  ],
  "outbounds": [
    {"type": "direct", "tag": "direct", "domain_strategy": ipv},
    {"type": "block", "tag": "block"}
  ]
}

if enable_tuic:
  conf["inbounds"].append({
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
      "key_path": key
    }
  })

# VLESS Reality TCP fallback
conf["inbounds"].append({
  "type": "vless",
  "tag": "vless-reality-in",
  "listen": "::",
  "listen_port": port_vless,
  "users": [{"name": "game", "uuid": vless_uuid, "flow": "xtls-rprx-vision"}],
  "tls": {
    "enabled": True,
    "server_name": reality_sni,
    "reality": {
      "enabled": True,
      "handshake": {"server": reality_hs_server, "server_port": reality_hs_port},
      "private_key": reality_priv,
      "short_id": [reality_short_id]
    }
  }
})

path = "/etc/sbg/sbg.json"
with open(path, "w", encoding="utf-8") as f:
  json.dump(conf, f, indent=2)
PY

  chmod 600 "${SBG_CONF}"
  _green "Server config generated: ${SBG_CONF}"
}

write_service(){
  cat > /etc/systemd/system/sbg.service <<EOF
[Unit]
Description=sbg (sing-box game node)
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=${SBG_BIN} run -c ${SBG_CONF}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sbg >/dev/null 2>&1 || true
}

restart_sbg(){
  systemctl restart sbg 2>/dev/null || return 1
  sleep 1
  if systemctl is-active --quiet sbg; then
    _green "sbg is ACTIVE ✅"
    return 0
  fi
  _red "sbg is NOT active ❌"
  _yellow "Quick diagnostics:"
  if [[ -x "${SBG_BIN}" ]]; then
    "${SBG_BIN}" check -c "${SBG_CONF}" >/dev/null 2>&1 || _yellow "sing-box config check reported issues (see logs below)."
  fi
  echo "---- systemctl status sbg (last 80 lines) ----"
  systemctl status sbg -l --no-pager 2>/dev/null | tail -n 80 || true
  echo "---- journalctl -u sbg (last 120 lines) ----"
  journalctl -u sbg -n 120 --no-pager 2>/dev/null || true
  echo "---- ports in use (443/8443/8444/random) ----"
  ss -tulnp 2>/dev/null | egrep ':(443|8443|8444)\b' || true
  ss -tulnp 2>/dev/null | tail -n 30 || true
  return 1
}

view_logs(){
  journalctl -u sbg -n 200 --no-pager 2>/dev/null || _red "No journalctl output."
}

fix_config_schema(){
  [[ -s "${SBG_CONF}" ]] || die "Missing ${SBG_CONF}"
  _green "Fixing known sing-box config schema issues (safe in-place patch)..."

  # Stop service first to avoid race while rewriting config.
  systemctl stop sbg >/dev/null 2>&1 || true

  python3 - <<'PY'
import json
p = '/etc/sbg/sbg.json'
with open(p,'r',encoding='utf-8') as f:
  conf = json.load(f)
changed = False

# Fix hysteria2 masquerade schema: old style used masquerade.proxy.{url,rewrite_host}
for ib in conf.get('inbounds', []) or []:
  if ib.get('type') == 'hysteria2':
    m = ib.get('masquerade')
    if isinstance(m, dict) and 'proxy' in m and isinstance(m.get('proxy'), dict):
      proxy = m.get('proxy')
      # Only rewrite when the new fields are missing.
      if 'url' not in m and 'rewrite_host' not in m:
        m['url'] = proxy.get('url', 'https://www.cloudflare.com/')
        m['rewrite_host'] = bool(proxy.get('rewrite_host', True))
        changed = True
      # Always remove nested proxy if present.
      if 'proxy' in m:
        m.pop('proxy', None)
        changed = True

# Fix TUIC inbound schema: some versions do not accept udp_relay_mode on inbound.
for ib in conf.get('inbounds', []) or []:
  if ib.get('type') == 'tuic':
    if 'udp_relay_mode' in ib:
      ib.pop('udp_relay_mode', None)
      changed = True

if changed:
  with open(p,'w',encoding='utf-8') as f:
    json.dump(conf, f, indent=2)
  print('patched')
else:
  print('no_change')
PY

  if [[ -x "${SBG_BIN}" ]]; then
    "${SBG_BIN}" check -c "${SBG_CONF}" || die "Config check still failing after patch. Please view logs."
  fi

  restart_sbg || die "Restart still failed after patch. Please view logs."
}

update_core(){
  systemctl stop sbg >/dev/null 2>&1 || true
  install_singbox_core
  restart_sbg || true
}

lnsbg(){
  rm -f /usr/bin/sbg
  curl -fL -o /usr/bin/sbg -# --retry 2 "${UPDATE_URL}" || die "Download update script failed."
  chmod +x /usr/bin/sbg
  _green "Updated /usr/bin/sbg"
}

show_sub(){
  [[ -s "${SBG_PUBLIC_INFO}" ]] || die "Missing ${SBG_PUBLIC_INFO}"

  # shellcheck disable=SC1090
  source "${SBG_PUBLIC_INFO}"

  v4v6
  local host
  host="${v4:-${DOMAIN}}"

  mkdir -p "${SBG_DIR}"

  local hy2_link tuic_link vless_link
  hy2_link="hysteria2://${HY2_PASSWORD}@${host}:${PORT_HY2}?security=tls&alpn=h3&sni=${DOMAIN}&insecure=${TLS_INSECURE_CLIENT}&obfs=salamander&obfs-password=${HY2_OBFS_PASSWORD}#HY2-${hostname}"

  vless_link="vless://${VLESS_UUID}@${host}:${PORT_VLESS}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&flow=xtls-rprx-vision#VLESS-REALITY-${hostname}"

  echo "${hy2_link}" > "${SBG_SUB_TXT}"
  if [[ "${ENABLE_TUIC}" == "1" && -n "${PORT_TUIC}" && "${PORT_TUIC}" != "0" ]]; then
    tuic_link="tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${host}:${PORT_TUIC}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${DOMAIN}&allow_insecure=${TLS_INSECURE_CLIENT}#TUIC-${hostname}"
    echo "${tuic_link}" >> "${SBG_SUB_TXT}"
  fi
  echo "${vless_link}" >> "${SBG_SUB_TXT}"

  local sub_b64
  sub_b64="$(base64 -w 0 < "${SBG_SUB_TXT}")"

  echo
  _green "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo -e "TLS_MODE: ${TLS_MODE}  (insecure=${TLS_INSECURE_CLIENT})"
  echo -e "SNI/DOMAIN: ${DOMAIN}"
  echo -e "HY2 UDP: ${PORT_HY2}"
  if [[ "${ENABLE_TUIC}" == "1" ]]; then
    echo -e "TUIC UDP: ${PORT_TUIC}"
  fi
  echo -e "VLESS Reality TCP: ${PORT_VLESS} (sni=${REALITY_SNI}, sid=${REALITY_SHORT_ID})"
  echo
  _red "Base64 subscription:"
  echo -e "${sub_b64}"
  _green "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
}

show_client_config(){
  [[ -s "${SBG_PUBLIC_INFO}" ]] || die "Missing ${SBG_PUBLIC_INFO}"
  # shellcheck disable=SC1090
  source "${SBG_PUBLIC_INFO}"

  v4v6
  local host
  host="${v4:-${DOMAIN}}"

  _green "Sing-box client config (TUN). Save as client.json and run as root on your client."
  echo
  cat <<EOF
{
  "log": { "disabled": false, "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": [ "172.19.0.1/30", "fd00::1/126" ],
      "auto_route": true,
      "strict_route": true,
      "sniff": true,
      "sniff_override_destination": true,
      "domain_strategy": "prefer_ipv4"
    }
  ],
  "outbounds": [
    {
      "tag": "select",
      "type": "selector",
      "default": "hy2",
      "outbounds": [
        "hy2",
        "vless_reality",
        "tuic",
        "direct"
      ]
    },
    {
      "tag": "hy2",
      "type": "hysteria2",
      "server": "${host}",
      "server_port": ${PORT_HY2},
      "password": "${HY2_PASSWORD}",
      "obfs": { "type": "salamander", "password": "${HY2_OBFS_PASSWORD}" },
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "insecure": ${TLS_INSECURE_CLIENT},
        "alpn": [ "h3" ]
      }
    },
    {
      "tag": "vless_reality",
      "type": "vless",
      "server": "${host}",
      "server_port": ${PORT_VLESS},
      "uuid": "${VLESS_UUID}",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SNI}",
        "reality": {
          "enabled": true,
          "public_key": "${REALITY_PUBLIC_KEY}",
          "short_id": "${REALITY_SHORT_ID}"
        }
      }
    },
    {
      "tag": "tuic",
      "type": "tuic",
      "server": "${host}",
      "server_port": ${PORT_TUIC:-0},
      "uuid": "${TUIC_UUID}",
      "password": "${TUIC_PASSWORD}",
      "congestion_control": "bbr",
      "udp_relay_mode": "native",
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "insecure": ${TLS_INSECURE_CLIENT},
        "alpn": [ "h3" ]
      }
    },
    { "tag": "direct", "type": "direct" },
    { "tag": "block", "type": "block" }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "select",
    "rules": [
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_is_private": true, "outbound": "direct" }
    ]
  }
}
EOF
  echo
}

uninstall_all(){
  systemctl stop sbg >/dev/null 2>&1 || true
  systemctl disable sbg >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/sbg.service
  systemctl daemon-reload >/dev/null 2>&1 || true

  rm -rf "${SBG_DIR}"
  rm -f /usr/bin/sbg

  _green "Uninstalled sbg."
}

install_gameonly(){
  if [[ -f /etc/systemd/system/sbg.service ]]; then
    die "sbg already installed. Uninstall first."
  fi

  install_deps
  enable_bbr
  detect_arch
  install_singbox_core
  choose_ports
  choose_tls_mode

  gen_ids_and_keys
  setup_firewall_gameonly
  gen_server_config || die "Failed to generate config."
  write_service

  if ! restart_sbg; then
    _red "Service failed to start. Check:"
    echo "  systemctl status sbg -l --no-pager"
    echo "  journalctl -u sbg -n 200 --no-pager"
    return 1
  fi

  (crontab -l 2>/dev/null; echo "0 4 * * * systemctl restart sbg >/dev/null 2>&1") | crontab -

  _green "Install done."
  show_sub
}

menu(){
  clear
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  print_version
  echo "Shortcut command: sbg"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  _green " 1. Install (game-only quick start: self-signed OR ACME)"
  _green " 2. Uninstall"
  _green " 3. Show subscription (Base64)"
  _green " 4. Update script"
  _green " 5. View logs"
  _green " 6. Restart service"
  _green " 7. Update sing-box core"
  _green " 8. Show client config (TUN)"
  _green " 9. Fix config schema (quick patch)"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  readp "Select: " Input

  case "$Input" in
    1) install_gameonly ;;
    2) uninstall_all ;;
    3) show_sub ;;
    4) lnsbg ;;
    5) view_logs ;;
    6) restart_sbg || { _red "Restart failed."; } ;;
    7) update_core ;;
    8) show_client_config ;;
    9) fix_config_schema ;;
    *) exit 0 ;;
  esac
}

# -------------------------
# main
# -------------------------
need_root
only_ubuntu
menu