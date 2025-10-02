#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

trap 'code=$?; echo -e "\033[31m\033[01m[ERROR]\033[0m at line $LINENO while running: ${BASH_COMMAND} (exit $code)"; exit $code' ERR
export LANG=en_US.UTF-8
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;36m'
bblue='\033[0;34m'
plain='\033[0m'

red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" "$2";}

base64_n0() {
    if base64 --help 2>/dev/null | grep -q -- '--wrap'; then base64 --wrap=0; elif base64 --help 2>/dev/null | grep -q -- '-w'; then base64 -w 0; else base64; fi
}

[[ $EUID -ne 0 ]] && yellow "請以root模式運行腳本" && exit
export sbfiles="/etc/s-box/sb.json"
hostname=$(hostname)

# --- 自我複製與快捷方式安裝 ---
self_install() {
    local self_path; self_path="$(realpath "${BASH_SOURCE[0]:-$0}")"
    local permanent_path="/usr/local/lib/ieduer-sb.sh"
    local shortcut_path="/usr/local/bin/sb"

    if [[ "$self_path" != "$permanent_path" ]]; then
        green "首次運行，正在將腳本安裝到 $permanent_path"
        cp "$self_path" "$permanent_path"
        chmod +x "$permanent_path"
        # 重新執行永久位置的腳本
        exec "$permanent_path" "$@"
    fi
    
    if [[ ! -L "$shortcut_path" ]] || [[ "$(readlink -f "$shortcut_path")" != "$permanent_path" ]]; then
        ln -sf "$permanent_path" "$shortcut_path"
        green "已安裝快捷命令：sb"
    fi
}

check_os() {
    if [[ -r /etc/os-release ]]; then . /etc/os-release; case "${ID,,}" in ubuntu|debian) release="Debian" ;; centos|rhel|rocky|almalinux) release="Centos" ;; alpine) release="alpine" ;; *) red "不支持的系統 (${PRETTY_NAME:-unknown})。" && exit 1 ;; esac; op="${PRETTY_NAME:-$ID}"; else red "无法识别的操作系统。" && exit 1; fi
    case "$(uname -m)" in armv7l) cpu=armv7 ;; aarch64) cpu=arm64 ;; x86_64) cpu=amd64 ;; *) red "不支持的架構 $(uname -m)" && exit 1 ;; esac
    vi=$(command -v systemd-detect-virt &>/dev/null && systemd-detect-virt || command -v virt-what &>/dev/null && virt-what || echo "unknown")
}

