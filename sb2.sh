#!/bin/bash
# Sing-Box 四協議一鍵安裝腳本 v3.0 — Nginx SNI 分流架構
# VLESS-Reality · VMess-WS · Hysteria2 · TUIC V5
# 所有 TCP 協議統一走 443 端口，由 Nginx stream 做 SNI 分流
export LANG=en_US.UTF-8
red='\\033[0;31m'
green='\\033[0;32m'
yellow='\\033[0;33m'
blue='\\033[0;36m'
bblue='\\033[0;34m'
plain='\\033[0m'

UPDATE_URL="${UPDATE_URL:-}"
UPDATE_SHA256="${UPDATE_SHA256:-}"
UPDATE_SHA256_URL="${UPDATE_SHA256_URL:-}"
SB_ALLOW_UNVERIFIED_UPDATE="${SB_ALLOW_UNVERIFIED_UPDATE:-0}"
SB_BATCH_MODE="${SB_BATCH_MODE:-0}"
SB_ENABLE_UFW="${SB_ENABLE_UFW:-0}"
SB_ROTATE_UUID_ON_MIGRATE="${SB_ROTATE_UUID_ON_MIGRATE:-1}"
SB_ROTATE_REALITY_SNI_ON_MIGRATE="${SB_ROTATE_REALITY_SNI_ON_MIGRATE:-1}"
SB_ROTATE_VM_WS_PATH_ON_MIGRATE="${SB_ROTATE_VM_WS_PATH_ON_MIGRATE:-1}"
SB_DNS_PORT53_HIJACK="${SB_DNS_PORT53_HIJACK:-1}"
SB_DNS_REJECT_BYPASS="${SB_DNS_REJECT_BYPASS:-0}"
ACME_SH_VERSION="${ACME_SH_VERSION:-3.1.2}"
SB_ENV_FILE="/etc/s-box/sb.env"
SB_CERT_RENEW_SCRIPT="/etc/s-box/cert_renew.sh"
SB_CERT_RENEW_STATUS="/etc/s-box/cert_renew.status"
SB_CERT_RENEW_LOG="/etc/s-box/cert_renew.log"
SB_CERT_RENEW_CRON_MARK="# sb-cert-renew"
SB_HY2_HOP_SCRIPT="/etc/s-box/hy2_port_hop.sh"
SB_HY2_HOP_SERVICE="sb-hy2-hop.service"
SB_NGINX_BACKUP_DIR="/etc/s-box/nginx-backups"
SB_NGINX_STREAM_CONF="/etc/nginx/stream.d/sb_sni_dispatch.conf"
SB_NGINX_HTTP_CONF="/etc/nginx/conf.d/sb_vmess_proxy.conf"
SB_NGINX_MANIFEST="/etc/s-box/nginx_manifest.tsv"
SB_SUPPORTED_STABLE_FAMILY="${SB_SUPPORTED_STABLE_FAMILY:-1.13}"
SB_LEGACY_CLIENT_VERSION="1.11.4"
SB_LATEST_STABLE_VERSION=""
SB_LATEST_STABLE_PUBLISHED_AT=""
SB_ROLLBACK_ACTIVE="0"
SB_ROLLBACK_SNAPSHOT_DIR=""
SB_ROLLBACK_CONTEXT=""
SB_ROLLBACK_RUNNING="0"
SB_MIGRATE_OLD_VLESS_PORT=""
SB_MIGRATE_OLD_VMESS_PORT=""

red(){ echo -e "\\033[31m\\033[01m$1\\033[0m";}
green(){ echo -e "\\033[32m\\033[01m$1\\033[0m";}
yellow(){ echo -e "\\033[33m\\033[01m$1\\033[0m";}
blue(){ echo -e "\\033[36m\\033[01m$1\\033[0m";}
white(){ echo -e "\\033[37m\\033[01m$1\\033[0m";}
readp(){ read -rp "$(yellow "$1")" "$2";}

ensure_sbox_dir(){
    mkdir -p /etc/s-box
    chmod 700 /etc/s-box 2>/dev/null || true
}

read_kv_from_file(){
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 1
    grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d= -f2-
}

upsert_kv_file(){
    local file="$1" key="$2" value="$3"
    local tmp_file
    touch "$file"
    chmod 600 "$file" 2>/dev/null || true
    tmp_file=$(mktemp /tmp/sb_kv.XXXXXX) || return 1
    awk -v key="$key" -v value="$value" '
        BEGIN { done = 0 }
        index($0, key "=") == 1 {
            if (!done) {
                printf "%s=%s\n", key, value
                done = 1
            }
            next
        }
        { print }
        END {
            if (!done) printf "%s=%s\n", key, value
        }
    ' "$file" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    mv "$tmp_file" "$file"
    chmod 600 "$file" 2>/dev/null || true
}

load_runtime_env(){
    SB_TELEGRAM_ENABLED="$(read_kv_from_file "$SB_ENV_FILE" "SB_TELEGRAM_ENABLED" 2>/dev/null || true)"
    SB_TELEGRAM_BOT_TOKEN="$(read_kv_from_file "$SB_ENV_FILE" "SB_TELEGRAM_BOT_TOKEN" 2>/dev/null || true)"
    SB_TELEGRAM_CHAT_ID="$(read_kv_from_file "$SB_ENV_FILE" "SB_TELEGRAM_CHAT_ID" 2>/dev/null || true)"
    SB_TELEGRAM_THREAD_ID="$(read_kv_from_file "$SB_ENV_FILE" "SB_TELEGRAM_THREAD_ID" 2>/dev/null || true)"
    SB_HY2_OBFS_ENABLED="$(read_kv_from_file "$SB_ENV_FILE" "SB_HY2_OBFS_ENABLED" 2>/dev/null || true)"
    SB_HY2_OBFS_PASSWORD="$(read_kv_from_file "$SB_ENV_FILE" "SB_HY2_OBFS_PASSWORD" 2>/dev/null || true)"
    SB_HY2_MASQUERADE_URL="$(read_kv_from_file "$SB_ENV_FILE" "SB_HY2_MASQUERADE_URL" 2>/dev/null || true)"
    SB_HY2_HOP_ENABLED="$(read_kv_from_file "$SB_ENV_FILE" "SB_HY2_HOP_ENABLED" 2>/dev/null || true)"
    SB_HY2_HOP_START="$(read_kv_from_file "$SB_ENV_FILE" "SB_HY2_HOP_START" 2>/dev/null || true)"
    SB_HY2_HOP_END="$(read_kv_from_file "$SB_ENV_FILE" "SB_HY2_HOP_END" 2>/dev/null || true)"
    SB_HY2_HOP_INTERVAL="$(read_kv_from_file "$SB_ENV_FILE" "SB_HY2_HOP_INTERVAL" 2>/dev/null || true)"
    SB_HY2_HOP_TARGET_PORT="$(read_kv_from_file "$SB_ENV_FILE" "SB_HY2_HOP_TARGET_PORT" 2>/dev/null || true)"
    SB_CLIENT_UTLS_ENABLED="$(read_kv_from_file "$SB_ENV_FILE" "SB_CLIENT_UTLS_ENABLED" 2>/dev/null || true)"
    SB_CLIENT_HOST_MODE="$(read_kv_from_file "$SB_ENV_FILE" "SB_CLIENT_HOST_MODE" 2>/dev/null || true)"
    SB_REALITY_UTLS_FINGERPRINT="$(read_kv_from_file "$SB_ENV_FILE" "SB_REALITY_UTLS_FINGERPRINT" 2>/dev/null || true)"
    SB_VMESS_UTLS_FINGERPRINT="$(read_kv_from_file "$SB_ENV_FILE" "SB_VMESS_UTLS_FINGERPRINT" 2>/dev/null || true)"
    SB_REALITY_SNI="$(read_kv_from_file "$SB_ENV_FILE" "SB_REALITY_SNI" 2>/dev/null || true)"
    SB_REALITY_SNI_CANDIDATES="$(read_kv_from_file "$SB_ENV_FILE" "SB_REALITY_SNI_CANDIDATES" 2>/dev/null || true)"
    SB_VM_WS_PATH="$(read_kv_from_file "$SB_ENV_FILE" "SB_VM_WS_PATH" 2>/dev/null || true)"
    [[ -z "$SB_TELEGRAM_ENABLED" ]] && SB_TELEGRAM_ENABLED="0"
    [[ -z "$SB_HY2_OBFS_ENABLED" ]] && SB_HY2_OBFS_ENABLED="1"
    [[ -z "$SB_HY2_HOP_ENABLED" ]] && SB_HY2_HOP_ENABLED="1"
    [[ -z "$SB_HY2_HOP_INTERVAL" ]] && SB_HY2_HOP_INTERVAL="30s"
    [[ -z "$SB_HY2_MASQUERADE_URL" ]] && SB_HY2_MASQUERADE_URL="https://www.cloudflare.com/"
    [[ -z "$SB_CLIENT_UTLS_ENABLED" ]] && SB_CLIENT_UTLS_ENABLED="0"
    [[ -z "$SB_CLIENT_HOST_MODE" ]] && SB_CLIENT_HOST_MODE="ip_prefer"
    [[ -z "$SB_REALITY_UTLS_FINGERPRINT" ]] && SB_REALITY_UTLS_FINGERPRINT="chrome"
    [[ -z "$SB_VMESS_UTLS_FINGERPRINT" ]] && SB_VMESS_UTLS_FINGERPRINT="chrome"
    [[ -z "$SB_REALITY_SNI" ]] && SB_REALITY_SNI=""
    [[ -z "$SB_REALITY_SNI_CANDIDATES" ]] && SB_REALITY_SNI_CANDIDATES=""
    [[ -z "$SB_VM_WS_PATH" ]] && SB_VM_WS_PATH=""
    export SB_TELEGRAM_ENABLED SB_TELEGRAM_BOT_TOKEN SB_TELEGRAM_CHAT_ID SB_TELEGRAM_THREAD_ID
    export SB_HY2_OBFS_ENABLED SB_HY2_OBFS_PASSWORD SB_HY2_MASQUERADE_URL
    export SB_HY2_HOP_ENABLED SB_HY2_HOP_START SB_HY2_HOP_END SB_HY2_HOP_INTERVAL SB_HY2_HOP_TARGET_PORT SB_CLIENT_UTLS_ENABLED SB_CLIENT_HOST_MODE
    export SB_REALITY_UTLS_FINGERPRINT SB_VMESS_UTLS_FINGERPRINT
    export SB_REALITY_SNI SB_REALITY_SNI_CANDIDATES SB_VM_WS_PATH
}

probe_latest_stable_release(){
    local api_json=""
    SB_LATEST_STABLE_VERSION=""
    SB_LATEST_STABLE_PUBLISHED_AT=""

    if command -v curl >/dev/null 2>&1; then
        api_json=$(curl -fsSL 'https://api.github.com/repos/SagerNet/sing-box/releases?per_page=10' 2>/dev/null || true)
    fi

    if [[ -n "$api_json" ]] && command -v jq >/dev/null 2>&1; then
        SB_LATEST_STABLE_VERSION=$(printf '%s' "$api_json" | jq -r '[.[] | select((.draft == false) and (.prerelease == false))][0].tag_name // empty' | sed 's/^v//')
        SB_LATEST_STABLE_PUBLISHED_AT=$(printf '%s' "$api_json" | jq -r '[.[] | select((.draft == false) and (.prerelease == false))][0].published_at // empty')
    fi

    if [[ -z "$SB_LATEST_STABLE_VERSION" ]] && command -v curl >/dev/null 2>&1; then
        SB_LATEST_STABLE_VERSION=$(curl -fsSL 'https://github.com/SagerNet/sing-box/releases/latest' 2>/dev/null | grep -oE 'releases/tag/v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's#.*v##')
    fi

    [[ -n "$SB_LATEST_STABLE_VERSION" ]]
}

build_dns_hijack_rule_json(){
    if is_true "${SB_DNS_PORT53_HIJACK:-1}"; then
        cat <<'EOF'
      { "type": "logical", "mode": "or", "rules": [
          { "protocol": "dns" },
          { "port": 53 }
        ], "action": "hijack-dns" },
EOF
    else
        printf '%s\n' '      { "protocol": "dns", "action": "hijack-dns" },'
    fi
}

build_dns_bypass_guard_rule_json(){
    if ! is_true "${SB_DNS_REJECT_BYPASS:-0}"; then
        return 0
    fi
    cat <<'EOF'
      { "type": "logical", "mode": "or", "rules": [
          { "port": 853 },
          { "network": "udp", "port": 443 },
          { "protocol": "stun" }
        ], "action": "reject" },
EOF
}

stable_track_label(){
    if probe_latest_stable_release; then
        printf '%s\n' "$SB_LATEST_STABLE_VERSION"
    else
        printf '%s.x\n' "$SB_SUPPORTED_STABLE_FAMILY"
    fi
}

is_true(){
    case "${1:-0}" in
        1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

timestamp_utc(){
    date -u +%Y%m%dT%H%M%SZ
}

calc_sha256(){
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        return 1
    fi
}

base64_no_wrap(){
    if base64 -w 0 /dev/null >/dev/null 2>&1; then
        base64 -w 0 "$@"
    else
        base64 "$@" | tr -d '\r\n'
    fi
}

uri_encode(){
    local value="${1:-}"
    if command -v jq >/dev/null 2>&1; then
        jq -nr --arg v "$value" '$v|@uri'
    else
        python3 - "$value" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=''))
PY
    fi
}

fetch_public_ip(){
    local family="$1" url ip=""
    local -a urls=()
    case "$family" in
        4) urls=("https://icanhazip.com" "https://api.ipify.org") ;;
        6) urls=("https://icanhazip.com" "https://api64.ipify.org") ;;
        *) return 1 ;;
    esac
    for url in "${urls[@]}"; do
        ip=$(curl -fsS -"$family" -m 5 "$url" 2>/dev/null | tr -d '\r\n ' || true)
        case "$family" in
            4) [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { printf '%s\n' "$ip"; return 0; } ;;
            6) [[ "$ip" == *:* ]] && { printf '%s\n' "$ip"; return 0; } ;;
        esac
    done
    return 1
}

extract_sha256_from_text(){
    sed -nE 's/.*([0-9a-fA-F]{64}).*/\1/p' | head -n1 | tr 'A-F' 'a-f'
}

verify_file_sha256(){
    local file="$1" expected="$2" actual=""
    [[ -f "$file" ]] || return 1
    expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual=$(calc_sha256 "$file" 2>/dev/null || true)
    [[ -n "$actual" && "$actual" == "$expected" ]]
}

