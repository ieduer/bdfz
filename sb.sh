#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# --- Logging ---
LOG_FILE="/var/log/sb.sh.log"
mkdir -p "$(dirname "$LOG_FILE")"
: >"$LOG_FILE" 2>/dev/null || true
# tee all stdout/stderr to log file
exec > >(tee -a "$LOG_FILE") 2>&1

trap_error(){
  local code=$?
  local line="$1"
  local cmd="$2"
  echo -e "\033[31m\033[01m[ERROR]\033[0m at line $line while running: $cmd (exit $code)"
  logger -t "sb.sh" "[ERROR] line $line cmd: $cmd exit: $code"
  return $code
}
trap 'trap_error $LINENO "$BASH_COMMAND"' ERR

export LANG=en_US.UTF_8
red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; blue='\033[0;36m'; plain='\033[0m'

red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}

readp(){ read -p "$(yellow "$1")" "$2";}
base64_n0() { if base64 --help 2>/dev/null | grep -q -- '--wrap'; then base64 --wrap=0; elif base64 --help 2>/dev/null | grep -q -- '-w'; then base64 -w 0; else base64; fi; }

[[ $EUID -ne 0 ]] && yellow "請以root模式運行腳本" && exit

# 全域變量，用於存儲配置參數
export sbfiles="/etc/s-box/sb10.json /etc/s-box/sb11.json" # 腳本1的邏輯需要兩個文件
hostname=$(hostname)
dns_strategy="prefer_ipv4"
tlsyn=false
ym_vl_re="" ym_vm_ws="" uuid=""
port_vl_re="" port_vm_ws="" port_hy2="" port_tu=""
certificatec_vmess_ws="" certificatep_vmess_ws=""
certificatec_hy2="" certificatep_hy2=""
certificatec_tuic="" certificatep_tuic=""
private_key="" public_key="" short_id=""
pvk="" v6="" res="" endip=""

bootstrap_and_exec() {
    local permanent_path="/usr/local/lib/ieduer-sb.sh"
    local shortcut_path="/usr/local/bin/sb"
    local script_url="https://raw.githubusercontent.com/ieduer/bdfz/main/sb.sh" # 假設這是您的新腳本地址
    if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then red "wget 和 curl 都不可用，无法下载脚本。"; exit 1; fi
    green "正在下載最新脚本到 $permanent_path ..."
    if command -v curl &>/dev/null; then curl -fsSL "$script_url" -o "$permanent_path"; else wget -qO "$permanent_path" "$script_url"; fi
    if [[ ! -s "$permanent_path" ]]; then red "脚本下载失败，请检查网络或链接。"; exit 1; fi
    chmod +x "$permanent_path"; ln -sf "$permanent_path" "$shortcut_path"; green "已安裝/更新快捷命令：sb"
    exec "$shortcut_path" "$@"
}

check_os() {
    if [[ -r /etc/os-release ]]; then . /etc/os-release; case "${ID,,}" in ubuntu|debian) release="Debian" ;; centos|rhel|rocky|almalinux) release="Centos" ;; alpine) release="alpine" ;; *) red "不支持的系統 (${PRETTY_NAME:-unknown})。" && exit 1 ;; esac; op="${PRETTY_NAME:-$ID}"; else red "无法识别的操作系统。" && exit 1; fi
    case "$(uname -m)" in armv7l) cpu=armv7 ;; aarch64) cpu=arm64 ;; x86_64) cpu=amd64 ;; *) red "不支持的架構 $(uname -m)" && exit 1 ;; esac
    vi=$(command -v systemd-detect-virt &>/dev/null && systemd-detect-virt || command -v virt-what &>/dev/null && virt-what || echo "unknown")
}

