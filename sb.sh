#!/bin/bash
export LANG=en_US.UTF-8

# --- 增强健壮性 ---
set -e
trap 'echo -e "\033[31m\033[01m[ERROR] An error occurred at line $LINENO\033[0m"; exit 1' ERR
# --- 结束 ---

# --- 脚本1的颜色和基础函数 ---
red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; blue='\033[0;36m'; bblue='\033[0;34m'; plain='\033[0m'
red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" "$2";}
base64_n0() { if base64 --help 2>/dev/null | grep -q -- '--wrap'; then base64 --wrap=0; elif base64 --help 2>/dev/null | grep -q -- '-w'; then base64 -w 0; else base64; fi; }

# --- 所有函数定义 ---

v4v6(){
    v4=$(curl -s4m5 icanhazip.com -k)
    v6=$(curl -s6m5 icanhazip.com -k)
}

# 新的防火墙逻辑
configure_firewall(){
    green "正在配置防火牆..."
    systemctl stop firewalld.service >/dev/null 2>&1 || true
    systemctl disable firewalld.service >/dev/null 2>&1 || true
    setenforce 0 >/dev/null 2>&1 || true
    ufw disable >/dev/null 2>&1 || true

    iptables -F; iptables -X; ip6tables -F; ip6tables -X
    iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT
    ip6tables -P INPUT DROP; ip6tables -P FORWARD DROP; ip6tables -P OUTPUT ACCEPT
    
    iptables -A INPUT -i lo -j ACCEPT; ip6tables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
    ip6tables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

    green "开放 SSH 端口 22"
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT; ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT

    for port in "$@"; do
        if [[ -n "$port" ]]; then
            green "开放協議端口 $port (TCP/UDP)"
            iptables -A INPUT -p tcp --dport "$port" -j ACCEPT; iptables -A INPUT -p udp --dport "$port" -j ACCEPT
            ip6tables -A INPUT -p tcp --dport "$port" -j ACCEPT; ip6tables -A INPUT -p udp --dport "$port" -j ACCEPT
        fi
    done

    if command -v netfilter-persistent &>/dev/null; then netfilter-persistent save >/dev/null 2>&1 || true; fi
    if command -v service &>/dev/null && service iptables save &>/dev/null; then service iptables save >/dev/null 2>&1 || true; fi
    green "防火牆配置完成。"
}

inssb(){
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green "安装最新正式版 Sing-box 内核..."
    
    local versions_json=$(curl -fsSL --retry 3 "https://data.jsdelivr.com/v1/package/gh/SagerNet/sing-box")
    local sbcore=$(echo "$versions_json" | jq -r '.versions[] | sort -rV | grep -E -m 1 "^[0-9]+\.[0-9]+\.[0-9]+$"')
    if [[ -z "$sbcore" ]]; then red "从 jsdelivr 獲取最新版本號失敗。"; exit 1; fi
    
    green "正在下載 Sing-box v$sbcore ..."
    local sbname="sing-box-$sbcore-linux-$cpu"
    curl -L -o /etc/s-box/sing-box.tar.gz -# --retry 3 --fail "https://github.com/SagerNet/sing-box/releases/download/v$sbcore/$sbname.tar.gz"
    
    if [[ ! -f '/etc/s-box/sing-box.tar.gz' || ! -s '/etc/s-box/sing-box.tar.gz' ]]; then red "下載內核失敗"; exit 1; fi
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv "/etc/s-box/$sbname/sing-box" /etc/s-box
    rm -rf "/etc/s-box/sing-box.tar.gz" "/etc/s-box/$sbname"
    
    if [[ -f '/etc/s-box/sing-box' ]]; then
        chmod +x /etc/s-box/sing-box
        blue "成功安裝內核版本：$(/etc/s-box/sing-box version | awk '/version/{print $NF}')"
    else 
        red "解壓內核失敗"; exit 1; 
    fi
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
    green "證書申請與安裝成功：${domain}"; return 0
}