fetch_github_release_asset_sha256(){
    local owner="$1" repo="$2" tag="$3" asset_name="$4" api_json="" digest=""
    [[ -n "$owner" && -n "$repo" && -n "$tag" && -n "$asset_name" ]] || return 1
    api_json=$(curl -fsSL "https://api.github.com/repos/${owner}/${repo}/releases/tags/v${tag}" 2>/dev/null || true)
    [[ -n "$api_json" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    digest=$(printf '%s' "$api_json" | jq -r --arg asset "$asset_name" '.assets[]? | select(.name == $asset) | .digest // empty' | head -n1 | sed 's/^sha256://')
    [[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    printf '%s\n' "$(printf '%s' "$digest" | tr 'A-F' 'a-f')"
}

resolve_expected_sha256(){
    local explicit_sha="$1" sha_url="$2" fetched=""
    if [[ -n "$explicit_sha" ]]; then
        printf '%s\n' "$explicit_sha" | extract_sha256_from_text
        return 0
    fi
    if [[ -n "$sha_url" ]]; then
        fetched=$(curl -fsSL "$sha_url" 2>/dev/null || true)
        [[ -n "$fetched" ]] || return 1
        printf '%s\n' "$fetched" | extract_sha256_from_text
        return 0
    fi
    return 1
}

record_snapshot_absent_paths(){
    local dir="$1"
    shift
    local path manifest="${dir}/absent_paths.txt"
    : > "$manifest"
    for path in "$@"; do
        [[ -n "$path" ]] || continue
        [[ -e "$path" ]] || printf '%s\n' "$path" >> "$manifest"
    done
}

create_rollout_snapshot(){
    local label="${1:-manual}" ts dir current_uuid=""
    ts=$(timestamp_utc)
    dir="/root/sb2-rollout-${label}-${ts}"
    mkdir -p "$dir" || return 1
    detect_install_layout
    if [[ -f /etc/s-box/sb.json ]] && command -v jq >/dev/null 2>&1; then
        current_uuid=$(jq -r '.inbounds[]? | select(.type=="vless") | .users[0].uuid // empty' /etc/s-box/sb.json 2>/dev/null)
    fi
    {
        echo "CREATED_AT_UTC=$ts"
        echo "HOSTNAME=$(hostname 2>/dev/null || echo unknown)"
        echo "LAYOUT=${SB_INSTALL_LAYOUT:-unknown}"
        echo "DOMAIN=$(head -n1 /etc/s-box/domain.log 2>/dev/null | tr -d '\r\n ' || true)"
        [[ -n "$current_uuid" ]] && echo "CURRENT_UUID=$current_uuid"
    } > "${dir}/meta.env"
    record_snapshot_absent_paths "$dir" \
        /etc/s-box \
        /etc/systemd/system/sing-box.service \
        "/etc/systemd/system/${SB_HY2_HOP_SERVICE}" \
        "$SB_HY2_HOP_SCRIPT" \
        "$SB_CERT_RENEW_SCRIPT" \
        "$SB_CERT_RENEW_STATUS" \
        "$SB_CERT_RENEW_LOG" \
        "$SB_NGINX_STREAM_CONF" \
        "$SB_NGINX_HTTP_CONF" \
        /usr/bin/sb \
        /root/tun.sh
    [[ -d /etc/s-box ]] && tar czf "${dir}/etc-s-box.tgz" -C / etc/s-box >/dev/null 2>&1 || true
    [[ -d /etc/nginx ]] && tar czf "${dir}/etc-nginx.tgz" -C / etc/nginx >/dev/null 2>&1 || true
    [[ -d /etc/ufw ]] && tar czf "${dir}/etc-ufw.tgz" -C / etc/ufw >/dev/null 2>&1 || true
    [[ -f /etc/systemd/system/sing-box.service ]] && cp -a /etc/systemd/system/sing-box.service "${dir}/sing-box.service" >/dev/null 2>&1 || true
    [[ -f "/etc/systemd/system/${SB_HY2_HOP_SERVICE}" ]] && cp -a "/etc/systemd/system/${SB_HY2_HOP_SERVICE}" "${dir}/${SB_HY2_HOP_SERVICE}" >/dev/null 2>&1 || true
    [[ -f /usr/bin/sb ]] && cp -a /usr/bin/sb "${dir}/sb.bin" >/dev/null 2>&1 || true
    [[ -f /etc/crontab ]] && cp -a /etc/crontab "${dir}/crontab" >/dev/null 2>&1 || true
    [[ -f /etc/sysctl.conf ]] && cp -a /etc/sysctl.conf "${dir}/sysctl.conf" >/dev/null 2>&1 || true
    [[ -f /root/tun.sh ]] && cp -a /root/tun.sh "${dir}/tun.sh" >/dev/null 2>&1 || true
    ss -lntup > "${dir}/ss_lntup.txt" 2>/dev/null || true
    ufw status numbered > "${dir}/ufw_status.txt" 2>/dev/null || true
    iptables-save > "${dir}/iptables.save" 2>/dev/null || true
    ip6tables-save > "${dir}/ip6tables.save" 2>/dev/null || true
    journalctl -u sing-box -n 200 --no-pager > "${dir}/journal_sing-box.log" 2>/dev/null || true
    journalctl -u nginx -n 200 --no-pager > "${dir}/journal-nginx.log" 2>/dev/null || true
    printf '%s\n' "$dir"
}

restore_rollout_snapshot(){
    local dir="$1"
    [[ -d "$dir" ]] || { red "回滾快照不存在: $dir"; return 1; }
    green "正在從快照回滾: $dir"
    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl stop "${SB_HY2_HOP_SERVICE}" >/dev/null 2>&1 || true
    [[ -f "${dir}/etc-nginx.tgz" ]] && tar xzf "${dir}/etc-nginx.tgz" -C / >/dev/null 2>&1 || true
    [[ -f "${dir}/etc-s-box.tgz" ]] && tar xzf "${dir}/etc-s-box.tgz" -C / >/dev/null 2>&1 || true
    [[ -f "${dir}/etc-ufw.tgz" ]] && tar xzf "${dir}/etc-ufw.tgz" -C / >/dev/null 2>&1 || true
    [[ -f "${dir}/sing-box.service" ]] && cp -a "${dir}/sing-box.service" /etc/systemd/system/sing-box.service >/dev/null 2>&1 || true
    [[ -f "${dir}/${SB_HY2_HOP_SERVICE}" ]] && cp -a "${dir}/${SB_HY2_HOP_SERVICE}" "/etc/systemd/system/${SB_HY2_HOP_SERVICE}" >/dev/null 2>&1 || true
    [[ -f "${dir}/sb.bin" ]] && cp -a "${dir}/sb.bin" /usr/bin/sb >/dev/null 2>&1 || true
    [[ -f "${dir}/crontab" ]] && cp -a "${dir}/crontab" /etc/crontab >/dev/null 2>&1 || true
    [[ -f "${dir}/sysctl.conf" ]] && cp -a "${dir}/sysctl.conf" /etc/sysctl.conf >/dev/null 2>&1 || true
    [[ -f "${dir}/tun.sh" ]] && cp -a "${dir}/tun.sh" /root/tun.sh >/dev/null 2>&1 || true
    if [[ -f "${dir}/absent_paths.txt" ]]; then
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            rm -rf "$path" >/dev/null 2>&1 || true
        done < "${dir}/absent_paths.txt"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    [[ -f "${dir}/iptables.save" ]] && iptables-restore < "${dir}/iptables.save" >/dev/null 2>&1 || true
    [[ -f "${dir}/ip6tables.save" ]] && ip6tables-restore < "${dir}/ip6tables.save" >/dev/null 2>&1 || true
    sysctl -p >/dev/null 2>&1 || true
    if command -v ufw >/dev/null 2>&1; then
        ufw reload >/dev/null 2>&1 || true
    fi
    if command -v nginx >/dev/null 2>&1; then
        nginx -t >/dev/null 2>&1 && (systemctl reload nginx >/dev/null 2>&1 || service nginx reload >/dev/null 2>&1 || true)
    fi
    systemctl restart sing-box >/dev/null 2>&1 || true
    [[ -f "/etc/systemd/system/${SB_HY2_HOP_SERVICE}" ]] && systemctl restart "${SB_HY2_HOP_SERVICE}" >/dev/null 2>&1 || true
}

begin_rollback_guard(){
    SB_ROLLBACK_SNAPSHOT_DIR="$1"
    SB_ROLLBACK_CONTEXT="${2:-未命名操作}"
    SB_ROLLBACK_ACTIVE="1"
}

end_rollback_guard(){
    SB_ROLLBACK_ACTIVE="0"
    SB_ROLLBACK_SNAPSHOT_DIR=""
    SB_ROLLBACK_CONTEXT=""
}

rollback_on_exit_if_needed(){
    local status="$?"
    if [[ "$SB_ROLLBACK_ACTIVE" == "1" && "$status" -ne 0 && -n "$SB_ROLLBACK_SNAPSHOT_DIR" && "${SB_ROLLBACK_RUNNING:-0}" != "1" ]]; then
        SB_ROLLBACK_RUNNING="1"
        red "${SB_ROLLBACK_CONTEXT:-本次操作} 異常退出，正在自動回滾..."
        restore_rollout_snapshot "$SB_ROLLBACK_SNAPSHOT_DIR" || true
        end_rollback_guard
        SB_ROLLBACK_RUNNING="0"
    fi
    return "$status"
}

assert_latest_stable_supported(){
    local action="${1:-本次更新}"
    if ! probe_latest_stable_release; then
        yellow "無法探測 GitHub 最新穩定版，暫按 ${SB_SUPPORTED_STABLE_FAMILY}.x 穩定族繼續。"
        return 0
    fi

    green "GitHub 最新穩定版: ${SB_LATEST_STABLE_VERSION}${SB_LATEST_STABLE_PUBLISHED_AT:+ (${SB_LATEST_STABLE_PUBLISHED_AT})}"
    ensure_sbox_dir
    upsert_kv_file "$SB_ENV_FILE" "SB_LAST_STABLE_VERSION" "$SB_LATEST_STABLE_VERSION"
    upsert_kv_file "$SB_ENV_FILE" "SB_LAST_STABLE_PUBLISHED_AT" "$SB_LATEST_STABLE_PUBLISHED_AT"

    if [[ ! "$SB_LATEST_STABLE_VERSION" =~ ^${SB_SUPPORTED_STABLE_FAMILY//./\\.}\. ]]; then
        red "檢測到新的穩定大版本 ${SB_LATEST_STABLE_VERSION}。"
        red "當前腳本的最新穩定版客戶端模板僅按 ${SB_SUPPORTED_STABLE_FAMILY}.x 驗證。"
        red "請先更新本地 dual-track 配置模板與校驗器，再執行 ${action}。"
        return 1
    fi
    return 0
}

sb(){
    local self="${BASH_SOURCE[0]:-$0}"
    [[ -f "$self" ]] || { red "無法定位當前腳本文件。"; return 1; }
    bash "$self"
    exit 0
}

[[ $EUID -ne 0 ]] && yellow "請以root模式運行脚本" && exit

if [[ -f /etc/issue ]] && grep -q -E -i "ubuntu" /etc/issue; then
    release="Ubuntu"
elif [[ -f /proc/version ]] && grep -q -E -i "ubuntu" /proc/version; then
    release="Ubuntu"
else
    red "脚本僅支持 Ubuntu 系統。" && exit
fi

if ! command -v systemctl >/dev/null 2>&1; then
    red "錯誤：當前系統未檢測到 systemd。"
    red "本脚本嚴重依賴 systemd 管理服務，無法繼續。"
    exit 1
fi

ufw_allow(){
    local port="$1" proto="$2" comment="$3"
    if [[ -z "$comment" ]]; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1
    else
        if ! ufw allow "${port}/${proto}" comment "${comment}" >/dev/null 2>&1; then
             ufw allow "${port}/${proto}" >/dev/null 2>&1
        fi
    fi
}

export sbfiles="/etc/s-box/sb.json"
case $(uname -m) in
    armv7l) cpu=armv7;;
    aarch64) cpu=arm64;;
    x86_64) cpu=amd64;;
    *) red "目前脚本不支持$(uname -m)架構" && exit;;
esac

load_runtime_env

hostname=$(hostname)
reality_sni="${REALITY_SNI:-}"
trap rollback_on_exit_if_needed EXIT

# ==================== 基礎功能 ====================

enable_bbr(){
    local needs_update=false
    if ! grep -q "net.core.default_qdisc = fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        needs_update=true
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        needs_update=true
    fi
    if [[ "$needs_update" == "true" ]]; then
        green "正在自動開啟 BBR 加速..."
        sysctl -p >/dev/null 2>&1
    fi
}

install_depend(){
    local dep_ver="6" missing=0
    local required_cmds=(jq openssl ss curl wget tar python3 cron file nginx)
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing=1
            break
        fi
    done
    if [[ "$(cat /etc/s-box/sbyg_update 2>/dev/null)" != "$dep_ver" || "$missing" == "1" ]]; then
        green "安裝必要依賴..."
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none apt update -y || {
            red "apt update 失敗，無法繼續安裝依賴。"
            return 1
        }
        DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none apt install -y jq openssl iproute2 iputils-ping coreutils expect git socat grep \
            util-linux curl wget tar python3 cron ufw iptables file nginx libnginx-mod-stream || {
            red "apt install 失敗，無法繼續安裝依賴。"
            return 1
        }
        mkdir -p /etc/s-box
        echo "$dep_ver" > /etc/s-box/sbyg_update
    fi
}

setup_tun(){
    if [[ ! -c /dev/net/tun ]]; then
        cat > /root/tun.sh <<'EOF'
#!/bin/bash
if [ ! -e /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 0666 /dev/net/tun
fi
EOF
        chmod +x /root/tun.sh
        grep -qE "^ *@reboot root bash /root/tun.sh >/dev/null 2>&1" /etc/crontab || echo "@reboot root bash /root/tun.sh >/dev/null 2>&1" >> /etc/crontab
    fi
}

_v4_cache=""
_v6_cache=""
v4v6(){
    if [[ -z "$_v4_cache" ]]; then
        _v4_cache=$(fetch_public_ip 4 2>/dev/null || echo "")
    fi
    if [[ -z "$_v6_cache" ]]; then
        _v6_cache=$(fetch_public_ip 6 2>/dev/null || echo "")
    fi
    v4="$_v4_cache"
    v6="$_v6_cache"
}

v4v6_refresh(){
    _v4_cache=""
    _v6_cache=""
    v4v6
}

is_valid_port_number(){
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

is_valid_hop_interval(){
    local v="$1"
    [[ "$v" =~ ^[0-9]+[smh]$ ]]
}

gen_random_alnum(){
    local n="${1:-20}"
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$n"
}

select_client_host(){
    local domain="$1" ip="$2"
    case "${SB_CLIENT_HOST_MODE:-ip_prefer}" in
        domain_only)
            [[ -n "$domain" ]] || return 1
            printf '%s\n' "$domain"
            ;;
        domain|domain_prefer)
            [[ -n "$domain" ]] && printf '%s\n' "$domain" || printf '%s\n' "$ip"
            ;;
        ip|ip_only|ip_prefer|*)
            [[ -n "$ip" ]] && printf '%s\n' "$ip" || printf '%s\n' "$domain"
            ;;
    esac
}

default_reality_sni_candidates(){
    cat <<'EOF'
download-installer.cdn.mozilla.net
gateway.icloud.com
swdist.apple.com
addons.mozilla.org
www.microsoft.com
www.speedtest.net
www.lovelive-anime.jp
dl.google.com
EOF
}

probe_reality_sni_candidate(){
    local candidate="$1" headers status_line handshake
    [[ -n "$candidate" ]] || return 1
    if command -v timeout >/dev/null 2>&1; then
        handshake=$(timeout 6 openssl s_client -connect "${candidate}:443" -servername "$candidate" -tls1_3 -alpn h2 </dev/null 2>/dev/null || true)
    else
        handshake=$(openssl s_client -connect "${candidate}:443" -servername "$candidate" -tls1_3 -alpn h2 </dev/null 2>/dev/null || true)
    fi
    printf '%s\n' "$handshake" | grep -q "ALPN protocol: h2" || return 1
    headers=$(curl -fsSI --http2 --connect-timeout 3 -m 6 "https://${candidate}/" 2>/dev/null || true)
    [[ -n "$headers" ]] || return 1
    status_line=$(printf '%s\n' "$headers" | awk 'toupper($0) ~ /^HTTP\/[0-9.]+ [0-9][0-9][0-9]/ {print; exit}')
    [[ "$status_line" == HTTP/2* ]] || return 1
    if printf '%s\n' "$status_line" | grep -qE '^HTTP/2 30[1278]\b'; then
        return 1
    fi
    return 0
}

resolve_reality_sni(){
    local candidates_raw="" candidate=""
    [[ -n "${REALITY_SNI:-}" ]] && reality_sni="$REALITY_SNI"
    if [[ -n "${reality_sni:-}" ]]; then
        return 0
    fi
    load_runtime_env
    if [[ -n "${SB_REALITY_SNI:-}" ]]; then
        reality_sni="$SB_REALITY_SNI"
        return 0
    fi

    candidates_raw="${SB_REALITY_SNI_CANDIDATES:-}"
    if [[ -z "$candidates_raw" ]]; then
        candidates_raw="$(default_reality_sni_candidates | paste -sd, -)"
        upsert_kv_file "$SB_ENV_FILE" "SB_REALITY_SNI_CANDIDATES" "$candidates_raw"
    fi

    local old_ifs="$IFS"
    IFS=','
    for candidate in $candidates_raw; do
        candidate=$(printf '%s' "$candidate" | tr -d '[:space:]')
        [[ -n "$candidate" ]] || continue
        if probe_reality_sni_candidate "$candidate"; then
            reality_sni="$candidate"
            upsert_kv_file "$SB_ENV_FILE" "SB_REALITY_SNI" "$reality_sni"
            load_runtime_env
            green "Reality 默認 SNI 已自動選定: ${reality_sni}"
            IFS="$old_ifs"
            return 0
        fi
    done
    IFS="$old_ifs"

    reality_sni="$(printf '%s\n' "$candidates_raw" | tr ',' '\n' | sed '/^[[:space:]]*$/d' | head -1)"
    [[ -n "$reality_sni" ]] || reality_sni="download-installer.cdn.mozilla.net"
    upsert_kv_file "$SB_ENV_FILE" "SB_REALITY_SNI" "$reality_sni"
    load_runtime_env
    yellow "未探測到可驗證的默認 Reality SNI，暫回退為候選池首選 ${reality_sni}"
    return 0
}

port_in_use(){
    local port="$1"
    ss -Htan "( sport = :${port} )" 2>/dev/null | grep -q . && return 0
    ss -Huan "( sport = :${port} )" 2>/dev/null | grep -q . && return 0
    return 1
}

pick_unused_high_port(){
    local attempts=0 port
    while (( attempts < 240 )); do
        port=$(shuf -i 10000-65535 -n 1)
        if ! port_in_use "$port" && [[ ! " $* " =~ " $port " ]]; then
            printf '%s\n' "$port"
            return 0
        fi
        attempts=$((attempts + 1))
    done
    return 1
}

detect_public_https_sites(){
    SB_PUBLIC_HTTPS_SITES=""
    command -v nginx >/dev/null 2>&1 || return 0
    local dump
    dump=$(nginx -T 2>/dev/null || true)
    [[ -n "$dump" ]] || return 0
    SB_PUBLIC_HTTPS_SITES=$(printf '%s\n' "$dump" | awk '
        /^[[:space:]]*server_name[[:space:]]+/ {
            for (i = 2; i <= NF; i++) {
                gsub(/;/, "", $i)
                if ($i != "_" && $i != "localhost" && $i != "" && $i !~ /^\$/) print $i
            }
        }
    ' | sort -u | paste -sd, -)
}

show_install_context(){
    detect_public_https_sites
    local tcp443="free" udp443="free"
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE '(^|:)443$' && tcp443="busy"
    ss -ulnH 2>/dev/null | awk '{print $4}' | grep -qE '(^|:)443$' && udp443="busy"
    green "安裝前環境預檢..."
    if [[ -n "$SB_PUBLIC_HTTPS_SITES" ]]; then
        yellow "檢測到現有公開站點: ${SB_PUBLIC_HTTPS_SITES}"
        green "將以 with_site 模式協調 443/TCP，保留現有網站。"
    else
        yellow "未檢測到現有公開站點。"
        green "仍採用四協議共存的 443/TCP 收斂架構；若後續做無站極簡模式，可再單獨收斂。"
    fi
    yellow "端口現狀: TCP 443=${tcp443}, UDP 443=${udp443}"
}

calc_cert_public_key_sha256(){
    local cert_path="${1:-/etc/s-box/cert.crt}"
    [[ -s "$cert_path" ]] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    openssl x509 -in "$cert_path" -pubkey -noout 2>/dev/null | \
        openssl pkey -pubin -outform der 2>/dev/null | \
        openssl dgst -sha256 -binary 2>/dev/null | \
        openssl enc -base64 2>/dev/null | tr -d '\r\n'
}

manifest_add_file(){
    local file="$1" backup="${2:-}"
    ensure_sbox_dir
    touch "$SB_NGINX_MANIFEST"
    chmod 600 "$SB_NGINX_MANIFEST" 2>/dev/null || true
    local tmp_file
    tmp_file=$(mktemp /tmp/sb_nginx_manifest.XXXXXX) || return 1
    awk -F '\t' -v file="$file" -v backup="$backup" '
        BEGIN { written = 0 }
        $1 == file {
            if (!written) {
                if (backup != "") print file "\t" backup; else print file
                written = 1
            }
            next
        }
        { print }
        END {
            if (!written) {
                if (backup != "") {
                    print file "\t" backup
                } else {
                    print file
                }
            }
        }
    ' "$SB_NGINX_MANIFEST" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    mv "$tmp_file" "$SB_NGINX_MANIFEST"
    chmod 600 "$SB_NGINX_MANIFEST" 2>/dev/null || true
}

nginx_backup_path_for_file(){
    local file="$1" safe_name=""
    safe_name="${file#/}"
    safe_name="${safe_name//\//__}"
    printf '%s/%s.sb_backup\n' "$SB_NGINX_BACKUP_DIR" "$safe_name"
}

backup_file_once(){
    local file="$1" backup=""
    [[ -f "$file" ]] || return 1
    mkdir -p "$SB_NGINX_BACKUP_DIR" || return 1
    backup="$(nginx_backup_path_for_file "$file")"
    cp -L --preserve=mode,timestamps "$file" "$backup" || return 1
    rm -f "${file}.sb_backup"
    manifest_add_file "$file" "$backup"
}

restore_recorded_backups(){
    local manifest="${1:-$SB_NGINX_MANIFEST}"
    local file backup
    [[ -f "$manifest" ]] || return 0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        file="${line%%$'\t'*}"
        backup="${line#*$'\t'}"
        [[ "$backup" == "$line" || -z "$backup" ]] && backup="$(nginx_backup_path_for_file "$file")"
        [[ -n "$file" ]] || continue
        [[ -f "$backup" ]] || backup="${file}.sb_backup"
        [[ -f "$backup" ]] || continue
        cp -a "$backup" "$file" 2>/dev/null || cat "$backup" > "$file"
    done < "$manifest"
}

cleanup_recorded_backups(){
    local manifest="${1:-$SB_NGINX_MANIFEST}"
    local file backup
    [[ -f "$manifest" ]] || return 0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        file="${line%%$'\t'*}"
        backup="${line#*$'\t'}"
        [[ "$backup" == "$line" || -z "$backup" ]] && backup="$(nginx_backup_path_for_file "$file")"
        [[ -n "$file" ]] || continue
        rm -f "$backup"
        rm -f "${file}.sb_backup"
    done < "$manifest"
    rm -f "$manifest"
    rmdir "$SB_NGINX_BACKUP_DIR" >/dev/null 2>&1 || true
}

repair_nginx_backup_storage(){
    ensure_sbox_dir
    mkdir -p "$SB_NGINX_BACKUP_DIR" || return 1
    local legacy_backup orig_file safe_backup repaired=0 line tmp_backup
    for legacy_backup in \
        /etc/nginx/nginx.conf.sb_backup \
        /etc/nginx/sites-enabled/*.sb_backup \
        /etc/nginx/conf.d/*.sb_backup; do
        [[ -f "$legacy_backup" ]] || continue
        orig_file="${legacy_backup%.sb_backup}"
        safe_backup="$(nginx_backup_path_for_file "$orig_file")"
        cp -L --preserve=mode,timestamps "$legacy_backup" "$safe_backup" || return 1
        manifest_add_file "$orig_file" "$safe_backup" || return 1
        rm -f "$legacy_backup"
        repaired=1
        green "已遷移 Nginx 備份: $legacy_backup -> $safe_backup"
    done
    if [[ -f "$SB_NGINX_MANIFEST" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            orig_file="${line%%$'\t'*}"
            safe_backup="${line#*$'\t'}"
            [[ "$safe_backup" == "$line" || -z "$safe_backup" ]] && safe_backup="$(nginx_backup_path_for_file "$orig_file")"
            [[ -L "$safe_backup" ]] || continue
            tmp_backup="$(mktemp "${SB_NGINX_BACKUP_DIR}/normalize.XXXXXX")" || return 1
            cp -L --preserve=mode,timestamps "$safe_backup" "$tmp_backup" || { rm -f "$tmp_backup"; return 1; }
            mv -f "$tmp_backup" "$safe_backup" || { rm -f "$tmp_backup"; return 1; }
            repaired=1
            green "已重寫 Nginx 備份為實體文件: $safe_backup"
        done < "$SB_NGINX_MANIFEST"
    fi
    [[ "$repaired" == "1" ]] || yellow "未檢測到需要遷移的舊式 Nginx 備份文件。"
}

rewrite_nginx_tcp_443_file(){
    local file="$1" loop_port="$2"
    python3 - "$file" "$loop_port" <<'PY2'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
port = sys.argv[2]
text = path.read_text()
lines = text.splitlines(True)
out = []
changed = False
have_ipv4_loopback = any(re.match(r'^\s*listen\s+127\.0\.0\.1:' + re.escape(port) + r'(\s|;)', line) for line in lines)
unsupported = []

for line in lines:
    stripped = line.lstrip()
    if stripped.startswith('#'):
        out.append(line)
        continue
    m4 = re.match(r'^(\s*)listen\s+(?:0\.0\.0\.0:)?443(\s+[^;]*?)?;\s*$', line)
    m6 = re.match(r'^(\s*)listen\s+\[::\]:443(\s+[^;]*?)?;\s*$', line)
    if m4:
        suffix = m4.group(2) or ''
        if 'quic' in suffix.split():
            out.append(line)
            continue
        out.append(f"{m4.group(1)}listen 127.0.0.1:{port}{suffix}\n")
        if not out[-1].endswith(';\n'):
            out[-1] = out[-1][:-1] + ';\n'
        have_ipv4_loopback = True
        changed = True
        continue
    if m6:
        suffix = m6.group(2) or ''
        if 'quic' in suffix.split():
            out.append(line)
            continue
        if not have_ipv4_loopback:
            inserted = f"{m6.group(1)}listen 127.0.0.1:{port}{suffix}\n"
            if not inserted.endswith(';\n'):
                inserted = inserted[:-1] + ';\n'
            out.append(inserted)
            have_ipv4_loopback = True
        out.append(f"{m6.group(1)}# sb-managed disabled external IPv6 443: listen [::]:443{suffix};\n")
        changed = True
        continue
    if 'listen' in line and '443' in line and 'quic' not in line:
        unsupported.append(line.rstrip())
    out.append(line)

if unsupported:
    for item in unsupported:
        print(item, file=sys.stderr)
    sys.exit(4)
if not changed:
    sys.exit(3)
path.write_text(''.join(out))
PY2
}

ensure_nginx_stream_include(){
    local nginx_conf="${1:-/etc/nginx/nginx.conf}"
    python3 - "$nginx_conf" <<'PY2'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
include_stmt = "    include /etc/nginx/stream.d/*.conf;\n"
stream_block = "stream {\n    include /etc/nginx/stream.d/*.conf;\n}\n"

if "include /etc/nginx/stream.d/*.conf;" in text:
    sys.exit(0)

stream_match = re.search(r'(?m)^(\s*stream\s*\{\s*\n)', text)
if stream_match:
    insert_at = stream_match.end(1)
    text = text[:insert_at] + include_stmt + text[insert_at:]
elif re.search(r'(?m)^\s*http\s*\{', text):
    text = re.sub(r'(?m)^\s*http\s*\{', stream_block + "\nhttp {", text, count=1)
else:
    if text and not text.endswith("\n"):
        text += "\n"
    text += "\n" + stream_block

path.write_text(text)
PY2
}

maybe_align_hy2_masquerade_with_site(){
    [[ -n "${domain_name:-}" ]] || return 0
    detect_public_https_sites
    [[ -n "$SB_PUBLIC_HTTPS_SITES" ]] || return 0
    if printf '%s\n' "$SB_PUBLIC_HTTPS_SITES" | tr ',' '\n' | grep -Fxq "$domain_name"; then
        if [[ -z "${SB_HY2_MASQUERADE_URL:-}" || "${SB_HY2_MASQUERADE_URL:-}" == "https://www.cloudflare.com/" ]]; then
            SB_HY2_MASQUERADE_URL="https://${domain_name}/"
            upsert_kv_file "$SB_ENV_FILE" "SB_HY2_MASQUERADE_URL" "$SB_HY2_MASQUERADE_URL"
            load_runtime_env
            green "HY2 偽裝已自動對齊站點: ${SB_HY2_MASQUERADE_URL}"
        fi
    fi
}

detect_install_layout(){
    SB_INSTALL_LAYOUT="none"
    if [[ -f "$SB_NGINX_STREAM_CONF" || -f "$SB_NGINX_HTTP_CONF" ]]; then
        SB_INSTALL_LAYOUT="v3_sni"
        return 0
    fi
    if [[ -f /etc/s-box/firewall_ports.log ]]; then
        if grep -q '^INT_PORT_REALITY=' /etc/s-box/firewall_ports.log 2>/dev/null; then
            SB_INSTALL_LAYOUT="v3_sni"
            return 0
        fi
        if grep -q '^VLESS_PORT=' /etc/s-box/firewall_ports.log 2>/dev/null || grep -q '^VMESS_PORT=' /etc/s-box/firewall_ports.log 2>/dev/null; then
            SB_INSTALL_LAYOUT="v2_split"
            return 0
        fi
    fi
    if [[ -f /etc/s-box/sb.json ]] && command -v jq >/dev/null 2>&1; then
        if jq -e '.inbounds[]? | select((.type=="vless" or .type=="vmess") and .listen=="127.0.0.1")' /etc/s-box/sb.json >/dev/null 2>&1; then
            SB_INSTALL_LAYOUT="v3_sni"
            return 0
        fi
        if jq -e '.inbounds[]? | select((.type=="vless" or .type=="vmess") and .listen != "127.0.0.1")' /etc/s-box/sb.json >/dev/null 2>&1; then
            SB_INSTALL_LAYOUT="v2_split"
            return 0
        fi
    fi
}

require_v3_layout(){
    local action="${1:-此操作}"
    detect_install_layout
    if [[ "$SB_INSTALL_LAYOUT" == "v3_sni" ]]; then
        return 0
    fi
    if [[ "$SB_INSTALL_LAYOUT" == "v2_split" ]]; then
        red "當前機器仍是舊版分端口架構，${action}已暫停。"
        yellow "先不要把舊機器直接當作 443 / Nginx SNI 架構輸出或更新。"
        yellow "需先完成顯式遷移流程，再使用此版本的 v3 功能。"
        return 1
    fi
    yellow "未能識別當前安裝架構，${action}已暫停。"
    return 1
}

layout_label(){
    detect_install_layout
    case "$SB_INSTALL_LAYOUT" in
        v3_sni) echo "Nginx SNI 443" ;;
        v2_split) echo "Legacy Split Ports" ;;
        *) echo "Unknown/Not Installed" ;;
    esac
}

# ==================== sing-box 安裝 ====================

inssb(){
    local expected_sha="" downloaded_sha=""
    green "下載並安裝 Sing-box 內核..."
    mkdir -p /etc/s-box
    if [[ -n "${SB_VERSION:-}" ]]; then
        sbcore="$SB_VERSION"
        green "使用指定版本: $sbcore"
    else
        probe_latest_stable_release >/dev/null 2>&1 || true
        sbcore="${SB_LATEST_STABLE_VERSION:-}"
        if [[ -z "$sbcore" ]]; then
            yellow "GitHub API 獲取失敗，嘗試 fallback..."
            sbcore=$(curl -fsSL "https://github.com/SagerNet/sing-box/releases/latest" 2>/dev/null | grep -oE 'releases/tag/v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's#.*v##')
        fi
        if [[ -z "$sbcore" ]]; then
            red "無法獲取 sing-box 最新版本號。"
            red "可嘗試：export SB_VERSION=$(stable_track_label) 後重新運行脚本指定版本。"
            exit 1
        fi
    fi
    sbname="sing-box-$sbcore-linux-$cpu"
    sburl="https://github.com/SagerNet/sing-box/releases/download/v${sbcore}/${sbname}.tar.gz"
    expected_sha=$(fetch_github_release_asset_sha256 "SagerNet" "sing-box" "$sbcore" "${sbname}.tar.gz" 2>/dev/null || true)
    green "準備下載版本: ${sbcore} (${sbname})"
    curl -fL -o /etc/s-box/sing-box.tar.gz -# --retry 2 "$sburl" || {
        red "下載 sing-box 內核失敗，請檢查網路或 GitHub 訪問。"
        exit 1
    }
    local file_type=$(file -b /etc/s-box/sing-box.tar.gz 2>/dev/null)
    if ! echo "$file_type" | grep -qi "gzip\|tar"; then
        red "下載的文件不是有效的 tar.gz 格式（可能被劫持或返回了 HTML 錯誤頁）"
        rm -f /etc/s-box/sing-box.tar.gz
        exit 1
    fi
    if [[ -n "$expected_sha" ]]; then
        if ! verify_file_sha256 /etc/s-box/sing-box.tar.gz "$expected_sha"; then
            downloaded_sha=$(calc_sha256 /etc/s-box/sing-box.tar.gz 2>/dev/null || echo "unknown")
            red "sing-box 下載文件 SHA256 校驗失敗。"
            red "期望: $expected_sha"
            red "實際: $downloaded_sha"
            rm -f /etc/s-box/sing-box.tar.gz
            exit 1
        fi
        green "sing-box 下載文件 SHA256 校驗通過。"
    else
        yellow "未能獲取官方 digest，保留文件類型與可執行校驗。"
    fi
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box 2>/dev/null || {
        red "解壓 sing-box.tar.gz 失敗，文件可能損壞。"
        rm -f /etc/s-box/sing-box.tar.gz
        exit 1
    }
    if [[ ! -x "/etc/s-box/${sbname}/sing-box" ]]; then
        red "未在解壓目錄中找到 sing-box 可執行文件，安裝中止。"
        exit 1
    fi
    mv "/etc/s-box/${sbname}/sing-box" /etc/s-box/
    rm -rf "/etc/s-box/${sbname}" /etc/s-box/sing-box.tar.gz
    chown root:root /etc/s-box/sing-box
    chmod +x /etc/s-box/sing-box
    local installed_ver=$(/etc/s-box/sing-box version 2>/dev/null | head -1 | awk '{print $NF}')
    if [[ -z "$installed_ver" ]]; then
        red "sing-box 二進制無法執行，可能已損壞或不匹配當前架構。"
        rm -f /etc/s-box/sing-box
        exit 1
    fi
    green "Sing-box 內核安裝完成，版本: $installed_ver"
}

# ==================== 端口生成（新架構）====================
# 內部端口：Reality / VMess-WS / Nginx HTTPS backend — 監聽 127.0.0.1
# 外部端口：HY2 / TUIC — 監聽 :: (UDP)
# 對外 TCP 只有 443（Nginx stream）

insport(){
    green "生成端口..."
    # 生成 5 個不衝突的高位隨機端口（3 個內部 + 2 個外部 UDP）
    local all_ports=() port
    for i in {1..5}; do
        port=$(pick_unused_high_port "${all_ports[@]}") || {
            red "高位端口生成失敗：未能在合理嘗試次數內找到空閒端口。"
            return 1
        }
        all_ports+=("$port")
    done
    # 內部端口（只聽 127.0.0.1，不對外暴露）
    int_port_reality=${all_ports[0]}
    int_port_vmws=${all_ports[1]}
    int_port_https_backend=${all_ports[2]}
    # 外部端口（UDP 協議，直接對外）
    port_hy2=${all_ports[3]}
    port_tu=${all_ports[4]}
    # 保持向下兼容的變量名（防火牆日誌等用到）
    port_vl_re=$int_port_reality
    port_vm_ws=$int_port_vmws

    green "  內部端口 — Reality: $int_port_reality, VMess-WS: $int_port_vmws, HTTPS-backend: $int_port_https_backend"
    green "  外部端口 — HY2: $port_hy2/udp, TUIC: $port_tu/udp"
    green "  對外 TCP  — 443 (Nginx SNI 分流)"
}

# ==================== HY2 端口跳躍（與原版相同）====================

pick_hy2_hop_range(){
    local width=79 attempts=0 start end
    local in_use=""
    local reserved_ports=()
    local p
    in_use=$(ss -ulnH 2>/dev/null | awk '{print $5}' | sed -E 's/.*[:.]([0-9]+)$/\1/' | grep -E '^[0-9]+$' | sort -u)
    for p in "$port_hy2" "$port_tu" "${int_port_reality:-}" "${int_port_vmws:-}" "${int_port_https_backend:-}"; do
        is_valid_port_number "$p" && reserved_ports+=("$p")
    done
    while (( attempts < 120 )); do
        start=$(shuf -i 20000-56000 -n 1)
        end=$((start + width))
        (( end > 65000 )) && { attempts=$((attempts + 1)); continue; }
        local conflict=0
        for p in "${reserved_ports[@]}"; do
            if (( p >= start && p <= end )); then conflict=1; break; fi
        done
        (( conflict == 1 )) && { attempts=$((attempts + 1)); continue; }
        for p in $in_use; do
            if (( p >= start && p <= end )); then conflict=1; break; fi
        done
        if (( conflict == 0 )); then
            echo "$start $end"
            return 0
        fi
        attempts=$((attempts + 1))
    done
    echo "24000 24079"
}

init_hy2_transport_env(){
    ensure_sbox_dir
    load_runtime_env
    local changed=0 hop_range
    if [[ "${SB_HY2_OBFS_ENABLED:-1}" != "0" ]]; then
        SB_HY2_OBFS_ENABLED="1"
        if [[ -z "${SB_HY2_OBFS_PASSWORD:-}" ]]; then
            SB_HY2_OBFS_PASSWORD="$(gen_random_alnum 20)"
            changed=1
        fi
    fi
    if [[ -z "${SB_HY2_MASQUERADE_URL:-}" ]]; then
        SB_HY2_MASQUERADE_URL="https://www.cloudflare.com/"
        changed=1
    fi
    if [[ "${SB_HY2_HOP_ENABLED:-1}" != "0" ]]; then SB_HY2_HOP_ENABLED="1"; fi
    if [[ -z "${SB_HY2_HOP_INTERVAL:-}" ]] || ! is_valid_hop_interval "$SB_HY2_HOP_INTERVAL"; then
        SB_HY2_HOP_INTERVAL="30s"; changed=1
    fi
    if [[ "${SB_HY2_HOP_ENABLED:-1}" == "1" ]]; then
        if ! is_valid_port_number "${SB_HY2_HOP_START:-}" || ! is_valid_port_number "${SB_HY2_HOP_END:-}" || (( SB_HY2_HOP_START >= SB_HY2_HOP_END )); then
            hop_range="$(pick_hy2_hop_range)"
            SB_HY2_HOP_START="${hop_range%% *}"
            SB_HY2_HOP_END="${hop_range##* }"
            changed=1
        fi
    fi
    if ! is_valid_port_number "${SB_HY2_HOP_TARGET_PORT:-}" || [[ "${SB_HY2_HOP_TARGET_PORT:-}" != "$port_hy2" ]]; then
        SB_HY2_HOP_TARGET_PORT="$port_hy2"
        changed=1
    fi
    upsert_kv_file "$SB_ENV_FILE" "SB_HY2_OBFS_ENABLED" "${SB_HY2_OBFS_ENABLED:-1}"
    upsert_kv_file "$SB_ENV_FILE" "SB_HY2_OBFS_PASSWORD" "${SB_HY2_OBFS_PASSWORD:-}"
    upsert_kv_file "$SB_ENV_FILE" "SB_HY2_MASQUERADE_URL" "${SB_HY2_MASQUERADE_URL:-https://www.cloudflare.com/}"
    upsert_kv_file "$SB_ENV_FILE" "SB_HY2_HOP_ENABLED" "${SB_HY2_HOP_ENABLED:-1}"
    upsert_kv_file "$SB_ENV_FILE" "SB_HY2_HOP_START" "${SB_HY2_HOP_START:-}"
    upsert_kv_file "$SB_ENV_FILE" "SB_HY2_HOP_END" "${SB_HY2_HOP_END:-}"
    upsert_kv_file "$SB_ENV_FILE" "SB_HY2_HOP_INTERVAL" "${SB_HY2_HOP_INTERVAL:-30s}"
    upsert_kv_file "$SB_ENV_FILE" "SB_HY2_HOP_TARGET_PORT" "${SB_HY2_HOP_TARGET_PORT:-$port_hy2}"
    upsert_kv_file "$SB_ENV_FILE" "SB_CLIENT_UTLS_ENABLED" "${SB_CLIENT_UTLS_ENABLED:-0}"
    upsert_kv_file "$SB_ENV_FILE" "SB_CLIENT_HOST_MODE" "${SB_CLIENT_HOST_MODE:-ip_prefer}"
    load_runtime_env
    green "HY2 抗封鎖增強: obfs=salamander, masquerade=${SB_HY2_MASQUERADE_URL}"
    if [[ "${SB_HY2_HOP_ENABLED:-1}" == "1" ]]; then
        green "HY2 端口跳躍: ${SB_HY2_HOP_START}:${SB_HY2_HOP_END} -> ${SB_HY2_HOP_TARGET_PORT} (${SB_HY2_HOP_INTERVAL})"
    else
        yellow "HY2 端口跳躍: 已停用"
    fi
    [[ "$changed" == "1" ]] && green "HY2 增強參數已寫入 ${SB_ENV_FILE}"
}

load_hy2_runtime_from_server_files(){
    load_runtime_env
    if [[ -z "${SB_HY2_OBFS_PASSWORD:-}" && -f /etc/s-box/sb.json ]]; then
        SB_HY2_OBFS_PASSWORD="$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .obfs.password // empty' /etc/s-box/sb.json 2>/dev/null)"
    fi
    if [[ -z "${SB_HY2_MASQUERADE_URL:-}" && -f /etc/s-box/sb.json ]]; then
        SB_HY2_MASQUERADE_URL="$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .masquerade // empty' /etc/s-box/sb.json 2>/dev/null)"
    fi
    if [[ -z "${SB_HY2_HOP_TARGET_PORT:-}" && -f /etc/s-box/sb.json ]]; then
        SB_HY2_HOP_TARGET_PORT="$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .listen_port // empty' /etc/s-box/sb.json 2>/dev/null)"
    fi
    if [[ -z "${SB_HY2_HOP_START:-}" || -z "${SB_HY2_HOP_END:-}" ]]; then
        local hop_range
        hop_range=$(grep '^HY2_HOP_RANGE=' /etc/s-box/firewall_ports.log 2>/dev/null | cut -d= -f2)
        if [[ "$hop_range" =~ ^([0-9]+):([0-9]+)$ ]]; then
            SB_HY2_HOP_START="${BASH_REMATCH[1]}"
            SB_HY2_HOP_END="${BASH_REMATCH[2]}"
        fi
    fi
    [[ -z "${SB_HY2_OBFS_ENABLED:-}" ]] && SB_HY2_OBFS_ENABLED="1"
    [[ -z "${SB_HY2_HOP_ENABLED:-}" ]] && SB_HY2_HOP_ENABLED="1"
    [[ -z "${SB_HY2_HOP_INTERVAL:-}" ]] && SB_HY2_HOP_INTERVAL="30s"
}

# ==================== ACME 證書申請 ====================

install_acme_sh_pinned(){
    local acme_ref="${ACME_SH_VERSION:-3.1.2}" tmp_dir=""
    [[ -x /root/.acme.sh/acme.sh ]] && return 0
    command -v git >/dev/null 2>&1 || { red "缺少 git，無法安裝固定版本 acme.sh"; return 1; }
    tmp_dir=$(mktemp -d /tmp/acmesh.XXXXXX) || return 1
    git clone --depth 1 --branch "$acme_ref" https://github.com/acmesh-official/acme.sh.git "$tmp_dir" >/dev/null 2>&1 || {
        rm -rf "$tmp_dir"
        red "下載 acme.sh 固定版本失敗：${acme_ref}"
        return 1
    }
    (cd "$tmp_dir" && ./acme.sh --install --home /root/.acme.sh >/dev/null 2>&1) || {
        rm -rf "$tmp_dir"
        red "安裝 acme.sh 固定版本失敗：${acme_ref}"
        return 1
    }
    rm -rf "$tmp_dir"
    upsert_kv_file "$SB_ENV_FILE" "SB_ACME_SH_VERSION" "$acme_ref"
    green "acme.sh 已按固定版本安裝：${acme_ref}"
}

apply_acme(){
    v4v6
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green "必須使用真實域名進行安裝 (自動申請證書)"
    green "請確保您的域名已解析到本機 IP: ${v4}"
    domain_name="${domain_name:-${DOMAIN_NAME:-}}"
    if [[ -z "$domain_name" ]]; then
        if is_true "$SB_BATCH_MODE"; then
            red "批次模式未提供 DOMAIN_NAME，無法自動申請證書。"
            exit 1
        fi
        readp "請輸入您的域名 (例如: example.com): " domain_name
    fi
    if [[ -z "$domain_name" ]]; then
        red "域名不能為空！" && exit 1
    fi
    mkdir -p /etc/s-box

    green "安裝/更新 acme.sh..."
    if [[ ! -x /root/.acme.sh/acme.sh ]]; then
        install_acme_sh_pinned || exit 1
    fi
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

    acme_install_existing(){
        local d="$1"
        /root/.acme.sh/acme.sh --installcert -d "$d" --fullchainpath /etc/s-box/cert.crt --keypath /etc/s-box/private.key --ecc >/dev/null 2>&1 && return 0
        /root/.acme.sh/acme.sh --installcert -d "$d" --fullchainpath /etc/s-box/cert.crt --keypath /etc/s-box/private.key >/dev/null 2>&1 && return 0
        return 1
    }

    acme_renew_and_reinstall(){
        local d="$1" renew_out rc port80_pid="" p_name="" stopped_nginx=0
        renew_out=$(mktemp /tmp/sb_acme_renew.XXXXXX)
        /root/.acme.sh/acme.sh --register-account -m "admin@$d" --server letsencrypt >/dev/null 2>&1 || true
        port80_pid=$(ss -tulnp 2>/dev/null | grep -E '(:|])80[[:space:]]' | awk '{print $NF}' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | head -1)
        if [[ -n "$port80_pid" ]]; then
            p_name=$(ps -p "$port80_pid" -o comm= 2>/dev/null || true)
            if [[ "$p_name" == "nginx" ]]; then
                yellow "檢測到 Nginx 佔用 80 端口，自動臨時停止..."
                systemctl stop nginx 2>/dev/null || service nginx stop 2>/dev/null || true
                stopped_nginx=1; sleep 1
            fi
        fi
        /root/.acme.sh/acme.sh --renew -d "$d" --ecc --server letsencrypt >"$renew_out" 2>&1; rc=$?
        if [[ $rc -ne 0 ]]; then
            /root/.acme.sh/acme.sh --renew -d "$d" --server letsencrypt >>"$renew_out" 2>&1; rc=$?
        fi
        if [[ $stopped_nginx -eq 1 ]]; then
            systemctl start nginx 2>/dev/null || service nginx start 2>/dev/null || true
        fi
        if [[ $rc -ne 0 ]]; then
            yellow "acme.sh 自動續期輸出（最後 20 行）:"; tail -n 20 "$renew_out" 2>/dev/null || true
            rm -f "$renew_out"; return 1
        fi
        acme_install_existing "$d" || { rm -f "$renew_out"; return 1; }
        rm -f "$renew_out"; return 0
    }

    if acme_install_existing "$domain_name"; then
        green "檢測到 acme.sh 已存在證書，已直接安裝到 /etc/s-box。"
    else
        local acme_mode="standalone" nginx_webroot=""
        local port80_pid=$(ss -tulnp 2>/dev/null | grep -E '(:|])80[[:space:]]' | awk '{print $NF}' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | head -1)
        if [[ -n "$port80_pid" ]]; then
            local p_name=$(ps -p "$port80_pid" -o comm= 2>/dev/null)
            yellow "檢測到 80 端口已被進程 [${p_name:-未知}] (PID: $port80_pid) 佔用。"
            if [[ "$p_name" == "nginx" ]]; then
                if is_true "$SB_BATCH_MODE"; then
                    acme_mode="${ACME_MODE:-webroot}"
                    case "$acme_mode" in
                        webroot)
                            nginx_webroot="${ACME_WEBROOT:-/var/www/html}"
                            mkdir -p "$nginx_webroot"
                            ;;
                        standalone)
                            yellow "批次模式：臨時停止 Nginx 申請證書..."
                            systemctl stop nginx 2>/dev/null || service nginx stop 2>/dev/null || true
                            ;;
                        nginx) : ;;
                        *)
                            acme_mode="webroot"
                            nginx_webroot="${ACME_WEBROOT:-/var/www/html}"
                            mkdir -p "$nginx_webroot"
                            ;;
                    esac
                else
                    yellow "識別到 Nginx 正在運行。"
                    echo
                    yellow "請選擇證書申請方式："
                    yellow "  [1] Webroot 模式 (推薦)"
                    yellow "  [2] Nginx 模式"
                    yellow "  [3] 臨時停止 Nginx，使用 Standalone 模式"
                    readp "   請選擇 [1/2/3]: " nginx_choice
                    case "${nginx_choice:-1}" in
                        1)
                            acme_mode="webroot"
                            if [[ -d /var/www/html ]]; then nginx_webroot="/var/www/html"
                            elif [[ -d /usr/share/nginx/html ]]; then nginx_webroot="/usr/share/nginx/html"
                            else
                                readp "   請輸入 Nginx webroot 路徑 (默認 /var/www/html): " custom_webroot
                                nginx_webroot="${custom_webroot:-/var/www/html}"; mkdir -p "$nginx_webroot"
                            fi
                            green "使用 Webroot 模式，路徑: $nginx_webroot";;
                        2) acme_mode="nginx"; yellow "注意：Nginx 模式需要該域名已在 Nginx 配置中存在 server block。";;
                        3) acme_mode="standalone"; yellow "臨時停止 Nginx..."
                           systemctl stop nginx 2>/dev/null || service nginx stop 2>/dev/null;;
                        *) acme_mode="webroot"; nginx_webroot="/var/www/html"; mkdir -p "$nginx_webroot";;
                    esac
                fi
            else
                red "Standalone 模式需要佔用 80 端口。請先停止該服務。"; exit 1
            fi
        fi
        green "正在申請證書 (模式: $acme_mode, CA: Let's Encrypt)..."
        /root/.acme.sh/acme.sh --register-account -m "admin@$domain_name" --server letsencrypt >/dev/null 2>&1 || true
        local issue_rc=0
        if [[ "$acme_mode" == "standalone" ]]; then
            ufw allow 80/tcp >/dev/null 2>&1 || true
            /root/.acme.sh/acme.sh --issue -d "$domain_name" -k ec-256 --server letsencrypt --standalone; issue_rc=$?
            if [[ -n "$port80_pid" ]]; then
                systemctl start nginx 2>/dev/null || service nginx start 2>/dev/null; green "Nginx 已重新啟動。"
            fi
        elif [[ "$acme_mode" == "nginx" ]]; then
            /root/.acme.sh/acme.sh --issue -d "$domain_name" -k ec-256 --server letsencrypt --nginx; issue_rc=$?
            if [[ $issue_rc -ne 0 ]]; then
                yellow "Nginx 模式失敗，嘗試 Webroot 模式..."
                nginx_webroot="/var/www/html"; mkdir -p "$nginx_webroot"
                /root/.acme.sh/acme.sh --issue -d "$domain_name" -k ec-256 --server letsencrypt -w "$nginx_webroot"; issue_rc=$?
            fi
        elif [[ "$acme_mode" == "webroot" ]]; then
            /root/.acme.sh/acme.sh --issue -d "$domain_name" -k ec-256 --server letsencrypt -w "$nginx_webroot"; issue_rc=$?
        fi
        if [[ $issue_rc -ne 0 ]]; then
            if acme_install_existing "$domain_name"; then
                yellow "acme.sh --issue 返回非 0，但證書已存在，繼續安裝。"
            else
                red "證書申請失敗！"; exit 1
            fi
        else
            acme_install_existing "$domain_name" || { red "證書安裝失敗！" && exit 1; }
        fi
    fi
    if [[ ! -s /etc/s-box/cert.crt || ! -s /etc/s-box/private.key ]]; then
        red "證書安裝失敗！" && exit 1
    fi
    chmod 600 /etc/s-box/private.key
    collect_cert_expiry_info
    if [[ "$CERT_IS_EXPIRED" != "否" ]]; then
        yellow "證書狀態異常，自動續期中..."
        acme_renew_and_reinstall "$domain_name" || { red "證書自動續期失敗。"; exit 1; }
        collect_cert_expiry_info
        if [[ "$CERT_IS_EXPIRED" != "否" ]]; then red "續期後證書狀態仍異常。"; exit 1; fi
        green "證書自動續期成功。"
    fi
    if command -v openssl >/dev/null 2>&1; then
        if ! openssl x509 -in /etc/s-box/cert.crt -noout -text | grep -A1 "Subject Alternative Name" | grep -q "$domain_name"; then
            red "⚠️ 證書 SAN 不包含域名 $domain_name"
        else
            green "✅ 證書域名匹配校驗通過 ($domain_name)"
        fi
    fi
    echo "$domain_name" > /etc/s-box/domain.log
}

# 證書續期腳本 + cron（與原版相同邏輯，省略以節省篇幅——安裝時從原版複製）
create_cert_renew_script(){
    ensure_sbox_dir
    cat > "$SB_CERT_RENEW_SCRIPT" <<'CERTEOF'
#!/bin/bash
set -u
ENV_FILE="/etc/s-box/sb.env"
DOMAIN_FILE="/etc/s-box/domain.log"
STATUS_FILE="/etc/s-box/cert_renew.status"
LOG_FILE="/etc/s-box/cert_renew.log"
ACME_BIN="/root/.acme.sh/acme.sh"
mode="${1:-auto}"
now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
read_env_value(){ local key="$1"; [[ -f "$ENV_FILE" ]] || return 0; grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-; }
record_status(){ local result="$1" detail="$2"; { echo "LAST_RUN_AT=$now_utc"; echo "LAST_MODE=$mode"; echo "LAST_RESULT=$result"; echo "LAST_DETAIL=$detail"; } > "$STATUS_FILE"; chmod 600 "$STATUS_FILE" 2>/dev/null || true; echo "$now_utc|$mode|$result|$detail" >> "$LOG_FILE"; }
send_telegram_fail(){ local msg="$1"; [[ "${SB_TELEGRAM_ENABLED:-0}" == "1" ]] || return 0; [[ -n "${SB_TELEGRAM_BOT_TOKEN:-}" && -n "${SB_TELEGRAM_CHAT_ID:-}" ]] || return 0; local api="https://api.telegram.org/bot${SB_TELEGRAM_BOT_TOKEN}/sendMessage"; local text="[sb] 證書續期失敗\n主機: $(hostname)\n域名: ${domain}\n時間(UTC): ${now_utc}\n原因: ${msg}"; if [[ -n "${SB_TELEGRAM_THREAD_ID:-}" ]]; then curl -fsS -X POST "$api" --data-urlencode "chat_id=${SB_TELEGRAM_CHAT_ID}" --data-urlencode "message_thread_id=${SB_TELEGRAM_THREAD_ID}" --data-urlencode "text=${text}" >/dev/null 2>&1 || true; else curl -fsS -X POST "$api" --data-urlencode "chat_id=${SB_TELEGRAM_CHAT_ID}" --data-urlencode "text=${text}" >/dev/null 2>&1 || true; fi; }
SB_TELEGRAM_ENABLED="$(read_env_value SB_TELEGRAM_ENABLED)"; SB_TELEGRAM_BOT_TOKEN="$(read_env_value SB_TELEGRAM_BOT_TOKEN)"; SB_TELEGRAM_CHAT_ID="$(read_env_value SB_TELEGRAM_CHAT_ID)"; SB_TELEGRAM_THREAD_ID="$(read_env_value SB_TELEGRAM_THREAD_ID)"
[[ -z "$SB_TELEGRAM_ENABLED" ]] && SB_TELEGRAM_ENABLED="0"
if [[ ! -x "$ACME_BIN" ]]; then domain=""; record_status "failed" "acme_bin_missing"; send_telegram_fail "acme_bin_missing"; exit 1; fi
domain="$(head -n1 "$DOMAIN_FILE" 2>/dev/null | tr -d '\r\n ')"; if [[ -z "$domain" ]]; then record_status "failed" "domain_missing"; send_telegram_fail "domain_missing"; exit 1; fi
renew_out="$(mktemp /tmp/sb_renew.XXXXXX)"; install_out="$(mktemp /tmp/sb_install.XXXXXX)"; stopped_nginx=0
"$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
port80_pid=$(ss -tulnp 2>/dev/null | grep -E '(:|])80[[:space:]]' | awk '{print $NF}' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | head -1)
if [[ -n "$port80_pid" ]]; then p_name=$(ps -p "$port80_pid" -o comm= 2>/dev/null || true); if [[ "$p_name" == "nginx" ]]; then systemctl stop nginx >/dev/null 2>&1 || service nginx stop >/dev/null 2>&1 || true; stopped_nginx=1; sleep 1; fi; fi
"$ACME_BIN" --renew -d "$domain" --ecc --server letsencrypt >"$renew_out" 2>&1; renew_rc=$?
if [[ $stopped_nginx -eq 1 ]]; then systemctl start nginx >/dev/null 2>&1 || service nginx start >/dev/null 2>&1 || true; fi
if [[ $renew_rc -ne 0 ]]; then if ! grep -qiE "not due|skip|domains not changed|is not due for renewal" "$renew_out"; then record_status "failed" "renew_failed_rc${renew_rc}"; send_telegram_fail "renew_failed_rc${renew_rc}"; rm -f "$renew_out" "$install_out"; exit 1; fi; fi
if ! "$ACME_BIN" --installcert -d "$domain" --fullchainpath /etc/s-box/cert.crt --keypath /etc/s-box/private.key --ecc >"$install_out" 2>&1; then
    if ! "$ACME_BIN" --installcert -d "$domain" --fullchainpath /etc/s-box/cert.crt --keypath /etc/s-box/private.key >"$install_out" 2>&1; then record_status "failed" "installcert_failed"; send_telegram_fail "installcert_failed"; rm -f "$renew_out" "$install_out"; exit 1; fi; fi
chmod 600 /etc/s-box/private.key 2>/dev/null || true
if [[ -f /etc/systemd/system/sing-box.service ]]; then systemctl restart sing-box >/dev/null 2>&1 || true; fi
if pgrep -x nginx >/dev/null 2>&1; then systemctl reload nginx >/dev/null 2>&1 || service nginx reload >/dev/null 2>&1 || true; fi
expiry="$(openssl x509 -in /etc/s-box/cert.crt -noout -enddate 2>/dev/null | cut -d= -f2)"
if [[ -n "$expiry" ]]; then record_status "success" "ok_expiry:${expiry// /_}"; else record_status "success" "ok"; fi
rm -f "$renew_out" "$install_out"; exit 0
CERTEOF
    chmod +x "$SB_CERT_RENEW_SCRIPT"
}

install_cert_renew_jobs(){
    ensure_sbox_dir; create_cert_renew_script
    /root/.acme.sh/acme.sh --uninstall-cronjob >/dev/null 2>&1 || true
    green "已停用 acme.sh 自帶 cron，改由 sb 自管續期任務。"
    if [[ ! -f /etc/crontab ]]; then yellow "未找到 /etc/crontab，跳過 sb 證書續期任務寫入。"; return; fi
    if grep -Fq "$SB_CERT_RENEW_CRON_MARK" /etc/crontab 2>/dev/null; then sed -i "\|${SB_CERT_RENEW_CRON_MARK}|d" /etc/crontab; fi
    echo "17 3 * * * root ${SB_CERT_RENEW_SCRIPT} auto >/dev/null 2>&1 ${SB_CERT_RENEW_CRON_MARK}" >> /etc/crontab
    green "已安裝 sb 證書續期任務：每日 03:17 (UTC) 自動檢查。"
}

collect_cert_expiry_info(){
    CERT_EXPIRY_DATE=""; CERT_IS_EXPIRED="未知"; CERT_DAYS_LEFT="N/A"
    if [[ ! -s /etc/s-box/cert.crt ]]; then CERT_IS_EXPIRED="未檢測到證書"; return; fi
    if ! command -v openssl >/dev/null 2>&1; then CERT_IS_EXPIRED="無法判斷 (缺少 openssl)"; return; fi
    CERT_EXPIRY_DATE=$(openssl x509 -in /etc/s-box/cert.crt -noout -enddate 2>/dev/null | cut -d= -f2)
    if [[ -z "$CERT_EXPIRY_DATE" ]]; then CERT_IS_EXPIRED="無法讀取"; return; fi
    local expire_epoch now_epoch diff overdue
    expire_epoch=$(date -d "$CERT_EXPIRY_DATE" +%s 2>/dev/null || echo "")
    now_epoch=$(date +%s)
    if [[ -z "$expire_epoch" ]]; then CERT_IS_EXPIRED="無法解析日期"; return; fi
    diff=$((expire_epoch - now_epoch))
    if (( diff < 0 )); then overdue=$(( (-diff + 86399) / 86400 )); CERT_IS_EXPIRED="是"; CERT_DAYS_LEFT="-$overdue"
    else CERT_IS_EXPIRED="否"; CERT_DAYS_LEFT="$((diff / 86400))"; fi
}

ensure_domain_and_cert(){
    local renew_jobs_done=0
    if [[ -f /etc/s-box/cert.crt && -s /etc/s-box/cert.crt && -f /etc/s-box/private.key && -s /etc/s-box/private.key && -f /etc/s-box/domain.log && -s /etc/s-box/domain.log ]]; then
        domain_name=$(head -n1 /etc/s-box/domain.log | tr -d '\r\n ')
        if [[ -z "$domain_name" ]]; then
            yellow "域名記錄為空，將重新走證書申請流程。"; apply_acme; install_cert_renew_jobs; renew_jobs_done=1; return 0
        fi
        collect_cert_expiry_info
        if [[ "$CERT_IS_EXPIRED" != "否" ]]; then
            yellow "歷史證書狀態異常，嘗試自動續期..."
            install_cert_renew_jobs; renew_jobs_done=1
            "$SB_CERT_RENEW_SCRIPT" manual && green "舊證書自動續期成功。" || { red "舊證書自動續期失敗。"; exit 1; }
        else
            green "檢測到已存在有效證書與域名：${yellow}${domain_name}${plain}，跳過 ACME 申請。"
        fi
    else
        apply_acme
    fi
    if [[ "$renew_jobs_done" != "1" ]]; then install_cert_renew_jobs; fi
}

# ==================== Nginx SNI 分流配置（核心新增）====================

setup_nginx_sni(){
    green "配置 Nginx SNI 分流 (所有 TCP 流量統一走 443)..."
    resolve_reality_sni
    load_runtime_env
    rm -f "$SB_NGINX_MANIFEST"

    if ! command -v nginx >/dev/null 2>&1; then
        green "安裝 Nginx..."
        apt install -y nginx libnginx-mod-stream
    fi
    if ! nginx -V 2>&1 | grep -q "stream"; then
        yellow "安裝 Nginx stream 模塊..."
        apt install -y libnginx-mod-stream
    fi

    mkdir -p /etc/nginx/stream.d

    if ! grep -q "include /etc/nginx/stream.d/\*.conf;" /etc/nginx/nginx.conf 2>/dev/null; then
        backup_file_once /etc/nginx/nginx.conf || { red "備份 nginx.conf 失敗"; exit 1; }
        ensure_nginx_stream_include /etc/nginx/nginx.conf
    fi

    local nginx_conf_dirs=("/etc/nginx/sites-enabled" "/etc/nginx/conf.d")
    local conf_dir conf_file rewrite_rc
    for conf_dir in "${nginx_conf_dirs[@]}"; do
        [[ -d "$conf_dir" ]] || continue
        for conf_file in "$conf_dir"/*.conf "$conf_dir"/*; do
            [[ -f "$conf_file" ]] || continue
            [[ "$conf_file" == "$SB_NGINX_HTTP_CONF" ]] && continue
            [[ "$conf_file" == "$SB_NGINX_STREAM_CONF" ]] && continue
            if grep -qE '^\s*listen\s+((0\.0\.0\.0:)?443|\[::\]:443)(\s+[^;]*)?;' "$conf_file" 2>/dev/null; then
                yellow "  遷移 $conf_file 的公網 TCP 443 到 127.0.0.1:${int_port_https_backend}"
                backup_file_once "$conf_file" || { red "備份 $conf_file 失敗"; exit 1; }
                rewrite_nginx_tcp_443_file "$conf_file" "$int_port_https_backend"
                rewrite_rc=$?
                if [[ "$rewrite_rc" -ne 0 ]]; then
                    if [[ "$rewrite_rc" -eq 3 ]]; then
                        yellow "  $conf_file 未檢測到需要遷移的 TCP 443 行，保持原樣。"
                    else
                        red "  無法安全改寫 $conf_file 的 443 監聽行。"
                        restore_recorded_backups
                        rm -f "$SB_NGINX_STREAM_CONF" "$SB_NGINX_HTTP_CONF"
                        exit 1
                    fi
                fi
            fi
        done
    done

    green "生成 Nginx stream SNI 分流配置..."
    cat > "$SB_NGINX_STREAM_CONF" <<STREAMEOF
# ========== Sing-box SNI 分流 — 由 sb2.sh 自動生成 ==========
# 請勿手動編輯，更新腳本時會覆蓋

map \$ssl_preread_server_name \$sni_backend {
    ${reality_sni}    reality_backend;
    ${domain_name}    https_backend;
    default           https_backend;
}

upstream reality_backend {
    server 127.0.0.1:${int_port_reality};
}

upstream https_backend {
    server 127.0.0.1:${int_port_https_backend};
}

server {
    listen 443 reuseport;
    listen [::]:443 reuseport;
    proxy_pass \$sni_backend;
    ssl_preread on;
    proxy_protocol off;
    proxy_connect_timeout 10s;
    proxy_timeout 86400s;
}
STREAMEOF

    green "生成 Nginx HTTP 反代配置 (VMess-WS + 偽裝站)..."
    local vm_ws_path
    vm_ws_path="${SB_VM_WS_PATH:-}"
    [[ -z "$vm_ws_path" ]] && vm_ws_path=$(jq -r '.inbounds[]? | select(.type=="vmess") | .transport.path // empty' /etc/s-box/sb.json 2>/dev/null)
    [[ -z "$vm_ws_path" ]] && { red "未找到 VMess-WS 路徑，停止生成 Nginx 反代配置以避免路徑漂移。"; restore_recorded_backups; exit 1; }
    cat > "$SB_NGINX_HTTP_CONF" <<HTTPEOF
# ========== Sing-box VMess-WS 反代 — 由 sb2.sh 自動生成 ==========

server {
    listen 127.0.0.1:${int_port_https_backend} ssl;
    server_name ${domain_name};

    ssl_certificate     /etc/s-box/cert.crt;
    ssl_certificate_key /etc/s-box/private.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Strict-Transport-Security "max-age=31536000" always;

    location ${vm_ws_path} {
        proxy_pass http://127.0.0.1:${int_port_vmws};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location / {
        root /var/www/html;
        index index.html;
        try_files \$uri \$uri/ =404;
    }
}
HTTPEOF

    green "驗證 Nginx 配置..."
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null
        green "✅ Nginx SNI 分流配置已生效"
        green "  443/tcp → SNI=${reality_sni} → 127.0.0.1:${int_port_reality} (Reality)"
        green "  443/tcp → SNI=${domain_name} → 127.0.0.1:${int_port_https_backend} (HTTPS/VMess-WS)"
    else
        red "❌ Nginx 配置校驗失敗，正在回滾已修改文件..."
        restore_recorded_backups
        rm -f "$SB_NGINX_STREAM_CONF" "$SB_NGINX_HTTP_CONF"
        nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
        red "Nginx 變更已回滾，請檢查現有站點配置後重試。"
        exit 1
    fi
}

# ==================== sing-box 配置生成（新架構）====================

gen_config(){
    resolve_reality_sni
    uuid="${uuid:-$(/etc/s-box/sing-box generate uuid)}"
    if [[ -z "${private_key_reality:-}" || -z "${public_key_reality:-}" ]]; then
        key_pair=$(/etc/s-box/sing-box generate reality-keypair)
        private_key_reality=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
        public_key_reality=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
    fi
    short_id="${short_id:-$(/etc/s-box/sing-box generate rand --hex 4)}"
    local vm_ws_path="${SB_VM_WS_PATH:-}"
    [[ -z "$vm_ws_path" ]] && vm_ws_path="/$(gen_random_alnum 24)"
    echo "$public_key_reality" > /etc/s-box/public.key

    load_hy2_runtime_from_server_files
    local hy2_obfs_password="${SB_HY2_OBFS_PASSWORD:-}"
    local hy2_masquerade_url="${SB_HY2_MASQUERADE_URL:-https://www.cloudflare.com/}"
    if [[ -z "$hy2_obfs_password" ]]; then
        hy2_obfs_password="$(gen_random_alnum 20)"
        upsert_kv_file "$SB_ENV_FILE" "SB_HY2_OBFS_PASSWORD" "$hy2_obfs_password"
        load_runtime_env
    fi

    v4v6
    if [[ -n $v4 ]]; then ipv="prefer_ipv4"; else ipv="prefer_ipv6"; fi

    # 保存內部端口到環境文件（供後續函數讀取）
    upsert_kv_file "$SB_ENV_FILE" "INT_PORT_REALITY" "$int_port_reality"
    upsert_kv_file "$SB_ENV_FILE" "INT_PORT_VMWS" "$int_port_vmws"
    upsert_kv_file "$SB_ENV_FILE" "INT_PORT_HTTPS_BACKEND" "$int_port_https_backend"
    upsert_kv_file "$SB_ENV_FILE" "SB_VM_WS_PATH" "$vm_ws_path"
    upsert_kv_file "$SB_ENV_FILE" "SB_REALITY_SNI" "$reality_sni"

cat > /etc/s-box/sb.json <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      { "type": "local", "tag": "local" }
    ]
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-sb",
      "listen": "127.0.0.1",
      "listen_port": ${int_port_reality},
      "users": [{"uuid": "${uuid}", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "${reality_sni}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${reality_sni}", "server_port": 443 },
          "private_key": "${private_key_reality}",
          "short_id": ["${short_id}"]
        }
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-sb",
      "listen": "127.0.0.1",
      "listen_port": ${int_port_vmws},
      "users": [{"uuid": "${uuid}", "alterId": 0}],
      "transport": {
        "type": "ws",
        "path": "${vm_ws_path}",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-sb",
      "listen": "::",
      "listen_port": ${port_hy2},
      "users": [{"password": "${uuid}"}],
      "ignore_client_bandwidth": false,
      "obfs": {
        "type": "salamander",
        "password": "${hy2_obfs_password}"
      },
      "masquerade": "${hy2_masquerade_url}",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/s-box/cert.crt",
        "key_path": "/etc/s-box/private.key"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic5-sb",
      "listen": "::",
      "listen_port": ${port_tu},
      "users": [{"uuid": "${uuid}", "password": "${uuid}"}],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/s-box/cert.crt",
        "key_path": "/etc/s-box/private.key"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "default_domain_resolver": {
      "server": "local",
      "strategy": "${ipv}"
    },
    "rules": [
      { "ip_is_private": true, "outbound": "block" }
    ]
  }
}
EOF
}

validate_v3_runtime_health(){
    local attempt
    for attempt in {1..5}; do
        /etc/s-box/sing-box check -c /etc/s-box/sb.json >/dev/null 2>&1 || { sleep 2; continue; }
        systemctl is-active --quiet sing-box >/dev/null 2>&1 || { sleep 2; continue; }
        systemctl is-active --quiet nginx >/dev/null 2>&1 || { sleep 2; continue; }
        nginx -t >/dev/null 2>&1 || { sleep 2; continue; }
        [[ -s /etc/s-box/cert.crt && -s /etc/s-box/private.key ]] || { sleep 2; continue; }
        [[ -f "$SB_NGINX_STREAM_CONF" && -f "$SB_NGINX_HTTP_CONF" ]] || { sleep 2; continue; }
        ss -tlnp 2>/dev/null | grep -q ":443 " || { sleep 2; continue; }
        ss -tlnp 2>/dev/null | grep -q ":${int_port_reality} " || { sleep 2; continue; }
        ss -tlnp 2>/dev/null | grep -q ":${int_port_vmws} " || { sleep 2; continue; }
        ss -ulnp 2>/dev/null | grep -q ":${port_hy2} " || { sleep 2; continue; }
        ss -ulnp 2>/dev/null | grep -q ":${port_tu} " || { sleep 2; continue; }
        return 0
    done
    return 1
}

cleanup_legacy_split_firewall_rules(){
    local old_vless_port="$1" old_vmess_port="$2"
    [[ -n "$old_vless_port" ]] && ufw delete allow "${old_vless_port}/tcp" >/dev/null 2>&1 || true
    [[ -n "$old_vmess_port" ]] && ufw delete allow "${old_vmess_port}/tcp" >/dev/null 2>&1 || true
}

preserve_external_udp_ports_for_migration(){
    local keep_hy2="$1" keep_tu="$2"
    local all_ports=() port
    for i in {1..3}; do
        port=$(pick_unused_high_port "$keep_hy2" "$keep_tu" "${all_ports[@]}") || {
            red "遷移端口生成失敗：未能在合理嘗試次數內找到空閒端口。"
            return 1
        }
        all_ports+=("$port")
    done
    int_port_reality=${all_ports[0]}
    int_port_vmws=${all_ports[1]}
    int_port_https_backend=${all_ports[2]}
    port_hy2="$keep_hy2"
    port_tu="$keep_tu"
    port_vl_re=$int_port_reality
    port_vm_ws=$int_port_vmws
    green "  保留外部 UDP 端口 — HY2: $port_hy2/udp, TUIC: $port_tu/udp"
    green "  新內部端口 — Reality: $int_port_reality, VMess-WS: $int_port_vmws, HTTPS-backend: $int_port_https_backend"
}

collect_v2_runtime_state(){
    local cfg="/etc/s-box/sb.json" existing_uuid="" old_vm_ws_path="" old_reality_sni=""
    [[ -f "$cfg" ]] || { red "未找到舊版 /etc/s-box/sb.json"; return 1; }
    command -v jq >/dev/null 2>&1 || { red "缺少 jq，無法遷移舊版配置"; return 1; }

    existing_uuid=$(jq -r '.inbounds[]? | select(.type=="vless") | .users[0].uuid // empty' "$cfg" 2>/dev/null)
    private_key_reality=$(jq -r '.inbounds[]? | select(.type=="vless") | .tls.reality.private_key // empty' "$cfg" 2>/dev/null)
    short_id=$(jq -r '.inbounds[]? | select(.type=="vless") | .tls.reality.short_id[0] // empty' "$cfg" 2>/dev/null)
    old_reality_sni=$(jq -r '.inbounds[]? | select(.type=="vless") | .tls.reality.handshake.server // .tls.server_name // empty' "$cfg" 2>/dev/null)
    public_key_reality=$(head -n1 /etc/s-box/public.key 2>/dev/null | tr -d '\r\n ')
    old_vm_ws_path=$(jq -r '.inbounds[]? | select(.type=="vmess") | .transport.path // empty' "$cfg" 2>/dev/null)
    SB_MIGRATE_OLD_VLESS_PORT=$(jq -r '.inbounds[]? | select(.type=="vless") | .listen_port // empty' "$cfg" 2>/dev/null)
    SB_MIGRATE_OLD_VMESS_PORT=$(jq -r '.inbounds[]? | select(.type=="vmess") | .listen_port // empty' "$cfg" 2>/dev/null)
    port_hy2=$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .listen_port // empty' "$cfg" 2>/dev/null)
    port_tu=$(jq -r '.inbounds[]? | select(.type=="tuic") | .listen_port // empty' "$cfg" 2>/dev/null)
    old_hy2_obfs_password=$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .obfs.password // empty' "$cfg" 2>/dev/null)
    old_hy2_masquerade_url=$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .masquerade // empty' "$cfg" 2>/dev/null)
    domain_name=$(head -n1 /etc/s-box/domain.log 2>/dev/null | tr -d '\r\n ')

    [[ -n "$existing_uuid" && -n "$private_key_reality" && -n "$short_id" && -n "$public_key_reality" && -n "$domain_name" ]] || {
        red "舊版配置缺少必要識別信息，無法安全遷移。"
        return 1
    }
    is_valid_port_number "$port_hy2" || { red "舊版 Hysteria2 端口無效"; return 1; }
    is_valid_port_number "$port_tu" || { red "舊版 TUIC 端口無效"; return 1; }

    upsert_kv_file "$SB_ENV_FILE" "SB_PREVIOUS_UUID" "$existing_uuid"
    if is_true "$SB_ROTATE_UUID_ON_MIGRATE"; then
        uuid=""
        yellow "遷移策略：將輪換 UUID，不沿用舊 UUID。"
    else
        uuid="$existing_uuid"
        yellow "遷移策略：沿用舊 UUID。"
    fi

    [[ -n "$old_hy2_obfs_password" ]] && upsert_kv_file "$SB_ENV_FILE" "SB_HY2_OBFS_PASSWORD" "$old_hy2_obfs_password"
    [[ -n "$old_hy2_masquerade_url" ]] && upsert_kv_file "$SB_ENV_FILE" "SB_HY2_MASQUERADE_URL" "$old_hy2_masquerade_url"
    if [[ -n "$old_reality_sni" ]]; then
        upsert_kv_file "$SB_ENV_FILE" "SB_PREVIOUS_REALITY_SNI" "$old_reality_sni"
        if is_true "$SB_ROTATE_REALITY_SNI_ON_MIGRATE"; then
            reality_sni=""
            upsert_kv_file "$SB_ENV_FILE" "SB_REALITY_SNI" ""
            yellow "遷移策略：將輪換 Reality SNI，不沿用舊 SNI。"
        else
            reality_sni="$old_reality_sni"
            upsert_kv_file "$SB_ENV_FILE" "SB_REALITY_SNI" "$old_reality_sni"
            yellow "遷移策略：沿用舊 Reality SNI。"
        fi
    else
        reality_sni=""
    fi
    if [[ -n "$old_vm_ws_path" ]]; then
        upsert_kv_file "$SB_ENV_FILE" "SB_PREVIOUS_VM_WS_PATH" "$old_vm_ws_path"
        if is_true "$SB_ROTATE_VM_WS_PATH_ON_MIGRATE"; then
            upsert_kv_file "$SB_ENV_FILE" "SB_VM_WS_PATH" ""
            yellow "遷移策略：將輪換 VMess-WS 路徑，不沿用舊路徑。"
        else
            upsert_kv_file "$SB_ENV_FILE" "SB_VM_WS_PATH" "$old_vm_ws_path"
            yellow "遷移策略：沿用舊 VMess-WS 路徑。"
        fi
    fi
    upsert_kv_file "$SB_ENV_FILE" "SB_CLIENT_HOST_MODE" "${SB_CLIENT_HOST_MODE:-ip_prefer}"
    load_runtime_env
}

collect_v3_runtime_state(){
    local cfg="/etc/s-box/sb.json" existing_uuid="" old_vm_ws_path="" old_reality_sni="" https_backend_port=""
    [[ -f "$cfg" ]] || { red "未找到當前 /etc/s-box/sb.json"; return 1; }
    command -v jq >/dev/null 2>&1 || { red "缺少 jq，無法讀取當前 v3 配置"; return 1; }

    load_runtime_env
    existing_uuid=$(jq -r '.inbounds[]? | select(.type=="vless") | .users[0].uuid // empty' "$cfg" 2>/dev/null)
    private_key_reality=$(jq -r '.inbounds[]? | select(.type=="vless") | .tls.reality.private_key // empty' "$cfg" 2>/dev/null)
    short_id=$(jq -r '.inbounds[]? | select(.type=="vless") | .tls.reality.short_id[0] // empty' "$cfg" 2>/dev/null)
    old_reality_sni=$(jq -r '.inbounds[]? | select(.type=="vless") | .tls.reality.handshake.server // .tls.server_name // empty' "$cfg" 2>/dev/null)
    public_key_reality=$(head -n1 /etc/s-box/public.key 2>/dev/null | tr -d '\r\n ')
    old_vm_ws_path=$(jq -r '.inbounds[]? | select(.type=="vmess") | .transport.path // empty' "$cfg" 2>/dev/null)
    int_port_reality=$(jq -r '.inbounds[]? | select(.type=="vless") | .listen_port // empty' "$cfg" 2>/dev/null)
    int_port_vmws=$(jq -r '.inbounds[]? | select(.type=="vmess") | .listen_port // empty' "$cfg" 2>/dev/null)
    port_hy2=$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .listen_port // empty' "$cfg" 2>/dev/null)
    port_tu=$(jq -r '.inbounds[]? | select(.type=="tuic") | .listen_port // empty' "$cfg" 2>/dev/null)
    old_hy2_obfs_password=$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .obfs.password // empty' "$cfg" 2>/dev/null)
    old_hy2_masquerade_url=$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .masquerade // empty' "$cfg" 2>/dev/null)
    domain_name=$(head -n1 /etc/s-box/domain.log 2>/dev/null | tr -d '\r\n ')

    https_backend_port="${INT_PORT_HTTPS_BACKEND:-}"
    if ! is_valid_port_number "$https_backend_port" && [[ -f "$SB_NGINX_STREAM_CONF" ]]; then
        https_backend_port=$(awk '/upstream https_backend/{flag=1; next} flag && /server 127\.0\.0\.1:/{gsub(/.*127\.0\.0\.1:/, "", $0); gsub(/;.*/, "", $0); print; exit}' "$SB_NGINX_STREAM_CONF" 2>/dev/null)
    fi
    if ! is_valid_port_number "$https_backend_port" && [[ -f "$SB_NGINX_HTTP_CONF" ]]; then
        https_backend_port=$(awk '/listen 127\.0\.0\.1:/{gsub(/.*127\.0\.0\.1:/, "", $0); gsub(/ ssl;.*/, "", $0); print; exit}' "$SB_NGINX_HTTP_CONF" 2>/dev/null)
    fi
    int_port_https_backend="$https_backend_port"

    [[ -n "$existing_uuid" && -n "$private_key_reality" && -n "$short_id" && -n "$public_key_reality" && -n "$domain_name" ]] || {
        red "當前 v3 配置缺少必要識別信息，無法安全做身份歸一化。"
        return 1
    }
    is_valid_port_number "$int_port_reality" || { red "當前 Reality 內部端口無效"; return 1; }
    is_valid_port_number "$int_port_vmws" || { red "當前 VMess-WS 內部端口無效"; return 1; }
    is_valid_port_number "$int_port_https_backend" || { red "當前 HTTPS backend 內部端口無效"; return 1; }
    is_valid_port_number "$port_hy2" || { red "當前 Hysteria2 端口無效"; return 1; }
    is_valid_port_number "$port_tu" || { red "當前 TUIC 端口無效"; return 1; }

    uuid="$existing_uuid"
    [[ -n "$old_hy2_obfs_password" ]] && upsert_kv_file "$SB_ENV_FILE" "SB_HY2_OBFS_PASSWORD" "$old_hy2_obfs_password"
    [[ -n "$old_hy2_masquerade_url" ]] && upsert_kv_file "$SB_ENV_FILE" "SB_HY2_MASQUERADE_URL" "$old_hy2_masquerade_url"
    if [[ -n "$old_reality_sni" ]]; then
        upsert_kv_file "$SB_ENV_FILE" "SB_PREVIOUS_REALITY_SNI" "$old_reality_sni"
    fi
    if [[ -n "$old_vm_ws_path" ]]; then
        upsert_kv_file "$SB_ENV_FILE" "SB_PREVIOUS_VM_WS_PATH" "$old_vm_ws_path"
    fi
    reality_sni=""
    upsert_kv_file "$SB_ENV_FILE" "SB_REALITY_SNI" ""
    upsert_kv_file "$SB_ENV_FILE" "SB_VM_WS_PATH" ""
    yellow "身份歸一化：將重新選定 Reality SNI 並輪換 VMess-WS 路徑。"
    load_runtime_env
}

migrate_v2_to_v3(){
    local snapshot_dir=""
    detect_install_layout
    if [[ "$SB_INSTALL_LAYOUT" != "v2_split" ]]; then
        yellow "當前不是舊版分端口架構，無需執行 v2 -> v3 遷移。"
        return 0
    fi

    snapshot_dir=$(create_rollout_snapshot "migrate-v2") || { red "建立遷移快照失敗。"; return 1; }
    green "已建立遷移快照: ${snapshot_dir}"
    begin_rollback_guard "$snapshot_dir" "v2 -> v3 遷移"
    install_depend || return 1
    assert_latest_stable_supported "Sing-box 遷移" || return 1
    collect_v2_runtime_state || return 1
    preserve_external_udp_ports_for_migration "$port_hy2" "$port_tu" || return 1
    init_hy2_transport_env
    ensure_domain_and_cert
    maybe_align_hy2_masquerade_with_site
    maybe_prompt_telegram_on_install
    inssb
    gen_config
    setup_nginx_sni
    setup_firewall
    sbservice || return 1
    setup_hy2_port_hopping
    if ! validate_v3_runtime_health; then
        red "遷移後健康檢查失敗，正在自動回滾。"
        restore_rollout_snapshot "$snapshot_dir"
        end_rollback_guard
        return 1
    fi
    cleanup_legacy_split_firewall_rules "$SB_MIGRATE_OLD_VLESS_PORT" "$SB_MIGRATE_OLD_VMESS_PORT"
    end_rollback_guard
    lnsb || yellow "快捷命令 /usr/bin/sb 更新失敗，但遷移已完成。"
    green "v2 -> v3 遷移完成。"
    yellow "快照保留於: ${snapshot_dir}"
    post_install_check
}

normalize_v3_identity(){
    local snapshot_dir=""
    detect_install_layout
    require_v3_layout "v3 身份歸一化" || return 1

    snapshot_dir=$(create_rollout_snapshot "normalize-v3-identity") || { red "建立身份歸一化快照失敗。"; return 1; }
    green "已建立身份歸一化快照: ${snapshot_dir}"
    begin_rollback_guard "$snapshot_dir" "v3 身份歸一化"
    assert_latest_stable_supported "v3 身份歸一化" || return 1
    collect_v3_runtime_state || return 1
    init_hy2_transport_env
    gen_config
    setup_nginx_sni
    setup_firewall
    sbservice || return 1
    setup_hy2_port_hopping
    if ! validate_v3_runtime_health; then
        red "身份歸一化後健康檢查失敗，正在自動回滾。"
        restore_rollout_snapshot "$snapshot_dir"
        end_rollback_guard
        return 1
    fi
    end_rollback_guard
    lnsb || yellow "快捷命令 /usr/bin/sb 更新失敗，但身份歸一化已完成。"
    green "v3 身份歸一化完成。"
    yellow "快照保留於: ${snapshot_dir}"
    post_install_check
}

# ==================== 服務管理 ====================

sbservice(){
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
After=network.target nss-lookup.target nginx.service
Wants=nginx.service
[Service]
User=root
WorkingDirectory=/root
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
NoNewPrivileges=true
ReadWritePaths=/etc/s-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStartPre=/etc/s-box/sing-box check -c /etc/s-box/sb.json
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || return 1
    systemctl enable sing-box >/dev/null 2>&1 || return 1
    systemctl restart sing-box || return 1
}

# ==================== HY2 端口跳躍服務 ====================

create_hy2_hop_script(){
    ensure_sbox_dir
    cat > "$SB_HY2_HOP_SCRIPT" <<'EOF'
#!/bin/bash
set -u
ENV_FILE="/etc/s-box/sb.env"
read_env(){ local key="$1"; [[ -f "$ENV_FILE" ]] || return 0; grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-; }
is_valid_port(){ local p="$1"; [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )); }
clean_bin_chain(){ local bin="$1" chain="SB_HY2_HOP"; command -v "$bin" >/dev/null 2>&1 || return 0; "$bin" -t nat -F "$chain" >/dev/null 2>&1 || true; while "$bin" -t nat -C PREROUTING -j "$chain" >/dev/null 2>&1; do "$bin" -t nat -D PREROUTING -j "$chain" >/dev/null 2>&1 || break; done; while "$bin" -t nat -C OUTPUT -m addrtype --dst-type LOCAL -j "$chain" >/dev/null 2>&1; do "$bin" -t nat -D OUTPUT -m addrtype --dst-type LOCAL -j "$chain" >/dev/null 2>&1 || break; done; "$bin" -t nat -X "$chain" >/dev/null 2>&1 || true; }
apply_bin_chain(){ local bin="$1" start="$2" end="$3" target="$4" chain="SB_HY2_HOP"; command -v "$bin" >/dev/null 2>&1 || return 0; "$bin" -t nat -N "$chain" >/dev/null 2>&1 || true; "$bin" -t nat -C PREROUTING -j "$chain" >/dev/null 2>&1 || "$bin" -t nat -A PREROUTING -j "$chain"; "$bin" -t nat -C OUTPUT -m addrtype --dst-type LOCAL -j "$chain" >/dev/null 2>&1 || "$bin" -t nat -A OUTPUT -m addrtype --dst-type LOCAL -j "$chain"; "$bin" -t nat -F "$chain" >/dev/null 2>&1 || true; "$bin" -t nat -A "$chain" -p udp --dport "${start}:${end}" -j REDIRECT --to-ports "$target" >/dev/null 2>&1 || true; }
mode="${1:-apply}"
if [[ "$mode" == "remove" ]]; then clean_bin_chain iptables; clean_bin_chain ip6tables; exit 0; fi
hop_enabled="$(read_env SB_HY2_HOP_ENABLED)"; hop_start="$(read_env SB_HY2_HOP_START)"; hop_end="$(read_env SB_HY2_HOP_END)"; target_port="$(read_env SB_HY2_HOP_TARGET_PORT)"
[[ -z "$hop_enabled" ]] && hop_enabled="0"
if [[ "$hop_enabled" != "1" ]]; then clean_bin_chain iptables; clean_bin_chain ip6tables; exit 0; fi
if ! is_valid_port "$hop_start" || ! is_valid_port "$hop_end" || ! is_valid_port "$target_port" || (( hop_start >= hop_end )); then exit 1; fi
apply_bin_chain iptables "$hop_start" "$hop_end" "$target_port"; apply_bin_chain ip6tables "$hop_start" "$hop_end" "$target_port"; exit 0
EOF
    chmod +x "$SB_HY2_HOP_SCRIPT"
}