check_dependencies() {
    local pkgs=("curl" "openssl" "iptables" "tar" "wget" "jq" "socat" "qrencode" "git" "ss" "lsof" "virt-what"); local missing_pkgs=()
    for pkg in "${pkgs[@]}"; do if ! command -v "$pkg" &> /dev/null; then missing_pkgs+=("$pkg"); fi; done
    if [ ${#missing_pkgs[@]} -gt 0 ]; then yellow "檢測到缺少依賴: ${missing_pkgs[*]}，將自動安裝。"; install_dependencies; fi
}

install_dependencies() {
    green "開始安裝必要的依賴……"; if [[ x"${release}" == x"alpine" ]]; then apk update && apk add jq openssl iproute2 iputils coreutils git socat iptables grep util-linux dcron tar tzdata qrencode virt-what
    else if [ -x "$(command -v apt-get)" ]; then apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y jq cron socat iptables-persistent coreutils util-linux curl openssl tar wget qrencode git iproute2 lsof virt-what
    elif [ -x "$(command -v yum)" ] || [ -x "$(command -v dnf)" ]; then local PKG_MANAGER; PKG_MANAGER=$(command -v yum || command -v dnf); $PKG_MANAGER install -y epel-release || true; $PKG_MANAGER install -y jq socat coreutils util-linux curl openssl tar wget qrencode git cronie iptables-services iproute lsof virt-what; systemctl enable --now cronie 2>/dev/null || true; systemctl enable --now iptables 2>/dev/null || true; fi; fi
    green "依賴安裝完成。"
}

ensure_dirs() { mkdir -p /etc/s-box /root/ieduerca; chmod 700 /etc/s-box; }

v4v6(){ v4=$(curl -fsS4m5 --retry 2 icanhazip.com || true); v6=$(curl -fsS6m5 --retry 2 icanhazip.com || true); }

v6_setup(){
    if ! curl -fsS4m5 --retry 2 icanhazip.com >/dev/null 2>&1; then
        yellow "檢測到 純IPV6 VPS，添加NAT64"; echo -e "nameserver 2a00:1098:2b::1\nnameserver 2a00:1098:2c::1" > /etc/resolv.conf
        dns_strategy="ipv6_only"
    else
        dns_strategy="prefer_ipv4"
    fi
}

configure_firewall() {
    green "正在配置防火牆..."; local ports_to_open=("$@")
    for port in "${ports_to_open[@]}"; do if [[ -n "$port" ]]; then iptables -I INPUT -p tcp --dport "$port" -j ACCEPT; iptables -I INPUT -p udp --dport "$port" -j ACCEPT; fi; done
    if command -v netfilter-persistent &>/dev/null; then netfilter-persistent save >/dev/null 2>&1 || true; elif command -v service &>/dev/null && service iptables save &>/dev/null; then service iptables save >/dev/null 2>&1 || true; elif [[ -d /etc/iptables ]]; then iptables-save >/etc/iptables/rules.v4 2>/dev/null || true; fi
    green "防火牆規則已保存。"
}

remove_firewall_rules() {
    if [[ ! -f /etc/s-box/sb.json ]]; then return; fi; green "正在移除防火牆規則..."; local ports_to_close=(); ports_to_close+=($(jq -r '.inbounds[].listen_port' /etc/s-box/sb.json 2>/dev/null))
    for port in "${ports_to_close[@]}"; do if [[ -n "$port" ]]; then iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true; iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true; fi; done
    if command -v netfilter-persistent &>/dev/null; then netfilter-persistent save >/dev/null 2>&1 || true; elif command -v service &>/dev/null && service iptables save &>/dev/null; then service iptables save >/dev/null 2>&1 || true; elif [[ -d /etc/iptables ]]; then iptables-save >/etc/iptables/rules.v4 2>/dev/null || true; fi
    green "防火牆規則已更新。"
}

apply_acme_cert() {
    if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then green "首次運行，正在安裝acme.sh..."; curl https://get.acme.sh | sh; if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then red "acme.sh 安裝失敗"; return 1; fi; fi
    readp "請輸入您解析到本機的域名: " domain; if [ -z "$domain" ]; then red "域名不能為空。"; return 1; fi
    if lsof -i:80 &>/dev/null; then yellow "80端口被佔用，嘗試臨時停止服務..."; systemctl stop nginx 2>/dev/null || true; systemctl stop apache2 2>/dev/null || true; systemctl stop httpd 2>/dev/null || true; fi
    green "正在申請證書..."; ~/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256
    systemctl start nginx 2>/dev/null || true; systemctl start apache2 2>/dev/null || true; systemctl start httpd 2>/dev/null || true
    local cert_path="/root/ieduerca"; if ~/.acme.sh/acme.sh --list | grep -q "$domain"; then mkdir -p "$cert_path"; if ~/.acme.sh/acme.sh --install-cert -d "$domain" --key-file "${cert_path}/private.key" --fullchain-file "${cert_path}/cert.crt" --ecc; then green "證書申請成功"; echo "$domain" > "${cert_path}/ca.log"; return 0; else red "證書安裝失敗。"; return 1; fi; else red "證書申請失敗。"; return 1; fi
}

check_port_in_use() { if ss -H -tunlp "sport = :$1" 2>/dev/null | grep -q .; then return 0; else return 1; fi; }

pick_uncommon_ports(){
    local exclude_ports="22 53 80 123 443"; local chosen=(); while [ ${#chosen[@]} -lt 4 ]; do local p; p=$(shuf -i 20000-65000 -n 1); if echo " $exclude_ports " | grep -q " $p "; then continue; fi; if check_port_in_use "$p"; then continue; fi; local dup=0; for c in "${chosen[@]}"; do [[ "$c" == "$p" ]] && dup=1 && break; done; [[ $dup -eq 1 ]] && continue; chosen+=("$p"); done
    port_vl_re=${chosen[0]}; port_vm_ws=${chosen[1]}; port_hy2=${chosen[2]}; port_tu=${chosen[3]}
}

inssb(){
    ensure_dirs; red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"; green "自動選擇並安裝 Sing-box 最新正式版"
    sbcore=$(curl -Ls https://data.jsdelivr.com/v1/package/gh/SagerNet/sing-box | grep -Eo '"[0-9.]+"' | head -n 1 | tr -d '"'); if [ -z "$sbcore" ]; then red "獲取版本號失敗"; exit 1; fi
    green "正在下載 Sing-box v$sbcore ..."; local sbname="sing-box-$sbcore-linux-$cpu"
    curl -L -o /etc/s-box/sing-box.tar.gz -# --retry 2 "https://github.com/SagerNet/sing-box/releases/download/v$sbcore/$sbname.tar.gz"
    if [[ ! -s '/etc/s-box/sing-box.tar.gz' ]]; then red "下載內核失敗"; exit 1; fi
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box; mv "/etc/s-box/$sbname/sing-box" /etc/s-box; rm -rf "/etc/s-box/sing-box.tar.gz" "/etc/s-box/$sbname"
    if [[ -f '/etc/s-box/sing-box' ]]; then
        chmod +x /etc/s-box/sing-box; blue "成功安裝內核版本：$(/etc/s-box/sing-box version | awk '/version/{print $NF}')"; if /etc/s-box/sing-box version >/dev/null 2>&1; then green "內核校驗通過。"; else red "內核校驗失敗。"; fi
        rebuild_config_and_start
    else red "解壓內核失敗"; exit 1; fi
}

rebuild_config_and_start(){
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"; green "重新生成配置並重啟服務..."
    readp "是否使用ACME證書? (y/n, 默認n使用自簽): " use_acme
    if [[ "${use_acme,,}" == "y" ]]; then
        if [[ ! -f /root/ieduerca/cert.crt || ! -s /root/ieduerca/cert.crt ]]; then yellow "未找到ACME證書，將嘗試申請。"; apply_acme_cert; fi
        if [[ -f /root/ieduerca/cert.crt && -s /root/ieduerca/cert.crt ]]; then
            tlsyn=true; ym_vl_re=apple.com; ym_vm_ws=$(cat /root/ieduerca/ca.log)
            certificatec_vmess_ws='/root/ieduerca/cert.crt'; certificatep_vmess_ws='/root/ieduerca/private.key'
            certificatec_hy2='/root/ieduerca/cert.crt'; certificatep_hy2='/root/ieduerca/private.key'
            certificatec_tuic='/root/ieduerca/cert.crt'; certificatep_tuic='/root/ieduerca/private.key'; blue "將使用ACME證書：$ym_vm_ws"
        else red "ACME證書依然無效，回退到自簽證書。"; tlsyn=false; fi
    else tlsyn=false; fi
    if [[ "$tlsyn" != "true" ]]; then
        tlsyn=false; ym_vl_re=apple.com; ym_vm_ws=www.bing.com
        openssl ecparam -genkey -name prime256v1 -out /etc/s-box/private.key >/dev/null 2>&1
        openssl req -new -x509 -days 36500 -key /etc/s-box/private.key -out /etc/s-box/cert.pem -subj "/CN=www.bing.com" >/dev/null 2>&1
        certificatec_vmess_ws='/etc/s-box/cert.pem'; certificatep_vmess_ws='/etc/s-box/private.key'
        certificatec_hy2='/etc/s-box/cert.pem'; certificatep_hy2='/etc/s-box/private.key'
        certificatec_tuic='/etc/s-box/cert.pem'; certificatep_tuic='/etc/s-box/private.key'; blue "將使用自簽證書。"
    fi
    pick_uncommon_ports; blue "Vless-reality端口：$port_vl_re"; blue "Vmess-ws端口：$port_vm_ws"; blue "Hysteria-2端口：$port_hy2"; blue "Tuic-v5端口：$port_tu"
    uuid=$(/etc/s-box/sing-box generate uuid); generate_reality_materials; v6_setup
    inssbjsonser; configure_firewall "$port_vl_re" "$port_vm_ws" "$port_hy2" "$port_tu"
    if ! sbservice; then return 1; fi
    if ! ipuuid; then red "IP UUID 信息生成失敗，請檢查服務狀態。"; return 1; fi
    gen_clash_sub || true; green "配置已更新並啟動。"
}

generate_reality_materials() {
    ensure_dirs; local pubfile="/etc/s-box/public.key"; local jsonfile="/etc/s-box/reality.json"; local rk pub
    if [[ ! -s "$pubfile" || -z "${private_key:-}" ]]; then
        local out; out=$(mktemp)
        /etc/s-box/sing-box generate reality-keypair >"$out" 2>/dev/null || true
        if jq -e -r '.private_key,.public_key' "$out" >/dev/null 2>&1; then
            private_key=$(jq -r '.private_key' "$out"); jq -r '.public_key' "$out" > "$pubfile"
        else
            private_key=$(awk -F'[: ]+' 'BEGIN{IGNORECASE=1} /Private[ _-]*Key/{print $NF; exit}' "$out")
            pub=$(awk -F'[: ]+' 'BEGIN{IGNORECASE=1} /Public[ _-]*Key/{print $NF; exit}' "$out")
            if [[ -n "$private_key" && -n "$pub" ]]; then printf '%s\n' "$pub" > "$pubfile"; else red "生成 Reality 密鑰失敗。"; exit 1; fi
        fi; rm -f "$out"
    fi
    : "${short_id:=$(head -c 8 /dev/urandom | hexdump -e '1/1 "%02x"' 2>/dev/null || openssl rand -hex 8)}"
    if [[ -n "${private_key:-}" && -s "$pubfile" ]]; then pub=$(cat "$pubfile"); printf '{ "private_key": "%s", "public_key": "%s" }\n' "$private_key" "$pub" > "$jsonfile"; fi
}

inssbjsonser(){
    : "${ym_vl_re:=apple.com}"; : "${tlsyn:=false}"; : "${ym_vm_ws:=www.bing.com}"; : "${certificatec_vmess_ws:=/etc/s-box/cert.pem}"; : "${certificatep_vmess_ws:=/etc/s-box/private.key}"; : "${certificatec_hy2:=/etc/s-box/cert.pem}"; : "${certificatep_hy2:=/etc/s-box/private.key}"; : "${certificatec_tuic:=/etc/s-box/cert.pem}"; : "${certificatep_tuic:=/etc/s-box/private.key}"; : "${uuid:=$(/etc/s-box/sing-box generate uuid)}"
    ensure_dirs; generate_reality_materials
    cat > /etc/s-box/sb.json <<EOF
{
  "log": { "disabled": false, "level": "info", "timestamp": true },
  "dns": { "strategy": "${dns_strategy:-prefer_ipv4}" },
  "inbounds": [
    { "type": "vless", "sniff": true, "sniff_override_destination": true, "tag": "vless-sb", "listen": "::", "listen_port": ${port_vl_re}, "users": [ { "uuid": "${uuid}", "flow": "xtls-rprx-vision" } ], "tls": { "enabled": true, "server_name": "${ym_vl_re}", "reality": { "enabled": true, "handshake": { "server": "${ym_vl_re}", "server_port": 443 }, "private_key": "$private_key", "short_id": ["$short_id"] } } },
    { "type": "vmess", "sniff": true, "sniff_override_destination": true, "tag": "vmess-sb", "listen": "::", "listen_port": ${port_vm_ws}, "users": [ { "uuid": "${uuid}", "alterId": 0 } ], "transport": { "type": "ws", "path": "/${uuid}-vm" }, "tls":{ "enabled": ${tlsyn}, "server_name": "${ym_vm_ws}", "certificate_path": "$certificatec_vmess_ws", "key_path": "$certificatep_vmess_ws" } }, 
    { "type": "hysteria2", "sniff": true, "sniff_override_destination": true, "tag": "hy2-sb", "listen": "::", "listen_port": ${port_hy2}, "users": [ { "password": "${uuid}" } ], "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$certificatec_hy2", "key_path": "$certificatep_hy2" } },
    { "type": "tuic", "sniff": true, "sniff_override_destination": true, "tag": "tuic5-sb", "listen": "::", "listen_port": ${port_tu}, "users": [ { "uuid": "${uuid}", "password": "${uuid}" } ], "congestion_control": "bbr", "tls":{ "enabled": true, "alpn": ["h3"], "certificate_path": "$certificatec_tuic", "key_path": "$certificatep_tuic" } }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": { "rules": [ { "protocol": ["quic", "stun"], "outbound": "block" }, { "outbound": "direct" } ], "final": "direct" }
}
EOF
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
        if ! /etc/s-box/sing-box check -c /etc/s-box/sb.json; then red "配置校驗失敗"; return 1; fi
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
        if ! /etc/s-box/sing-box check -c /etc/s-box/sb.json; then red "配置校驗失敗"; return 1; fi
        systemctl restart sing-box
        for i in {1..5}; do if systemctl -q is-active sing-box; then green "服務已成功啟動。"; return 0; fi; sleep 1; done
        red "服務啟動失敗"; journalctl -u sing-box -n 20 --no-pager || true; return 1;
    fi
}

ipuuid(){
    for i in {1..3}; do
        if [[ x"${release}" == x"alpine" ]]; then if rc-service sing-box status 2>/dev/null | grep -q 'started'; then break; fi
        else if systemctl -q is-active sing-box; then break; fi; fi
        if [ $i -eq 3 ]; then red "Sing-box服務未運行或啟動失敗。"; return 1; fi; sleep 1
    done
    v4v6; local menu
    if [[ -n "$v4" && -n "$v6" ]]; then
        readp "雙棧VPS，請選擇IP配置輸出 (1: IPv4, 2: IPv6, 默認2): " menu
        if [[ "$menu" == "1" ]]; then sbdnsip='tls://8.8.8.8/dns-query'; server_ip="$v4"; server_ipcl="$v4"; else sbdnsip='tls://[2001:4860:4860::8888]/dns-query'; server_ip="[$v6]"; server_ipcl="$v6"; fi
    elif [[ -n "$v6" ]]; then sbdnsip='tls://[2001:4860:4860::8888]/dns-query'; server_ip="[$v6]"; server_ipcl="$v6"
    elif [[ -n "$v4" ]]; then sbdnsip='tls://8.8.8.8/dns-query'; server_ip="$v4"; server_ipcl="$v4"
    else red "无法获取公網 IP 地址。" && return 1; fi
    echo "$sbdnsip" > /etc/s-box/sbdnsip.log; echo "$server_ip" > /etc/s-box/server_ip.log; echo "$server_ipcl" > /etc/s-box/server_ipcl.log
}

result_vl_vm_hy_tu(){
    if [[ -f /root/ieduerca/cert.crt && -s /root/ieduerca/cert.crt ]]; then local ym; ym=$(~/.acme.sh/acme.sh --list | tail -1 | awk '{print $1}' || true); echo "$ym" > /root/ieduerca/ca.log; fi
    rm -rf /etc/s-box/vm_ws.txt /etc/s-box/vm_ws_tls.txt; 
    sbdnsip=$(cat /etc/s-box/sbdnsip.log); server_ip=$(cat /etc/s-box/server_ip.log); server_ipcl=$(cat /etc/s-box/server_ipcl.log); 
    uuid=$(jq -r '.inbounds[0].users[0].uuid' /etc/s-box/sb.json); 
    vl_port=$(jq -r '.inbounds[0].listen_port' /etc/s-box/sb.json); vl_name=$(jq -r '.inbounds[0].tls.server_name' /etc/s-box/sb.json); 
    public_key=$(cat /etc/s-box/public.key); short_id=$(jq -r '.inbounds[0].tls.reality.short_id[0]' /etc/s-box/sb.json); 
    ws_path=$(jq -r '.inbounds[1].transport.path' /etc/s-box/sb.json); vm_port=$(jq -r '.inbounds[1].listen_port' /etc/s-box/sb.json); 
    tls=$(jq -r '.inbounds[1].tls.enabled' /etc/s-box/sb.json); vm_name=$(jq -r '.inbounds[1].tls.server_name' /etc/s-box/sb.json);
    if [[ "$tls" = "false" ]]; then vmadd_local=$server_ipcl; else vmadd_local=$vm_name; fi
    hy2_port=$(jq -r '.inbounds[2].listen_port' /etc/s-box/sb.json); local ym; ym=$(cat /root/ieduerca/ca.log 2>/dev/null || true); 
    hy2_sniname=$(jq -r '.inbounds[2].tls.key_path' /etc/s-box/sb.json); 
    if [[ "$hy2_sniname" = '/etc/s-box/private.key' ]]; then hy2_name=www.bing.com; cl_hy2_ip=$server_ipcl; hy2_ins=true; else hy2_name=$ym; cl_hy2_ip=$ym; hy2_ins=false; fi
    tu5_port=$(jq -r '.inbounds[3].listen_port' /etc/s-box/sb.json); 
    tu5_sniname=$(jq -r '.inbounds[3].tls.key_path' /etc/s-box/sb.json); 
    if [[ "$tu5_sniname" = '/etc/s-box/private.key' ]]; then tu5_name=www.bing.com; cl_tu5_ip=$server_ipcl; tu5_ins=true; else tu5_name=$ym; cl_tu5_ip=$ym; tu5_ins=false; fi
}

resvless(){ echo; white "~~~~~~~~~~~~~~~~~"; vl_link="vless://$uuid@$server_ipcl:$vl_port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$vl_name&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#vl-reality-$hostname"; echo "$vl_link" > /etc/s-box/vl_reality.txt; red "🚀 VLESS-Reality"; echo "链接:"; echo -e "${yellow}$vl_link${plain}"; echo "二维码:"; qrencode -o - -t ANSIUTF8 "$vl_link"; }
resvmess(){ echo; white "~~~~~~~~~~~~~~~~~"; if [[ "$tls" = "false" ]]; then red "🚀 VMess-WS"; vmess_json="{\"add\":\"$server_ipcl\",\"aid\":\"0\",\"host\":\"$vm_name\",\"id\":\"$uuid\",\"net\":\"ws\",\"path\":\"$ws_path\",\"port\":\"$vm_port\",\"ps\":\"vm-ws-$hostname\",\"tls\":\"\",\"type\":\"none\",\"v\":\"2\"}"; vmess_link="vmess://$(echo "$vmess_json" | base64_n0)"; echo "$vmess_link" > /etc/s-box/vm_ws.txt; else red "🚀 VMess-WS-TLS"; vmess_json="{\"add\":\"$vm_name\",\"aid\":\"0\",\"host\":\"$vm_name\",\"id\":\"$uuid\",\"net\":\"ws\",\"path\":\"$ws_path\",\"port\":\"$vm_port\",\"ps\":\"vm-ws-tls-$hostname\",\"tls\":\"tls\",\"sni\":\"$vm_name\",\"type\":\"none\",\"v\":\"2\"}"; vmess_link="vmess://$(echo "$vmess_json" | base64_n0)"; echo "$vmess_link" > /etc/s-box/vm_ws_tls.txt; fi; echo "链接:"; echo -e "${yellow}$vmess_link${plain}"; echo "二维码:"; qrencode -o - -t ANSIUTF8 "$vmess_link"; }
reshy2(){ echo; white "~~~~~~~~~~~~~~~~~"; hy2_link="hysteria2://$uuid@$cl_hy2_ip:$hy2_port?security=tls&alpn=h3&insecure=$hy2_ins&sni=$hy2_name#hy2-$hostname"; echo "$hy2_link" > /etc/s-box/hy2.txt; red "🚀 Hysteria-2"; echo "链接:"; echo -e "${yellow}$hy2_link${plain}"; echo "二维码:"; qrencode -o - -t ANSIUTF8 "$hy2_link"; }
restu5(){ echo; white "~~~~~~~~~~~~~~~~~"; tuic5_link="tuic://$uuid:$uuid@$cl_tu5_ip:$tu5_port?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$tu5_name&allow_insecure=$tu5_ins&allowInsecure=$tu5_ins#tuic5-$hostname"; echo "$tuic5_link" > /etc/s-box/tuic5.txt; red "🚀 TUIC-v5"; echo "链接:"; echo -e "${yellow}$tuic5_link${plain}"; echo "二维码:"; qrencode -o - -t ANSIUTF8 "$tuic5_link"; }

gen_clash_sub(){
    result_vl_vm_hy_tu
    local ws_path_client; ws_path_client=$(echo "$ws_path" | sed 's#^/##')
    local public_key; public_key=$(cat /etc/s-box/public.key 2>/dev/null || true)
    local tag_vless="vless-${hostname}"; local tag_vmess="vmess-${hostname}"; local tag_hy2="hy2-${hostname}"; local tag_tuic="tuic5-${hostname}"
    local sbdnsip; sbdnsip=$(cat /etc/s-box/sbdnsip.log 2>/dev/null); : "${sbdnsip:=tls://8.8.8.8/dns-query}"
    cat > /etc/s-box/clash_sub.json <<EOF
{ "dns": { "servers": [ { "tag": "proxydns", "address": "${sbdnsip}", "detour": "select" }, { "tag": "localdns", "address": "h3://223.5.5.5/dns-query", "detour": "direct" } ] }, "outbounds": [ { "tag": "select", "type": "selector", "default": "auto", "outbounds": ["auto", "${tag_vless}", "${tag_vmess}", "${tag_hy2}", "${tag_tuic}"] }, { "type": "vless", "tag": "${tag_vless}", "server": "${server_ipcl}", "server_port": ${vl_port}, "uuid": "${uuid}", "flow": "xtls-rprx-vision", "tls": { "enabled": true, "server_name": "${vl_name}", "utls": { "enabled": true, "fingerprint": "chrome" }, "reality": { "enabled": true, "public_key": "${public_key}", "short_id": "${short_id}" } } }, { "type": "vmess", "tag": "${tag_vmess}", "server": "${vmadd_local}", "server_port": ${vm_port}, "uuid": "${uuid}", "security": "auto", "transport": { "type": "ws", "path": "${ws_path_client}", "headers": { "Host": ["${vm_name}"] } }, "tls": { "enabled": ${tls}, "server_name": "${vm_name}", "utls": { "enabled": true, "fingerprint": "chrome" } } }, { "type": "hysteria2", "tag": "${tag_hy2}", "server": "${cl_hy2_ip}", "server_port": ${hy2_port}, "password": "${uuid}", "tls": { "enabled": true, "server_name": "${hy2_name}", "insecure": ${hy2_ins}, "alpn": ["h3"] } }, { "type": "tuic", "tag": "${tag_tuic}", "server": "${cl_tu5_ip}", "server_port": ${tu5_port}, "uuid": "${uuid}", "password": "${uuid}", "congestion_control": "bbr", "tls": { "enabled": true, "server_name": "${tu5_name}", "insecure": ${tu5_ins}, "alpn": ["h3"] } }, { "tag": "direct", "type": "direct" }, { "tag": "auto", "type": "urltest", "outbounds": ["${tag_vless}", "${tag_vmess}", "${tag_hy2}", "${tag_tuic}"], "url": "https://www.gstatic.com/generate_204", "interval": "1m" } ] }
EOF
}

clash_sb_share(){
    if ! ipuuid; then red "Sing-box 服務未運行，無法生成分享鏈接。"; return; fi
    result_vl_vm_hy_tu; resvless; resvmess; reshy2; restu5
    readp "是否生成/更新訂閱文件 (for Clash/Mihomo)? (y/n): " gen_sub
    if [[ "${gen_sub,,}" == "y" ]]; then gen_clash_sub; fi
}
sbshare(){ clash_sb_share; }

stclre(){
    echo -e "1) 重啟  2) 停止  3) 啟動  0) 返回"; readp "選擇【0-3】：" act
    if [[ x"${release}" == x"alpine" ]]; then
        case "$act" in 1) rc-service sing-box restart;; 2) rc-service sing-box stop;; 3) rc-service sing-box start;; *) return;; esac
    else
        case "$act" in 1) systemctl restart sing-box;; 2) systemctl stop sing-box;; 3) systemctl start sing-box;; *) return;; esac
    fi
}