check_dependencies() {
    local pkgs=("curl" "openssl" "iptables" "tar" "wget" "jq" "socat" "qrencode" "git" "ss" "lsof" "virt-what" "dig" "xxd" "python3" "expect"); local missing_pkgs=()
    for pkg in "${pkgs[@]}"; do if ! command -v "$pkg" &> /dev/null; then missing_pkgs+=("$pkg"); fi; done
    if [ ${#missing_pkgs[@]} -gt 0 ]; then yellow "檢測到缺少依賴: ${missing_pkgs[*]}，將自動安裝。"; install_dependencies "${missing_pkgs[@]}"; fi
}

install_dependencies() {
    green "開始安裝必要的依賴……"; 
    if [[ x"${release}" == x"alpine" ]]; then 
        apk update && apk add jq openssl iproute2 iputils coreutils git socat iptables grep util-linux dcron tar tzdata qrencode virt-what bind-tools python3 xxd expect
    else 
        local PKG_MANAGER
        if [ -x "$(command -v apt-get)" ]; then PKG_MANAGER="apt-get"; $PKG_MANAGER update -y; fi
        if [ -x "$(command -v yum)" ]; then PKG_MANAGER="yum"; $PKG_MANAGER install -y epel-release || true; fi
        if [ -x "$(command -v dnf)" ]; then PKG_MANAGER="dnf"; $PKG_MANAGER install -y epel-release || true; fi
        
        $PKG_MANAGER install -y jq cron socat iptables-persistent coreutils util-linux curl openssl tar wget qrencode git iproute2 lsof virt-what dnsutils python3 xxd expect
        
        if [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
            $PKG_MANAGER install -y cronie iptables-services
            systemctl enable --now cronie 2>/dev/null || true
            systemctl enable --now iptables 2>/dev/null || true
        fi
    fi
    green "依賴安裝完成。"
}

ensure_dirs() { mkdir -p /etc/s-box /root/ieduerca; chmod 700 /etc/s-box; }
v4v6(){ v4=$(curl -fsS4m5 --retry 2 icanhazip.com || true); v6=$(curl -fsS6m5 --retry 2 icanhazip.com || true); }

v6_setup(){
    if [[ -z "$(curl -s4m5 icanhazip.com -k)" ]]; then
        yellow "檢測到 純IPV6 VPS，添加NAT64"; echo -e "nameserver 2a00:1098:2b::1\nnameserver 2a00:1098:2c::1" > /etc/resolv.conf
        dns_strategy="prefer_ipv6"
    else
        dns_strategy="prefer_ipv4"
    fi

    if [ -n "$(curl -s6m5 icanhazip.com -k)" ]; then
        endip=2606:4700:d0::a29f:c001
    else
        endip=162.159.192.1
    fi
}

configure_firewall() {
    systemctl stop firewalld.service >/dev/null 2>&1
    systemctl disable firewalld.service >/dev/null 2>&1
    setenforce 0 >/dev/null 2>&1
    ufw disable >/dev/null 2>&1
    iptables -P INPUT ACCEPT >/dev/null 2>&1
    iptables -P FORWARD ACCEPT >/dev/null 2>&1
    iptables -P OUTPUT ACCEPT >/dev/null 2>&1
    iptables -t mangle -F >/dev/null 2>&1
    iptables -F >/dev/null 2>&1
    iptables -X >/dev/null 2>&1
    if command -v netfilter-persistent &>/dev/null; then netfilter-persistent save >/dev/null 2>&1; fi
    if command -v service &>/dev/null && service iptables save &>/dev/null; then service iptables save >/dev/null 2>&1; fi
    green "防火牆已關閉並清空規則。"
}

# 照抄腳本1的證書選擇邏輯
setup_certificates() {
    green "二、生成並設置相關證書"
    blue "自動生成bing自簽證書中……" && sleep 1
    openssl ecparam -genkey -name prime256v1 -out /etc/s-box/private.key
    openssl req -new -x509 -days 36500 -key /etc/s-box/private.key -out /etc/s-box/cert.pem -subj "/CN=www.bing.com"
    
    local use_acme=false
    if [[ -f /root/ieduerca/cert.crt && -s /root/ieduerca/cert.crt ]]; then
        yellow "經檢測，之前已申請過Acme域名證書：$(cat /root/ieduerca/ca.log)"
        readp "是否使用 $(cat /root/ieduerca/ca.log) 域名證書？(y/n, 默認n使用自簽): " choice
        [[ "${choice,,}" == "y" ]] && use_acme=true
    else
        readp "如果你有解析完成的域名，是否申請一個Acme域名證書？(y/n, 默認n使用自簽): " choice
        if [[ "${choice,,}" == "y" ]]; then
            # 使用腳本2更健壯的ACME申請函數
            if apply_acme_cert; then
                use_acme=true
            else
                red "Acme證書申請失敗，繼續使用自簽證書。"
                use_acme=false
            fi
        fi
    fi

    if $use_acme; then
        ym_vl_re="apple.com"
        ym_vm_ws=$(cat /root/ieduerca/ca.log)
        tlsyn=true
        certificatec_vmess_ws='/root/ieduerca/cert.crt'; certificatep_vmess_ws='/root/ieduerca/private.key'
        certificatec_hy2='/root/ieduerca/cert.crt'; certificatep_hy2='/root/ieduerca/private.key'
        certificatec_tuic='/root/ieduerca/cert.crt'; certificatep_tuic='/root/ieduerca/private.key'
        blue "Vless-reality SNI: apple.com"
        blue "Vmess-ws, Hysteria-2, Tuic-v5 将使用 $ym_vm_ws 證書並開啟TLS。"
    else
        ym_vl_re="apple.com"
        ym_vm_ws="www.bing.com"
        tlsyn=false
        certificatec_vmess_ws='/etc/s-box/cert.pem'; certificatep_vmess_ws='/etc/s-box/private.key'
        certificatec_hy2='/etc/s-box/cert.pem'; certificatep_hy2='/etc/s-box/private.key'
        certificatec_tuic='/etc/s-box/cert.pem'; certificatep_tuic='/etc/s-box/private.key'
        blue "Vless-reality SNI: apple.com"
        blue "Vmess-ws 將關閉TLS，Hysteria-2, Tuic-v5 將使用bing自簽證書。"
    fi
}

# 照抄腳本1的端口選擇邏輯
setup_ports() {
    green "三、設置各個協議端口"
    ports=()
    for i in {1..4}; do
        while true; do
            port=$(shuf -i 10000-65535 -n 1)
            if ! [[ " ${ports[@]} " =~ " $port " ]] && ! ss -H -tunlp "sport = :$port" | grep -q .; then
                ports+=($port)
                break
            fi
        done
    done
    port_vl_re=${ports[0]}; port_hy2=${ports[1]}; port_tu=${ports[2]}
    
    # vmess 端口特殊處理
    local cdn_ports
    if [[ "$tlsyn" == "true" ]]; then
        cdn_ports=("2053" "2083" "2087" "2096" "8443")
    else
        cdn_ports=("8080" "8880" "2052" "2082" "2086" "2095")
    fi
    port_vm_ws=${cdn_ports[$RANDOM % ${#cdn_ports[@]}]}
    while ss -H -tunlp "sport = :$port_vm_ws" | grep -q .; do
        port_vm_ws=${cdn_ports[$RANDOM % ${#cdn_ports[@]}]}
    done

    blue "Vless-reality端口：$port_vl_re"
    blue "Vmess-ws端口：$port_vm_ws"
    blue "Hysteria-2端口：$port_hy2"
    blue "Tuic-v5端口：$port_tu"
}

# 照抄腳本1的UUID生成邏輯
setup_uuid() {
    green "四、自動生成各個協議統一的uuid (密碼)"
    uuid=$(/etc/s-box/sing-box generate uuid)
    blue "已確認uuid (密碼)：${uuid}"
    blue "已確認Vmess的path路徑：/${uuid}-vm"
}

# 照抄腳本1的reality key生成邏輯
generate_reality_materials() {
    blue "Vless-reality相關key與id將自動生成……"
    local key_pair; key_pair=$(/etc/s-box/sing-box generate reality-keypair)
    private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
    echo "$public_key" > /etc/s-box/public.key
    short_id=$(/etc/s-box/sing-box generate rand --hex 4)
}

# 照抄腳本1的warp參數生成邏輯
warpwg() {
    green "五、自動生成warp-wireguard出站賬戶" && sleep 1
    local output
    # 內聯python3，避免多文件依賴
    output=$(python3 -c '
import json, subprocess, datetime, base64

def gen_keypair():
    p = subprocess.run(["openssl", "genpkey", "-algorithm", "X25519"], capture_output=True, text=True)
    private_key_b64 = subprocess.run(["openssl", "pkey", "-text", "-noout"], input=p.stdout, capture_output=True, text=True).stdout.split("priv:")[1].split("pub:")[0].replace(":", "").replace("\n", "").strip()
    public_key_b64 = subprocess.run(["openssl", "pkey", "-text", "-noout"], input=p.stdout, capture_output=True, text=True).stdout.split("pub:")[1].replace(":", "").replace("\n", "").strip()
    return base64.b64encode(bytes.fromhex(private_key_b64)).decode("utf-8"), base64.b64encode(bytes.fromhex(public_key_b64)).decode("utf-8")

def reg():
    priv, pub = gen_keypair()
    data = {"key": pub, "tos": datetime.datetime.utcnow().isoformat()[:-3] + "Z"}
    headers = {"CF-Client-Version": "a-7.21-0721", "Content-Type": "application/json"}
    try:
        p = subprocess.run(["curl", "-sL", "--tlsv1.3", "--connect-timeout", "3", "-X", "POST", "https://api.cloudflareclient.com/v0a2158/reg", "-H", f"CF-Client-Version: {headers[\"CF-Client-Version\"]}", "-H", f"Content-Type: {headers[\"Content-Type\"]}", "-d", json.dumps(data)], capture_output=True, text=True, timeout=5)
        resp = json.loads(p.stdout)
        resp["private_key"] = priv
        return resp
    except Exception:
        return None

warp_info = reg()
if warp_info and "account" in warp_info:
    res_str = warp_info["account"].get("client_id")
    if res_str:
        res_dec = list(base64.b64decode(res_str))
        warp_info["reserved"] = res_dec
    print(json.dumps(warp_info, indent=2))
' 2>/dev/null || true)

    if [[ -n "$output" ]] && echo "$output" | jq -e . >/dev/null 2>&1; then
        pvk=$(echo "$output" | jq -r .private_key)
        v6=$(echo "$output" | jq -r '.config.interface.addresses.v6')
        res=$(echo "$output" | jq -r .reserved | tr -d '\n ')
    else
        red "Warp賬戶生成失敗，使用預設值。"
        pvk="g9I2sgUH6OCbIBTehkEfVEnuvInHYZvPOFhWchMLSc4="
        v6="2606:4700:110:860e:738f:b37:f15:d38d"
        res="[33,217,129]"
    fi
    blue "Private_key私鑰：$pvk"
    blue "IPV6地址：$v6"
    blue "reserved值：$res"
}

# 核心改造：照抄腳本1的JSON生成邏輯
inssbjsonser(){
cat > /etc/s-box/sb10.json <<EOF
{
"log": { "disabled": false, "level": "info", "timestamp": true },
"inbounds": [
    { "type": "vless", "sniff": true, "sniff_override_destination": true, "tag": "vless-sb", "listen": "::", "listen_port": ${port_vl_re}, "users": [ { "uuid": "${uuid}", "flow": "xtls-rprx-vision" } ], "tls": { "enabled": true, "server_name": "${ym_vl_re}", "reality": { "enabled": true, "handshake": { "server": "${ym_vl_re}", "server_port": 443 }, "private_key": "$private_key", "short_id": ["$short_id"] } } },
    { "type": "vmess", "sniff": true, "sniff_override_destination": true, "tag": "vmess-sb", "listen": "::", "listen_port": ${port_vm_ws}, "users": [ { "uuid": "${uuid}", "alterId": 0 } ], "transport": { "type": "ws", "path": "/${uuid}-vm", "max_early_data":2048, "early_data_header_name": "Sec-WebSocket-Protocol" }, "tls":{ "enabled": ${tlsyn}, "server_name": "${ym_vm_ws}", "certificate_path": "$certificatec_vmess_ws", "key_path": "$certificatep_vmess_ws" } }, 
    { "type": "hysteria2", "sniff": true, "sniff_override_destination": true, "tag": "hy2-sb", "listen": "::", "listen_port": ${port_hy2}, "users": [ { "password": "${uuid}" } ], "ignore_client_bandwidth":false, "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$certificatec_hy2", "key_path": "$certificatep_hy2" } },
    { "type":"tuic", "sniff": true, "sniff_override_destination": true, "tag": "tuic5-sb", "listen": "::", "listen_port": ${port_tu}, "users": [ { "uuid": "${uuid}", "password": "${uuid}" } ], "congestion_control": "bbr", "tls":{ "enabled": true, "alpn": ["h3"], "certificate_path": "$certificatec_tuic", "key_path": "$certificatep_tuic" } }
],
"outbounds": [
    { "type":"direct", "tag":"direct", "domain_strategy": "$dns_strategy" },
    { "type": "block", "tag": "block" },
    { "type":"wireguard", "tag":"wireguard-out", "server":"$endip", "server_port":2408, "local_address":["172.16.0.2/32", "${v6}/128"], "private_key":"$pvk", "peer_public_key":"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "reserved": $res }
],
"route":{ "rules":[ { "protocol": ["quic", "stun"], "outbound": "block" }, { "outbound": "direct", "network": "udp,tcp" } ] }
}
EOF

cat > /etc/s-box/sb11.json <<EOF
{
"log": { "disabled": false, "level": "info", "timestamp": true },
"inbounds": [
    { "type": "vless", "tag": "vless-sb", "listen": "::", "listen_port": ${port_vl_re}, "users": [ { "uuid": "${uuid}", "flow": "xtls-rprx-vision" } ], "tls": { "enabled": true, "server_name": "${ym_vl_re}", "reality": { "enabled": true, "handshake": { "server": "${ym_vl_re}", "server_port": 443 }, "private_key": "$private_key", "short_id": ["$short_id"] } } },
    { "type": "vmess", "tag": "vmess-sb", "listen": "::", "listen_port": ${port_vm_ws}, "users": [ { "uuid": "${uuid}", "alterId": 0 } ], "transport": { "type": "ws", "path": "/${uuid}-vm", "max_early_data":2048, "early_data_header_name": "Sec-WebSocket-Protocol" }, "tls":{ "enabled": ${tlsyn}, "server_name": "${ym_vm_ws}", "certificate_path": "$certificatec_vmess_ws", "key_path": "$certificatep_vmess_ws" } }, 
    { "type": "hysteria2", "tag": "hy2-sb", "listen": "::", "listen_port": ${port_hy2}, "users": [ { "password": "${uuid}" } ], "ignore_client_bandwidth":false, "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$certificatec_hy2", "key_path": "$certificatep_hy2" } },
    { "type":"tuic", "tag": "tuic5-sb", "listen": "::", "listen_port": ${port_tu}, "users": [ { "uuid": "${uuid}", "password": "${uuid}" } ], "congestion_control": "bbr", "tls":{ "enabled": true, "alpn": ["h3"], "certificate_path": "$certificatec_tuic", "key_path": "$certificatep_tuic" } }
],
"endpoints":[
    { "type":"wireguard", "tag":"warp-out", "address":["172.16.0.2/32", "${v6}/128"], "private_key":"$pvk", "peers": [ { "address": "$endip", "port":2408, "public_key":"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "allowed_ips": ["0.0.0.0/0", "::/0"], "reserved": $res } ] }
],
"outbounds": [
    { "type":"direct", "tag":"direct", "domain_strategy": "$dns_strategy" }
],
"route":{ "rules":[ { "action": "sniff" }, { "outbound": "direct", "network": "udp,tcp" } ] }
}
EOF
    local sbnh; sbnh=$(/etc/s-box/sing-box version 2>/dev/null | awk '/version/{print $NF}' | cut -d '.' -f 1,2)
    [[ "$sbnh" == "1.10" ]] && cp /etc/s-box/sb10.json /etc/s-box/sb.json || cp /etc/s-box/sb11.json /etc/s-box/sb.json
}

# 腳本2的服務管理，更健壯
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

# 照抄腳本1的IP選擇邏輯
ipuuid(){
    for i in {1..3}; do if [[ x"${release}" == x"alpine" ]] && rc-service sing-box status 2>/dev/null | grep -q 'started'; then break; elif systemctl -q is-active sing-box; then break; fi; if [ $i -eq 3 ]; then red "Sing-box服務未運行或啟動失敗。"; return 1; fi; sleep 1; done
    
    v4v6; local menu
    if [[ -n "$v4" && -n "$v6" ]]; then
        readp "雙棧VPS，請選擇IP配置輸出 (1: IPv4, 2: IPv6, 默認2): " menu
        if [[ "$menu" == "1" ]]; then
            sbdnsip='https://dns.google/dns-query'; server_ip="$v4"; server_ipcl="$v4"
        else
            sbdnsip='https://[2001:4860:4860::8888]/dns-query'; server_ip="[$v6]"; server_ipcl="$v6"
        fi
    elif [[ -n "$v6" ]]; then
        sbdnsip='https://[2001:4860:4860::8888]/dns-query'; server_ip="[$v6]"; server_ipcl="$v6"
    elif [[ -n "$v4" ]]; then
        sbdnsip='https://dns.google/dns-query'; server_ip="$v4"; server_ipcl="$v4"
    else
        red "无法获取公網 IP 地址。" && return 1
    fi
    echo "$sbdnsip" > /etc/s-box/sbdnsip.log
    echo "$server_ip" > /etc/s-box/server_ip.log
    echo "$server_ipcl" > /etc/s-box/server_ipcl.log
}

# 以下是所有分享鏈接和客戶端配置生成函數，從腳本1移植
result_vl_vm_hy_tu(){
    rm -rf /etc/s-box/vm_ws.txt /etc/s-box/vm_ws_tls.txt; 
    sbdnsip=$(cat /etc/s-box/sbdnsip.log); server_ip=$(cat /etc/s-box/server_ip.log); server_ipcl=$(cat /etc/s-box/server_ipcl.log); 
    uuid=$(jq -r '.inbounds[0].users[0].uuid' /etc/s-box/sb.json); 
    vl_port=$(jq -r '.inbounds[0].listen_port' /etc/s-box/sb.json); vl_name=$(jq -r '.inbounds[0].tls.server_name' /etc/s-box/sb.json); 
    public_key=$(cat /etc/s-box/public.key); short_id=$(jq -r '.inbounds[0].tls.reality.short_id[0]' /etc/s-box/sb.json); 
    ws_path=$(jq -r '.inbounds[1].transport.path' /etc/s-box/sb.json); vm_port=$(jq -r '.inbounds[1].listen_port' /etc/s-box/sb.json); 
    tls=$(jq -r '.inbounds[1].tls.enabled' /etc/s-box/sb.json); vm_name=$(jq -r '.inbounds[1].tls.server_name' /etc/s-box/sb.json);
    if [[ "$tls" = "false" ]]; then
      vmadd_local=$server_ipcl; vmadd_are_local=$server_ip
    else
      vmadd_local=$vm_name; vmadd_are_local=$vm_name
    fi
    hy2_port=$(jq -r '.inbounds[2].listen_port' /etc/s-box/sb.json); local ym; ym=$(cat /root/ieduerca/ca.log 2>/dev/null || true);
    hy2_sniname=$(jq -r '.inbounds[2].tls.key_path' /etc/s-box/sb.json);
    if [[ "$hy2_sniname" = '/etc/s-box/private.key' ]]; then
      hy2_name=www.bing.com; sb_hy2_ip=$server_ip; cl_hy2_ip=$server_ipcl; hy2_ins=true
    else
      hy2_name=$ym; sb_hy2_ip=$ym; cl_hy2_ip=$ym; hy2_ins=false
    fi
    tu5_port=$(jq -r '.inbounds[3].listen_port' /etc/s-box/sb.json);
    tu5_sniname=$(jq -r '.inbounds[3].tls.key_path' /etc/s-box/sb.json);
    if [[ "$tu5_sniname" = '/etc/s-box/private.key' ]]; then
      tu5_name=www.bing.com; sb_tu5_ip=$server_ip; cl_tu5_ip=$server_ipcl; tu5_ins=true
    else
      tu5_name=$ym; sb_tu5_ip=$ym; cl_tu5_ip=$ym; tu5_ins=false
    fi
}
resvless(){ echo; white "~~~~~~~~~~~~~~~~~"; vl_link="vless://$uuid@$server_ipcl:$vl_port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$vl_name&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#vl-reality-$hostname"; echo "$vl_link" > /etc/s-box/vl_reality.txt; red "🚀 VLESS-Reality"; echo "链接:"; echo -e "${yellow}$vl_link${plain}"; echo "二维码:"; qrencode -o - -t ANSIUTF8 "$vl_link"; }
resvmess(){ echo; white "~~~~~~~~~~~~~~~~~"; if [[ "$tls" = "false" ]]; then red "🚀 VMess-WS"; vmess_json="{\"add\":\"$vmadd_are_local\",\"aid\":\"0\",\"host\":\"$vm_name\",\"id\":\"$uuid\",\"net\":\"ws\",\"path\":\"$ws_path\",\"port\":\"$vm_port\",\"ps\":\"vm-ws-$hostname\",\"tls\":\"\",\"type\":\"none\",\"v\":\"2\"}"; vmess_link="vmess://$(echo "$vmess_json" | base64_n0)"; echo "$vmess_link" > /etc/s-box/vm_ws.txt; else red "🚀 VMess-WS-TLS"; vmess_json="{\"add\":\"$vmadd_are_local\",\"aid\":\"0\",\"host\":\"$vm_name\",\"id\":\"$uuid\",\"net\":\"ws\",\"path\":\"$ws_path\",\"port\":\"$vm_port\",\"ps\":\"vm-ws-tls-$hostname\",\"tls\":\"tls\",\"sni\":\"$vm_name\",\"type\":\"none\",\"v\":\"2\"}"; vmess_link="vmess://$(echo "$vmess_json" | base64_n0)"; echo "$vmess_link" > /etc/s-box/vm_ws_tls.txt; fi; echo "链接:"; echo -e "${yellow}$vmess_link${plain}"; echo "二维码:"; qrencode -o - -t ANSIUTF8 "$vmess_link"; }
reshy2(){ echo; white "~~~~~~~~~~~~~~~~~"; hy2_link="hysteria2://$uuid@$sb_hy2_ip:$hy2_port?security=tls&alpn=h3&insecure=$hy2_ins&sni=$hy2_name#hy2-$hostname"; echo "$hy2_link" > /etc/s-box/hy2.txt; red "🚀 Hysteria-2"; echo "链接:"; echo -e "${yellow}$hy2_link${plain}"; echo "二维码:"; qrencode -o - -t ANSIUTF8 "$hy2_link"; }
restu5(){ echo; white "~~~~~~~~~~~~~~~~~"; tuic5_link="tuic://$uuid:$uuid@$sb_tu5_ip:$tu5_port?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$tu5_name&allow_insecure=$tu5_ins#tuic5-$hostname"; echo "$tuic5_link" > /etc/s-box/tuic5.txt; red "🚀 TUIC-v5"; echo "链接:"; echo -e "${yellow}$tuic5_link${plain}"; echo "二维码:"; qrencode -o - -t ANSIUTF8 "$tuic5_link"; }

gen_sb_client(){
    # 簡化：只生成 Sing-Box 客戶端配置
    result_vl_vm_hy_tu
    cat > /etc/s-box/sb_client.json <<EOF
{
  "log": { "disabled": false, "level": "info", "timestamp": true },
  "dns": { "servers": [ { "tag": "proxydns", "address": "$sbdnsip", "detour": "select" }, { "tag": "localdns", "address": "https://223.5.5.5/dns-query", "detour": "direct" } ], "final": "proxydns" },
  "inbounds": [ { "type": "tun", "tag": "tun-in", "inet4_address": "172.19.0.1/30", "auto_route": true, "sniff": true } ],
  "outbounds": [
    { "tag": "select", "type": "selector", "default": "auto", "outbounds": ["auto", "vless-${hostname}", "vmess-${hostname}", "hy2-${hostname}", "tuic5-${hostname}"] },
    { "type": "vless", "tag": "vless-${hostname}", "server": "${server_ipcl}", "server_port": ${vl_port}, "uuid": "${uuid}", "flow": "xtls-rprx-vision", "tls": { "enabled": true, "server_name": "${vl_name}", "utls": { "enabled": true, "fingerprint": "chrome" }, "reality": { "enabled": true, "public_key": "${public_key}", "short_id": "${short_id}" } } },
    { "type": "vmess", "tag": "vmess-${hostname}", "server": "${vmadd_local}", "server_port": ${vm_port}, "uuid": "${uuid}", "security": "auto", "transport": { "type": "ws", "path": "${ws_path}", "headers": { "Host": ["${vm_name}"] } }, "tls": { "enabled": ${tls}, "server_name": "${vm_name}", "insecure": false, "utls": { "enabled": true, "fingerprint": "chrome" } } },
    { "type": "hysteria2", "tag": "hy2-${hostname}", "server": "${cl_hy2_ip}", "server_port": ${hy2_port}, "password": "${uuid}", "tls": { "enabled": true, "server_name": "${hy2_name}", "insecure": ${hy2_ins}, "alpn": ["h3"] } },
    { "type": "tuic", "tag": "tuic5-${hostname}", "server": "${cl_tu5_ip}", "server_port": ${tu5_port}, "uuid": "${uuid}", "password": "${uuid}", "congestion_control": "bbr", "udp_relay_mode": "native", "tls": { "enabled": true, "server_name": "${tu5_name}", "insecure": ${tu5_ins}, "alpn": ["h3"] } },
    { "tag": "direct", "type": "direct" },
    { "tag": "auto", "type": "urltest", "outbounds": ["vless-${hostname}", "vmess-${hostname}", "hy2-${hostname}", "tuic5-${hostname}"], "url": "https://www.gstatic.com/generate_204" }
  ],
  "route": { "auto_detect_interface": true, "final": "select", "rules": [ { "ip_is_private": true, "outbound": "direct" }, { "domain_suffix": [".cn"], "outbound": "direct" } ] }
}
EOF
    green "Sing-Box 客戶端四協議配置已生成：/etc/s-box/sb_client.json"
}

clash_sb_share(){
    if ! ipuuid; then red "Sing-box 服務未運行，無法生成分享鏈接。"; return; fi
    result_vl_vm_hy_tu
    resvless; resvmess; reshy2; restu5
    gen_sb_client
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
upsbyg(){ yellow "正在嘗試更新..."; bootstrap_and_exec; }
sbsm(){ blue "安裝內核 → 自動生成默認配置 → 開機自啟。"; blue "可用功能：變更證書/端口、生成訂閱、查看日誌、開啟BBR。"; blue "分享/客戶端配置輸出：選 7 。產物在 /etc/s-box/"; }

# 核心安裝流程
install_or_reinstall_sb() {
    ensure_dirs
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green "選擇內核版本安裝模式:"
    yellow "1：最新正式版 (推薦，回車默認)"
    yellow "2：最新 1.10.x 版 (兼容 geosite)"
    readp "請選擇【1-2】：" menu
    
    local sbcore=""
    case "$menu" in
        2) sbcore=$(curl -Ls https://data.jsdelivr.com/v1/package/gh/SagerNet/sing-box | grep -Eo '"1\.10[0-9\.]*"' | sort -rV | head -n 1 | tr -d '"') ;;
        *) sbcore=$(curl -Ls https://data.jsdelivr.com/v1/package/gh/SagerNet/sing-box | grep -Eo '"[0-9.]+"' | sort -rV | head -n 1 | tr -d '"') ;;
    esac

    if [ -z "$sbcore" ]; then red "獲取版本號失敗"; exit 1; fi
    
    green "正在下載 Sing-box v$sbcore ..."
    local sbname="sing-box-$sbcore-linux-$cpu"
    curl -L -o /etc/s-box/sing-box.tar.gz -# --retry 2 "https://github.com/SagerNet/sing-box/releases/download/v$sbcore/$sbname.tar.gz"
    
    if [[ ! -s '/etc/s-box/sing-box.tar.gz' ]]; then red "下載內核失敗"; exit 1; fi
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv "/etc/s-box/$sbname/sing-box" /etc/s-box
    rm -rf "/etc/s-box/sing-box.tar.gz" "/etc/s-box/$sbname"
    
    if [[ -x '/etc/s-box/sing-box' ]]; then
        chmod +x /etc/s-box/sing-box
        blue "成功安裝內核版本：$(/etc/s-box/sing-box version | awk '/version/{print $NF}')"
        rebuild_config_and_start # 安裝完畢後直接進入配置流程
    else 
        red "解壓內核失敗"; exit 1; 
    fi
}

rebuild_config_and_start(){
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green "開始生成配置..."
    configure_firewall
    v6_setup
    setup_certificates
    setup_ports
    setup_uuid
    generate_reality_materials
    warpwg
    inssbjsonser

    if ! sbservice; then return 1; fi
    if ! ipuuid; then red "IP UUID 信息生成失敗，請檢查服務狀態。"; return 1; fi
    
    clash_sb_share # 生成所有分享信息
    green "配置已更新並啟動。";
}

unins(){
    readp "確認卸載Sing-box嗎? [y/n]: " confirm; [[ "${confirm,,}" != "y" ]] && yellow "卸載已取消" && return
    if [[ x"${release}" == x"alpine" ]]; then rc-service sing-box stop 2>/dev/null || true; rc-update del sing-box 2>/dev/null || true; rm -f /etc/init.d/sing-box; else systemctl stop sing-box 2>/dev/null || true; systemctl disable sing-box 2>/dev/null || true; rm -f /etc/systemd/system/sing-box.service; systemctl daemon-reload 2>/dev/null || true; fi
    readp "是否刪除 /etc/s-box 目錄與所有配置？(y/n, 默認n): " rmconf; if [[ "${rmconf,,}" == "y" ]]; then rm -rf /etc/s-box; green "已刪除 /etc/s-box。"; fi
    readp "是否移除快捷命令 sb？(y/n, 默認n): " rmsb; if [[ "${rmsb,,}" == "y" ]]; then rm -f /usr/local/bin/sb /usr/local/lib/ieduer-sb.sh; green "已移除 sb 命令和腳本文件。"; fi
    green "Sing-box 已卸載完成。"
}

# 腳本2的ACME功能，更為健壯
apply_acme_cert() {
    if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then
        green "首次運行，正在安裝acme.sh..."
        curl https://get.acme.sh | sh
        if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then red "acme.sh 安裝失敗"; return 1; fi
    fi
    local prev_domain=""; [[ -s "/root/ieduerca/ca.log" ]] && prev_domain=$(cat /root/ieduerca/ca.log 2>/dev/null || true)
    readp "請輸入您解析到本機的域名 (默認: ${prev_domain:-无}): " domain
    [[ -z "$domain" ]] && domain="$prev_domain"
    if [[ -z "$domain" ]]; then red "域名不能為空。"; return 1; fi
    v4v6; local a aaaa; a=$(dig +short A "$domain" 2>/dev/null | head -n1 || true); aaaa=$(dig +short AAAA "$domain" 2>/dev/null | head -n1 || true)
    if [[ (-n "$a" && -n "$v4" && "$a" != "$v4") || (-n "$aaaa" && -n "$v6" && "$aaaa" != "$v6") ]]; then
        yellow "警告: $domain 的 A/AAAA 記錄可能未指向本機，ACME 可能失敗。"
    fi
    systemctl stop nginx apache2 httpd sing-box >/dev/null 2>&1 || true
    if ! ~/.acme.sh/acme.sh --issue -d "${domain}" --standalone --httpport 80 -k ec-256; then
        red "證書申請失敗。"
        systemctl start nginx apache2 httpd sing-box >/dev/null 2>&1 || true
        return 1
    fi
    local cert_path="/root/ieduerca"; mkdir -p "$cert_path"
    ~/.acme.sh/acme.sh --install-cert -d "${domain}" --ecc \
      --key-file       "${cert_path}/private.key" \
      --fullchain-file "${cert_path}/cert.crt" \
      --reloadcmd "systemctl restart sing-box"
    echo "${domain}" > "${cert_path}/ca.log"
    systemctl start nginx apache2 httpd >/dev/null 2>&1 || true
    green "證書申請與安裝成功：${domain}"
    return 0
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
    else 
        yellow "Sing-box 核心未安裝，請先選 1 。"
    fi
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    readp "請輸入數字【0-10】：" Input
    case "$Input" in  
     1 ) install_or_reinstall_sb;;
     2 ) unins;;
     3 ) rebuild_config_and_start;;
     4 ) stclre;;
     5 ) upsbyg;; 
     6 ) install_or_reinstall_sb;; # 更新內核本質上是重裝
     7 ) clash_sb_share;;
     8 ) sblog;;
     9 ) apply_acme_cert;;
    10 ) ipuuid && clash_sb_share;;
     * ) exit 
    esac
}

# --- 腳本入口 ---
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    check_os
    check_dependencies
    ensure_dirs
    main_menu
fi