setup_hy2_port_hopping(){
    load_hy2_runtime_from_server_files; create_hy2_hop_script
    cat > "/etc/systemd/system/${SB_HY2_HOP_SERVICE}" <<EOF
[Unit]
Description=Sing-box HY2 Port Hopping Redirect Rules
After=network-online.target
Wants=network-online.target
Before=sing-box.service
[Service]
Type=oneshot
ExecStart=${SB_HY2_HOP_SCRIPT} apply
ExecStop=${SB_HY2_HOP_SCRIPT} remove
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    if [[ "${SB_HY2_HOP_ENABLED:-0}" == "1" ]]; then
        systemctl enable "${SB_HY2_HOP_SERVICE}" >/dev/null 2>&1 || true
        systemctl restart "${SB_HY2_HOP_SERVICE}" >/dev/null 2>&1 && green "HY2 端口跳躍規則已啟用。" || yellow "HY2 端口跳躍規則啟用失敗。"
    else
        systemctl disable --now "${SB_HY2_HOP_SERVICE}" >/dev/null 2>&1 || true
    fi
}

cleanup_hy2_port_hopping(){
    [[ -x "$SB_HY2_HOP_SCRIPT" ]] && "$SB_HY2_HOP_SCRIPT" remove >/dev/null 2>&1 || true
    systemctl disable --now "${SB_HY2_HOP_SERVICE}" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${SB_HY2_HOP_SERVICE}" "$SB_HY2_HOP_SCRIPT"
    systemctl daemon-reload >/dev/null 2>&1 || true
}