sblog(){ if [[ x"${release}" == x"alpine" ]]; then rc-service sing-box status || true; tail -n 200 /var/log/messages 2>/dev/null || true; else journalctl -u sing-box -e --no-pager; fi; }
upsbyg(){ yellow "請從源地址獲取最新腳本覆蓋當前文件。"; }
sbsm(){ blue "安裝內核 → 自動生成默認配置 → 開機自啟。"; blue "可用功能：變更證書/端口、生成訂閱、查看日誌、開啟BBR。"; blue "分享/訂閱輸出：選 7 或 11。產物在 /etc/s-box/"; }

showprotocol(){
    if [[ ! -s /etc/s-box/sb.json ]] || ! jq -e . /etc/s-box/sb.json >/dev/null 2>&1; then yellow "尚未生成運行配置。"; return 0; fi
    local vl_port vm_port hy2_port tu_port; vl_port=$(jq -r '.inbounds[]? | select(.type=="vless") | .listen_port // empty' /etc/s-box/sb.json 2>/dev/null || true); vm_port=$(jq -r '.inbounds[]? | select(.type=="vmess") | .listen_port // empty' /etc/s-box/sb.json 2>/dev/null || true); hy2_port=$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .listen_port // empty' /etc/s-box/sb.json 2>/dev/null || true); tu_port=$(jq -r '.inbounds[]? | select(.type=="tuic") | .listen_port // empty' /etc/s-box/sb.json 2>/dev/null || true)
    [[ -n "$vl_port" ]] && blue "VLESS-REALITY  端口：$vl_port"; [[ -n "$vm_port" ]] && blue "VMESS-WS       端口：$vm_port"; [[ -n "$hy2_port" ]] && blue "HY2            端口：$hy2_port"; [[ -n "$tu_port" ]] && blue "TUIC v5        端口：$tu_port"
}