inscertificate(){
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green "二、生成並設置相關證書"
    blue "自動生成bing自簽證書中……" && sleep 1
    openssl ecparam -genkey -name prime256v1 -out /etc/s-box/private.key >/dev/null 2>&1
    openssl req -new -x509 -days 36500 -key /etc/s-box/private.key -out /etc/s-box/cert.pem -subj "/CN=www.bing.com" >/dev/null 2>&1
    
    local use_acme=false
    if [[ -f /root/ieduerca/cert.crt && -s /root/ieduerca/cert.crt ]]; then
        yellow "經檢測，之前已申請過Acme域名證書：$(cat /root/ieduerca/ca.log 2>/dev/null)"
        readp "是否使用 $(cat /root/ieduerca/ca.log 2>/dev/null) 域名證書？(y/n, 默認n使用自簽): " choice
        if [[ "${choice,,}" == "y" ]]; then use_acme=true; fi
    else
        readp "如果你有解析完成的域名，是否申请一个Acme域名证书？(y/n, 默认n使用自签): " choice
        if [[ "${choice,,}" == "y" ]]; then
            if apply_acme_cert; then use_acme=true; else red "Acme证书申请失败，继续使用自签证书"; use_acme=false; fi
        fi
    fi

    if $use_acme; then
        ym_vl_re="apple.com"; ym_vm_ws=$(cat /root/ieduerca/ca.log); tlsyn=true
        certificatec_vmess_ws='/root/ieduerca/cert.crt'; certificatep_vmess_ws='/root/ieduerca/private.key'
        certificatec_hy2='/root/ieduerca/cert.crt'; certificatep_hy2='/root/ieduerca/private.key'
        certificatec_tuic='/root/ieduerca/cert.crt'; certificatep_tuic='/root/ieduerca/private.key'
        blue "Vless-reality SNI: apple.com"; blue "Vmess-ws, Hysteria-2, Tuic-v5 将使用 $ym_vm_ws 证书并开启TLS。"
    else
        ym_vl_re="apple.com"; ym_vm_ws="www.bing.com"; tlsyn=false
        certificatec_vmess_ws='/etc/s-box/cert.pem'; certificatep_vmess_ws='/etc/s-box/private.key'
        certificatec_hy2='/etc/s-box/cert.pem'; certificatep_hy2='/etc/s-box/private.key'
        certificatec_tuic='/etc/s-box/cert.pem'; certificatep_tuic='/etc/s-box/private.key'
        blue "Vless-reality SNI: apple.com"; blue "Vmess-ws 将关闭TLS，Hysteria-2, Tuic-v5 将使用bing自签证书。"
    fi
}