# ==================== 防火牆（精簡：只暴露 443 + UDP）====================

setup_firewall(){
    green "正在配置防火牆 (UFW - 安全模式)..."
    load_hy2_runtime_from_server_files
    local hy2_hop_range=""
    if [[ "${SB_HY2_HOP_ENABLED:-0}" == "1" ]] && is_valid_port_number "${SB_HY2_HOP_START:-}" && is_valid_port_number "${SB_HY2_HOP_END:-}" && (( SB_HY2_HOP_START < SB_HY2_HOP_END )); then
        hy2_hop_range="${SB_HY2_HOP_START}:${SB_HY2_HOP_END}"
    fi

    # 檢測 SSH 端口
    local ssh_port=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        ssh_port=$(echo "$SSH_CONNECTION" | awk '{print $4}' 2>/dev/null)
    fi
    if [[ -z "$ssh_port" ]]; then ssh_port=$(ss -tlnp 2>/dev/null | grep -E 'sshd|"ssh"' | awk '{print $4}' | grep -oE '[0-9]+$' | head -1); fi
    if [[ -z "$ssh_port" ]] && command -v sshd >/dev/null 2>&1; then ssh_port=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}'); fi
    if [[ -z "$ssh_port" ]]; then ssh_port=$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | tail -n 1 | awk '{print $2}'); fi
    [[ -z "$ssh_port" ]] && ssh_port=22
    green "將放行 SSH 端口: $ssh_port"

    local ufw_status=$(ufw status 2>/dev/null | head -1)
    if echo "$ufw_status" | grep -qi "inactive"; then
        green "UFW 未啟用，進行首次安全配置..."
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
    else
        green "UFW 已啟用，採用增量模式..."
    fi

    # 只暴露必要端口（新架構：TCP 只有 443）
    ufw_allow "$ssh_port" tcp "SSH"
    ufw_allow 80 tcp "ACME"
    ufw_allow 443 tcp "HTTPS+Reality"
    # 不再暴露 Reality/VMess 高位 TCP 端口（它們只聽 127.0.0.1）
    ufw_allow "$port_hy2" udp "Hysteria2"
    [[ -n "$hy2_hop_range" ]] && ufw_allow "$hy2_hop_range" udp "HY2-PortHop"
    ufw_allow "$port_tu" udp "TUIC5"

    cat > /etc/s-box/firewall_ports.log <<EOF
