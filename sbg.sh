#!/bin/bash
export LANG=en_US.UTF-8

SBG_VERSION="v0.1.1-game-accel"

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
  echo "sbg — Sing-box Game Accelerator (Hysteria2/TUIC)  |  ${SBG_VERSION}"
}

v4v6(){
  v4="$(curl -s4m5 -k icanhazip.com 2>/dev/null | tr -d ' \r\n' || true)"
  v6="$(curl -s6m5 -k icanhazip.com 2>/dev/null | tr -d ' \r\n' || true)"
}

rand_port(){
  # random high port not currently in use
  while true; do
    local p
    p="$(shuf -i 10000-65535 -n 1)"
    if ! ss -tunlp 2>/dev/null | awk '{print $5}' | sed 's/.*://g' | grep -qx "$p"; then
      echo "$p"
      return
    fi
  done
}

rand_str(){
  # safe random string for passwords
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

enable_bbr(){
  if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    _green "Enabling BBR..."
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-sbg-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl --system >/dev/null 2>&1 || true
  fi
}

apt_update_best_effort(){
  # Mirror sync happens; don't hard-fail.
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
  DEBIAN_FRONTEND=noninteractive apt install -y jq openssl iproute2 iputils-ping coreutils grep util-linux curl wget tar socat cron ufw ca-certificates python3 >/dev/null 2>&1 || \
    die "Failed to install dependencies."
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
    PORT_HY2="$(rand_port)"
  else
    PORT_HY2="443"
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
      PORT_TUIC="$(rand_port)"
    fi
  else
    ENABLE_TUIC="0"
    PORT_TUIC=""
  fi
}

acme_install_existing(){
  local d="$1"
  # ECC
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

apply_acme(){
  v4v6
  _red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  _green "ACME certificate required (Let's Encrypt)."
  _green "Your domain must resolve to this server IP:"
  echo -e "IPv4: ${v4:-<none>}"
  echo -e "IPv6: ${v6:-<none>}"
  readp "Enter your domain (e.g. example.com): " domain_name
  domain_name="$(echo "$domain_name" | tr -d ' \r\n')"
  [[ -z "$domain_name" ]] && die "Domain cannot be empty."

  mkdir -p "${SBG_DIR}"

  _green "Installing/Upgrading acme.sh..."
  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    curl -fsSL https://get.acme.sh | sh || die "Install acme.sh failed."
  fi

  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  /root/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1 || true

  # Try install existing first (no need 80)
  if acme_install_existing "$domain_name"; then
    _green "Existing cert found in acme.sh, installed to ${SBG_DIR}."
  else
    # Need standalone on 80
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

    # Optional: close 80 after issuance (keep strict)
    ufw delete allow 80/tcp >/dev/null 2>&1 || true
  fi

  [[ -s "${SBG_CERT}" && -s "${SBG_KEY}" ]] || die "Cert/key missing under ${SBG_DIR}."

  /root/.acme.sh/acme.sh --install-cronjob >/dev/null 2>&1 || true

  echo "${domain_name}" > "${SBG_DOMAIN_LOG}"
  chmod 600 "${SBG_DOMAIN_LOG}"
  _green "Domain saved: ${domain_name}"
}

ensure_domain_and_cert(){
  if [[ -s "${SBG_CERT}" && -s "${SBG_KEY}" && -s "${SBG_DOMAIN_LOG}" ]]; then
    domain_name="$(head -n1 "${SBG_DOMAIN_LOG}" | tr -d '\r\n ')"
    _green "Found existing cert and domain: ${domain_name}. Skipping ACME."
  else
    apply_acme
  fi
}

setup_firewall(){
  _green "Configuring UFW (strict game-accelerator ports only)..."

  local ssh_port
  ssh_port="22"
  if command -v sshd >/dev/null 2>&1; then
    local p
    p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
    [[ -n "$p" ]] && ssh_port="$p"
  fi

  echo "y" | ufw reset >/dev/null 2>&1 || true
  ufw default deny incoming >/dev/null 2>&1 || true
  ufw default allow outgoing >/dev/null 2>&1 || true

  ufw allow "${ssh_port}"/tcp comment "SSH" >/dev/null 2>&1 || true
  ufw allow "${PORT_HY2}"/udp comment "HY2" >/dev/null 2>&1 || true

  if [[ "${ENABLE_TUIC}" == "1" && -n "${PORT_TUIC}" ]]; then
    ufw allow "${PORT_TUIC}"/udp comment "TUIC" >/dev/null 2>&1 || true
  fi

  echo "y" | ufw enable >/dev/null 2>&1 || true

  if [[ "${ENABLE_TUIC}" == "1" ]]; then
    _green "UFW enabled. Allowed: SSH(${ssh_port}/tcp), HY2(${PORT_HY2}/udp), TUIC(${PORT_TUIC}/udp)."
  else
    _green "UFW enabled. Allowed: SSH(${ssh_port}/tcp), HY2(${PORT_HY2}/udp)."
  fi
}

gen_server_config(){
  mkdir -p "${SBG_DIR}"

  local hy2_pass tuic_uuid tuic_pass
  hy2_pass="$(rand_str)"
  tuic_uuid="$(${SBG_BIN} generate uuid 2>/dev/null || true)"
  [[ -z "$tuic_uuid" ]] && tuic_uuid="$(rand_str)"
  tuic_pass="$(rand_str)"

  v4v6
  local ipv
  if [[ -n "${v4}" ]]; then
    ipv="prefer_ipv4"
  else
    ipv="prefer_ipv6"
  fi

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

  DOMAIN_NAME="${domain_name}" \
  PORT_HY2="${PORT_HY2}" \
  HY2_PASS="${hy2_pass}" \
  ENABLE_TUIC="${ENABLE_TUIC}" \
  PORT_TUIC="${PORT_TUIC:-0}" \
  TUIC_UUID="${tuic_uuid}" \
  TUIC_PASS="${tuic_pass}" \
  SBG_CERT="${SBG_CERT}" \
  SBG_KEY="${SBG_KEY}" \
  IPV_STRATEGY="${ipv}" \
  python3 - <<'PY'
import json, os

domain = os.environ.get("DOMAIN_NAME","")
port_hy2 = int(os.environ.get("PORT_HY2","0") or 0)
hy2_pass = os.environ.get("HY2_PASS","")
enable_tuic = os.environ.get("ENABLE_TUIC","0") == "1"
port_tuic = int(os.environ.get("PORT_TUIC","0") or 0)
tuic_uuid = os.environ.get("TUIC_UUID","")
tuic_pass = os.environ.get("TUIC_PASS","")
cert = os.environ.get("SBG_CERT","/etc/sbg/cert.crt")
key  = os.environ.get("SBG_KEY","/etc/sbg/private.key")
ipv  = os.environ.get("IPV_STRATEGY","prefer_ipv4")

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
        "key_path": key
      },
      "masquerade": {
        "type": "proxy",
        "proxy": {
          "url": "https://www.cloudflare.com/",
          "rewrite_host": True
        }
      }
    }
  ],
  "outbounds": [
    {"type":"direct","tag":"direct","domain_strategy": ipv},
    {"type":"block","tag":"block"}
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

path="/etc/sbg/sbg.json"
with open(path,"w",encoding="utf-8") as f:
  json.dump(conf,f,indent=2)
PY

  chmod 600 "${SBG_CONF}"
  _green "Server config generated: ${SBG_CONF}"
}

