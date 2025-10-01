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

# Portable base64 with no line wrapping
base64_n0() {
    # Print base64 with no wrapping across distros
    if base64 --help 2>/dev/null | grep -q -- '--wrap'; then
        base64 --wrap=0
    elif base64 --help 2>/dev/null | grep -q -- '-w'; then
        base64 -w 0
    else
        base64
    fi
}

[[ $EUID -ne 0 ]] && yellow "請以root模式運行腳本" && exit

# --- 全局變量 ---
export sbfiles="/etc/s-box/sb10.json /etc/s-box/sb11.json /etc/s-box/sb.json"
hostname=$(hostname)

# --- 系統與依賴檢測 ---
check_os() {
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        case "${ID,,}" in
            ubuntu)   release="Ubuntu" ;;
            debian)   release="Debian" ;;
            centos|rhel|rocky|almalinux) release="Centos" ;;
            alpine)   release="alpine" ;;
            *)        red "腳本不支持當前的系統 (${PRETTY_NAME:-unknown})，請選擇使用Ubuntu, Debian, Centos/EL或Alpine。" && exit 1 ;;
        esac
        op="${PRETTY_NAME:-$ID}"
    else
        # Fallbacks for very old systems
        if [[ -f /etc/redhat-release ]]; then
            release="Centos"; op=$(cat /etc/redhat-release)
        elif grep -qi alpine /etc/issue 2>/dev/null; then
            release="alpine"; op="Alpine"
        elif grep -qi debian /etc/issue 2>/dev/null; then
            release="Debian"; op="Debian"
        elif grep -qi ubuntu /etc/issue 2>/dev/null; then
            release="Ubuntu"; op="Ubuntu"
        else
            red "腳本不支持當前的系統，請選擇使用Ubuntu, Debian, Centos/EL或Alpine。" && exit 1
        fi
    fi

    if echo "$op" | grep -qi -E "arch"; then
        red "腳本不支持當前的 $op 系統。" && exit 1
    fi

    case "$(uname -m)" in
        armv7l)  cpu=armv7 ;;
        aarch64) cpu=arm64 ;;
        x86_64)  cpu=amd64 ;;
        *) red "目前腳本不支持 $(uname -m) 架構" && exit 1 ;;
    esac

    vi=$(command -v systemd-detect-virt &>/dev/null && systemd-detect-virt || command -v virt-what &>/dev/null && virt-what || echo "unknown")
}

check_dependencies() {
    local pkgs=("curl" "openssl" "iptables" "tar" "wget" "jq" "socat" "qrencode" "git" "ss" "lsof" "virt-what")
    local missing_pkgs=()
    for pkg in "${pkgs[@]}"; do
        if ! command -v "$pkg" &> /dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        yellow "檢測到缺少以下核心依賴: ${missing_pkgs[*]}，將自動安裝。"
        install_dependencies
    fi
}

install_dependencies() {
    green "開始安裝必要的依賴……"
    if [[ x"${release}" == x"alpine" ]]; then
        apk update && apk add jq openssl iproute2 iputils coreutils git socat iptables grep util-linux dcron tar tzdata qrencode
    else
        if [ -x "$(command -v apt-get)" ]; then
            apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y jq cron socat iptables-persistent coreutils util-linux curl openssl tar wget qrencode git iproute2 lsof virt-what
        elif [ -x "$(command -v yum)" ]; then
            yum install -y epel-release
            yum install -y jq socat coreutils util-linux curl openssl tar wget qrencode git cronie iptables-services iproute lsof virt-what
            systemctl enable --now cronie 2>/dev/null
            systemctl enable --now iptables 2>/dev/null
        elif [ -x "$(command -v dnf)" ]; then
            dnf install -y jq socat coreutils util-linux curl openssl tar wget qrencode git cronie iptables-services iproute lsof virt-what
            systemctl enable --now cronie 2>/dev/null
            systemctl enable --now iptables 2>/dev/null
        fi
    fi
    green "依賴安裝完成。"
}

ensure_dirs() {
    mkdir -p /etc/s-box /root/ieduerca
    chmod 700 /etc/s-box
}