# 本腳本添加的防火牆端口（卸載時自動清理）
# v3.0 Nginx SNI 架構 — TCP 只暴露 443
SSH_PORT=$ssh_port
HY2_PORT=$port_hy2
HY2_HOP_RANGE=$hy2_hop_range
TUIC_PORT=$port_tu
INT_PORT_REALITY=$int_port_reality
INT_PORT_VMWS=$int_port_vmws
INT_PORT_HTTPS_BACKEND=$int_port_https_backend
EOF

    local ufw_was_inactive=false
    echo "$ufw_status" | grep -qi "inactive" && ufw_was_inactive=true
    if [[ "$ufw_was_inactive" == "true" ]]; then
        yellow "  ⚠️  UFW 防火牆目前未啟用"
        local enable_ufw_choice=""
        if is_true "$SB_BATCH_MODE"; then
            is_true "$SB_ENABLE_UFW" && enable_ufw_choice="y" || enable_ufw_choice="n"
        else
            readp "   是否啟用 UFW 防火牆？[y/N]: " enable_ufw_choice
        fi
        if [[ "$enable_ufw_choice" =~ ^[Yy]$ ]]; then
            echo "y" | ufw enable >/dev/null 2>&1; green "UFW 已啟用。"
        else
            yellow "已跳過 UFW 啟用。手動啟用: ufw enable"
        fi
    fi

    green "防火牆配置完成！"
    echo -e "  SSH: ${yellow}$ssh_port${plain}"
    echo -e "  HTTPS+Reality: ${yellow}443/tcp${plain} (Nginx SNI 分流)"
    echo -e "  Hysteria2: ${yellow}$port_hy2/udp${plain}"
    [[ -n "$hy2_hop_range" ]] && echo -e "  HY2-PortHop: ${yellow}${hy2_hop_range}/udp -> $port_hy2${plain}"
    echo -e "  TUIC5: ${yellow}$port_tu/udp${plain}"
    yellow "  注意：Reality 和 VMess-WS 不再暴露獨立端口，統一走 443"
}

