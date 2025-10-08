#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# --- Logging ---
LOG_FILE="/var/log/sb-yg.log"
mkdir -p "$(dirname "$LOG_FILE")"
: >"$LOG_FILE" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1

trap_error(){
  local code=$?
  local line="$1"
  local cmd="$2"
  echo -e "\033[31m\033[01m[ERROR]\033[0m at line $line while running: '$cmd' (exit code: $code)"
  logger -t "sb-yg.sh" "[ERROR] line $line cmd: $cmd exit: $code"
  exit $code
}
trap 'trap_error $LINENO "$BASH_COMMAND"' ERR

export LANG=en_US.UTF-8
red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; blue='\033[0;36m'; bblue='\033[0;34m'; plain='\033[0m'
red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" "$2";}
base64_n0() { if base64 --help 2>/dev/null | grep -q -- '--wrap'; then base64 --wrap=0; elif base64 --help 2>/dev/null | grep -q -- '-w'; then base64 -w 0; else base64; fi; }

[[ $EUID -ne 0 ]] && yellow "請以root模式運行腳本" && exit

# --- 引導程序 (Bootstrapper) ---
bootstrap_and_exec() {
    local permanent_path="/usr/local/lib/ieduer-sb.sh"
    local shortcut_path="/usr/local/bin/sb"
    local script_url="https://raw.githubusercontent.com/ieduer/bdfz/main/sb.sh"
    if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then red "wget 和 curl 都不可用，无法下载脚本。"; exit 1; fi
    green "首次運行，正在下載腳本到 $permanent_path ..."
    if command -v curl &>/dev/null; then 
        curl -fsSL --retry 3 "$script_url" -o "$permanent_path"
    else 
        wget -qO "$permanent_path" --tries=3 "$script_url"
    fi
    if [[ ! -s "$permanent_path" ]]; then red "腳本下載失敗，請檢查網絡或链接。"; exit 1; fi
    chmod +x "$permanent_path"; ln -sf "$permanent_path" "$shortcut_path"; green "已安裝/更新快捷命令：sb"
    # 使用 exec 替換當前進程，確保新腳本立即生效
    exec "$permanent_path" "$@"
}

# 腳本自我更新函數
upsbyg(){
    yellow "正在嘗試更新腳本..."
    bootstrap_and_exec
}

# 只有當腳本不是從永久路徑執行時，才運行引導程序
# realpath 可能不存在於極簡系統，用 readlink -f 替代
SELF_PATH=""
if command -v realpath >/dev/null; then SELF_PATH=$(realpath "$0"); else SELF_PATH=$(readlink -f "$0"); fi
PERMANENT_PATH="/usr/local/lib/ieduer-sb.sh"
if [[ "$SELF_PATH" != "$PERMANENT_PATH" ]]; then
    bootstrap_and_exec "$@"
    exit 0 # 確保引導程序執行後，舊的臨時進程乾淨退出
fi
# --- 引導結束 ---

# --- 主腳本邏輯開始 ---

hostname=$(hostname)

check_os() {
    if [[ -r /etc/os-release ]]; then 
        . /etc/os-release
        case "${ID,,}" in 
            ubuntu|debian) release="Debian" ;; 
            centos|rhel|rocky|almalinux) release="Centos" ;; 
            alpine) release="alpine" ;; 
            *) red "不支持的系統 (${PRETTY_NAME:-unknown})。" && exit 1 ;;
        esac
        op="${PRETTY_NAME:-$ID}"
    else 
        red "無法識別的作業系統。" && exit 1
    fi
    
    case "$(uname -m)" in 
        armv7l) cpu=armv7 ;; aarch64) cpu=arm64 ;; x86_64) cpu=amd64 ;; 
        *) red "不支持的架構 $(uname -m)" && exit 1 ;; 
    esac
}