# --- 安裝全局快捷方式 ---
install_shortcut(){
    local target="/usr/local/bin/sb"
    local self
    self="$(realpath "${BASH_SOURCE[0]:-$0}" 2>/dev/null || readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")"
    [[ "$self" != /* ]] && self="$(pwd)/$self"
    if [[ ! -x "$target" ]] || ! grep -q "$self" "$target" 2>/dev/null; then
        cat >"$target" <<'EOX'
#!/usr/bin/env bash
# cursor shortcut wrapper for sb
exec "__SB_SCRIPT__" "$@"
EOX
        # replace placeholder with absolute script path
        sed -i "s|__SB_SCRIPT__|$self|g" "$target"
        chmod +x "$target"
        green "已安裝快捷命令：sb  （現在可直接輸入 sb 呼出腳本）"
    fi
    hash -r 2>/dev/null || true
}

# --- 網絡與防火牆 ---
v4v6(){
    v4=$(curl -fsS4m5 --retry 2 icanhazip.com || true)
    v6=$(curl -fsS6m5 --retry 2 icanhazip.com || true)
}

v6_setup(){
    if ! curl -fsS4m5 --retry 2 icanhazip.com >/dev/null 2>&1; then
        yellow "檢測到 純IPV6 VPS，添加NAT64"
        echo -e "nameserver 2a00:1098:2b::1\nnameserver 2a00:1098:2c::1" > /etc/resolv.conf
        ipv="prefer_ipv6"
    else
        ipv="prefer_ipv4"
    fi

    if curl -fsS6m5 --retry 2 icanhazip.com >/dev/null 2>&1; then
        endip="2606:4700:d0::a29f:c001"
    else
        endip="162.159.192.1"
    fi
}

configure_firewall() {
    green "正在配置防火牆..."
    local ports_to_open=("$@")
    for port in "${ports_to_open[@]}"; do
        if [[ -n "$port" ]]; then
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
            iptables -I INPUT -p udp --dport "$port" -j ACCEPT
            green "已開放端口: $port (TCP/UDP)"
        fi
    done
    
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
    elif command -v service &>/dev/null && service iptables save &>/dev/null; then
        service iptables save >/dev/null 2>&1 || true
    elif [[ -d /etc/iptables ]]; then
        iptables-save >/etc/iptables/rules.v4 2>/dev/null || true
        ip6tables-save >/etc/iptables/rules.v6 2>/dev/null || true
    fi
    green "防火牆規則已保存。"
}

remove_firewall_rules() {
    if [[ ! -f /etc/s-box/sb.json ]]; then return; fi
    green "正在移除防火牆規則..."
    local ports_to_close=()
    ports_to_close+=($(jq -r '.inbounds[].listen_port' /etc/s-box/sb.json 2>/dev/null))
    
    for port in "${ports_to_close[@]}"; do
        if [[ -n "$port" ]]; then
            iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
            iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null
            green "已關閉端口: $port (TCP/UDP)"
        fi
    done

    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
    elif command -v service &>/dev/null && service iptables save &>/dev/null; then
        service iptables save >/dev/null 2>&1 || true
    elif [[ -d /etc/iptables ]]; then
        iptables-save >/etc/iptables/rules.v4 2>/dev/null || true
        ip6tables-save >/etc/iptables/rules.v6 2>/dev/null || true
    fi
    green "防火牆規則已更新。"
}

# --- 證書管理（保留ACME，默認自簽在 inscertificate） ---
apply_acme_cert() {
    if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then
        green "首次運行，正在安裝acme.sh證書申請客戶端..."
        curl https://get.acme.sh | sh
        if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then
            red "acme.sh 安裝失敗，請檢查網絡或手動安裝。"
            return 1
        fi
    fi

    readp "請輸入您解析到本機的域名: " domain
    if [ -z "$domain" ]; then
        red "域名不能為空。"
        return 1
    fi
    
    # 嘗試釋放80端口
    if command -v lsof &>/dev/null && lsof -i:80 &>/dev/null; then
        yellow "檢測到80端口被佔用，將嘗試臨時停止常見服務..."
        systemctl stop nginx 2>/dev/null || true
        systemctl stop apache2 2>/dev/null || true
        systemctl stop httpd 2>/dev/null || true
        systemctl stop caddy 2>/dev/null || true
    elif ss -H -ltn sport = :80 2>/dev/null | grep -q .; then
        yellow "檢測到80端口被佔用，將嘗試臨時停止常見服務..."
        systemctl stop nginx 2>/dev/null || true
        systemctl stop apache2 2>/dev/null || true
        systemctl stop httpd 2>/dev/null || true
        systemctl stop caddy 2>/dev/null || true
    fi

    green "正在嘗試通過80端口獨立模式申請證書..."
    ~/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256
    
    systemctl start nginx 2>/dev/null; systemctl start apache2 2>/dev/null; systemctl start httpd 2>/dev/null

    local cert_path="/root/ieduerca"
    if ~/.acme.sh/acme.sh --list | grep -q "$domain"; then
        mkdir -p "$cert_path"
        if ~/.acme.sh/acme.sh --install-cert -d "$domain" --key-file "${cert_path}/private.key" --fullchain-file "${cert_path}/cert.crt" --ecc; then
            green "證書申請成功並已安裝到 ${cert_path}"
            echo "$domain" > "${cert_path}/ca.log"
            return 0
        else
            red "證書安裝失敗。"
            return 1
        fi
    else
        red "證書申請失敗，請檢查域名解析和80端口。"
        return 1
    fi
}

# 默認自簽，無交互
inscertificate(){
    # 默認使用自簽；如需 ACME，請用菜單 10 申請後再執行「變更配置」
    ym_vl_re=apple.com
    tlsyn=false
    ym_vm_ws=www.bing.com
    ensure_dirs
    openssl ecparam -genkey -name prime256v1 -out /etc/s-box/private.key >/dev/null 2>&1 || true
    openssl req -new -x509 -days 36500 -key /etc/s-box/private.key -out /etc/s-box/cert.pem -subj "/CN=www.bing.com" >/dev/null 2>&1 || true
    certificatec_vmess_ws='/etc/s-box/cert.pem'; certificatep_vmess_ws='/etc/s-box/private.key'
    certificatec_hy2='/etc/s-box/cert.pem';    certificatep_hy2='/etc/s-box/private.key'
    certificatec_tuic='/etc/s-box/cert.pem';   certificatep_tuic='/etc/s-box/private.key'
    blue "Vless-reality 的 SNI 默認：apple.com"
    blue "Vmess-ws 默認關閉 TLS；Hysteria-2 / Tuic-v5 使用自簽，關閉嚴格驗證"
}

# --- 端口管理 ---
check_port_in_use() {
    local port_to_check=$1
    if ss -H -tunlp 2>/dev/null | awk -v p=":$port_to_check" '$5 ~ p"$" {found=1} END{exit !found}'; then
        return 0
    else
        return 1
    fi
}

# 非常用端口自動選擇
pick_uncommon_ports(){
    local exclude_ports="22 53 80 123 443 587 110 143 993 995 3306 5432 6379 8080 8443 25 21 3389 1521 27017 5000 8888 27015 25565"
    local chosen=()
    while [ ${#chosen[@]} -lt 4 ]; do
        local p; p=$(shuf -i 20000-65000 -n 1)
        if echo " $exclude_ports " | grep -q " $p "; then continue; fi
        if check_port_in_use "$p"; then continue; fi
        local dup=0; for c in "${chosen[@]}"; do [[ "$c" == "$p" ]] && dup=1 && break; done
        [[ $dup -eq 1 ]] && continue
        chosen+=("$p")
    done
    port_vl_re=${chosen[0]}
    port_vm_ws=${chosen[1]}
    port_hy2=${chosen[2]}
    port_tu=${chosen[3]}
}

# --- sing-box核心安裝與配置 ---
inssb(){
    ensure_dirs
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green "自動選擇並安裝 Sing-box 最新正式版（默認）"
    sbcore=$(curl -Ls https://data.jsdelivr.com/v1/package/gh/SagerNet/sing-box | grep -Eo '"[0-9.]+"' | sed -n 1p | tr -d '",')
    if [ -z "$sbcore" ]; then
        red "獲取Sing-box版本號失敗，請檢查網絡。" && exit 1
    fi
    
    green "正在下載 Sing-box v$sbcore ..."
    local sbname="sing-box-$sbcore-linux-$cpu"
    curl -L -o /etc/s-box/sing-box.tar.gz -# --retry 2 "https://github.com/SagerNet/sing-box/releases/download/v$sbcore/$sbname.tar.gz"
    
    if [[ ! -f '/etc/s-box/sing-box.tar.gz' || ! -s '/etc/s-box/sing-box.tar.gz' ]]; then
        red "下載 Sing-box 內核失敗，請檢查VPS網絡是否可以訪問Github。" && exit 1
    fi
    
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box
    mv "/etc/s-box/$sbname/sing-box" /etc/s-box
    rm -rf "/etc/s-box/sing-box.tar.gz" "/etc/s-box/$sbname"
    
    if [[ -f '/etc/s-box/sing-box' ]]; then
        chmod +x /etc/s-box/sing-box
        blue "成功安裝 Sing-box 內核版本：$(/etc/s-box/sing-box version | awk '/version/{print $NF}')"
        install_shortcut
        yellow "提示：現在可以在任意目錄執行 ${bblue}sb${plain} 喚起腳本。"
        if /etc/s-box/sing-box version >/dev/null 2>&1; then
            green "內核安裝校驗通過。"
        else
            red "內核安裝校驗可能失敗，請檢查 /etc/s-box/sing-box 是否存在。"
        fi
        # 首次安裝後自動生成默認配置並啟動
        if [[ ! -f /etc/s-box/sb.json ]]; then
            blue "首次安裝：正在自動生成默認配置並啟動服務..."
            auto_config_and_start
        fi
    else
        red "解壓或移動 Sing-box 內核失敗，安裝終止。" && exit 1
    fi
}

# --- 自動默認配置安裝與啟動 ---
auto_config_and_start(){
    # 1) 自簽默認證書與變量（無交互）
    ensure_dirs
    openssl ecparam -genkey -name prime256v1 -out /etc/s-box/private.key >/dev/null 2>&1 || true
    openssl req -new -x509 -days 36500 -key /etc/s-box/private.key -out /etc/s-box/cert.pem -subj "/CN=www.bing.com" >/dev/null 2>&1 || true
    tlsyn=false
    ym_vl_re=apple.com
    ym_vm_ws=www.bing.com
    certificatec_vmess_ws='/etc/s-box/cert.pem'; certificatep_vmess_ws='/etc/s-box/private.key'
    certificatec_hy2='/etc/s-box/cert.pem';    certificatep_hy2='/etc/s-box/private.key'
    certificatec_tuic='/etc/s-box/cert.pem';   certificatep_tuic='/etc/s-box/private.key'

    # 2) 端口（自動選擇非常用端口，無交互）
    pick_uncommon_ports

    # 3) UUID、Reality材料、網絡策略
    uuid=$(/etc/s-box/sing-box generate uuid)
    generate_reality_materials
    v6_setup

    # 4) 生成配置、開放防火牆、啟動服務
    inssbjsonser
    configure_firewall "$port_vl_re" "$port_vm_ws" "$port_hy2" "$port_tu"
    sbservice

    # 5) 生成出站/訂閱輔助信息
    ipuuid || true
    result_vl_vm_hy_tu || true
    gen_clash_sub || true

    green "默認配置已生成並啟動。配置文件：/etc/s-box/sb.json"
    yellow "節點與訂閱：/etc/s-box/{vl_reality.txt,vm_ws*.txt,hy2.txt,tuic5.txt,clash_sub.json}"
}

# Backward-compat wrapper for older menu typo
instsllsingbox(){ inssb; }

# 端口與 UUID（無交互）
insport(){
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green "三、設置各協議端口（自動選擇非常用端口，避免佔用）"
    pick_uncommon_ports
    blue "Vless-reality端口：$port_vl_re"
    blue "Vmess-ws端口：$port_vm_ws"
    blue "Hysteria-2端口：$port_hy2"
    blue "Tuic-v5端口：$port_tu"
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green "四、生成統一UUID"
    uuid=$(/etc/s-box/sing-box generate uuid)
    blue "已確認uuid (密碼)：${uuid}"
}

# --- Reality materials (generate if missing) ---
generate_reality_materials() {
    ensure_dirs
    local out="/etc/s-box/reality.out"
    local pubfile="/etc/s-box/public.key"
    local jsonfile="/etc/s-box/reality.json"
    local rk pub

    # Only (re)generate if we don't have a public key file or the private_key var is empty
    if [[ ! -s "$pubfile" || -z "${private_key:-}" ]]; then
        # Capture generator output (some versions print JSON, others plain text)
        /etc/s-box/sing-box generate reality-keypair >"$out" 2>/dev/null || true

        # Try JSON first
        if jq -e -r '.private_key,.public_key' "$out" >/dev/null 2>&1; then
            private_key=$(jq -r '.private_key' "$out")
            jq -r '.public_key' "$out" > "$pubfile"
        else
            # Fallback: parse textual formats like:
            #   PrivateKey: xxxxx
            #   PublicKey:  yyyyy
            private_key=$(awk -F'[: ]+' 'BEGIN{IGNORECASE=1} /Private[ _-]*Key/{print $NF; exit}' "$out")
            pub=$(awk -F'[: ]+' 'BEGIN{IGNORECASE=1} /Public[ _-]*Key/{print $NF; exit}' "$out")

            # If still empty, try capturing to a variable (some builds write to stderr)
            if [[ -z "$private_key" || -z "$pub" ]]; then
                rk=$(/etc/s-box/sing-box generate reality-keypair 2>/dev/null || true)
                private_key=${private_key:-$(echo "$rk" | awk -F'[: ]+' 'BEGIN{IGNORECASE=1} /Private[ _-]*Key/{print $NF; exit}')}
                pub=${pub:-$(echo "$rk" | awk -F'[: ]+' 'BEGIN{IGNORECASE=1} /Public[ _-]*Key/{print $NF; exit}')}
            fi

            if [[ -n "$private_key" && -n "$pub" ]]; then
                printf '%s\n' "$pub" > "$pubfile"
            else
                red "生成 Reality 密鑰失敗，請確認 /etc/s-box/sing-box 是否可執行與兼容。"
                exit 1
            fi
        fi
    fi

    # short_id is an 8-16 hex string (robust, correct format, OpenSSL fallback)
    : "${short_id:=$(head -c 8 /dev/urandom | hexdump -e '1/1 "%02x"' 2>/dev/null || openssl rand -hex 8)}"

    # Always export a compatible JSON for legacy code paths
    if [[ -n "${private_key:-}" && -s "$pubfile" ]]; then
        pub=$(cat "$pubfile")
        printf '{ "private_key": "%s", "public_key": "%s" }\n' "$private_key" "$pub" > "$jsonfile"
    fi
}

# Sane defaults if 證書部分未配置
: "${ym_vl_re:=apple.com}"
: "${tlsyn:=false}"
: "${ym_vm_ws:=www.bing.com}"
: "${certificatec_vmess_ws:=/etc/s-box/cert.pem}"
: "${certificatep_vmess_ws:=/etc/s-box/private.key}"
: "${certificatec_hy2:=/etc/s-box/cert.pem}"
: "${certificatep_hy2:=/etc/s-box/private.key}"
: "${certificatec_tuic:=/etc/s-box/cert.pem}"
: "${certificatep_tuic:=/etc/s-box/private.key}"

inssbjsonser(){
    ensure_dirs
    generate_reality_materials
    cat > /etc/s-box/sb10.json <<EOF
{
"log": { "disabled": false, "level": "info", "timestamp": true },
"inbounds": [
    { "type": "vless", "sniff": true, "sniff_override_destination": true, "tag": "vless-sb", "listen": "::", "listen_port": ${port_vl_re},
      "users": [ { "uuid": "${uuid}", "flow": "xtls-rprx-vision" } ],
      "tls": { "enabled": true, "server_name": "${ym_vl_re}", "reality": { "enabled": true, "handshake": { "server": "${ym_vl_re}", "server_port": 443 }, "private_key": "$private_key", "short_id": ["$short_id"] } }
    },
    { "type": "vmess", "sniff": true, "sniff_override_destination": true, "tag": "vmess-sb", "listen": "::", "listen_port": ${port_vm_ws},
      "users": [ { "uuid": "${uuid}", "alterId": 0 } ],
      "transport": { "type": "ws", "path": "/${uuid}-vm", "max_early_data": 2048, "early_data_header_name": "Sec-WebSocket-Protocol" },
      "tls":{ "enabled": ${tlsyn}, "server_name": "${ym_vm_ws}", "certificate_path": "$certificatec_vmess_ws", "key_path": "$certificatep_vmess_ws" }
    }, 
    { "type": "hysteria2", "sniff": true, "sniff_override_destination": true, "tag": "hy2-sb", "listen": "::", "listen_port": ${port_hy2},
      "users": [ { "password": "${uuid}" } ], "ignore_client_bandwidth": false,
      "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$certificatec_hy2", "key_path": "$certificatep_hy2" }
    },
    { "type": "tuic", "sniff": true, "sniff_override_destination": true, "tag": "tuic5-sb", "listen": "::", "listen_port": ${port_tu},
      "users": [ { "uuid": "${uuid}", "password": "${uuid}" } ], "congestion_control": "bbr",
      "tls":{ "enabled": true, "alpn": ["h3"], "certificate_path": "$certificatec_tuic", "key_path": "$certificatep_tuic" }
    }
],
"outbounds": [
    { "type": "direct", "tag": "direct", "domain_strategy": "$ipv" },
    { "type": "block", "tag": "block" }
],
"route": {
  "rules": [
    { "protocol": "stun", "outbound": "block" },
    { "protocol": "quic", "outbound": "block" }
  ],
  "final": "direct"
}
}
EOF

    cat > /etc/s-box/sb11.json <<EOF
{
"log": { "disabled": false, "level": "info", "timestamp": true },
"inbounds": [
    { "type": "vless", "tag": "vless-sb", "listen": "::", "listen_port": ${port_vl_re},
      "users": [ { "uuid": "${uuid}", "flow": "xtls-rprx-vision" } ],
      "tls": { "enabled": true, "server_name": "${ym_vl_re}", "reality": { "enabled": true, "handshake": { "server": "${ym_vl_re}", "server_port": 443 }, "private_key": "$private_key", "short_id": ["$short_id"] } }
    },
    { "type": "vmess", "tag": "vmess-sb", "listen": "::", "listen_port": ${port_vm_ws},
      "users": [ { "uuid": "${uuid}", "alterId": 0 } ],
      "transport": { "type": "ws", "path": "/${uuid}-vm", "max_early_data": 2048, "early_data_header_name": "Sec-WebSocket-Protocol" },
      "tls":{ "enabled": ${tlsyn}, "server_name": "${ym_vm_ws}", "certificate_path": "$certificatec_vmess_ws", "key_path": "$certificatep_vmess_ws" }
    }, 
    { "type": "hysteria2", "tag": "hy2-sb", "listen": "::", "listen_port": ${port_hy2},
      "users": [ { "password": "${uuid}" } ], "ignore_client_bandwidth": false,
      "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "$certificatec_hy2", "key_path": "$certificatep_hy2" }
    },
    { "type": "tuic", "tag": "tuic5-sb", "listen": "::", "listen_port": ${port_tu},
      "users": [ { "uuid": "${uuid}", "password": "${uuid}" } ], "congestion_control": "bbr",
      "tls":{ "enabled": true, "alpn": ["h3"], "certificate_path": "$certificatec_tuic", "key_path": "$certificatep_tuic" }
    }
],
"outbounds": [
    { "type": "direct", "tag": "direct", "domain_strategy": "$ipv" },
    { "type": "direct", "tag": "vps-outbound-v4", "domain_strategy": "prefer_ipv4" },
    { "type": "direct", "tag": "vps-outbound-v6", "domain_strategy": "prefer_ipv6" }
],
"route": {
  "rules": [
    { "protocol": "stun", "outbound": "block" },
    { "protocol": "quic", "outbound": "block" }
  ],
  "final": "direct"
}
}
EOF
sbnh=$(/etc/s-box/sing-box version 2>/dev/null | awk '/version/{print $NF}' | cut -d '.' -f 1,2)
[[ "$sbnh" == "1.10" ]] && num=10 || num=11
cp "/etc/s-box/sb${num}.json" /etc/s-box/sb.json
}

sbservice(){
if [[ x"${release}" == x"alpine" ]]; then
echo '#!/sbin/openrc-run
description="sing-box service"
command="/etc/s-box/sing-box"
command_args="run -c /etc/s-box/sb.json"
command_background=true
pidfile="/var/run/sing-box.pid"' > /etc/init.d/sing-box
chmod +x /etc/init.d/sing-box
rc-update add sing-box default
# 配置校驗
if ! /etc/s-box/sing-box check -c /etc/s-box/sb.json; then
    red "配置校驗失敗，未啟動服務。請檢查 /etc/s-box/sb.json"; return 1; fi
rc-service sing-box start
else
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
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
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1
# 配置校驗
if ! /etc/s-box/sing-box check -c /etc/s-box/sb.json; then
    red "配置校驗失敗，未啟動服務。請檢查 /etc/s-box/sb.json"; return 1; fi
systemctl start sing-box
systemctl restart sing-box
# 健康檢查
if ! systemctl -q is-active sing-box; then
    red "Sing-box 服務未運行。最近的錯誤："
    journalctl -u sing-box -n 50 --no-pager || true
fi
fi
}

ipuuid(){
if [[ x"${release}" == x"alpine" ]]; then status_cmd="rc-service sing-box status"; status_pattern="started"; else status_cmd="systemctl status sing-box"; status_pattern="active"; fi
if [[ -n $($status_cmd 2>/dev/null | grep -w "$status_pattern") && -f '/etc/s-box/sb.json' ]]; then
v4v6
if [[ -n $v6 ]]; then
    sbdnsip='tls://[2001:4860:4860::8888]/dns-query'
    server_ip="[$v6]"; server_ipcl="$v6"
elif [[ -n $v4 ]]; then
    sbdnsip='tls://8.8.8.8/dns-query'
    server_ip="$v4"; server_ipcl="$v4"
else
    serip=$(curl -s4m5 icanhazip.com -k || curl -s6m5 icanhazip.com -k)
    if [[ "$serip" =~ : ]]; then sbdnsip='tls://[2001:4860:4860::8888]/dns-query'; server_ip="[$serip]"; server_ipcl="$serip"; else sbdnsip='tls://8.8.8.8/dns-query'; server_ip="$serip"; server_ipcl="$serip"; fi
fi

# 保存
echo "$sbdnsip" > /etc/s-box/sbdnsip.log; echo "$server_ip" > /etc/s-box/server_ip.log; echo "$server_ipcl" > /etc/s-box/server_ipcl.log
else red "Sing-box服務未運行"; return 1; fi
}

wgcfgo(){ ipuuid; }

# 綜合輸出分享與訂閱
clash_sb_share(){
    if ! ipuuid; then
        red "Sing-box 服務未運行，請先選 1 安裝或 3 變更配置後啟動。"
        return
    fi
    result_vl_vm_hy_tu
    resvless
    resvmess
    reshy2
    restu5
    gen_clash_sub
    green "Clash/Mihomo 訂閱已生成：/etc/s-box/clash_sub.json"
}

# 兼容別名
sbshare(){ clash_sb_share; }

# 啟停/重啟
stclre(){
    echo -e "1) 重啟  2) 停止  3) 啟動  0) 返回"
    readp "選擇【0-3】：" act
    if [[ x"${release}" == x"alpine" ]]; then
        case "$act" in
            1) rc-service sing-box restart;;
            2) rc-service sing-box stop;;
            3) rc-service sing-box start;;
            *) return;;
        esac
    else
        case "$act" in
            1) systemctl restart sing-box;;
            2) systemctl stop sing-box;;
            3) systemctl start sing-box;;
            *) return;;
        esac
    fi
}

# 切換/更新內核（簡化：走安裝流程）
upsbcroe(){ inssb; }

# 查看運行日誌
sblog(){
    if [[ x"${release}" == x"alpine" ]]; then
        rc-service sing-box status || true
        tail -n 200 /var/log/messages 2>/dev/null || true
    else
        journalctl -u sing-box -e --no-pager
    fi
}

# 腳本更新（暫不實作）
upsbyg(){ yellow "暫未實作：更新腳本。請使用最新 sb.sh 覆蓋當前版本。"; }

# 使用說明（簡版）
sbsm(){
    blue "安裝內核 → 自動生成默認配置 → 開機自啟。"
    blue "可用功能：變更證書/端口、生成訂閱、查看日誌、開啟BBR。"
    blue "分享/訂閱輸出：選 7 或 11（雙棧選 IP）。產物在 /etc/s-box/"
}

# 卸載
unins(){
    remove_firewall_rules
    if [[ x"${release}" == x"alpine" ]]; then
        rc-service sing-box stop 2>/dev/null || true
        rc-update del sing-box 2>/dev/null || true
        rm -f /etc/init.d/sing-box
    else
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload 2>/dev/null || true
    fi
    readp "是否刪除 /etc/s-box 目錄與所有配置？(y/n, 默認n): " rmconf
    if [[ "$rmconf" == "y" || "$rmconf" == "Y" ]]; then
        rm -rf /etc/s-box
        green "已刪除 /etc/s-box。"
    fi
    readp "是否移除快捷命令 sb？(y/n, 默認n): " rmsb
    if [[ "$rmsb" == "y" || "$rmsb" == "Y" ]]; then
        rm -f /usr/local/bin/sb
        hash -r 2>/dev/null || true
        green "已移除 sb 命令。"
    fi
    green "Sing-box 已卸載完成。"
}

result_vl_vm_hy_tu(){
if [[ -f /root/ieduerca/cert.crt && -f /root/ieduerca/private.key && -s /root/ieduerca/cert.crt && -s /root/ieduerca/private.key ]]; then ym=$(bash ~/.acme.sh/acme.sh --list | tail -1 | awk '{print $1}'); echo "$ym" > /root/ieduerca/ca.log; fi
rm -rf /etc/s-box/vm_ws.txt /etc/s-box/vm_ws_tls.txt; sbdnsip=$(cat /etc/s-box/sbdnsip.log 2>/dev/null || echo 'tls://8.8.8.8/dns-query'); server_ip=$(cat /etc/s-box/server_ip.log 2>/dev/null || true); server_ipcl=$(cat /etc/s-box/server_ipcl.log 2>/dev/null || true); uuid=$(jq -r '.inbounds[0].users[0].uuid' /etc/s-box/sb.json); vl_port=$(jq -r '.inbounds[0].listen_port' /etc/s-box/sb.json); vl_name=$(jq -r '.inbounds[0].tls.server_name' /etc/s-box/sb.json); public_key=$(cat /etc/s-box/public.key); short_id=$(jq -r '.inbounds[0].tls.reality.short_id[0]' /etc/s-box/sb.json); ws_path=$(jq -r '.inbounds[1].transport.path' /etc/s-box/sb.json); vm_port=$(jq -r '.inbounds[1].listen_port' /etc/s-box/sb.json); tls=$(jq -r '.inbounds[1].tls.enabled' /etc/s-box/sb.json); vm_name=$(jq -r '.inbounds[1].tls.server_name' /etc/s-box/sb.json)
if [[ "$tls" = "false" ]]; then vmadd_local=$server_ipcl; vmadd_are_local=$server_ip; else vmadd_local=$vm_name; vmadd_are_local=$vm_name; fi
hy2_port=$(jq -r '.inbounds[2].listen_port' /etc/s-box/sb.json); ym=$(cat /root/ieduerca/ca.log 2>/dev/null); hy2_sniname=$(jq -r '.inbounds[2].tls.key_path' /etc/s-box/sb.json); if [[ "$hy2_sniname" = '/etc/s-box/private.key' ]]; then hy2_name=www.bing.com; sb_hy2_ip=$server_ip; cl_hy2_ip=$server_ipcl; ins_hy2=1; hy2_ins=true; else hy2_name=$ym; sb_hy2_ip=$ym; cl_hy2_ip=$ym; ins_hy2=0; hy2_ins=false; fi
tu5_port=$(jq -r '.inbounds[3].listen_port' /etc/s-box/sb.json); tu5_sniname=$(jq -r '.inbounds[3].tls.key_path' /etc/s-box/sb.json); if [[ "$tu5_sniname" = '/etc/s-box/private.key' ]]; then tu5_name=www.bing.com; sb_tu5_ip=$server_ip; cl_tu5_ip=$server_ipcl; ins=1; tu5_ins=true; else tu5_name=$ym; sb_tu5_ip=$ym; cl_tu5_ip=$ym; ins=0; tu5_ins=false; fi
}

# 生成 Clash/Mihomo 訂閱模板
gen_clash_sub(){
    # Ensure latest runtime vars are loaded from sb.json and helper logs
    result_vl_vm_hy_tu

    # Normalize WS path for client (remove leading slash)
    ws_path_client=$(echo "$ws_path" | sed 's#^/##')

    # Public key for Reality
    public_key=$(cat /etc/s-box/public.key 2>/dev/null)

    # Tags for outbounds
    tag_vless="vless-${hostname}"
    tag_vmess="vmess-${hostname}"
    tag_hy2="hy2-${hostname}"
    tag_tuic="tuic5-${hostname}"

    # Proxydns address from saved choice (v4/v6)
    sbdnsip=$(cat /etc/s-box/sbdnsip.log 2>/dev/null)
    : "${sbdnsip:=tls://8.8.8.8/dns-query}"

    cat > /etc/s-box/clash_sub.json <<EOF
{
  "log": { "disabled": false, "level": "info", "timestamp": true },
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "external_ui": "ui",
      "external_ui_download_url": "",
      "external_ui_download_detour": "",
      "secret": "",
      "default_mode": "Rule"
    },
    "cache_file": {
      "enabled": true,
      "path": "cache.db",
      "store_fakeip": true
    }
  },
  "dns": {
    "servers": [
      { "tag": "proxydns", "address": "${sbdnsip}", "detour": "select" },
      { "tag": "localdns", "address": "h3://223.5.5.5/dns-query", "detour": "direct" },
      { "tag": "dns_fakeip", "address": "fakeip" }
    ],
    "rules": [
      { "outbound": "any", "server": "localdns", "disable_cache": true },
      { "clash_mode": "Global", "server": "proxydns" },
      { "clash_mode": "Direct", "server": "localdns" },
      { "rule_set": "geosite-cn", "server": "localdns" },
      { "rule_set": "geosite-geolocation-!cn", "server": "proxydns" },
      { "rule_set": "geosite-geolocation-!cn", "query_type": ["A", "AAAA"], "server": "dns_fakeip" }
    ],
    "fakeip": { "enabled": true, "inet4_range": "198.18.0.0/15", "inet6_range": "fc00::/18" },
    "independent_cache": true,
    "final": "proxydns"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30", "fd00::1/126"],
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
      "default": "auto",
      "outbounds": ["auto", "${tag_vless}", "${tag_vmess}", "${tag_hy2}", "${tag_tuic}"]
    },
    {
      "type": "vless",
      "tag": "${tag_vless}",
      "server": "${server_ipcl}",
      "server_port": ${vl_port},
      "uuid": "${uuid}",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "${vl_name}",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": { "enabled": true, "public_key": "${public_key}", "short_id": "${short_id}" }
      }
    },
    {
      "type": "vmess",
      "tag": "${tag_vmess}",
      "server": "${vmadd_local}",
      "server_port": ${vm_port},
      "uuid": "${uuid}",
      "security": "auto",
      "packet_encoding": "packetaddr",
      "transport": { "type": "ws", "path": "${ws_path_client}", "headers": { "Host": ["${vm_name}"] } },
      "tls": {
        "enabled": ${tls},
        "server_name": "${vm_name}",
        "insecure": false,
        "utls": { "enabled": true, "fingerprint": "chrome" }
      }
    },
    {
      "type": "hysteria2",
      "tag": "${tag_hy2}",
      "server": "${cl_hy2_ip}",
      "server_port": ${hy2_port},
      "password": "${uuid}",
      "tls": { "enabled": true, "server_name": "${hy2_name}", "insecure": ${hy2_ins}, "alpn": ["h3"] }
    },
    {
      "type": "tuic",
      "tag": "${tag_tuic}",
      "server": "${cl_tu5_ip}",
      "server_port": ${tu5_port},
      "uuid": "${uuid}",
      "password": "${uuid}",
      "congestion_control": "bbr",
      "udp_relay_mode": "native",
      "udp_over_stream": false,
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": { "enabled": true, "server_name": "${tu5_name}", "insecure": ${tu5_ins}, "alpn": ["h3"] }
    },
    { "tag": "direct", "type": "direct" },
    {
      "tag": "auto",
      "type": "urltest",
      "outbounds": ["${tag_vless}", "${tag_vmess}", "${tag_hy2}", "${tag_tuic}"],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "1m",
      "tolerance": 50,
      "interrupt_exist_connections": false
    }
  ],
  "route": {
    "rule_set": [
      { "tag": "geosite-geolocation-!cn", "type": "remote", "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/geolocation-!cn.srs",
        "download_detour": "select", "update_interval": "1d" },
      { "tag": "geosite-cn", "type": "remote", "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/geolocation-cn.srs",
        "download_detour": "select", "update_interval": "1d" },
      { "tag": "geoip-cn", "type": "remote", "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/cn.srs",
        "download_detour": "select", "update_interval": "1d" }
    ],
    "auto_detect_interface": true,
    "final": "select",
    "rules": [
      { "inbound": "tun-in", "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "port": 443, "network": "udp", "action": "reject" },
      { "clash_mode": "Direct", "outbound": "direct" },
      { "clash_mode": "Global", "outbound": "select" },
      { "rule_set": "geoip-cn", "outbound": "direct" },
      { "rule_set": "geosite-cn", "outbound": "direct" },
      { "ip_is_private": true, "outbound": "direct" },
      { "rule_set": "geosite-geolocation-!cn", "outbound": "select" }
    ]
  },
  "ntp": { "enabled": true, "server": "time.apple.com", "server_port": 123, "interval": "30m", "detour": "direct" }
}
EOF

    if jq empty /etc/s-box/clash_sub.json >/dev/null 2>&1; then
        green "Clash/Mihomo 訂閱模板已生成：/etc/s-box/clash_sub.json"
    else
        red "訂閱模板 JSON 生成後無法通過校驗，請檢查變量是否完整。"
    fi
}

resvless(){ echo; white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"; vl_link="vless://$uuid@$server_ip:$vl_port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$vl_name&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#vl-reality-$hostname"; echo "$vl_link" > /etc/s-box/vl_reality.txt; red "🚀【 vless-reality-vision 】节点信息如下："; echo; echo "分享链接："; echo -e "${yellow}$vl_link${plain}"; echo; echo "二维码："; qrencode -o - -t ANSIUTF8 "$vl_link"; white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"; echo; }
resvmess(){ echo; white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"; if [[ "$tls" = "false" ]]; then red "🚀【 vmess-ws 】节点信息如下："; vmess_json="{\"add\":\"$server_ipcl\",\"aid\":\"0\",\"host\":\"$vm_name\",\"id\":\"$uuid\",\"net\":\"ws\",\"path\":\"$ws_path\",\"port\":\"$vm_port\",\"ps\":\"vm-ws-$hostname\",\"tls\":\"\",\"type\":\"none\",\"v\":\"2\"}"; vmess_link="vmess://$(echo "$vmess_json" | base64_n0)"; echo "$vmess_link" > /etc/s-box/vm_ws.txt; else red "🚀【 vmess-ws-tls 】节点信息如下："; vmess_json="{\"add\":\"$vm_name\",\"aid\":\"0\",\"host\":\"$vm_name\",\"id\":\"$uuid\",\"net\":\"ws\",\"path\":\"$ws_path\",\"port\":\"$vm_port\",\"ps\":\"vm-ws-tls-$hostname\",\"tls\":\"tls\",\"sni\":\"$vm_name\",\"type\":\"none\",\"v\":\"2\"}"; vmess_link="vmess://$(echo "$vmess_json" | base64_n0)"; echo "$vmess_link" > /etc/s-box/vm_ws_tls.txt; fi; echo; echo "分享链接："; echo -e "${yellow}$vmess_link${plain}"; echo; echo "二维码："; qrencode -o - -t ANSIUTF8 "$vmess_link"; white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"; echo; }
reshy2(){ echo; white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"; hy2_link="hysteria2://$uuid@$cl_hy2_ip:$hy2_port?security=tls&alpn=h3&insecure=$hy2_ins&sni=$hy2_name#hy2-$hostname"; echo "$hy2_link" > /etc/s-box/hy2.txt; red "🚀【 Hysteria-2 】节点信息如下："; echo; echo "分享链接："; echo -e "${yellow}$hy2_link${plain}"; echo; echo "二维码："; qrencode -o - -t ANSIUTF8 "$hy2_link"; white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"; echo; }
restu5(){ echo; white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"; tuic5_link="tuic://$uuid:$uuid@$cl_tu5_ip:$tu5_port?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$tu5_name&allow_insecure=$ins&allowInsecure=$ins#tu5-$hostname"; echo "$tuic5_link" > /etc/s-box/tuic5.txt; red "🚀【 Tuic-v5 】节点信息如下："; echo; echo "分享链接："; echo -e "${yellow}$tuic5_link${plain}"; echo; echo "二维码："; qrencode -o - -t ANSIUTF8 "$tuic5_link"; white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"; echo; }

# --- 交互變更配置流程（已盡可能默認） ---
changeserv(){
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green "變更配置流程開始：默認自簽證書 / 自動端口 / 自動IP優先"
    inscertificate
    insport
    v6_setup
    inssbjsonser
    configure_firewall "$port_vl_re" "$port_vm_ws" "$port_hy2" "$port_tu"
    sbservice
    ipuuid || true
    result_vl_vm_hy_tu || true
    gen_clash_sub || true
    green "配置已更新並啟動。可在 /etc/s-box 查看相關文件。"
}

# --- 協議端口狀態摘要 ---
showprotocol(){
    if [[ ! -s /etc/s-box/sb.json ]] || ! jq -e . /etc/s-box/sb.json >/dev/null 2>&1; then
        yellow "尚未生成運行配置（/etc/s-box/sb.json）。選擇【3】生成/調整配置，或按【1】安裝內核/依賴。"
        return 0
    fi
    local vl_port vm_port hy2_port tu_port
    vl_port=$(jq -r '.inbounds[]? | select(.type=="vless")      | .listen_port // empty' /etc/s-box/sb.json 2>/dev/null || true)
    vm_port=$(jq -r '.inbounds[]? | select(.type=="vmess")      | .listen_port // empty' /etc/s-box/sb.json 2>/dev/null || true)
    hy2_port=$(jq -r '.inbounds[]? | select(.type=="hysteria2")  | .listen_port // empty' /etc/s-box/sb.json 2>/dev/null || true)
    tu_port=$(jq -r '.inbounds[]? | select(.type=="tuic")       | .listen_port // empty' /etc/s-box/sb.json 2>/dev/null || true)
    [[ -n "$vl_port"  ]] && blue "VLESS-REALITY  端口：$vl_port"
    [[ -n "$vm_port"  ]] && blue "VMESS-WS       端口：$vm_port"
    [[ -n "$hy2_port" ]] && blue "HY2            端口：$hy2_port"
    [[ -n "$tu_port"  ]] && blue "TUIC v5        端口：$tu_port"
}

# --- BBR 安裝模塊 (內置, 無重啟) ---
install_bbr_local() {
    if [[ $vi =~ lxc|openvz ]]; then
        yellow "當前VPS的架構為 $vi，不支持安裝原版BBR。"
        return
    fi

    # 檢查內核版本
    local kernel_version
    kernel_version=$(uname -r | cut -d- -f1)
    if dpkg --compare-versions "$kernel_version" "ge" "4.9"; then
        green "當前內核版本 ($kernel_version) 已支持BBR。"
    else
        red "當前內核版本 ($kernel_version) 過低，不支持BBR。"
        yellow "請手動升級內核到 4.9 或更高版本後再嘗試開啟BBR。"
        return
    fi
    
    # 檢查BBR是否已開啟
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        green "BBR 已開啟，無需重複操作。"
        return
    fi

    green "正在開啟BBR..."
    # 寫入sysctl配置
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    
    # 動態加載配置使其立即生效
    sysctl -p >/dev/null 2>&1

    # 嘗試載入模塊（對於未內建的內核）
    modprobe tcp_bbr 2>/dev/null || true
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true

    # 最終檢查（內核可用算法列表包含 bbr 即可）
    if sysctl net.ipv4.tcp_congestion_control | grep -qw "bbr" && sysctl net.ipv4.tcp_available_congestion_control | grep -qw "bbr"; then
        green "BBR已成功開啟並立即生效，無需重啟！"
    else
        red "BBR開啟可能未成功，請檢查：sysctl net.ipv4.tcp_available_congestion_control"
    fi
}

main_menu() {
    clear
    white "Vless-reality-vision、Vmess-ws(tls)、Hysteria-2、Tuic-v5 四協議共存腳本"
    white "腳本快捷方式：sb"
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green " 1. 一鍵安裝 Sing-box" 
    green " 2. 刪除卸載 Sing-box"
    white "----------------------------------------------------------------------------------"
    green " 3. 變更配置 【證書/UUID/IP優先/訂閱】" 
    green " 4. 關閉/重啟 Sing-box"   
    green " 5. 更新 Sing-box 腳本"
    green " 6. 更新/切換 Sing-box 內核版本"
    white "----------------------------------------------------------------------------------"
    green " 7. 刷新並查看節點與配置"
    green " 8. 查看 Sing-box 運行日誌"
    green " 9. 一鍵開啟BBR (無重啟)"
    green "10. 管理 Acme 申請域名證書"
    green "11. 雙棧VPS切換IP配置輸出"
    white "----------------------------------------------------------------------------------"
    green "12. 腳本使用說明書"
    green "13. 生成/更新訂閱模板"
    white "----------------------------------------------------------------------------------"
    green " 0. 退出腳本"
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    
    if [[ -x '/etc/s-box/sing-box' ]]; then
        corev=$(/etc/s-box/sing-box version 2>/dev/null | awk '/version/{print $NF}')
        green "Sing-box 核心已安裝：$corev"
    else
        yellow "Sing-box 核心未安裝"
    fi
    if [[ -f '/etc/s-box/sb.json' ]]; then 
        showprotocol
    else
        yellow "尚未生成運行配置（/etc/s-box/sb.json）。選擇【3】生成/調整配置，或按【1】安裝內核/依賴。"
    fi
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    readp "請輸入數字【0-13】：" Input
    case "$Input" in  
     1 ) inssb;;
     2 ) unins;;
     3 ) changeserv;;
     4 ) stclre;;
     5 ) upsbyg;; 
     6 ) upsbcroe;;
     7 ) clash_sb_share;;
     8 ) sblog;;
     9 ) install_bbr_local;;
    10 ) apply_acme_cert;;
    11 ) wgcfgo && sbshare;;
    12 ) sbsm;;
    13 ) gen_clash_sub;;
     * ) exit 
    esac
}

# --- 腳本入口 ---
check_os
check_dependencies
ensure_dirs
install_shortcut
main_menu