# ==================== Telegram 通知 ====================

configure_telegram_notify(){
    ensure_sbox_dir; load_runtime_env
    echo; yellow "Telegram 通知用於：證書自動續期失敗時提醒。"
    readp "啟用 Telegram 失敗通知？[y/N]: " tele_enable_choice
    if [[ ! "${tele_enable_choice:-n}" =~ ^[Yy]$ ]]; then
        upsert_kv_file "$SB_ENV_FILE" "SB_TELEGRAM_ENABLED" "0"; load_runtime_env; green "已關閉 Telegram 通知。"; return 0
    fi
    local token_input chat_input thread_input
    readp "Bot Token [留空沿用]: " token_input; token_input=$(echo "$token_input" | tr -d '[:space:]'); [[ -z "$token_input" ]] && token_input="$SB_TELEGRAM_BOT_TOKEN"
    [[ -z "$token_input" ]] && { red "Bot Token 不能為空。"; return 1; }
    readp "Chat ID [留空沿用]: " chat_input; chat_input=$(echo "$chat_input" | tr -d '[:space:]'); [[ -z "$chat_input" ]] && chat_input="$SB_TELEGRAM_CHAT_ID"
    [[ -z "$chat_input" ]] && { red "Chat ID 不能為空。"; return 1; }
    readp "Thread ID (可選，none 清空): " thread_input; thread_input=$(echo "$thread_input" | tr -d '[:space:]')
    [[ "$thread_input" == "none" || "$thread_input" == "NONE" ]] && thread_input="" || { [[ -z "$thread_input" ]] && thread_input="$SB_TELEGRAM_THREAD_ID"; }
    upsert_kv_file "$SB_ENV_FILE" "SB_TELEGRAM_ENABLED" "1"
    upsert_kv_file "$SB_ENV_FILE" "SB_TELEGRAM_BOT_TOKEN" "$token_input"
    upsert_kv_file "$SB_ENV_FILE" "SB_TELEGRAM_CHAT_ID" "$chat_input"
    upsert_kv_file "$SB_ENV_FILE" "SB_TELEGRAM_THREAD_ID" "$thread_input"
    load_runtime_env; green "Telegram 參數已寫入。"
}

maybe_prompt_telegram_on_install(){
    local tele_enabled_saved
    tele_enabled_saved="$(read_kv_from_file "$SB_ENV_FILE" "SB_TELEGRAM_ENABLED" 2>/dev/null || true)"
    if [[ -n "$tele_enabled_saved" ]]; then load_runtime_env; return 0; fi
    if is_true "$SB_BATCH_MODE"; then
        upsert_kv_file "$SB_ENV_FILE" "SB_TELEGRAM_ENABLED" "0"
        load_runtime_env
        return 0
    fi
    echo; yellow "可選設置：證書續期失敗 Telegram 通知。"
    readp "現在配置？[y/N]: " tele_init_choice
    if [[ "${tele_init_choice:-n}" =~ ^[Yy]$ ]]; then configure_telegram_notify
    else
        upsert_kv_file "$SB_ENV_FILE" "SB_TELEGRAM_ENABLED" "0"; load_runtime_env; green "已跳過。"
    fi
}

# ==================== 安裝後自檢 ====================

post_install_check(){
    green "正在進行安裝後自檢..."

    # Nginx 狀態
    if systemctl is-active --quiet nginx; then green "✅ Nginx 服務已運行"
    else red "❌ Nginx 服務未運行"; systemctl status nginx --no-pager -n 5; fi

    # sing-box 狀態
    if systemctl is-active --quiet sing-box; then green "✅ sing-box 服務已運行"
    else red "❌ sing-box 服務未運行"; systemctl status sing-box --no-pager -n 5; fi

    # 443 端口由 Nginx 監聽
    if ss -tlnp 2>/dev/null | grep -q ":443 "; then green "✅ TCP 443 正在監聽 (Nginx)"
    else yellow "⚠️ TCP 443 未監聽"; fi

    # 內部端口
    if ss -tlnp 2>/dev/null | grep -q ":${int_port_reality} "; then green "✅ Reality 內部端口 $int_port_reality 監聽中"
    else yellow "⚠️ Reality 內部端口 $int_port_reality 未監聽"; fi

    if ss -tlnp 2>/dev/null | grep -q ":${int_port_vmws} "; then green "✅ VMess-WS 內部端口 $int_port_vmws 監聽中"
    else yellow "⚠️ VMess-WS 內部端口 $int_port_vmws 未監聽"; fi

    # UDP 端口
    if ss -ulnp 2>/dev/null | grep -q ":${port_hy2} "; then green "✅ HY2 UDP $port_hy2 監聽中"
    else yellow "⚠️ HY2 UDP $port_hy2 未監聽"; fi

    if ss -ulnp 2>/dev/null | grep -q ":${port_tu} "; then green "✅ TUIC UDP $port_tu 監聽中"
    else yellow "⚠️ TUIC UDP $port_tu 未監聽"; fi

    # 配置校驗
    if /etc/s-box/sing-box check -c /etc/s-box/sb.json >/dev/null 2>&1; then green "✅ 配置文件校驗通過"
    else red "❌ 配置文件校驗失敗"; /etc/s-box/sing-box check -c /etc/s-box/sb.json; fi
}

# ==================== 訂閱鏈接（端口統一 443）====================