install_bbr_local() {
    if [[ $vi =~ lxc|openvz ]]; then yellow "當前VPS的架構為 $vi，不支持安裝原版BBR。"; return; fi
    local kernel_version; kernel_version=$(uname -r | cut -d- -f1); if (echo "$kernel_version" "4.9" | awk '{exit !($1 >= $2)}'); then green "當前內核版本 ($kernel_version) 已支持BBR。"; else red "當前內核版本 ($kernel_version) 過低，不支持BBR。"; yellow "請手動升級內核到 4.9 或更高版本。"; return; fi
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then green "BBR 已開啟，無需重複操作。"; return; fi
    green "正在開啟BBR..."; sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf; sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf; echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1; modprobe tcp_bbr 2>/dev/null || true
    if sysctl net.ipv4.tcp_congestion_control | grep -qw "bbr" && sysctl net.ipv4.tcp_available_congestion_control | grep -qw "bbr"; then green "BBR已成功開啟並立即生效，無需重啟！"; else red "BBR開啟可能未成功，請檢查。"; fi
}

unins(){
    readp "確認卸載Sing-box嗎? [y/n]: " confirm; [[ "${confirm,,}" != "y" ]] && yellow "卸載已取消" && return
    remove_firewall_rules
    if [[ x"${release}" == x"alpine" ]]; then rc-service sing-box stop 2>/dev/null || true; rc-update del sing-box 2>/dev/null || true; rm -f /etc/init.d/sing-box; else systemctl stop sing-box 2>/dev/null || true; systemctl disable sing-box 2>/dev/null || true; rm -f /etc/systemd/system/sing-box.service; systemctl daemon-reload 2>/dev/null || true; fi
    readp "是否刪除 /etc/s-box 目錄與所有配置？(y/n, 默認n): " rmconf; if [[ "${rmconf,,}" == "y" ]]; then rm -rf /etc/s-box; green "已刪除 /etc/s-box。"; fi
    readp "是否移除快捷命令 sb？(y/n, 默認n): " rmsb; if [[ "${rmsb,,}" == "y" ]]; then rm -f /usr/local/bin/sb; green "已移除 sb 命令。"; fi
    green "Sing-box 已卸載完成。"
}

