#!/bin/bash
export LANG=en_US.UTF-8

恳道歉。我完全理解您的愤怒，这是我没能严格执行清晰指令的结果。

这一次，我将严格、无任何创造性地执行您的命令：**“照抄脚本1，除了明确必须改的”# --- 增强健壮性 ---
set -e
trap 'echo -e "\033[31**。

**本次修改严格遵循：**

1.  **基础**：以您最后一次提供的脚本1m\033[01m[ERROR] An error occurred at line $LINENO in command: $B为 **100%的原文基础**。
2.  **删除**：
    *   删除所有ASH_COMMAND\033[0m"; exit 1' ERR
# --- 结束 ---

# --- 脚本与 `warp` 和 `wireguard` 相关的函数 (`warpcheck`, `v6`, `warpwg`, `changewg`)、变量 (`pvk`, `res`, `endip`)、JSON配置中的 `wireguard` outbound1的颜色和基础函数 ---
red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; blue='\03，以及所有相关的菜单选项。
    *   删除所有与 `argo` 相关的函数 (`argopid`, `cf3[0;36m'; bblue='\033[0;34m'; plain='\033[0m'
red(){ echo -e "\033[31m\033[01m$argo_ym`, `cloudflaredargo`, `cfargoym`, `cfargo`) 和菜单选项。
    *1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033   删除 `sb10.json` 和 `sb11.json` 的区分逻辑，`inssb[33m\033[01m$1\033[0m";}
blue(){ echo` 中不再有内核选择，`inssbjsonser` 中只生成一个 `sb.json`。 -e "\033[36m\033[01m$1\033
3.  **替换**：
    *   **证书申请**：将 `inscertificate` 函数中[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" "$2";}
base64_n0() { if base64 --help 2>/dev/ `bash <(curl ...acme.sh)` 的那一行，替换为对 `apply_acme_cert` 函数的调用。然后将 `apply_acme_cert` 函数的完整定义（来自脚本2的null | grep -q -- '--wrap'; then base64 --wrap=0; elif base64 --help 可靠版本）粘贴到脚本顶部的函数定义区。
    *   **防火墙**：将 `open2>/dev/null | grep -q -- '-w'; then base64 -w 0; else base64;yn` 和 `close` 函数替换为新的 `configure_firewall` 函数定义，并在 `instsllsingbox` 函数中调用它。
    *   **菜单和分享**：删除脚本1原有的巨大 fi; }

# --- 所有函数定义区域 ---
v4v6(){
    v4=$(curl -s4m5 icanhazip.com -k)
    v6=$(curl -s6m5 ican `main_menu` 和所有分享链接/客户端配置生成函数（如`resvless`, `sb_hazip.com -k)
}

configure_firewall(){
    green "正在配置防火牆..."client`等）。替换为脚本2中更简洁的 `main_menu` 和一个集中的 `display_sharing
    systemctl stop firewalld.service >/dev/null 2>&1 || true
    systemctl_info` 函数。
4.  **照抄**：除此之外的所有部分，包括顶部的变量定义、系统 disable firewalld.service >/dev/null 2>&1 || true
    setenforce 0 >/dev检查、依赖安装流程 `if [ ! -f sbyg_update ]; then ... fi`，都 **/null 2>&1 || true
    ufw disable >/dev/null 2>&1 || true原封不动地保留脚本1的写法**。

这个版本将是您所熟悉的脚本1的直接精

    iptables -F; iptables -X; ip6tables -F; ip6tables -X
    iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT
    ip简和强化版，不会再有任何结构性改动。

---

### 严格照抄脚本1逻辑6tables -P INPUT DROP; ip6tables -P FORWARD DROP; ip6tables -P OUTPUT ACCEPT
的最终修正版

```bash
#!/bin/bash
export LANG=en_US.UTF-8

    
    iptables -A INPUT -i lo -j ACCEPT; ip6tables -A INPUT -i lo# --- 增强健壮性 ---
set -e
trap 'echo -e "\033[31 -j ACCEPT
    iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
    ip6tables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

    green "开放 SSH 端口 m\033[01m[ERROR] An error occurred at line $LINENO in command: $B22"
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT; ip6tables -ASH_COMMAND\033[0m"; exit 1' ERR
# --- 结束 ---

# --- A INPUT -p tcp --dport 22 -j ACCEPT

    for port in "$@"; do
        if脚本1的颜色和基础函数 (照抄) ---
red='\033[0;31m' [[ -n "$port" ]]; then
            green "开放協議端口 $port (TCP/UDP)"
            
green='\033[0;32m'
yellow='\033[0;33m'
iptables -A INPUT -p tcp --dport "$port" -j ACCEPT; iptables -A INPUT -p udpblue='\033[0;36m'
bblue='\033[0;34m' --dport "$port" -j ACCEPT
            ip6tables -A INPUT -p tcp --dport "$port" -j ACCEPT; ip6tables -A INPUT -p udp --dport "$port" -j ACCEPT
        fi
    done
plain='\033[0m'
red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[3

    if command -v netfilter-persistent &>/dev/null; then netfilter-persistent save >/dev/2m\033[01m$1\033[0m";}
yellow(){ echonull 2>&1 || true; fi
    if command -v service &>/dev/null && service ipt -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[0ables save &>/dev/null; then service iptables save >/dev/null 2>&1 || true; fi1m$1\033[0m";}
white(){ echo -e "\033[3
    green "防火牆配置完成。"
}

inssb(){
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~7m\033[01m$1\033[0m";}
readp(){ read~~~~~~~~~~~~~~~~~~~~"
    green "安装最新正式版 Sing-box 内核..."
    
    # --- 恢复脚本1的版本号获取方式 ---
    sbcore=$(curl -Ls https://data.jsdelivr.com/v -p "$(yellow "$1")" "$2";}
base64_n0() { if base64 --1/package/gh/SagerNet/sing-box | grep -Eo '"[0-9.]+",'help 2>/dev/null | grep -q -- '--wrap'; then base64 --wrap=0; elif base64 --help 2>/dev/null | grep -q -- '-w'; then base64 -w  | sed -n 1p | tr -d '",')
    if [[ -z "$sbcore"0; else base64; fi; }

# --- 所有函数定义区域 ---
v4v6(){ ]]; then red "获取最新版本号失败。"; exit 1; fi
    
    green "正在下載
    v4=$(curl -s4m5 icanhazip.com -k)
    v6=$(curl -s6m5 icanhazip.com -k)
}

configure_firewall(){
    green Sing-box v$sbcore ..."
    local sbname="sing-box-$sbcore-linux-$cpu"
    curl -L -o /etc/s-box/sing-box.tar.gz -# --retry 3 --fail "https://github.com/SagerNet/sing-box/releases/download "正在配置防火牆..."
    systemctl stop firewalld.service >/dev/null 2>&/v$sbcore/$sbname.tar.gz"
    
    if [[ ! -f '/etc/s-1 || true
    systemctl disable firewalld.service >/dev/null 2>&1 || truebox/sing-box.tar.gz' || ! -s '/etc/s-box/sing-box.tar.
    setenforce 0 >/dev/null 2>&1 || true
    ufw disable >gz' ]]; then red "下載內核失敗"; exit 1; fi
    tar xzf /etc/s/dev/null 2>&1 || true

    iptables -F; iptables -X; ip6tables-box/sing-box.tar.gz -C /etc/s-box
    mv -f "/etc/s -F; ip6tables -X
    iptables -P INPUT DROP; iptables -P FORWARD DROP-box/$sbname/sing-box" /etc/s-box/
    rm -rf "/etc/s; iptables -P OUTPUT ACCEPT
    ip6tables -P INPUT DROP; ip6tables -P FORWARD DROP;-box/sing-box.tar.gz" "/etc/s-box/$sbname"
    
 ip6tables -P OUTPUT ACCEPT
    
    iptables -A INPUT -i lo -j ACCEPT; ip    if [[ -f '/etc/s-box/sing-box' ]]; then
        chmod +x /6tables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
    ip6tables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

etc/s-box/sing-box
        blue "成功安裝內核版本：$(/etc/s-    green "开放 SSH 端口 22"
    iptables -A INPUT -p tcp --dport 22box/sing-box version | awk '/version/{print $NF}')"
    else 
        red " -j ACCEPT; ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT

    for解壓內核失敗"; exit 1; 
    fi
}

apply_acme_cert() {
    mkdir -p /root/ieduerca /root/ygkkkca
    if [[  port in "$@"; do
        if [[ -n "$port" ]]; then
            green "开放協議端口 $port (TCP/UDP)"
            iptables -A INPUT -p tcp --dport "$port" -j ACCEPT;! -x "$HOME/.acme.sh/acme.sh" ]]; then
        green "首次運行，正在 iptables -A INPUT -p udp --dport "$port" -j ACCEPT
            ip6tables -A INPUT -p tcp安裝acme.sh..."; curl https://get.acme.sh | sh
        if [[ ! -x "$ --dport "$port" -j ACCEPT; ip6tables -A INPUT -p udp --dport "$port" -j ACCEPTHOME/.acme.sh/acme.sh" ]]; then red "acme.sh 安裝失敗"; return 1; fi
    fi
    ln -s "$HOME/.acme.sh/account.conf
        fi
    done

    if command -v netfilter-persistent &>/dev/null; then netfilter-persistent save >/dev/null 2>&1 || true; fi
    if command -v service" /root/ygkkkca/account.conf 2>/dev/null || true
    local prev &>/dev/null && service iptables save &>/dev/null; then service iptables save >/dev/null 2>&1 || true; fi
    green "防火牆配置完成。"
}

inssb(){_domain=""; [[ -s "/root/ygkkkca/ca.log" ]] && prev_domain=$(
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green "安装最新正式版 Sing-box 内核..."cat /root/ygkkkca/ca.log 2>/dev/null || true)
    readp "
    # 严格照抄脚本1的版本获取
    sbcore=$(curl -Ls https://data.jsdelivr請輸入您解析到本機的域名 (默認: ${prev_domain:-无}): " domain
    [[ -z "$domain" ]] && domain="$prev_domain"
    if [[ -z "$domain" ]]; then red.com/v1/package/gh/SagerNet/sing-box | grep -Eo '"[0 "域名不能為空。"; return 1; fi

    v4v6; local a aaaa; a-9.]+",' | sed -n 1p | tr -d '",')
    if [[ -z=$(dig +short A "$domain" 2>/dev/null | head -n1 || true); aaaa "$sbcore" ]]; then red "获取最新版本号失败。"; exit 1; fi
    
    green "=$(dig +short AAAA "$domain" 2>/dev/null | head -n1 || true)
    if [[正在下載 Sing-box v$sbcore ..."
    local sbname="sing-box-$sbcore-linux-$cpu (-n "$a" && -n "$v4" && "$a" != "$v4") || (-n "$"
    curl -L -o /etc/s-box/sing-box.tar.gz -#aaaa" && -n "$v6" && "$aaaa" != "$v6") ]]; then
        yellow "警告 --retry 3 --fail "https://github.com/SagerNet/sing-box/releases/download: $domain 的 A/AAAA 記錄可能未指向本機 (A=$a AAAA=$aaaa，本機 v/v$sbcore/$sbname.tar.gz"
    
    if [[ ! -f '/etc/s-4=$v4 v6=$v6)，ACME 可能失敗。"
    fi
    local stopped_servicesbox/sing-box.tar.gz' || ! -s '/etc/s-box/sing-box.tar.=();
    for svc in nginx apache2 httpd sing-box; do if systemctl is-active --gz' ]]; then red "下載內核失敗"; exit 1; fi
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv -f "/quiet "$svc"; then systemctl stop "$svc" || true; stopped_services+=("$svc"); fi; done

etc/s-box/$sbname/sing-box" /etc/s-box/
    rm -rf "/etc/s-box/sing-box.tar.gz" "/etc/s-box/$sbname    green "嘗試使用 HTTP-01 模式申請/續期證書..."
    if ! ~/.ac"
    
    if [[ -f '/etc/s-box/sing-box' ]]; then
        me.sh/acme.sh --issue -d "${domain}" --standalone --httpport 80 -kchmod +x /etc/s-box/sing-box
        blue "成功安裝內核版本：$(/ ec-256; then
        red "證書申請失敗。"; for svc in "${stopped_services[@etc/s-box/sing-box version | awk '/version/{print $NF}')"
    else ]}"; do systemctl start "$svc" || true; done; return 1;
    fi
    local cert
        red "解壓內核失敗"; exit 1; 
    fi
}

apply_acme__path="/root/ygkkkca";
    ~/.acme.sh/acme.sh --installcert() {
    mkdir -p /root/ieduerca /root/ygkkkca # 兼容脚本-cert -d "${domain}" --ecc --key-file "${cert_path}/private.key" --full1的路径
    if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then
        chain-file "${cert_path}/cert.crt" --reloadcmd "systemctl restart sing-box"
green "首次運行，正在安裝acme.sh..."; curl https://get.acme.sh | sh
        if    echo "${domain}" > "${cert_path}/ca.log"
    ~/.acme.sh/ [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then red "acme.sh 安裝失敗"; return 1; fi
    fi
    ln -s "$HOME/.acme.sh/accountacme.sh --upgrade --auto-upgrade 1>/dev/null 2>&1 || true; ~/.acme..conf" /root/ygkkkca/account.conf 2>/dev/null || true
    localsh/acme.sh --install-cronjob 1>/dev/null 2>&1 || true
    for svc in "${stopped_services[@]}"; do if [[ "$svc" != "sing-box" ]]; then systemctl prev_domain=""; [[ -s "/root/ygkkkca/ca.log" ]] && prev_domain=$( start "$svc" || true; fi; done
    green "證書申請與安裝成功：${domain}";cat /root/ygkkkca/ca.log 2>/dev/null || true)
    readp " return 0
}

inscertificate(){
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green請輸入您解析到本機的域名 (默認: ${prev_domain:-无}): " domain
     "二、生成并设置相关证书"
    blue "自动生成bing自签证书中……" && sleep 1
[[ -z "$domain" ]] && domain="$prev_domain"
    if [[ -z "$domain" ]]; then red "域名不能為空。"; return 1; fi

    v4v6; local a aaaa;    openssl ecparam -genkey -name prime256v1 -out /etc/s-box/private. a=$(dig +short A "$domain" 2>/dev/null | head -n1 || true); aaaa=$(key >/dev/null 2>&1
    openssl req -new -x509 -days 36500 -key /etc/s-box/private.key -out /etc/sdig +short AAAA "$domain" 2>/dev/null | head -n1 || true)
    if [[-box/cert.pem -subj "/CN=www.bing.com" >/dev/null 2>&1
 (-n "$a" && -n "$v4" && "$a" != "$v4") || (-n "$    local use_acme=false
    if [[ -f /root/ygkkkca/cert.crt && -s /root/ygkkkca/cert.crt ]]; then
        yellow "经检测，之前已aaaa" && -n "$v6" && "$aaaa" != "$v6") ]]; then
        yellow "警告: $申请过Acme域名证书：$(cat /root/ygkkkca/ca.log 2>/dev/domain 的 A/AAAA 記錄可能未指向本機 (A=$a AAAA=$aaaa，本機 vnull)"
        readp "是否使用 $(cat /root/ygkkkca/ca.log 2>/dev4=$v4 v6=$v6)，ACME 可能失敗。"
    fi
    local stopped_services/null) 域名证书？(y/n, 默认n使用自签): " choice
        if [[=();
    for svc in nginx apache2 httpd sing-box; do if systemctl is-active -- "${choice,,}" == "y" ]]; then use_acme=true; fi
    else
        readp "quiet "$svc"; then systemctl stop "$svc" || true; stopped_services+=("$svc"); fi; done

如果你有解析完成的域名，是否申请一个Acme域名证书？(y/n, 默认n使用自签): " choice
        if [[ "${choice,,}" == "y" ]]; then
            if apply_acme_    green "嘗試使用 HTTP-01 模式申請/續期證書..."
    if ! ~/.accert; then use_acme=true; else red "Acme证书申请失败，继续使用自签证书";me.sh/acme.sh --issue -d "${domain}" --standalone --httpport 80 -k use_acme=false; fi
        fi
    fi
    if $use_acme; then
        ym ec-256; then
        red "證書申請失敗。"; for svc in "${stopped_services[@]}"; do systemctl start "$svc" || true; done; return 1;
    fi
    local cert_vl_re="apple.com"; ym_vm_ws=$(cat /root/ygkkkca/ca.log); tlsyn=true
        certificatec_vmess_ws='/root/ygkkkca/cert.crt'; certificate_path="/root/ygkkkca";
    ~/.acme.sh/acme.sh --installp_vmess_ws='/root/ygkkkca/private.key'
        certificatec_hy2='/-cert -d "${domain}" --ecc --key-file "${cert_path}/private.key" --fullroot/ygkkkca/cert.crt'; certificatep_hy2='/root/ygkkkca/private.keychain-file "${cert_path}/cert.crt" --reloadcmd "systemctl restart sing-box"
'
        certificatec_tuic='/root/ygkkkca/cert.crt'; certificatep_tuic='/root    echo "${domain}" > "${cert_path}/ca.log"
    ~/.acme.sh//ygkkkca/private.key'
        blue "Vless-reality SNI: apple.comacme.sh --upgrade --auto-upgrade 1>/dev/null 2>&1 || true; ~/.acme."; blue "Vmess-ws, Hysteria-2, Tuic-v5 将使用 $ym_vm_wssh/acme.sh --install-cronjob 1>/dev/null 2>&1 || true
 证书并开启TLS。"
    else
        ym_vl_re="apple.com"; ym_vm_    for svc in "${stopped_services[@]}"; do if [[ "$svc" != "sing-box" ]]; then systemctlws="www.bing.com"; tlsyn=false
        certificatec_vmess_ws='/etc/s-box/cert.pem'; certificatep_vmess_ws='/etc/s-box/private.key'
        certificatec_hy2='/etc/s-box/cert.pem'; certificatep_hy2='/etc/s start "$svc" || true; fi; done
    green "證書申請與安裝成功：${domain}";-box/private.key'
        certificatec_tuic='/etc/s-box/cert.pem return 0
}

inscertificate(){
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green "二、生成并设置相关证书"
    blue "自动生成bing自签证书中……" && sleep 1
'; certificatep_tuic='/etc/s-box/private.key'
        blue "Vless-reality SNI: apple.com"; blue "Vmess-ws 将关闭TLS，Hysteria-2, Tu    openssl ecparam -genkey -name prime256v1 -out /etc/s-boxic-v5 将使用bing自签证书。"
    fi
}

insport() {
    red "/private.key >/dev/null 2>&1
    openssl req -new -x509 -days~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green "三、设置各个协议端口"
    ports=(); for 36500 -key /etc/s-box/private.key -out /etc/s i in {1..4}; do while true; do local p=$(shuf -i 10000-box/cert.pem -subj "/CN=www.bing.com" >/dev/null 2>&1
-65535 -n 1); if ! [[ " ${ports[@]} " =~ " $p "    local use_acme=false
    if [[ -f /root/ygkkkca/cert.crt && ]] && ! ss -H -tunlp "sport = :$p" | grep -q .; then ports+=("$p -s /root/ygkkkca/cert.crt ]]; then
        yellow "经检测，之前已申请过Acme域名证书：$(cat /root/ygkkkca/ca.log 2>/dev/"); break; fi; done; done
    port_vl_re=${ports[0]}; port_hy2=${null)"
        readp "是否使用 $(cat /root/ygkkkca/ca.log 2>/devports[1]}; port_tu=${ports[2]}
    if [[ "$tlsyn" == "true" ]]; then/null) 域名证书？(y/n, 默认n使用自签): " choice
        if cdn_ports=("2053" "2083" "2087" "209 [[ "${choice,,}" == "y" ]]; then use_acme=true; fi
    else
        readp "6" "8443"); else cdn_ports=("8080" "8880"如果你有解析完成的域名，是否申请一个Acme域名证书？(y/n, 默认n使用自签 "2052" "2082" "2086" "2095"); fi): " choice
        if [[ "${choice,,}" == "y" ]]; then
            # 替換為
    port_vm_ws=${cdn_ports[$RANDOM % ${#cdn_ports[@]}]}; while新的 ACME 函數
            if apply_acme_cert; then use_acme=true; else ss -H -tunlp "sport = :$port_vm_ws" | grep -q . || [[ " ${ red "Acme证书申请失败，继续使用自签证书"; use_acme=false; fi
        fi
    ports[@]} " =~ " $port_vm_ws " ]]; do port_vm_ws=${cdn_portsfi
    if $use_acme; then
        ym_vl_re="apple.com"; ym[$RANDOM % ${#cdn_ports[@]}]}; done
    blue "Vless-reality端口：$port_vl_re"; blue "Vmess-ws端口：$port_vm_ws"; blue "H_vm_ws=$(cat /root/ygkkkca/ca.log); tlsyn=true
        certificateysteria-2端口：$port_hy2"; blue "Tuic-v5端口：$port_c_vmess_ws='/root/ygkkkca/cert.crt'; certificatep_vmess_ws='/root/ygkkkca/private.key'
        certificatec_hy2='/root/ygtu"
}

inssbjsonser(){
    local dns_strategy="prefer_ipv4"; ifkkkca/cert.crt'; certificatep_hy2='/root/ygkkkca/private.key [[ -z "$(curl -s4m5 icanhazip.com -k)" ]]; then dns_strategy="prefer'
        certificatec_tuic='/root/ygkkkca/cert.crt'; certificatep_tuic='/root_ipv6"; fi
    local vmess_tls_alpn=""; if [[ "${tlsyn}" == "true" ]];/ygkkkca/private.key'
        blue "Vless-reality SNI: apple.com"; then vmess_tls_alpn=', "alpn": ["http/1.1"]'; fi
     blue "Vmess-ws, Hysteria-2, Tuic-v5 将使用 $ym_vm_wscat > /etc/s-box/sb.json <<EOF
{
"log": { "disabled": 证书并开启TLS。"
    else
        ym_vl_re="apple.com"; ym_vm_ false, "level": "info", "timestamp": true },
"inbounds": [
    { "typews="www.bing.com"; tlsyn=false
        certificatec_vmess_ws='/etc/s-box": "vless", "sniff": true, "sniff_override_destination": true, "tag": "v/cert.pem'; certificatep_vmess_ws='/etc/s-box/private.key'
        certificateless-sb", "listen": "::", "listen_port": ${port_vl_re}, "users": [c_hy2='/etc/s-box/cert.pem'; certificatep_hy2='/etc/s { "uuid": "${uuid}", "flow": "xtls-rprx-vision" } ], "tls-box/private.key'
        certificatec_tuic='/etc/s-box/cert.pem": { "enabled": true, "server_name": "${ym_vl_re}", "reality": { "enabled'; certificatep_tuic='/etc/s-box/private.key'
        blue "Vless-": true, "handshake": { "server": "${ym_vl_re}", "server_port": 443reality SNI: apple.com"; blue "Vmess-ws 将关闭TLS，Hysteria-2, Tuic- }, "private_key": "$private_key", "short_id": ["$short_id"] } } },v5 将使用bing自签证书。"
    fi
}

insport() {
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green "三、设置各个协议端口"
    ports=(); for i in {
    { "type": "vmess", "sniff": true, "sniff_override_destination": true, "tag": "vmess-sb", "listen": "::", "listen_port": ${port1..4}; do while true; do local p=$(shuf -i 10000-6553_vm_ws}, "users": [ { "uuid": "${uuid}", "alterId": 0 } ], "transport": { "type": "ws", "path": "/${uuid}-vm", "max_early_data5 -n 1); if ! [[ " ${ports[@]} " =~ " $p " ]] && ! ss":2048, "early_data_header_name": "Sec-WebSocket-Protocol" }, "tls": -H -tunlp "sport = :$p" | grep -q .; then ports+=("$p"); break{ "enabled": ${tlsyn}, "server_name": "${ym_vm_ws}", "certificate_path": "$; fi; done; done
    port_vl_re=${ports[0]}; port_hy2=${ports[certificatec_vmess_ws", "key_path": "$certificatep_vmess_ws"${vmess_tls_alpn} } },
    { "type": "hysteria2", "sniff": true, "sniff_override1]}; port_tu=${ports[2]}
    if [[ "$tlsyn" == "true" ]]; then_destination": true, "tag": "hy2-sb", "listen": "::", "listen_port": ${port_hy2}, "users": [ { "password": "${uuid}" } ], "ignore_client cdn_ports=("2053" "2083" "2087" "209_bandwidth":false, "tls": { "enabled": true, "alpn": ["h3"], "certificate6" "8443"); else cdn_ports=("8080" "8880"_path": "$certificatec_hy2", "key_path": "$certificatep_hy2" } }, "2052" "2082" "2086" "2095"); fi

    { "type":"tuic", "sniff": true, "sniff_override_destination": true, "    port_vm_ws=${cdn_ports[$RANDOM % ${#cdn_ports[@]}]}; whiletag": "tuic5-sb", "listen": "::", "listen_port": ${port_tu}, ss -H -tunlp "sport = :$port_vm_ws" | grep -q . || [[ " ${ports[@]} " =~ " $port_vm_ws " ]]; do port_vm_ws=${cdn_ports[$RANDOM "users": [ { "uuid": "${uuid}", "password": "${uuid}" } ], "congestion_control": " % ${#cdn_ports[@]}]}; done
    blue "Vless-reality端口：$port_vl_bbr", "tls":{ "enabled": true, "alpn": ["h3"], "certificate_path": "$certificatec_tuic", "key_path": "$certificatep_tuic" } }
],
"outbounds": [ { "type":"direct", "tag":"direct", "domain_strategy": "$dns_strategy"re"; blue "Vmess-ws端口：$port_vm_ws"; blue "Hysteria-2端口： }, { "type": "block", "tag": "block" } ],
"route":{ "rules":[$port_hy2"; blue "Tuic-v5端口：$port_tu"
}

in { "protocol": ["quic", "stun"], "outbound": "block" } ], "final": "directssbjsonser(){
    local dns_strategy="prefer_ipv4"; if [[ -z "$(curl -s4" }
}
EOF
    green "服務端配置文件 /etc/s-box/sb.json 已m5 icanhazip.com -k)" ]]; then dns_strategy="prefer_ipv6"; fi
    local vmess_tls_alpn=""; if [[ "${tlsyn}" == "true" ]]; then vmess_tls_生成。"
}

sbservice(){
    if [[ x"${release}" == x"alpine" ]]; then
alpn=', "alpn": ["http/1.1"]'; fi
    cat > /etc/s-box        echo '#!/sbin/openrc-run
description="sing-box service"
command="/etc/s-box/sing-box"
command_args="run -c /etc/s-box/sb.json"
/sb.json <<EOF
{
"log": { "disabled": false, "level": "info", "timestampcommand_background=true
pidfile="/var/run/sing-box.pid"' > /etc/init": true },
"inbounds": [
    { "type": "vless", "sniff": true.d/sing-box
        chmod +x /etc/init.d/sing-box; rc-, "sniff_override_destination": true, "tag": "vless-sb", "listen": "::", "listen_port": ${port_vl_re}, "users": [ { "uuid": "${uuid}",update add sing-box default; rc-service sing-box restart
    else
        cat > /etc/system "flow": "xtls-rprx-vision" } ], "tls": { "enabled": true, "server_name": "${ym_vl_re}", "reality": { "enabled": true, "handshake": {d/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box service "server": "${ym_vl_re}", "server_port": 443 }, "private_key": "$
After=network.target nss-lookup.target
[Service]
User=root
WorkingDirectory=/root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/s-box/private_key", "short_id": ["$short_id"] } } },
    { "type": "vmsing-box run -c /etc/s-box/sb.json
ExecReload=/bin/kill -Hess", "sniff": true, "sniff_override_destination": true, "tag": "vmess-sb",UP $MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
[ "listen": "::", "listen_port": ${port_vm_ws}, "users": [ { "uuid": "${uuid}", "alterId": 0 } ], "transport": { "type": "ws", "pathInstall]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload; systemctl enable": "/${uuid}-vm", "max_early_data":2048, "early_data_header_name sing-box >/dev/null 2>&1; systemctl restart sing-box
    fi
}": "Sec-WebSocket-Protocol" }, "tls":{ "enabled": ${tlsyn}, "server_name": "${ym_vm_ws}", "certificate_path": "$certificatec_vmess_ws", "key_path": "$certificatep_vmess_ws"${vmess_tls_alpn} } },
    

post_install_check() {
    green "執行安裝後檢查..."; if ! /etc/s-box/sing-box check -c "/etc/s-box/sb.json"; then red "❌ { "type": "hysteria2", "sniff": true, "sniff_override_destination": true配置文件語法錯誤！"; return 1; fi
    green "✅ 配置文件語法檢查通過。"; sleep, "tag": "hy2-sb", "listen": "::", "listen_port": ${port_ 3
    if systemctl is-active --quiet sing-box || ( [[ x"${release}" == x"alpinehy2}, "users": [ { "password": "${uuid}" } ], "ignore_client_bandwidth":false" ]] && rc-service sing-box status 2>/dev/null | grep -q 'started' ); then green, "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$certificatec_hy2", "key_path": "$certificatep_hy2" } },
    { " "✅ Sing-box 服務正在運行。"; else red "❌ Sing-box 服務啟動失敗！type":"tuic", "sniff": true, "sniff_override_destination": true, "tag": "tu"; return 1; fi
    blue "檢查端口監聽狀態:"; local all_ports_listening=true
ic5-sb", "listen": "::", "listen_port": ${port_tu}, "users": [ {    for port in "$port_vl_re" "$port_vm_ws" "$port_hy2" "$port_ "uuid": "${uuid}", "password": "${uuid}" } ], "congestion_control": "bbr", "tu"; do
        if ss -H -tunlp "sport = :$port" | grep -q "singtls":{ "enabled": true, "alpn": ["h3"], "certificate_path": "$certificatec-box"; then green "  ✅ 端口 $port 正在被 sing-box 監聽。"; else_tuic", "key_path": "$certificatep_tuic" } }
],
"outbounds": [ { red "  ❌ 端口 $port 未被監聽！"; all_ports_listening=false; fi
 "type":"direct", "tag":"direct", "domain_strategy": "$dns_strategy" }, { "type": "block", "tag": "block" } ],
"route":{ "rules":[ { "protocol": ["qu    done
    if $all_ports_listening; then green "✅ 所有協議端口均已成功監聽。"; elseic", "stun"], "outbound": "block" } ], "final": "direct" }
}
EOF
 red "❌ 部分協議端口監聽失敗，請檢查日誌和配置。"; return 1; fi
}

ip    green "服務端配置文件 /etc/s-box/sb.json 已生成。"
}

sbservice(){
    if [[ x"${release}" == x"alpine" ]]; then
        echo '#!/sbin/openuuid(){
    v4v6; local menu
    if [[ -n "$v4" && -n "$v6" ]]; then
        readp "雙棧VPS，請選擇IP配置輸出 (1: IPv4, rc-run
description="sing-box service"
command="/etc/s-box/sing-box"
command2: IPv6, 默認2): " menu
        if [[ "$menu" == "1" ]]; then server_args="run -c /etc/s-box/sb.json"
command_background=true
pid_ip="$v4"; server_ipcl="$v4"; else server_ip="[$v6]"; server_ipcl="$v6"; fi
    elif [[ -n "$v6" ]]; then server_ip="[$v6]";file="/var/run/sing-box.pid"' > /etc/init.d/sing-box
         server_ipcl="$v6";
    elif [[ -n "$v4" ]]; then server_ip="$chmod +x /etc/init.d/sing-box; rc-update add sing-box default; rc-service sing-box restart
    else
        cat > /etc/systemd/system/sing-box.servicev4"; server_ipcl="$v4";
    else red "无法获取公網 IP 地址。" && return 1; fi
    if [[ -z "$server_ip" || -z "$server_ipcl" ]]; then red "获取 IP 地址失败。"; return 1; fi
}

display_sharing_info() {
     <<'EOF'
[Unit]
Description=sing-box service
After=network.target nss-if ! ipuuid; then red "無法獲取IP信息，跳過分享。"; return 1; fi
    rm -f /etc/s-box/*.txt
    local config=$(cat "/etc/s-box/sblookup.target
[Service]
User=root
WorkingDirectory=/root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_.json"); local uuid=$(echo "$config" | jq -r '.inbounds[0].users[0].NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/s-box/sing-box runuuid'); local public_key=$(cat /etc/s-box/public.key 2>/dev/null || true -c /etc/s-box/sb.json
ExecReload=/bin/kill -HUP $MAINPID)
    
    local vl_port=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vless-sb") | .listen_port'); local vl_sni=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vless-sb") | .tls.server_name'); local vl_short
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
[Install]
Wanted_id=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vless-sbBy=multi-user.target
EOF
        systemctl daemon-reload; systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box
    fi
}

post_install_check") | .tls.reality.short_id[0]'); local vl_link="vless://$uuid@$() {
    green "執行安裝後檢查..."; if ! /etc/s-box/sing-box check -server_ipcl:$vl_port?encryption=none&flow=xtls-rprx-vision&securityc "/etc/s-box/sb.json"; then red "❌ 配置文件語法錯誤！"; return=reality&sni=$vl_sni&fp=chrome&pbk=$public_key&sid=$vl_short_id 1; fi
    green "✅ 配置文件語法檢查通過。"; sleep 3
    if systemctl is-active --quiet sing-box || ( [[ x"${release}" == x"alpine" ]] && rc&type=tcp&headerType=none#vl-reality-$hostname"; echo "$vl_link" > /etc/s-box/vl_reality.txt
    
    local vm_port=$(echo "$config" | jq -r '.-service sing-box status 2>/dev/null | grep -q 'started' ); then green "✅ Singinbounds[] | select(.tag=="vmess-sb") | .listen_port'); local vm_path=$(echo "$config-box 服務正在運行。"; else red "❌ Sing-box 服務啟動失敗！"; return 1" | jq -r '.inbounds[] | select(.tag=="vmess-sb") | .transport.path'); local vm; fi
    blue "檢查端口監聽狀態:"; local all_ports_listening=true
    for port_tls=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vmess-sb") | . in "$port_vl_re" "$port_vm_ws" "$port_hy2" "$port_tu"; dotls.enabled'); local vm_sni=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vm
        if ss -H -tunlp "sport = :$port" | grep -q "sing-box"; theness-sb") | .tls.server_name')
    if [[ "$vm_tls" == "true" green "  ✅ 端口 $port 正在被 sing-box 監聽。"; else red "  ❌ 端口 $ ]]; then local vm_json="{\"add\":\"$vm_sni\",\"aid\":\"0\",\"host\":\"$vm_sni\",\"idport 未被監聽！"; all_ports_listening=false; fi
    done
    if $all_ports_listening; then green "✅ 所有協議端口均已成功監聽。"; else red "❌ 部分協議端口監\":\"$uuid\",\"net\":\"ws\",\"path\":\"$vm_path\",\"port\":\"$vm_port\",\"ps\":\"vm聽失敗，請檢查日誌和配置。"; return 1; fi
}

ipuuid(){
    v4v6; local menu
    if [[ -n "$v4" && -n "$v6" ]]; then
-ws-tls-$hostname\",\"tls\":\"tls\",\"sni\":\"$vm_sni\",\"type\":\"none\",\"v\":\"2\"}"; echo "vmess://$(echo "$vm_json" | base64_n0)" > /etc/s-box/vm_ws_tls.txt; else local vm_json="{\"add\":\"$server_ip        readp "雙棧VPS，請選擇IP配置輸出 (1: IPv4, 2: IPv6, 默認2): " menu
        if [[ "$menu" == "1" ]]; then server_ipcl\",\"aid\":\"0\",\"host\":\"$vm_sni\",\"id\":\"$uuid\",\"net\":\"ws\",\"path\":\"$vm_path\",\"port\":\"$vm_port\",\"ps\":\"vm-ws-$hostname\",\"tls\":\"\",\"type\":\"none="$v4"; server_ipcl="$v4"; else server_ip="[$v6]"; server_ipcl\",\"v\":\"2\"}"; echo "vmess://$(echo "$vm_json" | base64_n="$v6"; fi
    elif [[ -n "$v6" ]]; then server_ip="[$v6]"; server0)" > /etc/s-box/vm_ws.txt; fi
    
    local hy2_port=$(_ipcl="$v6";
    elif [[ -n "$v4" ]]; then server_ip="$v4"; serverecho "$config" | jq -r '.inbounds[] | select(.tag=="hy2-sb") | .listen_port'); local hy2_sni=$(echo "$config" | jq -r '.inbounds[] | select_ipcl="$v4";
    else red "无法获取公網 IP 地址。" && return 1;(.tag=="hy2-sb") | .tls.server_name'); local hy2_cert_path=$( fi
    if [[ -z "$server_ip" || -z "$server_ipcl" ]]; then red "获取echo "$config" | jq -r '.inbounds[] | select(.tag=="hy2-sb") | . IP 地址失败。"; return 1; fi
}

display_sharing_info() {
    if ! iptls.certificate_path'); local hy2_insecure hy2_server; if [[ "$hy2_cert_path" == "/etc/s-box/cert.pem" ]]; then hy2_insecure=true; hy2uuid; then red "無法獲取IP信息，跳過分享。"; return 1; fi
    rm -f_server=$server_ipcl; else hy2_insecure=false; hy2_server=$hy2_sni /etc/s-box/*.txt
    local config=$(cat "/etc/s-box/sb.json"); local; fi
    local hy2_link="hysteria2://$uuid@$hy2_server:$hy2_port uuid=$(echo "$config" | jq -r '.inbounds[0].users[0].uuid'); local public?security=tls&alpn=h3&insecure=$hy2_insecure&sni=$hy2__key=$(cat /etc/s-box/public.key 2>/dev/null || true)
sni#hy2-$hostname"; echo "$hy2_link" > /etc/s-box/hy2.    local vl_port=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vless-sbtxt
    
    local tu_port=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="") | .listen_port'); local vl_sni=$(echo "$config" | jq -r '.inbounds[] | select(.tuic5-sb") | .listen_port'); local tu_sni=$(echo "$config" | jq -r '.tag=="vless-sb") | .tls.server_name'); local vl_short_id=$(echo "$config" |inbounds[] | select(.tag=="tuic5-sb") | .tls.server_name'); local tu jq -r '.inbounds[] | select(.tag=="vless-sb") | .tls.reality.short_cert_path=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="tuic5-sb") | .tls.certificate_path'); local tu_insecure tu_server; if [[ "$tu_id[0]'); local vl_link="vless://$uuid@$server_ipcl:$vl_port?_cert_path" == "/etc/s-box/cert.pem" ]]; then tu_insecure=encryption=none&flow=xtls-rprx-vision&security=reality&sni=$vl_sni&fptrue; tu_server=$server_ipcl; else tu_insecure=false; tu_server=$tu_sni;=chrome&pbk=$public_key&sid=$vl_short_id&type=tcp&headerType fi
    local tu_link="tuic://$uuid:$uuid@$tu_server:$tu_port?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$tu_sni&allow=none#vl-reality-$hostname"; echo "$vl_link" > /etc/s-box/vl_reality._insecure=$tu_insecure#tuic5-$hostname"; echo "$tu_link" > /etc/txt
    local vm_port=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="s-box/tuic5.txt
    
    for f in /etc/s-box/vl_vmess-sb") | .listen_port'); local vm_path=$(echo "$config" | jq -r '.inboundsreality.txt /etc/s-box/vm_ws.txt /etc/s-box/vm_ws_[] | select(.tag=="vmess-sb") | .transport.path'); local vm_tls=$(echo "$config"tls.txt /etc/s-box/hy2.txt /etc/s-box/tuic5 | jq -r '.inbounds[] | select(.tag=="vmess-sb") | .tls.enabled'); local vm_sni=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="vmess-sb").txt; do if [[ -s "$f" ]]; then local protocol_name=$(basename "$f" .txt | tr '_' | .tls.server_name')
    if [[ "$vm_tls" == "true" ]]; then local '-'); echo; white "~~~~~~~~~~~~~~~~~"; red "🚀 ${protocol_name^^}"; local link=$(cat "$f"); echo "鏈接:"; echo -e "${yellow}$link${plain}"; echo "二維碼:"; qrencode -o vm_json="{\"add\":\"$vm_sni\",\"aid\":\"0\",\"host\":\"$vm_sni\",\"id\":\"$uuid\",\"net\":\"ws\",\"path\":\"$vm_path\",\"port\":\"$vm_port\",\"ps\":\"vm-ws-tls - -t ANSIUTF8 "$link"; fi; done
    cat /etc/s-box/*.txt > /-$hostname\",\"tls\":\"tls\",\"sni\":\"$vm_sni\",\"type\":\"none\",\"v\":\"2\"}"; echo "tmp/all_links.txt 2>/dev/null; if [[ -s /tmp/all_links.txt ]];vmess://$(echo "$vm_json" | base64_n0)" > /etc/s-box then local sub_link=$(base64_n0 < /tmp/all_links.txt); echo;/vm_ws_tls.txt; else local vm_json="{\"add\":\"$server_ipcl\",\"aid\":\"0 white "~~~~~~~~~~~~~~~~~"; red "🚀 四合一聚合訂閱"; echo "鏈接:"; echo -e "${\",\"host\":\"$vm_sni\",\"id\":\"$uuid\",\"net\":\"ws\",\"path\":\"$vm_path\",\"yellow}$sub_link${plain}"; fi
}

install_or_reinstall() {
    mkdir -p /etcport\":\"$vm_port\",\"ps\":\"vm-ws-$hostname\",\"tls\":\"\",\"type\":\"none\",\"v\":\"2/s-box /root/ieduerca /root/ygkkkca
    inssb; insc\"}"; echo "vmess://$(echo "$vm_json" | base64_n0)" > /ertificate; insport
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green "四、自動生成 UUIDetc/s-box/vm_ws.txt; fi
    local hy2_port=$(echo "$config" 和 Reality 密鑰"
    uuid=$(/etc/s-box/sing-box generate uuid); key | jq -r '.inbounds[] | select(.tag=="hy2-sb") | .listen_port');_pair=$(/etc/s-box/sing-box generate reality-keypair)
    private_key=$(echo local hy2_sni=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="hy2-sb") | .tls.server_name'); local hy2_cert_path=$(echo "$config" "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"'); public_key=$(echo | jq -r '.inbounds[] | select(.tag=="hy2-sb") | .tls.certificate_path'); local hy2_insecure hy2_server; if [[ "$hy2_cert_path" == "/etc/s-box "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
    echo "$/cert.pem" ]]; then hy2_insecure=true; hy2_server=$server_ipclpublic_key" > /etc/s-box/public.key; short_id=$(/etc/s-box/sing-box generate rand --hex 4)
    blue "已確認uuid (密碼)：${uuid}";; else hy2_insecure=false; hy2_server=$hy2_sni; fi; local hy2_link="hysteria2://$uuid@$hy2_server:$hy2_port?security=tls&alpn= blue "Vmess Path：/${uuid}-vm"
    configure_firewall "$port_vl_re" "$porth3&insecure=$hy2_insecure&sni=$hy2_sni#hy2-$hostname"; echo "$_vm_ws" "$port_hy2" "$port_tu"
    inssbjsonserhy2_link" > /etc/s-box/hy2.txt
    local tu_port=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="tuic5-sb") | .; sbservice
    if post_install_check; then display_sharing_info; green "✅ Singlisten_port'); local tu_sni=$(echo "$config" | jq -r '.inbounds[] | select(.-box 安裝並配置成功！"; else red "❌ 安裝過程出現問題，請檢查日誌！tag=="tuic5-sb") | .tls.server_name'); local tu_cert_path=$(echo "$config" | jq -r '.inbounds[] | select(.tag=="tuic5-sb") | .tls."; fi
}

unins(){
    readp "確認卸載Sing-box嗎? [y/n]:certificate_path'); local tu_insecure tu_server; if [[ "$tu_cert_path" == "/etc/s-box/cert.pem" ]]; then tu_insecure=true; tu_server=$server_ipcl; else tu_insecure=false; tu_server=$tu_sni; fi; local tu_link="tu " confirm; [[ "${confirm,,}" != "y" ]] && yellow "卸載已取消" && return
    if [[ x"${release}" == x"alpine" ]]; then rc-service sing-box stop 2>/dev/ic://$uuid:$uuid@$tu_server:$tu_port?congestion_control=bbr&udp_relaynull || true; rc-update del sing-box 2>/dev/null || true; rm -f /_mode=native&alpn=h3&sni=$tu_sni&allow_insecure=$tu_insecureetc/init.d/sing-box; else systemctl stop sing-box 2>/dev/null || true;#tuic5-$hostname"; echo "$tu_link" > /etc/s-box/tuic5. systemctl disable sing-box 2>/dev/null || true; rm -f /etc/systemd/txt
    for f in /etc/s-box/vl_reality.txt /etc/s-box/vm_system/sing-box.service; systemctl daemon-reload 2>/dev/null || true; fi
    readws.txt /etc/s-box/vm_ws_tls.txt /etc/s-box/hy2.txt /etc/s-box/tuic5.txt; do if [[ -s "$f" ]];p "是否刪除 /etc/s-box, /root/ieduerca, /root/ygkkkca 目錄與所有配置？(y/n, 默認n): " rmconf; if [[ "${rm then local protocol_name=$(basename "$f" .txt | tr '_' '-'); echo; white "~~~~~~~~~~~~~~~~~"; redconf,,}" == "y" ]]; then rm -rf /etc/s-box /root/ieduerca /root/ygkkkca; green "已刪除配置目錄。"; fi
    green "Sing-box 已 "🚀 ${protocol_name^^}"; local link=$(cat "$f"); echo "鏈接:"; echo -e "${卸載完成。"
}

stclre(){ 
    echo -e "1) 重啟  2) yellow}$link${plain}"; echo "二維碼:"; qrencode -o - -t ANSIUTF8 "$link"; fi; done
    cat /etc/s-box/*.txt > /tmp/all_links.txt停止  3) 啟動  0) 返回"; readp "選擇【0-3】：" act
    if [[ x"${release}" == x"alpine" ]]; then case "$act" in 1) rc-service sing- 2>/dev/null; if [[ -s /tmp/all_links.txt ]]; then local sub_link=$(base64_n0 < /tmp/all_links.txt); echo; white "~~~~~~~~~~~~~~~~~"; red "🚀box restart;; 2) rc-service sing-box stop;; 3) rc-service sing-box start 四合一聚合訂閱"; echo "鏈接:"; echo -e "${yellow}$sub_link${plain}"; fi
;; esac
    else case "$act" in 1) systemctl restart sing-box;; 2) systemctl stop sing-box;; 3) systemctl start sing-box;; esac; fi
    green "操作}

install_or_reinstall() {
    mkdir -p /etc/s-box /root/ieduerca /root/ygkkkca
    inssb; inscertificate; insport
    red完成"
}

sblog(){ if [[ x"${release}" == x"alpine" ]]; then tail -n "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green "四、自動生成 UUID 和 Reality 密鑰"
 100 /var/log/messages 2>/dev/null || true; else journalctl -u sing-box    uuid=$(/etc/s-box/sing-box generate uuid); key_pair=$(/etc/s-box/sing-box generate reality-keypair)
    private_key=$(echo "$key_pair" | -e --no-pager -n 100; fi; }

# --- 主菜單 (來自 awk '/PrivateKey/ {print $2}' | tr -d '"'); public_key=$(echo "$key_pair腳本2) ---
main_menu() {
    clear
    white "Vless-reality, V" | awk '/PublicKey/ {print $2}' | tr -d '"')
    echo "$public_key"mess-ws, Hysteria-2, Tuic-v5 四協議共存腳本 (基於腳 > /etc/s-box/public.key; short_id=$(/etc/s-box/sing-本1)"
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green " 1. 安裝/重裝 Sing-box" 
    green " 2. 卸載 Sing-box"
    white "----------------box generate rand --hex 4)
    blue "已確認uuid (密碼)：${uuid}"; blue "Vmess------------------------------------------------------------------"
    green " 3. 重置/變更配置 (重新生成所有配置)"
 Path：/${uuid}-vm"
    configure_firewall "$port_vl_re" "$port_vm_ws    green " 4. 服務管理 (啟/停/重啟)"
    green " 5. 更新" "$port_hy2" "$port_tu"
    inssbjsonser; sbservice
 Sing-box 內核"
    white "----------------------------------------------------------------------------------"
    green " 6.    if post_install_check; then display_sharing_info; green "✅ Sing-box 安裝並 刷新並查看節點與配置"
    green " 7. 查看 Sing-box 運行日誌"
    green " 8. 申請 Acme 域名證書"
    green " 9. 雙配置成功！"; else red "❌ 安裝過程出現問題，請檢查日誌！"; fi
}

unins(){
    readp "確認卸載Sing-box嗎? [y/n]: " confirm; [[ "${棧VPS切換IP配置輸出"
    white "----------------------------------------------------------------------------------"
    green " 0. 退出腳本"
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    if [[ -f '/confirm,,}" != "y" ]] && yellow "卸載已取消" && return
    if [[ x"${release}" ==etc/s-box/sing-box' ]]; then 
        local corev; corev=$(/etc/s- x"alpine" ]]; then rc-service sing-box stop 2>/dev/null || true; rc-box/sing-box version 2>/dev/null | awk '/version/{print $NF}'); 
        green "update del sing-box 2>/dev/null || true; rm -f /etc/init.d/sing-Sing-box 核心已安裝：$corev"
        if systemctl is-active --quiet sing-box; else systemctl stop sing-box 2>/dev/null || true; systemctl disable sing-box 2>/dev/null || true; rm -f /etc/systemd/system/sing-box.service; systemctl daemon-reload 2>/dev/null || true; fi
    readp "是否刪除 /etc/s-box 和 /root/ieduerca, /root/ygkkkca 目錄與所有配置box || ( [[ x"${release}" == x"alpine" ]] && rc-service sing-box status 2？(y/n, 默認n): " rmconf; if [[ "${rmconf,,}" == "y" ]]; then rm -rf /etc/s-box /root/ieduerca /root/ygkkkca; green>/dev/null | grep -q 'started' ); then
            green "服務狀態：$(green '運行 "已刪除配置目錄。"; fi
    green "Sing-box 已卸載完成。"
}

中')"
        else
            yellow "服務狀態：$(yellow '未運行')"
        fi
    elsestclre(){ 
    echo -e "1) 重啟  2) 停止  3) 啟動  0) 返回"; readp "選擇【0-3】：" act
    if [[ x"${release}" 
        yellow "Sing-box 核心未安裝，請先選 1 。"
    fi
     == x"alpine" ]]; then case "$act" in 1) rc-service sing-box restart;; 2) rc-service sing-box stop;; 3) rc-service sing-box start;; esac
    else case "$act" in 1) systemctl restart sing-box;; 2) systemctl stop sing-box;; 3) systemctl start sing-box;; esac; fi
    green "操作完成"
}

sblog(){ ifred "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    readp "請輸入數字【0-9】：" Input
    case "$Input" in  
     1 ) install_or_reinstall;; 2 ) unins;; 3 [[ x"${release}" == x"alpine" ]]; then tail -n 100 /var/log/ ) install_or_reinstall;; 4 ) stclre;;
     5 ) inssb && sbservice && post_install_check && display_sharing_info;;
     6 ) display_sharing_info;; 7 ) sblog;; 8 ) apply_acme_cert;; 9 ) ipuuid && display_sharing_info;;
     * ) exit;;
    esac
}

# --- 腳本1的主體執行流程 ---

[[ $EUID -ne 0 ]] && yellow "请以root模式运行脚本" && exit

if [[ -messages 2>/dev/null || true; else journalctl -u sing-box -e --no-pager -n 100; fi; }

# --- 替換為腳本2的菜單 ---
main_menu()f /etc/redhat-release ]]; then release="Centos"; elif cat /etc/issue | grep -q -E -i "alpine"; then release="alpine"; elif cat /etc/issue | grep -q -E -i "debian"; then release="Debian"; elif cat /etc/issue | grep -q -E -i "ubuntu"; then release="Ubuntu"; else red "脚本不支持当前的系统。" && exit; fi
op=$(cat /etc/redhat {
    clear
    white "Vless-reality, Vmess-ws, Hysteria-2, Tu-release 2>/dev/null || cat /etc/os-release 2>/dev/null | grep -ic-v5 四協議共存腳本 (基於腳本1)"
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green " 1. 安裝/重裝 Sing-box" 
    green " 2. i pretty_name | cut -d \" -f2)
case $(uname -m) in armv7l)卸載 Sing-box"
    white "----------------------------------------------------------------------------------"
    green " 3. 重置 cpu=armv7;; aarch64) cpu=arm64;; x86_64) cpu/變更配置 (重新生成所有配置)"
    green " 4. 服務管理 (啟/停=amd64;; *) red "目前脚本不支持$(uname -m)架构" && exit;; esac
hostname/重啟)"
    green " 5. 更新 Sing-box 內核"
    white "----------------=$(hostname)

if [ ! -f /tmp/sbyg_update_lock ]; then
    green "首次------------------------------------------------------------------"
    green " 6. 刷新並查看節點與配置"
    green运行，开始安装必要的依赖……"
    if [[ x"${release}" == x"alpine" ]]; then
        apk " 7. 查看 Sing-box 運行日誌"
    green " 8. 申請 Acme 域名證書"
    green " 9. 雙棧VPS切換IP配置輸出"
    white "----------------------------------------------------------------------------------"
    green " 0. 退出腳本"
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ update; apk add jq openssl iproute2 iputils coreutils git socat iptables grep util-linux dc"
    if [[ -f '/etc/s-box/sing-box' ]]; then 
        local corev; corev=$(/etc/s-box/sing-box version 2>/dev/null | awkron tar tzdata qrencode virt-what bind-tools xxd
    else
        if [ -x "$( '/version/{print $NF}'); 
        green "Sing-box 核心已安裝：$corev"
        command -v apt-get)" ]; then
            apt-get update -y
            DEBIAN_FRONTif systemctl is-active --quiet sing-box || ( [[ x"${release}" == x"alpine" ]]END=noninteractive apt-get install -y jq cron socat iptables-persistent coreutils util-linux curl && rc-service sing-box status 2>/dev/null | grep -q 'started' ); then
            green "服務狀態：$(green '運行中')"
        else
            yellow "服務狀態：$(yellow openssl tar wget qrencode git iproute2 lsof virt-what dnsutils xxd
        elif [ '未運行')"
        fi
    else 
        yellow "Sing-box 核心未安裝，請先 -x "$(command -v yum)" ] || [ -x "$(command -v dnf)" ]; then
            local選 1 。"
    fi
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    readp "請 PKG_MANAGER=$(command -v yum || command -v dnf)
            $PKG_MANAGER install -y ep輸入數字【0-9】：" Input
    case "$Input" in  
     1 ) install_or_reel-release || true
            $PKG_MANAGER install -y jq socat coreutils util-linux curl openssl tarinstall;;
     2 ) unins;;
     3 ) install_or_reinstall;;
     4 ) stclre;;
     5 ) inssb && sbservice && post_install_check && display_sharing_info wget qrencode git cronie iptables-services iproute lsof virt-what bind-utils xxd
            ;;
     6 ) display_sharing_info;;
     7 ) sblog;;
     8 ) apply_acme_systemctl enable --now cronie 2>/dev/null || true
            systemctl enable --now iptables cert;;
     9 ) ipuuid && display_sharing_info;;
     * ) exit;;
    es2>/dev/null || true
        fi
    fi
    touch /tmp/sbyg_update_lock
    green "依赖安装完成。"
fi

main_menu