sbshare(){
    require_v3_layout "節點輸出" || return 1
    v4v6
    domain=$(cat /etc/s-box/domain.log 2>/dev/null | head -n1 | tr -d '\r\n ')
    uuid=$(jq -r '.inbounds[0].users[0].uuid' /etc/s-box/sb.json 2>/dev/null)
    port_hy=$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
    port_tu_share=$(jq -r '.inbounds[]? | select(.type=="tuic") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
    pk=$(cat /etc/s-box/public.key 2>/dev/null)
    sid=$(jq -r '.inbounds[0].tls.reality.short_id[0]' /etc/s-box/sb.json 2>/dev/null)
    vm_path=$(jq -r '.inbounds[]? | select(.type=="vmess") | .transport.path' /etc/s-box/sb.json 2>/dev/null)
    reality_sni_share=$(jq -r '.inbounds[0].tls.reality.handshake.server // .inbounds[0].tls.server_name // empty' /etc/s-box/sb.json 2>/dev/null)
    [[ -z "$reality_sni_share" ]] && reality_sni_share="$reality_sni"

    host="$(select_client_host "$domain" "$v4")" || { red "節點地址策略 ${SB_CLIENT_HOST_MODE:-ip_prefer} 無可用目標。"; return 1; }
    load_hy2_runtime_from_server_files
    local domain_enc reality_sni_enc hy2_obfs_password_enc hy2_query="security=tls&alpn=h3&insecure=0" hy2_hop_range=""
    domain_enc="$(uri_encode "$domain")"
    reality_sni_enc="$(uri_encode "$reality_sni_share")"
    hy2_query="${hy2_query}&sni=${domain_enc}"
    if [[ "${SB_HY2_OBFS_ENABLED:-1}" == "1" && -n "${SB_HY2_OBFS_PASSWORD:-}" ]]; then
        hy2_obfs_password_enc="$(uri_encode "${SB_HY2_OBFS_PASSWORD}")"
        hy2_query="${hy2_query}&obfs=salamander&obfs-password=${hy2_obfs_password_enc}"
    fi
    if [[ "${SB_HY2_HOP_ENABLED:-0}" == "1" ]] && is_valid_port_number "${SB_HY2_HOP_START:-}" && is_valid_port_number "${SB_HY2_HOP_END:-}" && (( SB_HY2_HOP_START < SB_HY2_HOP_END )); then
        hy2_hop_range="${SB_HY2_HOP_START}-${SB_HY2_HOP_END}"
    fi

    # 所有 TCP 協議端口統一為 443
    vl_link="vless://$uuid@$host:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$reality_sni_enc&fp=chrome&pbk=$pk&sid=$sid&type=tcp&headerType=none#VL-$hostname"

    vm_json=$(jq -n \
        --arg add "$host" --arg aid "0" --arg host "$domain" --arg id "$uuid" \
        --arg net "ws" --arg path "$vm_path" --arg port "443" \
        --arg ps "VM-$hostname" --arg tls "tls" --arg sni "$domain" \
        --arg type "none" --arg v "2" \
        '{add:$add, aid:$aid, host:$host, id:$id, net:$net, path:$path, port:$port, ps:$ps, tls:$tls, sni:$sni, type:$type, v:$v}')
    vm_link="vmess://$(echo -n "$vm_json" | base64_no_wrap)"

    hy_link="hysteria2://$uuid@$host:$port_hy?${hy2_query}#HY2-$hostname"
    hy_hop_link=""
    [[ -n "$hy2_hop_range" ]] && hy_hop_link="hysteria2://$uuid@$host:$hy2_hop_range?${hy2_query}#HY2-Hop-$hostname"
    tu_link="tuic://$uuid:$uuid@$host:$port_tu_share?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$domain_enc&allow_insecure=0#TU5-$hostname"

    echo "$vl_link" > /etc/s-box/sub.txt
    echo "$vm_link" >> /etc/s-box/sub.txt
    echo "$hy_link" >> /etc/s-box/sub.txt
    [[ -n "$hy_hop_link" ]] && echo "$hy_hop_link" >> /etc/s-box/sub.txt
    echo "$tu_link" >> /etc/s-box/sub.txt
    chmod 600 /etc/s-box/sub.txt

    sub_base64=$(base64_no_wrap < /etc/s-box/sub.txt)

    echo
    white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo -e "域名: ${green}$domain${plain}"
    echo -e "UUID: ${green}$uuid${plain}"
    echo -e "架構: ${green}Nginx SNI 分流 (v3.0)${plain}"
    echo
    echo -e "VLESS-Reality: ${yellow}443/tcp${plain} (SNI: $reality_sni_share)"
    echo -e "VMess-WS-TLS:  ${yellow}443/tcp${plain} (Nginx 反代)"
    echo -e "Hysteria2:     ${yellow}$port_hy/udp${plain}"
    [[ -n "$hy2_hop_range" ]] && echo -e "HY2-Hop:       ${yellow}${hy2_hop_range}/udp${plain}"
    echo -e "TUIC V5:       ${yellow}$port_tu_share/udp${plain}"
    echo
    red "🚀【 聚合訂閱 (Base64) 】"
    echo -e "${yellow}$sub_base64${plain}"
    white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
}

# ==================== 客戶端配置（雙軌：1.11.4 + 最新穩定版）====================

show_client_conf_latest(){
    local host="$1" domain="$2" uuid="$3" pk="$4" sid="$5" reality_sni_client="$6" vm_path="$7" port_hy="$8" port_tu_client="$9" hy2_server_ports="${10}" hy2_hop_interval="${11}" hy2_obfs_password="${12}" cert_pin="${13}"
    local current_stable_label="${14}"
    local standard_tls_pin_json="" vless_utls_json=', "utls": { "enabled": true, "fingerprint": "'"${SB_REALITY_UTLS_FINGERPRINT:-chrome}"'" }' vmess_utls_json="" hy2_hop_json="" dns_hijack_rule_json="" dns_bypass_guard_rule_json=""

    [[ -n "$cert_pin" ]] && standard_tls_pin_json=', "certificate_public_key_sha256": ["'"$cert_pin"'"]'
    if [[ "${SB_CLIENT_UTLS_ENABLED:-0}" == "1" ]]; then
        vmess_utls_json=', "utls": { "enabled": true, "fingerprint": "'"${SB_VMESS_UTLS_FINGERPRINT:-chrome}"'" }'
    fi
    if [[ "$hy2_server_ports" =~ ^[0-9]+[:\-][0-9]+$ ]]; then
        hy2_hop_json=', "server_ports": ["'"$hy2_server_ports"'"], "hop_interval": "'"$hy2_hop_interval"'"'
    fi
    dns_hijack_rule_json="$(build_dns_hijack_rule_json)"
    dns_bypass_guard_rule_json="$(build_dns_bypass_guard_rule_json)"

    green "══════════════════════════════════════════════════════════════"
    green "  Sing-box ${current_stable_label} 客戶端配置 (最新穩定版軌)"
    green "  ✅ 所有 TCP 協議統一走 443"
    green "  🌐 節點地址策略: ${SB_CLIENT_HOST_MODE:-ip_prefer} (${host})"
    yellow "  ⚠️ Reality 客戶端固定啟用 uTLS（內核要求）"
    [[ "${SB_CLIENT_UTLS_ENABLED:-0}" == "1" ]] && yellow "  ⚠️ 已啟用 uTLS（默認不建議）"
    green "══════════════════════════════════════════════════════════════"
    echo
    cat <<EOF
{
  "log": { "disabled": false, "level": "info", "timestamp": true },
  "experimental": {
    "cache_file": { "enabled": true, "path": "cache.db", "store_fakeip": true },
    "clash_api": { "external_controller": "127.0.0.1:9090", "external_ui": "ui", "secret": "", "default_mode": "rule" }
  },
  "dns": {
    "servers": [
      { "type": "tls", "tag": "proxydns", "server": "8.8.8.8", "server_port": 853, "detour": "select" },
      { "type": "https", "tag": "localdns", "server": "223.5.5.5", "path": "/dns-query" },
      { "type": "fakeip", "tag": "dns_fakeip", "inet4_range": "198.18.0.0/15", "inet6_range": "fc00::/18" }
    ],
    "rules": [
      { "clash_mode": "Global", "server": "proxydns" },
      { "clash_mode": "Direct", "server": "localdns" },
      { "rule_set": "geosite-cn", "server": "localdns" },
      { "rule_set": "geosite-geolocation-!cn", "server": "proxydns" },
      { "rule_set": "geosite-geolocation-!cn", "query_type": ["A", "AAAA"], "server": "dns_fakeip" }
    ],
    "independent_cache": true,
    "final": "proxydns"
  },
  "inbounds": [
    { "type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30", "fd00::1/126"], "auto_route": true, "strict_route": true }
  ],
  "outbounds": [
    { "tag": "select", "type": "selector", "default": "auto", "outbounds": ["auto", "vless-sb", "hy2-sb", "tuic5-sb", "vmess-sb"], "interrupt_exist_connections": false },
    {
      "type": "vless", "tag": "vless-sb", "server": "$host", "server_port": 443,
      "uuid": "$uuid", "flow": "xtls-rprx-vision", "network": "tcp", "packet_encoding": "xudp",
      "tls": {
        "enabled": true, "server_name": "$reality_sni_client"${vless_utls_json},
        "reality": { "enabled": true, "public_key": "$pk", "short_id": "$sid" }
      }
    },
    {
      "type": "vmess", "tag": "vmess-sb", "server": "$host", "server_port": 443,
      "uuid": "$uuid", "security": "auto", "alter_id": 0, "packet_encoding": "packetaddr", "network": "tcp",
      "tls": { "enabled": true, "server_name": "$domain", "insecure": false${standard_tls_pin_json}${vmess_utls_json} },
      "transport": { "type": "ws", "path": "$vm_path", "headers": { "Host": ["$domain"] } }
    },
    {
      "type": "hysteria2", "tag": "hy2-sb", "server": "$host", "server_port": $port_hy,
      "network": "udp"${hy2_hop_json},
      "password": "$uuid",
      "obfs": { "type": "salamander", "password": "$hy2_obfs_password" },
      "tls": { "enabled": true, "server_name": "$domain", "insecure": false${standard_tls_pin_json}, "alpn": ["h3"] }
    },
    {
      "type": "tuic", "tag": "tuic5-sb", "server": "$host", "server_port": $port_tu_client,
      "uuid": "$uuid", "password": "$uuid", "congestion_control": "bbr", "udp_relay_mode": "native", "network": "udp",
      "tls": { "enabled": true, "server_name": "$domain", "insecure": false${standard_tls_pin_json}, "alpn": ["h3"] }
    },
    { "tag": "direct", "type": "direct" },
    { "tag": "auto", "type": "urltest", "outbounds": ["vless-sb", "hy2-sb", "tuic5-sb", "vmess-sb"], "url": "https://www.gstatic.com/generate_204", "interval": "3m", "tolerance": 150, "interrupt_exist_connections": false }
  ],
  "route": {
    "default_domain_resolver": { "server": "proxydns" },
    "rule_set": [
      { "tag": "geosite-geolocation-!cn", "type": "remote", "format": "binary", "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/geolocation-!cn.srs", "download_detour": "select", "update_interval": "1d" },
      { "tag": "geosite-cn", "type": "remote", "format": "binary", "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/geolocation-cn.srs", "download_detour": "select", "update_interval": "1d" },
      { "tag": "geoip-cn", "type": "remote", "format": "binary", "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/cn.srs", "download_detour": "select", "update_interval": "1d" }
    ],
    "auto_detect_interface": true,
    "final": "select",
    "rules": [
      { "inbound": "tun-in", "action": "sniff" },
${dns_hijack_rule_json}${dns_bypass_guard_rule_json}
      { "ip_is_private": true, "outbound": "direct" },
      { "clash_mode": "Direct", "outbound": "direct" },
      { "clash_mode": "Global", "outbound": "select" },
      { "rule_set": "geoip-cn", "outbound": "direct" },
      { "rule_set": "geosite-cn", "outbound": "direct" },
      { "rule_set": "geosite-geolocation-!cn", "outbound": "select" }
    ]
  }
}
EOF
    echo
    yellow "📌 適用於: Sing-box ${current_stable_label}"
}

show_client_conf_legacy(){
    local host="$1" domain="$2" uuid="$3" pk="$4" sid="$5" reality_sni_client="$6" vm_path="$7" port_hy="$8" port_tu_client="$9" hy2_server_ports="${10}" hy2_hop_interval="${11}" hy2_obfs_password="${12}"
    local legacy_vless_utls_json=', "utls": { "enabled": true, "fingerprint": "'"${SB_REALITY_UTLS_FINGERPRINT:-chrome}"'" }'
    local legacy_vmess_utls_json=', "utls": { "enabled": true, "fingerprint": "'"${SB_VMESS_UTLS_FINGERPRINT:-chrome}"'" }'
    local hy2_hop_json="" dns_hijack_rule_json="" dns_bypass_guard_rule_json=""
    if [[ "$hy2_server_ports" =~ ^[0-9]+[:\-][0-9]+$ ]]; then
        hy2_hop_json=', "server_ports": ["'"$hy2_server_ports"'"], "hop_interval": "'"$hy2_hop_interval"'"'
    fi
    dns_hijack_rule_json="$(build_dns_hijack_rule_json)"
    dns_bypass_guard_rule_json="$(build_dns_bypass_guard_rule_json)"

    green "══════════════════════════════════════════════════════════════"
    green "  Sing-box ${SB_LEGACY_CLIENT_VERSION} 客戶端配置 (legacy 軌)"
    green "  📱 適用於 iOS SFI / 舊版 1.11.4"
    green "  🌐 節點地址策略: ${SB_CLIENT_HOST_MODE:-ip_prefer} (${host})"
    yellow "  ⚠️ legacy Reality 固定啟用 uTLS（1.11.4 必需）"
    green "══════════════════════════════════════════════════════════════"
    echo
    cat <<EOF
{
  "log": { "disabled": false, "level": "info", "timestamp": true },
  "experimental": {
    "cache_file": { "enabled": true, "path": "cache.db", "store_fakeip": true }
  },
  "dns": {
    "servers": [
      { "tag": "proxydns", "address": "https://8.8.8.8/dns-query", "detour": "select" },
      { "tag": "localdns", "address": "https://223.5.5.5/dns-query", "detour": "direct" },
      { "tag": "dns_fakeip", "address": "fakeip" }
    ],
    "rules": [
      { "clash_mode": "Global", "server": "proxydns" },
      { "clash_mode": "Direct", "server": "localdns" },
      { "rule_set": "geosite-cn", "server": "localdns" },
      { "rule_set": "geosite-geolocation-!cn", "query_type": ["A", "AAAA"], "server": "dns_fakeip" },
      { "rule_set": "geosite-geolocation-!cn", "server": "proxydns" }
    ],
    "fakeip": { "enabled": true, "inet4_range": "198.18.0.0/15", "inet6_range": "fc00::/18" },
    "independent_cache": true,
    "final": "proxydns"
  },
  "inbounds": [
    {
      "type": "tun", "tag": "tun-in",
      "address": ["172.19.0.1/30", "fd00::1/126"],
      "auto_route": true, "strict_route": true,
      "sniff": true, "sniff_override_destination": true,
      "domain_strategy": "prefer_ipv4"
    }
  ],
  "outbounds": [
    { "tag": "select", "type": "selector", "default": "auto", "outbounds": ["auto", "vless-sb", "hy2-sb", "tuic5-sb", "vmess-sb"], "interrupt_exist_connections": false },
    {
      "type": "vless", "tag": "vless-sb", "server": "$host", "server_port": 443,
      "uuid": "$uuid", "flow": "xtls-rprx-vision", "network": "tcp",
      "tls": {
        "enabled": true, "server_name": "$reality_sni_client"${legacy_vless_utls_json},
        "reality": { "enabled": true, "public_key": "$pk", "short_id": "$sid" }
      }
    },
    {
      "type": "vmess", "tag": "vmess-sb", "server": "$host", "server_port": 443,
      "uuid": "$uuid", "security": "auto", "packet_encoding": "packetaddr", "network": "tcp",
      "tls": { "enabled": true, "server_name": "$domain", "insecure": false${legacy_vmess_utls_json} },
      "transport": { "type": "ws", "path": "$vm_path", "headers": { "Host": "$domain" } }
    },
    {
      "type": "hysteria2", "tag": "hy2-sb", "server": "$host", "server_port": $port_hy,
      "network": "udp"${hy2_hop_json},
      "password": "$uuid",
      "obfs": { "type": "salamander", "password": "$hy2_obfs_password" },
      "tls": { "enabled": true, "server_name": "$domain", "insecure": false, "alpn": ["h3"] }
    },
    {
      "type": "tuic", "tag": "tuic5-sb", "server": "$host", "server_port": $port_tu_client,
      "uuid": "$uuid", "password": "$uuid", "congestion_control": "bbr", "udp_relay_mode": "native",
      "udp_over_stream": false, "zero_rtt_handshake": false, "heartbeat": "10s",
      "tls": { "enabled": true, "server_name": "$domain", "insecure": false, "alpn": ["h3"] }
    },
    { "tag": "direct", "type": "direct" },
    {
      "tag": "auto", "type": "urltest",
      "outbounds": ["vless-sb", "hy2-sb", "tuic5-sb", "vmess-sb"],
      "url": "https://www.gstatic.com/generate_204", "interval": "3m", "tolerance": 150,
      "interrupt_exist_connections": false
    }
  ],
  "route": {
    "rule_set": [
      { "tag": "geosite-geolocation-!cn", "type": "remote", "format": "binary", "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/geolocation-!cn.srs", "download_detour": "select", "update_interval": "1d" },
      { "tag": "geosite-cn", "type": "remote", "format": "binary", "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/geolocation-cn.srs", "download_detour": "select", "update_interval": "1d" },
      { "tag": "geoip-cn", "type": "remote", "format": "binary", "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/cn.srs", "download_detour": "select", "update_interval": "1d" }
    ],
    "auto_detect_interface": true,
    "final": "select",
    "rules": [
      { "inbound": "tun-in", "action": "sniff" },
${dns_hijack_rule_json}${dns_bypass_guard_rule_json}
      { "ip_is_private": true, "outbound": "direct" },
      { "clash_mode": "Direct", "outbound": "direct" },
      { "clash_mode": "Global", "outbound": "select" },
      { "rule_set": "geoip-cn", "outbound": "direct" },
      { "rule_set": "geosite-cn", "outbound": "direct" },
      { "rule_set": "geosite-geolocation-!cn", "outbound": "select" }
    ]
  }
}
EOF
    echo
    yellow "📌 適用於: Sing-box ${SB_LEGACY_CLIENT_VERSION}"
}

client_conf(){
    local requested_track="${1:-${SB_CLIENT_CONF_TRACK:-}}"
    local current_stable_label="" cert_pin="" hy2_server_ports="" hy2_hop_interval="" hy2_obfs_password="" ver_choice=""
    require_v3_layout "客戶端配置輸出" || return 1
    [[ ! -f /etc/s-box/sb.json ]] && { red "未找到 /etc/s-box/sb.json"; return; }
    command -v jq >/dev/null 2>&1 || { red "缺少 jq"; return; }
    domain=$(head -n1 /etc/s-box/domain.log 2>/dev/null | tr -d '\r\n ')
    [[ -z "$domain" ]] && { red "未找到域名記錄"; return; }
    uuid=$(jq -r '.inbounds[0].users[0].uuid' /etc/s-box/sb.json 2>/dev/null)
    pk=$(cat /etc/s-box/public.key 2>/dev/null)
    sid=$(jq -r '.inbounds[0].tls.reality.short_id[0]' /etc/s-box/sb.json 2>/dev/null)
    vm_path=$(jq -r '.inbounds[]? | select(.type=="vmess") | .transport.path' /etc/s-box/sb.json 2>/dev/null)
    port_hy=$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
    port_tu_client=$(jq -r '.inbounds[]? | select(.type=="tuic") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
    reality_sni_client=$(jq -r '.inbounds[0].tls.reality.handshake.server // empty' /etc/s-box/sb.json 2>/dev/null)
    [[ -z "$reality_sni_client" ]] && reality_sni_client="$reality_sni"
    [[ -z "$uuid" || -z "$pk" || -z "$sid" || -z "$vm_path" || -z "$port_hy" || -z "$port_tu_client" ]] && { red "服務端配置信息不完整，無法輸出客戶端配置。"; return; }

    current_stable_label="$(stable_track_label)"
    v4v6
    host="$(select_client_host "$domain" "$v4")" || { red "節點地址策略 ${SB_CLIENT_HOST_MODE:-ip_prefer} 無可用目標。"; return 1; }
    load_hy2_runtime_from_server_files
    hy2_server_ports="$port_hy"
    hy2_hop_interval="${SB_HY2_HOP_INTERVAL:-30s}"
    hy2_obfs_password="${SB_HY2_OBFS_PASSWORD:-}"
    if [[ "${SB_HY2_HOP_ENABLED:-0}" == "1" ]] && is_valid_port_number "${SB_HY2_HOP_START:-}" && is_valid_port_number "${SB_HY2_HOP_END:-}" && (( SB_HY2_HOP_START < SB_HY2_HOP_END )); then
        hy2_server_ports="${SB_HY2_HOP_START}:${SB_HY2_HOP_END}"
    fi
    cert_pin=$(calc_cert_public_key_sha256 /etc/s-box/cert.crt 2>/dev/null || true)

    echo
    green "══════════════════════════════════════════════════════════════"
    green "          請選擇客戶端配置版本"
    green "──────────────────────────────────────────────────────────────"
    yellow "  [1] 📦 ${SB_LEGACY_CLIENT_VERSION} (legacy 軌)"
    yellow "  [2] 🆕 ${current_stable_label} (最新穩定版軌)"
    yellow "  [3] 📚 兩者都顯示"
    yellow "  [0] ↩️  返回主菜單"
    green "══════════════════════════════════════════════════════════════"
    echo
    case "$requested_track" in
        legacy|1) ver_choice="1" ;;
        latest|stable|2) ver_choice="2" ;;
        both|3) ver_choice="3" ;;
        menu|"") ;;
        *)
            red "未知客戶端配置軌道: ${requested_track}"
            yellow "可用值: legacy | latest | both"
            return 1
            ;;
    esac
    if [[ -z "$ver_choice" ]]; then
        if is_true "$SB_BATCH_MODE"; then
            ver_choice="3"
        else
            readp "   選擇版本 [0-3]: " ver_choice
        fi
    fi

    case "$ver_choice" in
        1) show_client_conf_legacy "$host" "$domain" "$uuid" "$pk" "$sid" "$reality_sni_client" "$vm_path" "$port_hy" "$port_tu_client" "$hy2_server_ports" "$hy2_hop_interval" "$hy2_obfs_password" ;;
        2) show_client_conf_latest "$host" "$domain" "$uuid" "$pk" "$sid" "$reality_sni_client" "$vm_path" "$port_hy" "$port_tu_client" "$hy2_server_ports" "$hy2_hop_interval" "$hy2_obfs_password" "$cert_pin" "$current_stable_label" ;;
        3)
            show_client_conf_legacy "$host" "$domain" "$uuid" "$pk" "$sid" "$reality_sni_client" "$vm_path" "$port_hy" "$port_tu_client" "$hy2_server_ports" "$hy2_hop_interval" "$hy2_obfs_password"
            echo
            show_client_conf_latest "$host" "$domain" "$uuid" "$pk" "$sid" "$reality_sni_client" "$vm_path" "$port_hy" "$port_tu_client" "$hy2_server_ports" "$hy2_hop_interval" "$hy2_obfs_password" "$cert_pin" "$current_stable_label"
            ;;
        0|*) return ;;
    esac
}