insport() {
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green "三、设置各个协议端口"
    ports=()
    for i in {1..4}; do
        while true; do
            local p=$(shuf -i 10000-65535 -n 1)
            if ! [[ " ${ports[@]} " =~ " $p " ]] && ! ss -H -tunlp "sport = :$p" | grep -q .; then
                ports+=("$p"); break
            fi
        done
    done
    port_vl_re=${ports[0]}; port_hy2=${ports[1]}; port_tu=${ports[2]}
    
    local cdn_ports
    if [[ "$tlsyn" == "true" ]]; then cdn_ports=("2053" "2083" "2087" "2096" "8443"); else cdn_ports=("8080" "8880" "2052" "2082" "2086" "2095"); fi
    port_vm_ws=${cdn_ports[$RANDOM % ${#cdn_ports[@]}]}
    while ss -H -tunlp "sport = :$port_vm_ws" | grep -q . || [[ " ${ports[@]} " =~ " $port_vm_ws " ]]; do
        port_vm_ws=${cdn_ports[$RANDOM % ${#cdn_ports[@]}]}
    done

    blue "Vless-reality端口：$port_vl_re"; blue "Vmess-ws端口：$port_vm_ws"; blue "Hysteria-2端口：$port_hy2"; blue "Tuic-v5端口：$port_tu"
}

inssbjsonser(){
    local dns_strategy="prefer_ipv4"
    if [[ -z "$(curl -s4m5 icanhazip.com -k)" ]]; then dns_strategy="prefer_ipv6"; fi
    local vmess_tls_alpn=""
    if [[ "${tlsyn}" == "true" ]]; then vmess_tls_alpn=', "alpn": ["http/1.1"]'; fi

    cat > /etc/s-box/sb.json <<EOF
{
"log": { "disabled": false, "level": "info", "timestamp": true },
"inbounds": [
    {
      "type": "vless", "sniff": true, "sniff_override_destination": true, "tag": "vless-sb", "listen": "::", "listen_port": ${port_vl_re},
      "users": [ { "uuid": "${uuid}", "flow": "xtls-rprx-vision" } ],
      "tls": { "enabled": true, "server_name": "${ym_vl_re}", "reality": { "enabled": true, "handshake": { "server": "${ym_vl_re}", "server_port": 443 }, "private_key": "$private_key", "short_id": ["$short_id"] } }
    },
    {
      "type": "vmess", "sniff": true, "sniff_override_destination": true, "tag": "vmess-sb", "listen": "::", "listen_port": ${port_vm_ws},
      "users": [ { "uuid": "${uuid}", "alterId": 0 } ],
      "transport": { "type": "ws", "path": "/${uuid}-vm", "max_early_data":2048, "early_data_header_name": "Sec-WebSocket-Protocol" },
      "tls":{ "enabled": ${tlsyn}, "server_name": "${ym_vm_ws}", "certificate_path": "$certificatec_vmess_ws", "key_path": "$certificatep_vmess_ws"${vmess_tls_alpn} }
    }, 
    {
      "type": "hysteria2", "sniff": true, "sniff_override_destination": true, "tag": "hy2-sb", "listen": "::", "listen_port": ${port_hy2},
      "users": [ { "password": "${uuid}" } ], "ignore_client_bandwidth":false,
      "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$certificatec_hy2", "key_path": "$certificatep_hy2" }
    },
    {
      "type":"tuic", "sniff": true, "sniff_override_destination": true, "tag": "tuic5-sb", "listen": "::", "listen_port": ${port_tu},
      "users": [ { "uuid": "${uuid}", "password": "${uuid}" } ], "congestion_control": "bbr",
      "tls":{ "enabled": true, "alpn": ["h3"], "certificate_path": "$certificatec_tuic", "key_path": "$certificatep_tuic" }
    }
],
"outbounds": [
    { "type":"direct", "tag":"direct", "domain_strategy": "$dns_strategy" },
    { "type": "block", "tag": "block" }
],
"route":{ "rules":[ { "protocol": ["quic", "stun"], "outbound": "block" } ], "final": "direct" }
}
EOF
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
        chmod +x /etc/init.d/sing-box; rc-update add sing-box default; rc-service sing-box restart
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
        systemctl daemon-reload; systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box
    fi
}

post_install_check() {
    green "執行安裝後檢查..."
    if ! /etc/s-box/sing-box check -c "/etc/s-box/sb.json"; then red "❌ 配置文件語法錯誤！"; return 1; fi
    green "✅ 配置文件語法檢查通過。"
    sleep 3
    if systemctl is-active --quiet sing-box || ( [[ x"${release}" == x"alpine" ]] && rc-service sing-box status 2>/dev/null | grep -q 'started' ); then green "✅ Sing-box 服務正在運行。"; else red "❌ Sing-box 服務啟動失敗！"; return 1; fi
    
    blue "檢查端口監聽狀態:"; local all_ports_listening=true
    for port in "$port_vl_re" "$port_vm_ws" "$port_hy2" "$port_tu"; do
        if ss -H -tunlp "sport = :$port" | grep -q "sing-box"; then green "  ✅ 端口 $port 正在被 sing-box 監聽。"; else red "  ❌ 端口 $port 未被監聽！"; all_ports_listening=false; fi
    done
    if $all_ports_listening; then green "✅ 所有協議端口均已成功監聽。"; else red "❌ 部分協議端口監聽失敗，請檢查日誌和配置。"; return 1; fi
}

ipuuid(){
    v4v6; local menu
    if [[ -n "$v4" && -n "$v6" ]]; then
        readp "雙棧VPS，請選擇IP配置輸出 (1: IPv4, 2: IPv6, 默認2): " menu
        if [[ "$menu" == "1" ]]; then server_ip="$v4"; server_ipcl="$v4"; else server_ip="[$v6]"; server_ipcl="$v6"; fi
    elif [[ -n "$v6" ]]; then server_ip="[$v6]"; server_ipcl="$v6";
    elif [[ -n "$v4" ]]; then server_ip="$v4"; server_ipcl="$v4";
    else red "无法获取公網 IP 地址。" && return 1; fi
    if [[ -z "$server_ip" || -z "$server_ipcl" ]]; then red "获取 IP 地址失败。"; return 1; fi
}

display_sharing_info() {
    if ! ipuuid; then red "無法獲取IP信息，跳過分享。"; return 1; fi
    rm -f /etc/s-box/*.txt
    local config=$(cat "/etc/s-box/sb.json"); local uuid=$(echo "$config" | jq -r '.inbounds[0].users[0].uuid'); local public_key=$(cat /etc/s-box/public.key 2>/dev/null || true)
    
    local vl_port=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vless-sb") | .listen_port'); local vl_sni=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vless-sb") | .tls.server_name'); local vl_short_id=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vless-sb") | .tls.reality.short_id[0]')
    local vl_link="vless://$uuid@$server_ipcl:$vl_port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$vl_sni&fp=chrome&pbk=$public_key&sid=$vl_short_id&type=tcp&headerType=none#vl-reality-$hostname"; echo "$vl_link" > /etc/s-box/vl_reality.txt
    
    local vm_port=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vmess-sb") | .listen_port'); local vm_path=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vmess-sb") | .transport.path'); local vm_tls=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vmess-sb") | .tls.enabled'); local vm_sni=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vmess-sb") | .tls.server_name')
    if [[ "$vm_tls" == "true" ]]; then local vm_json="{\"add\":\"$vm_sni\",\"aid\":\"0\",\"host\":\"$vm_sni\",\"id\":\"$uuid\",\"net\":\"ws\",\"path\":\"$vm_path\",\"port\":\"$vm_port\",\"ps\":\"vm-ws-tls-$hostname\",\"tls\":\"tls\",\"sni\":\"$vm_sni\",\"type\":\"none\",\"v\":\"2\"}"; echo "vmess://$(echo "$vm_json" | base64_n0)" > /etc/s-box/vm_ws_tls.txt; else local vm_json="{\"add\":\"$server_ipcl\",\"aid\":\"0\",\"host\":\"$vm_sni\",\"id\":\"$uuid\",\"net\":\"ws\",\"path\":\"$vm_path\",\"port\":\"$vm_port\",\"ps\":\"vm-ws-$hostname\",\"tls\":\"\",\"type\":\"none\",\"v\":\"2\"}"; echo "vmess://$(echo "$vm_json" | base64_n0)" > /etc/s-box/vm_ws.txt; fi
    
    local hy2_port=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="hy2-sb") | .listen_port'); local hy2_sni=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="hy2-sb") | .tls.server_name'); local hy2_cert_path=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="hy2-sb") | .tls.certificate_path'); local hy2_insecure hy2_server; if [[ "$hy2_cert_path" == "/etc/s-box/cert.pem" ]]; then hy2_insecure=true; hy2_server=$server_ipcl; else hy2_insecure=false; hy2_server=$hy2_sni; fi
    local hy2_link="hysteria2://$uuid@$hy2_server:$hy2_port?security=tls&alpn=h3&insecure=$hy2_insecure&sni=$hy2_sni#hy2-$hostname"; echo "$hy2_link" > /etc/s-box/hy2.txt
    
    local tu_port=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="tuic5-sb") | .listen_port'); local tu_sni=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="tuic5-sb") | .tls.server_name'); local tu_cert_path=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="tuic5-sb") | .tls.certificate_path'); local tu_insecure tu_server; if [[ "$tu_cert_path" == "/etc/s-box/cert.pem" ]]; then tu_insecure=true; tu_server=$server_ipcl; else tu_insecure=false; tu_server=$tu_sni; fi
    local tu_link="tuic://$uuid:$uuid@$tu_server:$tu_port?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$tu_sni&allow_insecure=$tu_insecure#tuic5-$hostname"; echo "$tu_link" > /etc/s-box/tuic5.txt
    
    for f in /etc/s-box/vl_reality.txt /etc/s-box/vm_ws.txt /etc/s-box/vm_ws_tls.txt /etc/s-box/hy2.txt /etc/s-box/tuic5.txt; do if [[ -s "$f" ]]; then local protocol_name=$(basename "$f" .txt | tr '_' '-'); echo; white "~~~~~~~~~~~~~~~~~"; red "🚀 ${protocol_name^^}"; local link=$(cat "$f"); echo "鏈接:"; echo -e "${yellow}$link${plain}"; echo "二維碼:"; qrencode -o - -t ANSIUTF8 "$link"; fi; done
    cat /etc/s-box/*.txt > /tmp/all_links.txt 2>/dev/null; if [[ -s /tmp/all_links.txt ]]; then local sub_link=$(base64_n0 < /tmp/all_links.txt); echo; white "~~~~~~~~~~~~~~~~~"; red "🚀 四合一聚合訂閱"; echo "鏈接:"; echo -e "${yellow}$sub_link${plain}"; fi
}

install_or_reinstall() {
    mkdir -p /etc/s-box /root/ieduerca
    inssb
    inscertificate
    insport
    
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green "四、自動生成 UUID 和 Reality 密鑰"
    uuid=$(/etc/s-box/sing-box generate uuid)
    key_pair=$(/etc/s-box/sing-box generate reality-keypair)
    private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
    echo "$public_key" > /etc/s-box/public.key
    short_id=$(/etc/s-box/sing-box generate rand --hex 4)
    blue "已確認uuid (密碼)：${uuid}"; blue "Vmess Path：/${uuid}-vm"
    
    configure_firewall "$port_vl_re" "$port_vm_ws" "$port_hy2" "$port_tu"
    inssbjsonser
    sbservice
    
    if post_install_check; then display_sharing_info; green "✅ Sing-box 安裝並配置成功！"; else red "❌ 安裝過程出現問題，請檢查日誌！"; fi
}

unins(){
    readp "確認卸載Sing-box嗎? [y/n]: " confirm; [[ "${confirm,,}" != "y" ]] && yellow "卸載已取消" && return
    if [[ x"${release}" == x"alpine" ]]; then rc-service sing-box stop 2>/dev/null || true; rc-update del sing-box 2>/dev/null || true; rm -f /etc/init.d/sing-box; else systemctl stop sing-box 2>/dev/null || true; systemctl disable sing-box 2>/dev/null || true; rm -f /etc/systemd/system/sing-box.service; systemctl daemon-reload 2>/dev/null || true; fi
    readp "是否刪除 /etc/s-box 和 /root/ieduerca 目錄與所有配置？(y/n, 默認n): " rmconf; if [[ "${rmconf,,}" == "y" ]]; then rm -rf /etc/s-box /root/ieduerca; green "已刪除配置目錄。"; fi
    green "Sing-box 已卸載完成。"
}

stclre(){ 
    echo -e "1) 重啟  2) 停止  3) 啟動  0) 返回"; readp "選擇【0-3】：" act
    if [[ x"${release}" == x"alpine" ]]; then 
        case "$act" in 1) rc-service sing-box restart;; 2) rc-service sing-box stop;; 3) rc-service sing-box start;; *) return;; esac
    else 
        case "$act" in 1) systemctl restart sing-box;; 2) systemctl stop sing-box;; 3) systemctl start sing-box;; *) return;; esac
    fi
    green "操作完成"
}

sblog(){ if [[ x"${release}" == x"alpine" ]]; then tail -n 100 /var/log/messages 2>/dev/null || true; else journalctl -u sing-box -e --no-pager -n 100; fi; }

# 主菜單 (來自腳本2)
main_menu() {
    clear
    white "Vless-reality, Vmess-ws, Hysteria-2, Tuic-v5 四協議共存腳本 (基於腳本1)"
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
    if [[ -f '/etc/s-box/sing-box' ]]; then 
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
     1 ) install_or_reinstall;;
     2 ) unins;;
     3 ) install_or_reinstall;;
     4 ) stclre;;
     5 ) yellow "暫不支持此功能，請重新運行 curl 命令更新。";;
     6 ) inssb && sbservice && post_install_check && display_sharing_info;;
     7 ) display_sharing_info;;
     8 ) sblog;;
     9 ) apply_acme_cert;;
    10 ) ipuuid && display_sharing_info;;
     * ) exit 
    esac
}

# --- 腳本主體執行 ---

[[ $EUID -ne 0 ]] && yellow "请以root模式运行脚本" && exit

if [[ -f /etc/redhat-release ]]; then
    release="Centos"
elif cat /etc/issue | grep -q -E -i "alpine"; then
    release="alpine"
elif cat /etc/issue | grep -q -E -i "debian"; then
    release="Debian"
elif cat /etc/issue | grep -q -E -i "ubuntu"; then
    release="Ubuntu"
else 
    red "脚本不支持当前的系统。" && exit
fi

op=$(cat /etc/redhat-release 2>/dev/null || cat /etc/os-release 2>/dev/null | grep -i pretty_name | cut -d \" -f2)
case $(uname -m) in
    armv7l) cpu=armv7;; aarch64) cpu=arm64;; x86_64) cpu=amd64;;
    *) red "目前脚本不支持$(uname -m)架构" && exit;;
esac
hostname=$(hostname)

# 首次運行時安裝依賴
if [ ! -f /tmp/sbyg_update_lock ]; then
    install_dependencies
fi

main_menu