regen_server_config_from_public_info(){
  if [[ ! -s "${SBG_PUBLIC_INFO}" || ! -s "${SBG_DOMAIN_LOG}" ]]; then
    _red "Missing ${SBG_PUBLIC_INFO} or ${SBG_DOMAIN_LOG}. Cannot regenerate config."
    return 1
  fi

  # shellcheck disable=SC1090
  source "${SBG_PUBLIC_INFO}"
  domain_name="$(head -n1 "${SBG_DOMAIN_LOG}" | tr -d '\r\n ')"

  v4v6
  local ipv
  if [[ -n "${v4}" ]]; then
    ipv="prefer_ipv4"
  else
    ipv="prefer_ipv6"
  fi

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

port_hy2 = int(os.environ.get("PORT_HY2","0") or 0)
hy2_pass = os.environ.get("HY2_PASS","")
enable_tuic = os.environ.get("ENABLE_TUIC","0") == "1"
port_tuic = int(os.environ.get("PORT_TUIC","0") or 0)
tuic_uuid = os.environ.get("TUIC_UUID","")
tuic_pass = os.environ.get("TUIC_PASS","")
cert = os.environ.get("SBG_CERT","/etc/sbg/cert.crt")
key  = os.environ.get("SBG_KEY","/etc/sbg/private.key")
ipv  = os.environ.get("IPV_STRATEGY","prefer_ipv4")

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
        "key_path": key
      },
      "masquerade": {
        "type": "proxy",
        "proxy": {
          "url": "https://www.cloudflare.com/",
          "rewrite_host": True
        }
      }
    }
  ],
  "outbounds": [
    {"type":"direct","tag":"direct","domain_strategy": ipv},
    {"type":"block","tag":"block"}
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

path="/etc/sbg/sbg.json"
with open(path,"w",encoding="utf-8") as f:
  json.dump(conf,f,indent=2)
PY

  chmod 600 "${SBG_CONF}"
  _green "Regenerated server config: ${SBG_CONF}"
  return 0
}