main_menu() {
    clear
    white "Vless-reality, Vmess-ws, Hysteria-2, Tuic-v5 四協議共存腳本"
    white "快捷命令：sb"
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green " 1. 安裝/重裝 Sing-box" 
    green " 2. 卸載 Sing-box"
    white "----------------------------------------------------------------------------------"
    green " 3. 重置/變更配置 (交互式)"
    green " 4. 服務管理 (啟/停/重啟)"
    green " 5. 更新 Sing-box 腳本 (手動)"
    green " 6. 更新 Sing-box 內核"
    white "----------------------------------------------------------------------------------"
    green " 7. 刷新並查看節點與配置"
    green " 8. 查看 Sing-box 運行日誌"
    green " 9. 一鍵開啟BBR (無重啟)"
    green "10. 申請 Acme 域名證書"
    green "11. 雙棧VPS切換IP配置輸出"
    white "----------------------------------------------------------------------------------"
    green " 0. 退出腳本"
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    if [[ -x '/etc/s-box/sing-box' ]]; then
        local corev; corev=$(/etc/s-box/sing-box version 2>/dev/null | awk '/version/{print $NF}'); green "Sing-box 核心已安裝：$corev"; showprotocol
    else
        yellow "Sing-box 核心未安裝，請先選 1 。"
    fi
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    readp "請輸入數字【0-11】：" Input
    case "$Input" in  
     1 ) inssb;;
     2 ) unins;;
     3 ) rebuild_config_and_start;;
     4 ) stclre;;
     5 ) upsbyg;; 
     6 ) inssb;;
     7 ) clash_sb_share;;
     8 ) sblog;;
     9 ) install_bbr_local;;
    10 ) apply_acme_cert;;
    11 ) ipuuid && clash_sb_share;;
     * ) exit 
    esac
}

check_os
check_dependencies
ensure_dirs
self_install
main_menu