check_dependencies() {
    local pkgs=("curl" "openssl" "iptables" "tar" "wget" "jq" "socat" "qrencode" "git" "ss" "lsof" "virt-what" "dig" "xxd")
    local missing_pkgs=()
    for pkg in "${pkgs[@]}"; do if ! command -v "$pkg" &> /dev/null; then missing_pkgs+=("$pkg"); fi; done
    if [ ${#missing_pkgs[@]} -gt 0 ]; then 
        yellow "檢測到缺少依賴: ${missing_pkgs[*]}，將自動安裝。"
        install_dependencies
    fi
}

install_dependencies() {
    green "開始安裝必要的依賴……"
    if [[ x"${release}" == x"alpine" ]]; then 
        apk update && apk add jq openssl iproute2 iputils coreutils git socat iptables grep util-linux dcron tar tzdata qrencode virt-what bind-tools xxd
    else 
        local PKG_MANAGER
        if [ -x "$(command -v apt-get)" ]; then PKG_MANAGER="apt-get"; apt-get update -y; fi
        if [ -x "$(command -v yum)" ]; then PKG_MANAGER="yum"; yum install -y epel-release || true; fi
        if [ -x "$(command -v dnf)" ]; then PKG_MANAGER="dnf"; dnf install -y epel-release || true; fi
        
        $PKG_MANAGER install -y jq cron socat iptables-persistent coreutils util-linux curl openssl tar wget qrencode git iproute2 lsof virt-what dnsutils xxd
        
        if [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
            $PKG_MANAGER install -y cronie iptables-services
            systemctl enable --now cronie 2>/dev/null || true
            systemctl enable --now iptables 2>/dev/null || true
        fi
    fi
    green "依賴安裝完成。"
}

ensure_dirs() { mkdir -p /etc/s-box /root/ieduerca; chmod 700 /etc/s-box /root/ieduerca; }
v4v6(){ v4=$(curl -s4m5 icanhazip.com -k); v6=$(curl -s6m5 icanhazip.com -k); }

configure_firewall(){
    green "正在配置防火牆... (將清除所有現有iptables規則，並設置默認允許)"
    systemctl stop firewalld.service >/dev/null 2>&1 || true; systemctl disable firewalld.service >/dev/null 2>&1 || true
    setenforce 0 >/dev/null 2>&1 || true
    ufw disable >/dev/null 2>&1 || true
    iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT
    iptables -F; iptables -X; iptables -t nat -F; iptables -t nat -X; iptables -t mangle -F; iptables -t mangle -X
    ip6tables -P INPUT ACCEPT; ip6tables -P FORWARD ACCEPT; ip6tables -P OUTPUT ACCEPT
    ip6tables -F; ip6tables -X; ip6tables -t nat -F; ip6tables -t nat -X; ip6tables -t mangle -F; ip6tables -t mangle -X
    if command -v netfilter-persistent &>/dev/null; then netfilter-persistent save >/dev/null 2>&1 || true; fi
    if command -v service &>/dev/null && service iptables save &>/dev/null; then service iptables save >/dev/null 2>&1 || true; fi
    green "防火牆規則已清除，並設置為默認允許。"
}

setup_certificates(){
    green "二、生成並設置相關證書"
    blue "自動生成bing自簽證書中……" && sleep 1
    openssl ecparam -genkey -name prime256v1 -out /etc/s-box/private.key >/dev/null 2>&1
    openssl req -new -x509 -days 36500 -key /etc/s-box/private.key -out /etc/s-box/cert.pem -subj "/CN=www.bing.com" >/dev/null 2>&1
    
    local use_acme=false
    if [[ -f /root/ieduerca/cert.crt && -s /root/ieduerca/cert.crt ]]; then
        yellow "經檢測，之前已申請過Acme域名證書：$(cat /root/ieduerca/ca.log)"
        readp "是否使用 $(cat /root/ieduerca/ca.log) 域名證書？(y/n, 默認n使用自簽): " choice
        [[ "${choice,,}" == "y" ]] && use_acme=true
    else
        readp "如果你有解析完成的域名，是否申請一個Acme域名證書？(y/n, 默認n使用自簽): " choice
        if [[ "${choice,,}" == "y" ]]; then
            if apply_acme_cert; then use_acme=true; else red "Acme證書申請失敗，回退到自簽證書。"; use_acme=false; fi
        fi
    fi

    if $use_acme; then
        local ym_acme=$(cat /root/ieduerca/ca.log)
        jq -n --arg vl_re "apple.com" \
              --arg vm_ws "$ym_acme" \
              --arg hy2 "$ym_acme" \
              --arg tuic "$ym_acme" \
              --arg cert "/root/ieduerca/cert.crt" \
              --arg key "/root/ieduerca/private.key" \
              --argjson tlsyn true \
              '{vl_re: $vl_re, vm_ws: $vm_ws, hy2: $hy2, tuic: $tuic, cert: $cert, key: $key, tlsyn: $tlsyn}' > /tmp/cert_config.json
        blue "Vless-reality SNI: apple.com"
        blue "Vmess-ws, Hysteria-2, Tuic-v5 將使用 $ym_acme 證書並開啟TLS。"
    else
        jq -n --arg vl_re "apple.com" \
              --arg vm_ws "www.bing.com" \
              --arg hy2 "www.bing.com" \
              --arg tuic "www.bing.com" \
              --arg cert "/etc/s-box/cert.pem" \
              --arg key "/etc/s-box/private.key" \
              --argjson tlsyn false \
              '{vl_re: $vl_re, vm_ws: $vm_ws, hy2: $hy2, tuic: $tuic, cert: $cert, key: $key, tlsyn: $tlsyn}' > /tmp/cert_config.json
        blue "Vless-reality SNI: apple.com"
        blue "Vmess-ws 將關閉TLS，Hysteria-2, Tuic-v5 將使用bing自簽證書。"
    fi
}

setup_ports() {
    green "三、設置各個協議端口"
    local ports=()
    for i in {1..4}; do
        while true; do
            local p=$(shuf -i 10000-65535 -n 1)
            if ! [[ " ${ports[@]} " =~ " $p " ]] && ! ss -H -tunlp "sport = :$p" | grep -q .; then
                ports+=("$p"); break
            fi
        done
    done
    
    local tls_enabled=$(jq -r .tlsyn /tmp/cert_config.json)
    local cdn_ports
    if [[ "$tls_enabled" == "true" ]]; then cdn_ports=("2053" "2083" "2087" "2096" "8443"); else cdn_ports=("8080" "8880" "2052" "2082" "2086" "2095"); fi
    local port_vm_ws=${cdn_ports[$RANDOM % ${#cdn_ports[@]}]}
    while ss -H -tunlp "sport = :$port_vm_ws" | grep -q . || [[ " ${ports[@]} " =~ " $port_vm_ws " ]]; do
        port_vm_ws=${cdn_ports[$RANDOM % ${#cdn_ports[@]}]}
    done
    
    jq -n --argjson vl ${ports[0]} --argjson vm $port_vm_ws --argjson hy2 ${ports[1]} --argjson tuic ${ports[2]} \
        '{vl: $vl, vm: $vm, hy2: $hy2, tuic: $tuic}' > /tmp/port_config.json
        
    blue "Vless-reality端口：${ports[0]}"
    blue "Vmess-ws端口：$port_vm_ws"
    blue "Hysteria-2端口：${ports[1]}"
    blue "Tuic-v5端口：${ports[2]}"
}

setup_uuid_and_reality() {
    green "四、生成 UUID 和 Reality 密鑰"
    local uuid=$(/etc/s-box/sing-box generate uuid)
    local key_pair=$(/etc/s-box/sing-box generate reality-keypair)
    local private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    local public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
    local short_id=$(/etc/s-box/sing-box generate rand --hex 4)
    
    jq -n --arg uuid "$uuid" --arg pk "$private_key" --arg pubk "$public_key" --arg sid "$short_id" \
        '{uuid: $uuid, private_key: $pk, public_key: $pubk, short_id: $sid}' > /tmp/user_config.json

    blue "已確認uuid (密碼)：${uuid}"
    blue "Vmess Path：/${uuid}-vm"
    blue "Reality 公鑰和 short_id 已生成。"
}

inssbjsonser(){
    green "正在使用 jq 生成服務端配置文件..."
    local cert_conf="/tmp/cert_config.json"
    local port_conf="/tmp/port_config.json"
    local user_conf="/tmp/user_config.json"
    
    local dns_strategy="prefer_ipv4"
    if [[ -z "$(curl -s4m5 icanhazip.com -k)" ]]; then dns_strategy="prefer_ipv6"; fi
    
    local base_json='{
        "log": { "disabled": false, "level": "info", "timestamp": true },
        "inbounds": [],
        "outbounds": [
            { "type":"direct", "tag":"direct", "domain_strategy": "'$dns_strategy'" },
            { "type": "block", "tag": "block" }
        ],
        "route":{ "rules":[ { "protocol": ["quic", "stun"], "outbound": "block" } ], "final": "direct" }
    }'
    
    local vless_inbound=$(jq -n \
        --argjson port "$(jq -r .vl $port_conf)" \
        --arg uuid "$(jq -r .uuid $user_conf)" \
        --arg sni "$(jq -r .vl_re $cert_conf)" \
        --arg pk "$(jq -r .private_key $user_conf)" \
        --arg sid "$(jq -r .short_id $user_conf)" \
        '{type: "vless", tag: "vless-sb", listen: "::", listen_port: $port, sniff: true, sniff_override_destination: true, users: [{uuid: $uuid, flow: "xtls-rprx-vision"}], tls: {enabled: true, server_name: $sni, reality: {enabled: true, handshake: {server: $sni, server_port: 443}, private_key: $pk, short_id: [$sid]}}}')
    
    local vmess_inbound=$(jq -n \
        --argjson port "$(jq -r .vm $port_conf)" \
        --arg uuid "$(jq -r .uuid $user_conf)" \
        --arg path "/$(jq -r .uuid $user_conf)-vm" \
        --argjson tls_enabled "$(jq -r .tlsyn $cert_conf)" \
        --arg sni "$(jq -r .vm_ws $cert_conf)" \
        --arg cert "$(jq -r .cert $cert_conf)" \
        --arg key "$(jq -r .key $cert_conf)" \
        '
        {
            type: "vmess", tag: "vmess-sb", listen: "::", listen_port: $port, sniff: true, sniff_override_destination: true,
            users: [{uuid: $uuid, alterId: 0}],
            transport: {type: "ws", path: $path, max_early_data: 2048, early_data_header_name: "Sec-WebSocket-Protocol"},
            tls: {enabled: $tls_enabled, server_name: $sni, certificate_path: $cert, key_path: $key}
        }
        | if .tls.enabled then .tls.alpn = ["http/1.1"] else . end
        ')

    local hy2_inbound=$(jq -n \
        --argjson port "$(jq -r .hy2 $port_conf)" \
        --arg pass "$(jq -r .uuid $user_conf)" \
        --arg sni "$(jq -r .hy2 $cert_conf)" \
        --arg cert "$(jq -r .cert $cert_conf)" \
        --arg key "$(jq -r .key $cert_conf)" \
        '{type: "hysteria2", tag: "hy2-sb", listen: "::", listen_port: $port, sniff: true, sniff_override_destination: true, users: [{password: $pass}], tls: {enabled: true, server_name: $sni, alpn: ["h3"], certificate_path: $cert, key_path: $key}}')
        
    local tuic_inbound=$(jq -n \
        --argjson port "$(jq -r .tuic $port_conf)" \
        --arg uuid "$(jq -r .uuid $user_conf)" \
        --arg sni "$(jq -r .tuic $cert_conf)" \
        --arg cert "$(jq -r .cert $cert_conf)" \
        --arg key "$(jq -r .key $cert_conf)" \
        '{type: "tuic", tag: "tuic5-sb", listen: "::", listen_port: $port, sniff: true, sniff_override_destination: true, users: [{uuid: $uuid, password: $uuid}], congestion_control: "bbr", tls: {enabled: true, server_name: $sni, alpn: ["h3"], certificate_path: $cert, key_path: $key}}')

    echo "$base_json" | jq ".inbounds += [$vless_inbound, $vmess_inbound, $hy2_inbound, $tuic_inbound]" > "$sbfiles"
    
    rm -f /tmp/cert_config.json /tmp/port_config.json /tmp/user_config.json
    green "服務端配置文件 /etc/s-box/sb.json 已生成。"
}

sbservice(){
    if [[ x"${release}" == x"alpine" ]]; then
        echo '#!/sbin/openrc-run
description="sing-box service"
command="/etc/s-box/sing-box"
command_args="run -c /etc/s-box/sb.json"
command_background=true
pidfile="/var/run/sing-box.pid"' > /etc/init.d/sing-box
        chmod +x /etc/init.d/sing-box; rc-update add sing-box default
        rc-service sing-box restart
    else
        cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box service
After=network.target nss-lookup.target
[Service]
User=root
WorkingDirectory=/root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload; systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box
    fi
}

post_install_check() {
    green "執行安裝後檢查..."
    if ! /etc/s-box/sing-box check -c "$sbfiles"; then
        red "❌ 配置文件語法錯誤！請檢查 $LOG_FILE 日誌。"; return 1;
    else
        green "✅ 配置文件語法檢查通過。"
    fi
    
    sleep 3
    if systemctl is-active --quiet sing-box || ( [[ x"${release}" == x"alpine" ]] && rc-service sing-box status 2>/dev/null | grep -q 'started' ); then
        green "✅ Sing-box 服務正在運行。"
    else
        red "❌ Sing-box 服務啟動失敗！請使用選項 8 查看日誌。"; return 1;
    fi
    
    blue "檢查端口監聽狀態:"
    local all_ports_listening=true
    local ports_to_check=$(jq -r '.inbounds[].listen_port' "$sbfiles")
    
    for port in $ports_to_check; do
        if ss -H -tunlp "sport = :$port" | grep -q "sing-box"; then
            green "  ✅ 端口 $port 正在被 sing-box 監聽。"
        else
            red "  ❌ 端口 $port 未被監聽！"; all_ports_listening=false
        fi
    done
    
    if $all_ports_listening; then
        green "✅ 所有協議端口均已成功監聽。"; return 0;
    else
        red "❌ 部分協議端口監聽失敗，請檢查日誌和配置。"; return 1;
    fi
}

ipuuid(){
    for i in {1..3}; do if [[ x"${release}" == x"alpine" ]] && rc-service sing-box status 2>/dev/null | grep -q 'started'; then break; elif systemctl -q is-active sing-box; then break; fi; if [ $i -eq 3 ]; then red "Sing-box服務未運行或啟動失敗。"; return 1; fi; sleep 1; done
    v4v6; local menu
    if [[ -n "$v4" && -n "$v6" ]]; then
        readp "雙棧VPS，請選擇IP配置輸出 (1: IPv4, 2: IPv6, 默認2): " menu
        if [[ "$menu" == "1" ]]; then
            server_ip="$v4"; server_ipcl="$v4"
        else
            server_ip="[$v6]"; server_ipcl="$v6"
        fi
    elif [[ -n "$v6" ]]; then
        server_ip="[$v6]"; server_ipcl="$v6"
    elif [[ -n "$v4" ]]; then
        server_ip="$v4"; server_ipcl="$v4"
    else red "无法获取公網 IP 地址。" && return 1; fi
}

display_sharing_info() {
    if ! ipuuid; then red "無法獲取IP信息，跳過分享。"; return 1; fi
    rm -f /etc/s-box/*.txt
    local config=$(cat "$sbfiles")
    local uuid=$(echo "$config" | jq -r '.inbounds[0].users[0].uuid')
    local public_key=$(cat /etc/s-box/public.key 2>/dev/null || true)
    
    # VLESS
    local vl_port=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vless-sb") | .listen_port')
    local vl_sni=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vless-sb") | .tls.server_name')
    local vl_short_id=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vless-sb") | .tls.reality.short_id[0]')
    local vl_link="vless://$uuid@$server_ipcl:$vl_port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$vl_sni&fp=chrome&pbk=$public_key&sid=$vl_short_id&type=tcp&headerType=none#vl-reality-$hostname"
    echo "$vl_link" > /etc/s-box/vl_reality.txt
    
    # VMESS
    local vm_port=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vmess-sb") | .listen_port')
    local vm_path=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vmess-sb") | .transport.path')
    local vm_tls=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vmess-sb") | .tls.enabled')
    local vm_sni=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vmess-sb") | .tls.server_name')
    if [[ "$vm_tls" == "true" ]]; then
        local vm_json="{\"add\":\"$vm_sni\",\"aid\":\"0\",\"host\":\"$vm_sni\",\"id\":\"$uuid\",\"net\":\"ws\",\"path\":\"$vm_path\",\"port\":\"$vm_port\",\"ps\":\"vm-ws-tls-$hostname\",\"tls\":\"tls\",\"sni\":\"$vm_sni\",\"type\":\"none\",\"v\":\"2\"}"
        echo "vmess://$(echo "$vm_json" | base64_n0)" > /etc/s-box/vm_ws_tls.txt
    else
        local vm_json="{\"add\":\"$server_ipcl\",\"aid\":\"0\",\"host\":\"$vm_sni\",\"id\":\"$uuid\",\"net\":\"ws\",\"path\":\"$vm_path\",\"port\":\"$vm_port\",\"ps\":\"vm-ws-$hostname\",\"tls\":\"\",\"type\":\"none\",\"v\":\"2\"}"
        echo "vmess://$(echo "$vm_json" | base64_n0)" > /etc/s-box/vm_ws.txt
    fi
    
    # HYSTERIA2
    local hy2_port=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="hy2-sb") | .listen_port')
    local hy2_sni=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="hy2-sb") | .tls.server_name')
    local hy2_cert_path=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="hy2-sb") | .tls.certificate_path')
    local hy2_insecure hy2_server
    if [[ "$hy2_cert_path" == "/etc/s-box/cert.pem" ]]; then hy2_insecure=true; hy2_server=$server_ipcl; else hy2_insecure=false; hy2_server=$hy2_sni; fi
    local hy2_link="hysteria2://$uuid@$hy2_server:$hy2_port?security=tls&alpn=h3&insecure=$hy2_insecure&sni=$hy2_sni#hy2-$hostname"
    echo "$hy2_link" > /etc/s-box/hy2.txt
    
    # TUIC
    local tu_port=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="tuic5-sb") | .listen_port')
    local tu_sni=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="tuic5-sb") | .tls.server_name')
    local tu_cert_path=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="tuic5-sb") | .tls.certificate_path')
    local tu_insecure tu_server
    if [[ "$tu_cert_path" == "/etc/s-box/cert.pem" ]]; then tu_insecure=true; tu_server=$server_ipcl; else tu_insecure=false; tu_server=$tu_sni; fi
    local tu_link="tuic://$uuid:$uuid@$tu_server:$tu_port?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$tu_sni&allow_insecure=$tu_insecure#tuic5-$hostname"
    echo "$tu_link" > /etc/s-box/tuic5.txt
    
    for f in /etc/s-box/vl_reality.txt /etc/s-box/vm_ws.txt /etc/s-box/vm_ws_tls.txt /etc/s-box/hy2.txt /etc/s-box/tuic5.txt; do
        if [[ -s "$f" ]]; then
            local protocol_name=$(basename "$f" .txt | tr '_' '-'); echo; white "~~~~~~~~~~~~~~~~~"; red "🚀 ${protocol_name^^}"
            local link=$(cat "$f"); echo "鏈接:"; echo -e "${yellow}$link${plain}"; echo "二維碼:"; qrencode -o - -t ANSIUTF8 "$link"
        fi
    done
    cat /etc/s-box/*.txt > /tmp/all_links.txt 2>/dev/null
    if [[ -s /tmp/all_links.txt ]]; then
        local sub_link=$(base64_n0 < /tmp/all_links.txt)
        echo; white "~~~~~~~~~~~~~~~~~"; red "🚀 四合一聚合訂閱"; echo "鏈接:"; echo -e "${yellow}$sub_link${plain}"
    fi
}

install_process() {
    configure_firewall
    inssb
    setup_certificates
    setup_ports
    setup_uuid_and_reality
    inssbjsonser
    sbservice
    
    if post_install_check; then
        display_sharing_info
        green "✅ Sing-box 安裝並配置成功！"
    else
        red "❌ 安裝過程出現問題，請檢查日誌！"
    fi
}

unins(){
    readp "確認卸載Sing-box嗎? [y/n]: " confirm; [[ "${confirm,,}" != "y" ]] && yellow "卸載已取消" && return
    if [[ x"${release}" == x"alpine" ]]; then rc-service sing-box stop 2>/dev/null || true; rc-update del sing-box 2>/dev/null || true; rm -f /etc/init.d/sing-box; else systemctl stop sing-box 2>/dev/null || true; systemctl disable sing-box 2>/dev/null || true; rm -f /etc/systemd/system/sing-box.service; systemctl daemon-reload 2>/dev/null || true; fi
    readp "是否刪除 /etc/s-box 和 /root/ieduerca 目錄與所有配置？(y/n, 默認n): " rmconf; if [[ "${rmconf,,}" == "y" ]]; then rm -rf /etc/s-box /root/ieduerca; green "已刪除配置目錄。"; fi
    readp "是否移除快捷命令 sb？(y/n, 默認n): " rmsb; if [[ "${rmsb,,}" == "y" ]]; then rm -f /usr/local/bin/sb /usr/local/lib/ieduer-sb.sh; green "已移除 sb 命令和腳本文件。"; fi
    green "Sing-box 已卸載完成。"
}

apply_acme_cert() {
    if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then
        green "首次運行，正在安裝acme.sh..."; curl https://get.acme.sh | sh
        if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then red "acme.sh 安裝失敗"; return 1; fi
    fi
    local prev_domain=""; [[ -s "/root/ieduerca/ca.log" ]] && prev_domain=$(cat /root/ieduerca/ca.log 2>/dev/null || true)
    readp "請輸入您解析到本機的域名 (默認: ${prev_domain:-无}): " domain
    [[ -z "$domain" ]] && domain="$prev_domain"
    if [[ -z "$domain" ]]; then red "域名不能為空。"; return 1; fi

    v4v6; local a aaaa; a=$(dig +short A "$domain" 2>/dev/null | head -n1 || true); aaaa=$(dig +short AAAA "$domain" 2>/dev/null | head -n1 || true)
    if [[ (-n "$a" && -n "$v4" && "$a" != "$v4") || (-n "$aaaa" && -n "$v6" && "$aaaa" != "$v6") ]]; then
        yellow "警告: $domain 的 A/AAAA 記錄可能未指向本機 (A=$a AAAA=$aaaa，本機 v4=$v4 v6=$v6)，ACME 可能失敗。"
    fi
    local stopped_services=();
    for svc in nginx apache2 httpd sing-box; do if systemctl is-active --quiet "$svc"; then systemctl stop "$svc" || true; stopped_services+=("$svc"); fi; done

    green "嘗試使用 HTTP-01 模式申請/續期證書..."
    if ! ~/.acme.sh/acme.sh --issue -d "${domain}" --standalone --httpport 80 -k ec-256; then
        red "證書申請失敗。"; for svc in "${stopped_services[@]}"; do systemctl start "$svc" || true; done; return 1;
    fi
    local cert_path="/root/ieduerca";
    ~/.acme.sh/acme.sh --install-cert -d "${domain}" --ecc --key-file "${cert_path}/private.key" --fullchain-file "${cert_path}/cert.crt" --reloadcmd "systemctl restart sing-box"
    echo "${domain}" > "${cert_path}/ca.log"
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade 1>/dev/null 2>&1 || true; ~/.acme.sh/acme.sh --install-cronjob 1>/dev/null 2>&1 || true
    for svc in "${stopped_services[@]}"; do if [[ "$svc" != "sing-box" ]]; then systemctl start "$svc" || true; fi; done
    green "證書申請與安裝成功：${domain}"
    return 0
}

enable_bbr_autonomously() {
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]]; then green "BBR 已啟用。"; return 0; fi
    if [[ $(uname -r | cut -d. -f1) -lt 5 && $(uname -r | cut -d. -f2) -lt 9 && $(uname -r | cut -d. -f1) -eq 4 ]]; then return 0; fi
    green "正在嘗試啟用 BBR..."
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]]; then green "BBR 已成功啟用！"; else red "BBR 啟用失敗。"; fi
}

stclre(){ 
    echo -e "1) 重啟  2) 停止  3) 啟動  0) 返回"; readp "選擇【0-3】：" act
    if [[ x"${release}" == x"alpine" ]]; then 
        case "$act" in 1) rc-service sing-box restart;; 2) rc-service sing-box stop;; 3) rc-service sing-box start;; *) return;; esac
    else 
        case "$act" in 1) systemctl restart sing-box;; 2) systemctl stop sing-box;; 3) systemctl start sing-box;; *) return;; esac
    fi
}

sblog(){ if [[ x"${release}" == x"alpine" ]]; then rc-service sing-box status || true; tail -n 200 /var/log/messages 2>/dev/null || true; else journalctl -u sing-box -e --no-pager -n 100; fi; echo -e "\n[Log saved to $LOG_FILE]"; }

main_menu() {
    clear
    white "Vless-reality, Vmess-ws, Hysteria-2, Tuic-v5 四協議共存腳本 (融合版)"
    white "快捷命令：sb"
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green " 1. 安裝/重裝 Sing-box" 
    green " 2. 卸載 Sing-box"
    white "----------------------------------------------------------------------------------"
    green " 3. 重置/變更配置 (將重新生成所有配置)"
    green " 4. 服務管理 (啟/停/重啟)"
    green " 5. 更新 Sing-box 腳本"
    green " 6. 更新 Sing-box 內核"
    white "----------------------------------------------------------------------------------"
    green " 7. 刷新並查看節點與配置"
    green " 8. 查看 Sing-box 運行日誌"
    green " 9. 申請 Acme 域名證書"
    green "10. 雙棧VPS切換IP配置輸出"
    white "----------------------------------------------------------------------------------"
    green " 0. 退出腳本"
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    if [[ -x '/etc/s-box/sing-box' ]]; then 
        local corev; corev=$(/etc/s-box/sing-box version 2>/dev/null | awk '/version/{print $NF}'); 
        green "Sing-box 核心已安裝：$corev"
        if systemctl is-active --quiet sing-box || ( [[ x"${release}" == x"alpine" ]] && rc-service sing-box status 2>/dev/null | grep -q 'started' ); then
            green "服務狀態：$(green '運行中')"
        else
            yellow "服務狀態：$(yellow '未運行')"
        fi
    else 
        yellow "Sing-box 核心未安裝，請先選 1 。"
    fi
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    readp "請輸入數字【0-10】：" Input
    case "$Input" in  
     1 ) install_process;;
     2 ) unins;;
     3 ) install_process;;
     4 ) stclre;;
     5 ) upsbyg;; 
     6 ) inssb && sbservice && post_install_check && display_sharing_info;;
     7 ) display_sharing_info;;
     8 ) sblog;;
     9 ) apply_acme_cert;;
    10 ) ipuuid && display_sharing_info;;
     * ) exit 
    esac
}

# --- 腳本入口 ---
check_os
check_dependencies
ensure_dirs
main_menu