write_service(){
  cat > /etc/systemd/system/sbg.service <<EOF
[Unit]
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
  return 1
}

view_logs(){
  journalctl -u sbg -n 200 --no-pager 2>/dev/null || _red "No journalctl output."
}

update_core(){
  systemctl stop sbg >/dev/null 2>&1 || true
  install_singbox_core
  restart_sbg || true
}

lnsbg(){
  rm -f /usr/bin/sbg
  curl -fL -o /usr/bin/sbg -# --retry 2 --insecure "${UPDATE_URL}" || die "Download update script failed."
  chmod +x /usr/bin/sbg
  _green "Updated /usr/bin/sbg"
}

show_sub(){
  [[ -s "${SBG_PUBLIC_INFO}" ]] || die "Missing ${SBG_PUBLIC_INFO}"
  [[ -s "${SBG_DOMAIN_LOG}" ]] || die "Missing ${SBG_DOMAIN_LOG}"

  # shellcheck disable=SC1090
  source "${SBG_PUBLIC_INFO}"

  v4v6
  local host
  host="${v4:-${DOMAIN}}"

  mkdir -p "${SBG_DIR}"

  # Hy2 link: hysteria2://<password>@<host>:<port>?security=tls&alpn=h3&sni=<domain>#HY2-<hostname>
  local hy2_link tuic_link
  hy2_link="hysteria2://${HY2_PASSWORD}@${host}:${PORT_HY2}?security=tls&alpn=h3&insecure=0&sni=${DOMAIN}#HY2-${hostname}"

  echo "${hy2_link}" > "${SBG_SUB_TXT}"

  if [[ "${ENABLE_TUIC}" == "1" && -n "${PORT_TUIC}" ]]; then
    tuic_link="tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${host}:${PORT_TUIC}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${DOMAIN}&allow_insecure=0#TUIC-${hostname}"
    echo "${tuic_link}" >> "${SBG_SUB_TXT}"
  fi

  local sub_b64
  sub_b64="$(base64 -w 0 < "${SBG_SUB_TXT}")"

  echo
  _green "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo -e "Domain: ${DOMAIN}"
  echo -e "HY2 UDP: ${PORT_HY2}"
  if [[ "${ENABLE_TUIC}" == "1" ]]; then
    echo -e "TUIC UDP: ${PORT_TUIC}"
  fi
  echo
  _red "Base64 subscription:"
  echo -e "${sub_b64}"
  _green "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
}

show_client_config(){
  [[ -s "${SBG_PUBLIC_INFO}" ]] || die "Missing ${SBG_PUBLIC_INFO}"
  [[ -s "${SBG_DOMAIN_LOG}" ]] || die "Missing ${SBG_DOMAIN_LOG}"

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
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "insecure": false,
        "alpn": [ "h3" ]
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
        "insecure": false,
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
  _yellow "Note: If you disabled TUIC on server, keep using 'hy2' outbound only."
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

install_all(){
  if [[ -f /etc/systemd/system/sbg.service ]]; then
    die "sbg already installed. Uninstall first."
  fi

  install_deps
  enable_bbr
  detect_arch
  install_singbox_core
  choose_ports
  ensure_domain_and_cert
  setup_firewall
  gen_server_config || die "Failed to generate config."
  write_service

  if ! restart_sbg; then
    _red "Service failed to start. Check:"
    echo "  systemctl status sbg -l --no-pager"
    echo "  journalctl -u sbg -n 200 --no-pager"
    return 1
  fi

  # daily restart as keepalive (optional)
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
  _green " 1. Install (domain + ACME cert required)"
  _green " 2. Uninstall"
  _green " 3. Show subscription (Base64)"
  _green " 4. Update script"
  _green " 5. View logs"
  _green " 6. Restart service"
  _green " 7. Update sing-box core"
  _green " 8. Show game-only client config (TUN)"
  _green " 9. Regenerate server config (fix broken JSON)"
  echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  readp "Select: " Input

  case "$Input" in
    1) install_all ;;
    2) uninstall_all ;;
    3) show_sub ;;
    4) lnsbg ;;
    5) view_logs ;;
    6) restart_sbg || { _red "Restart failed."; } ;;
    7) update_core ;;
    8) show_client_config ;;
    9) regen_server_config_from_public_info && restart_sbg ;;
    *) exit 0 ;;
  esac
}

# -------------------------
# main
# -------------------------
need_root
only_ubuntu
menu