# ==================== 日誌 + 重啟 + 更新 ====================

view_log(){
    if command -v journalctl >/dev/null 2>&1; then
        green "最近 100 行 sing-box 運行日誌："; journalctl -u sing-box --no-pager -n 100 2>/dev/null || red "未找到日誌。"
    else red "不支持 journalctl。"; fi
}

restart_singbox(){
    green "正在重啟 sing-box 服務..."
    systemctl restart sing-box 2>/dev/null || { red "重啟失敗。"; return; }
    sleep 1
    systemctl is-active --quiet sing-box && green "sing-box 已成功重啟。" || red "sing-box 重啟後狀態異常。"
}

update_core(){
    green "正在更新 Sing-box 內核..."
    assert_latest_stable_supported "Sing-box 內核更新" || return 1
    systemctl stop sing-box 2>/dev/null || true; inssb
    if ! /etc/s-box/sing-box check -c /etc/s-box/sb.json; then red "內核已更新，但配置校驗失敗。"; return; fi
    systemctl restart sing-box 2>/dev/null || { yellow "內核已更新，但重啟失敗。"; return; }
    green "Sing-box 內核已更新並重啟。"
}

cleanup_managed_sbox_files(){
    local path
    local managed_paths=(
        /etc/s-box/sb.json
        /etc/s-box/sb.env
        /etc/s-box/sub.txt
        /etc/s-box/domain.log
        /etc/s-box/public.key
        /etc/s-box/cert.crt
        /etc/s-box/private.key
        /etc/s-box/firewall_ports.log
        /etc/s-box/sing-box
        /etc/s-box/sing-box.tar.gz
        /etc/s-box/sbyg_update
        "$SB_NGINX_MANIFEST"
        /root/geoip.db
        /root/geosite.db
        "$SB_CERT_RENEW_SCRIPT"
        "$SB_CERT_RENEW_STATUS"
        "$SB_CERT_RENEW_LOG"
        "$SB_HY2_HOP_SCRIPT"
    )
    for path in "${managed_paths[@]}"; do
        rm -f "$path"
    done
    rm -rf "$SB_NGINX_BACKUP_DIR"
    rmdir /etc/s-box >/dev/null 2>&1 || true
}

repair_hy2_hop_defaults(){
    detect_install_layout
    require_v3_layout "HY2 hop 默認修復" || return 1
    command -v jq >/dev/null 2>&1 || { red "缺少 jq"; return 1; }
    port_hy2=$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .listen_port // empty' /etc/s-box/sb.json 2>/dev/null)
    port_tu=$(jq -r '.inbounds[]? | select(.type=="tuic") | .listen_port // empty' /etc/s-box/sb.json 2>/dev/null)
    is_valid_port_number "$port_hy2" || { red "未找到有效的 HY2 端口"; return 1; }
    is_valid_port_number "$port_tu" || { red "未找到有效的 TUIC 端口"; return 1; }
    init_hy2_transport_env
    setup_firewall
    setup_hy2_port_hopping
    green "HY2 hop 默認參數已修復。"
    if [[ "${SB_HY2_HOP_ENABLED:-0}" == "1" ]]; then
        green "當前 HY2 hop 範圍: ${SB_HY2_HOP_START}:${SB_HY2_HOP_END} -> ${SB_HY2_HOP_TARGET_PORT} (${SB_HY2_HOP_INTERVAL})"
    else
        yellow "當前 HY2 hop 仍為停用。"
    fi
}

lnsb(){
    local tmp_script="/tmp/sb_update.sh" expected_sha="" downloaded_sha=""
    local target="/usr/bin/sb"
    local backup="/usr/bin/sb.bak"
    local source_url="${UPDATE_URL:-}"
    if [[ -z "$source_url" ]]; then
        if [[ -f "$0" ]]; then
            [[ -f "$target" ]] && cp "$target" "$backup" 2>/dev/null || true
            cp "$0" "$target" || { red "安裝快捷命令失敗。"; return 1; }
            chmod +x "$target"
            green "已從當前腳本安裝快捷命令 /usr/bin/sb。"
            return 0
        fi
        yellow "本地版腳本未配置默認 UPDATE_URL，且無法從當前路徑複製自身。"
        yellow "請先 export UPDATE_URL=<可信腳本地址>，或使用本地文件方式運行此腳本。"
        return 1
    fi
    expected_sha=$(resolve_expected_sha256 "${UPDATE_SHA256:-}" "${UPDATE_SHA256_URL:-}" 2>/dev/null || true)
    if [[ -z "$expected_sha" ]] && ! is_true "$SB_ALLOW_UNVERIFIED_UPDATE"; then
        red "遠程更新已默認要求 SHA256 校驗。"
        yellow "請提供 UPDATE_SHA256 或 UPDATE_SHA256_URL；如確需跳過，顯式設置 SB_ALLOW_UNVERIFIED_UPDATE=1。"
        return 1
    fi
    curl -fsSL -o "$tmp_script" --retry 2 "$source_url" || { red "下載更新失敗。"; return 1; }
    local file_type=$(file -b "$tmp_script" 2>/dev/null)
    if ! echo "$file_type" | grep -qi "shell\|script\|text\|ASCII"; then red "下載的文件不是有效腳本。"; rm -f "$tmp_script"; return 1; fi
    if [[ -n "$expected_sha" ]]; then
        if ! verify_file_sha256 "$tmp_script" "$expected_sha"; then
            downloaded_sha=$(calc_sha256 "$tmp_script" 2>/dev/null || echo "unknown")
            red "更新腳本 SHA256 校驗失敗。"
            red "期望: $expected_sha"
            red "實際: $downloaded_sha"
            rm -f "$tmp_script"
            return 1
        fi
    else
        yellow "警告：本次遠程腳本更新未做 SHA256 校驗。"
    fi
    if ! bash -n "$tmp_script" 2>/dev/null; then red "腳本語法錯誤。"; rm -f "$tmp_script"; return 1; fi
    if ! grep -q "Sing-Box 四協議一鍵安裝腳本" "$tmp_script"; then red "腳本校驗失敗。"; rm -f "$tmp_script"; return 1; fi
    if [[ -f "$target" ]]; then
        cp "$target" "$backup" 2>/dev/null || true
    fi
    chmod +x "$tmp_script"
    mv "$tmp_script" "$target" || {
        red "腳本替換失敗，已保留原文件。"
        rm -f "$tmp_script"
        return 1
    }
    chmod +x "$target"
    green "腳本更新成功。"
}

# ==================== 卸載（含 Nginx 清理）====================

unins(){
    systemctl stop sing-box 2>/dev/null; systemctl disable sing-box 2>/dev/null

    green "清理 Nginx SNI 分流配置..."
    rm -f "$SB_NGINX_STREAM_CONF" "$SB_NGINX_HTTP_CONF"
    if [[ -f "$SB_NGINX_MANIFEST" ]]; then
        restore_recorded_backups
    else
        local nginx_conf_dirs=("/etc/nginx/sites-enabled" "/etc/nginx/conf.d")
        local conf_dir backup_file orig_file
        for conf_dir in "${nginx_conf_dirs[@]}"; do
            [[ -d "$conf_dir" ]] || continue
            for backup_file in "$conf_dir"/*.sb_backup; do
                [[ -f "$backup_file" ]] || continue
                orig_file="${backup_file%.sb_backup}"
                if [[ -f "$orig_file" || ! -e "$orig_file" ]]; then
                    cp -a "$backup_file" "$orig_file" 2>/dev/null || true
                fi
            done
        done
        if [[ -f /etc/nginx/nginx.conf.sb_backup ]]; then cp -a /etc/nginx/nginx.conf.sb_backup /etc/nginx/nginx.conf 2>/dev/null || true; fi
    fi
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    cleanup_recorded_backups

    if [[ -f /etc/s-box/firewall_ports.log ]]; then
        green "清理防火牆規則..."
        local HY2_PORT=$(grep '^HY2_PORT=' /etc/s-box/firewall_ports.log 2>/dev/null | cut -d= -f2)
        local HY2_HOP_RANGE=$(grep '^HY2_HOP_RANGE=' /etc/s-box/firewall_ports.log 2>/dev/null | cut -d= -f2)
        local TUIC_PORT=$(grep '^TUIC_PORT=' /etc/s-box/firewall_ports.log 2>/dev/null | cut -d= -f2)
        [[ -n "$HY2_PORT" ]] && ufw delete allow "$HY2_PORT"/udp >/dev/null 2>&1
        [[ -n "$HY2_HOP_RANGE" ]] && ufw delete allow "$HY2_HOP_RANGE"/udp >/dev/null 2>&1
        [[ -n "$TUIC_PORT" ]] && ufw delete allow "$TUIC_PORT"/udp >/dev/null 2>&1
        yellow "80/443 可能被其他服務使用，是否刪除？"
        readp "   刪除 80/443 規則？[y/N]: " del_common_ports
        [[ "$del_common_ports" =~ ^[Yy]$ ]] && { ufw delete allow 80/tcp >/dev/null 2>&1; ufw delete allow 443/tcp >/dev/null 2>&1; green "已刪除。"; }
    fi

    cleanup_hy2_port_hopping
    cleanup_managed_sbox_files
    rm -f /usr/bin/sb /etc/systemd/system/sing-box.service
    systemctl daemon-reload 2>/dev/null
    green "卸載完成 (BBR/Nginx 保留)。"
}

# ==================== 安裝主流程 ====================

install_singbox(){
    local snapshot_dir=""
    if [[ -f '/etc/systemd/system/sing-box.service' ]]; then
        detect_install_layout
        if [[ "$SB_INSTALL_LAYOUT" == "v2_split" ]]; then
            red "已檢測到舊版分端口架構，請勿直接重裝。"
            yellow "請改用顯式遷移流程：sb migrate-v2"
        else
            red "已安裝 Sing-box，請先卸載。"
        fi
        exit
    fi
    snapshot_dir=$(create_rollout_snapshot "install-v3") || { red "建立安裝快照失敗。"; return 1; }
    green "已建立安裝快照: ${snapshot_dir}"
    begin_rollback_guard "$snapshot_dir" "v3 安裝"
    install_depend || return 1
    assert_latest_stable_supported "Sing-box 安裝" || return 1
    show_install_context
    enable_bbr
    setup_tun
    inssb
    insport || return 1
    init_hy2_transport_env
    ensure_domain_and_cert
    maybe_align_hy2_masquerade_with_site
    maybe_prompt_telegram_on_install
    gen_config
    setup_nginx_sni       # 核心：配置 Nginx SNI 分流
    setup_firewall
    sbservice || return 1
    setup_hy2_port_hopping
    if ! validate_v3_runtime_health; then
        red "安裝後健康檢查失敗，正在自動回滾。"
        restore_rollout_snapshot "$snapshot_dir"
        end_rollback_guard
        return 1
    fi
    end_rollback_guard
    lnsb || yellow "快捷命令 /usr/bin/sb 安裝失敗，但服務已完成部署。"
    green "安裝完成！"
    post_install_check
    sbshare
}

precheck_local_host(){
    detect_install_layout
    v4v6
    echo "HOSTNAME=$(hostname 2>/dev/null || echo unknown)"
    echo "IPV4=${v4:-}"
    echo "LAYOUT=${SB_INSTALL_LAYOUT:-unknown}"
    echo "DOMAIN=$(head -n1 /etc/s-box/domain.log 2>/dev/null | tr -d '\r\n ' || true)"
    echo "SINGBOX_SERVICE=$(systemctl is-active sing-box 2>/dev/null || echo inactive)"
    echo "NGINX_SERVICE=$(systemctl is-active nginx 2>/dev/null || echo inactive)"
    echo "HTTPS_SITES=${SB_PUBLIC_HTTPS_SITES:-$(detect_public_https_sites >/dev/null 2>&1; printf '%s' "${SB_PUBLIC_HTTPS_SITES:-}")}"
    ss -lntup 2>/dev/null | sed 's/^/SS /'
}

print_cli_usage(){
    cat <<'EOF'
Usage:
  sb install
  sb migrate-v2
  sb normalize-v3-identity
  sb rollback-snapshot /root/sb2-rollout-<label>-<timestamp>
  sb precheck
  sb repair-hy2-hop
  sb repair-nginx-backups
  sb update-core
  sb share
  sb client-conf [legacy|latest|both]
EOF
}

run_cli_command(){
    local cmd="${1:-}" arg="${2:-}"
    case "$cmd" in
        install) install_singbox ;;
        migrate-v2) migrate_v2_to_v3 ;;
        normalize-v3-identity) normalize_v3_identity ;;
        rollback-snapshot)
            [[ -n "$arg" ]] || { red "請提供快照目錄。"; return 1; }
            restore_rollout_snapshot "$arg"
            ;;
        precheck) precheck_local_host ;;
        repair-hy2-hop) repair_hy2_hop_defaults ;;
        repair-nginx-backups) repair_nginx_backup_storage ;;
        update-core) update_core ;;
        share) sbshare ;;
        client-conf) client_conf "$arg" ;;
        ""|-h|--help|help) print_cli_usage ;;
        *) red "未知命令: $cmd"; print_cli_usage; return 1 ;;
    esac
}

# ==================== Banner + 菜單 ====================

show_banner(){
    local C1="\\033[38;5;75m" C2="\\033[38;5;111m" C3="\\033[38;5;147m" C4="\\033[38;5;183m" G="\\033[38;5;114m" D="\\033[38;5;245m" W="\\033[1;37m" R="\\033[0m"
    clear; echo
    echo -e "${C1}    ██████╗ ${C2}██████╗ ${C3}███████╗${C4}███████╗  ${C1}███████╗${C2}██╗   ██╗${C3}███████╗${C4}███╗   ██╗${R}"
    echo -e "${C1}    ██╔══██╗${C2}██╔══██╗${C3}██╔════╝${C4}╚══███╔╝  ${C1}██╔════╝${C2}██║   ██║${C3}██╔════╝${C4}████╗  ██║${R}"
    echo -e "${C2}    ██████╔╝${C3}██║  ██║${C3}█████╗  ${C4}  ███╔╝   ${C1}███████╗${C2}██║   ██║${C3}█████╗  ${C4}██╔██╗ ██║${R}"
    echo -e "${C2}    ██╔══██╗${C3}██║  ██║${C4}██╔══╝  ${C4} ███╔╝    ${C1}╚════██║${C2}██║   ██║${C3}██╔══╝  ${C4}██║╚██╗██║${R}"
    echo -e "${C3}    ██████╔╝${C4}██████╔╝${C4}██║     ${C3}███████╗  ${C1}███████║${C2}╚██████╔╝${C3}███████╗${C4}██║ ╚████║${R}"
    echo -e "${C3}    ╚═════╝ ${C4}╚═════╝ ${C4}╚═╝     ${C3}╚══════╝  ${C1}╚══════╝${C2} ╚═════╝ ${C3}╚══════╝${C4}╚═╝  ╚═══╝${R}"
    echo
    echo -e "${W}        Sing-Box Multi-Protocol Installer ${G}v3.0 (Nginx SNI)${R}"
    echo -e "${D}       VLESS-Reality · VMess-WS · Hysteria2 · TUIC V5${R}"
    echo -e "${D}            所有 TCP 統一走 443 · Nginx SNI 分流${R}"
    echo
}

show_status(){
    local C="[0;36m" G="[0;32m" Y="[0;33m" W="[1;37m" R="[0m"
    local sb_status ng_status
    systemctl is-active --quiet sing-box 2>/dev/null && sb_status="${G}● 運行中${R}" || { [[ -f /etc/systemd/system/sing-box.service ]] && sb_status="${Y}○ 已停止${R}" || sb_status="${Y}◌ 未安裝${R}"; }
    systemctl is-active --quiet nginx 2>/dev/null && ng_status="${G}● 運行中${R}" || ng_status="${Y}○ 未運行${R}"
    local sb_ver=""; [[ -x /etc/s-box/sing-box ]] && { sb_ver=$(/etc/s-box/sing-box version 2>/dev/null | head -n1 | awk '{print $NF}'); [[ -n "$sb_ver" ]] && sb_ver=" v${sb_ver}"; }
    v4v6
    local ip_addr="${v4:-N/A}"
    local layout=$(layout_label)
    local sites="none"
    detect_public_https_sites
    [[ -n "$SB_PUBLIC_HTTPS_SITES" ]] && sites="$SB_PUBLIC_HTTPS_SITES"
    if [[ ${#sites} -gt 56 ]]; then sites="${sites:0:56}..."; fi
    echo -e "   ${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
    echo -e "   ${C}Sing-box:${R} $sb_status${sb_ver}    ${C}Nginx:${R} $ng_status    ${C}快捷命令:${R} sb"
    echo -e "   ${C}IP:${R} ${W}${ip_addr}${R}    ${C}架構:${R} ${layout}"
    echo -e "   ${C}站點:${R} ${sites}"
    echo -e "   ${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
}

show_menu(){
    local G="\\033[0;32m" Y="\\033[0;33m" C="\\033[0;36m" W="\\033[1;37m" R="\\033[0m"
    echo
    echo -e "   ${W}◆ 安裝與管理${R}"
    echo -e "   ${G}  [1]${R} 🛠️  安裝 Sing-box (Nginx SNI 分流 / 新裝)"
    echo -e "   ${G}  [2]${R} 🗑️  卸載 Sing-box"
    echo -e "   ${G}  [3]${R} ⬆️  更新 Sing-box 內核"
    echo -e "   ${G}  [9]${R} 🔁 遷移舊版 v2 → v3"
    echo -e "   ${G}  [A]${R} 🧭 歸一化當前 v3 身份 (SNI / VMess-WS 路徑)"
    echo
    echo -e "   ${W}◆ 節點與配置${R}"
    echo -e "   ${C}  [4]${R} 📋 查看節點訂閱鏈接"
    echo -e "   ${C}  [5]${R} 📱 顯示客戶端配置"
    echo
    echo -e "   ${W}◆ 運維操作${R}"
    echo -e "   ${Y}  [6]${R} 📜 查看運行日誌"
    echo -e "   ${Y}  [7]${R} 🔄 重啟 Sing-box"
    echo -e "   ${Y}  [8]${R} 📥 更新此腳本"
    echo
    echo -e "   ${W}◆ 退出${R}"
    echo -e "   ${R}  [0]${R} ❌ 退出腳本"
    echo
}

# 主程序入口
if [[ $# -gt 0 ]]; then
    run_cli_command "$1" "${2:-}"
    exit $?
fi

show_banner
show_status
show_menu

readp "   請選擇操作 [0-9]: " Input
echo

case "$Input" in
    1 ) install_singbox;;
    2 ) unins;;
    3 ) update_core;;
    4 ) sbshare;;
    5 ) client_conf;;
    6 ) view_log;;
    7 ) restart_singbox;;
    8 ) lnsb && green "腳本已更新，請重新運行 sb" && exit;;
    9 ) migrate_v2_to_v3;;
    A|a ) normalize_v3_identity;;
    0 ) green "再見！" && exit 0;;
    * ) yellow "無效選項。" && exit 1
esac
