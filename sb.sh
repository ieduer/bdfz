#!/bin/bash
export LANG=en_US.UTF-8
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;36m'
bblue='\033[0;34m'
plain='\033[0m'

# 更新链接定义
UPDATE_URL="https://raw.githubusercontent.com/ieduer/bdfz/main/sb.sh"

red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" $2;}

# 内部调用 sb 时重新执行当前脚本
sb(){
    bash "$0"
    exit 0
}

[[ $EUID -ne 0 ]] && yellow "请以root模式运行脚本" && exit

# 系统检测（仅支持 Ubuntu）
if [[ -f /etc/issue ]] && grep -q -E -i "ubuntu" /etc/issue; then
    release="Ubuntu"
elif [[ -f /proc/version ]] && grep -q -E -i "ubuntu" /proc/version; then
    release="Ubuntu"
else
    red "脚本仅支持 Ubuntu 系统。" && exit
fi

export sbfiles="/etc/s-box/sb.json"
case $(uname -m) in
    armv7l) cpu=armv7;;
    aarch64) cpu=arm64;;
    x86_64) cpu=amd64;;
    *) red "目前脚本不支持$(uname -m)架构" && exit;;
esac

hostname=$(hostname)
reality_sni="www.apple.com"  # VLESS-Reality 默认伪装域名，可按需修改

# 1. 自动开启 BBR (无需交互)
enable_bbr(){
    if ! grep -q "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.conf; then
        green "正在自动开启 BBR 加速..."
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
}

# 安装依赖
install_depend(){
    if [ ! -f /etc/s-box/sbyg_update ]; then
        green "安装必要依赖..."
        apt update -y
        # 增加 ufw, socat (acme需要)
        apt install -y jq openssl iproute2 iputils-ping coreutils expect git socat grep util-linux curl wget tar python3 cron ufw
        mkdir -p /etc/s-box
        touch /etc/s-box/sbyg_update
    fi
}

# TUN 设置
setup_tun(){
    TUN=$(cat /dev/net/tun 2>&1)
    if [[ ! $TUN =~ 'in bad state' ]] && [[ ! $TUN =~ '处于错误状态' ]]; then 
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

# 获取 IP
v4v6(){
    v4=$(curl -s4m5 icanhazip.com -k)
    v6=$(curl -s6m5 icanhazip.com -k)
}

# 安装 Sing-box 核心
inssb(){
    green "下载并安装 Sing-box 内核..."
    mkdir -p /etc/s-box

    # 从 GitHub 官方 API 获取最新版本号 (tag_name 形如 v1.13.0)
    sbcore=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' 2>/dev/null | sed 's/^v//')
    if [[ -z "$sbcore" ]]; then
        red "无法从 GitHub API 获取 sing-box 最新版本号，请检查网络或稍后重试。"
        exit 1
    fi

    sbname="sing-box-$sbcore-linux-$cpu"
    sburl="https://github.com/SagerNet/sing-box/releases/download/v${sbcore}/${sbname}.tar.gz"

    green "准备下载版本: ${sbcore} (${sbname})"
    curl -fL -o /etc/s-box/sing-box.tar.gz -# --retry 2 "$sburl" || {
        red "下载 sing-box 内核失败，请检查网络或 GitHub 访问。"
        exit 1
    }

    # 解压并校验
    tar xzf /etc/s-box/sing-box.tar.gz -C /etc/s-box 2>/dev/null || {
        red "解压 sing-box.tar.gz 失败，文件可能损坏。"
        rm -f /etc/s-box/sing-box.tar.gz
        exit 1
    }

    if [[ ! -x "/etc/s-box/${sbname}/sing-box" ]]; then
        red "未在解压目录中找到 sing-box 可执行文件，安装中止。"
        exit 1
    fi

    mv "/etc/s-box/${sbname}/sing-box" /etc/s-box/
    rm -rf "/etc/s-box/${sbname}" /etc/s-box/sing-box.tar.gz
    chown root:root /etc/s-box/sing-box
    chmod +x /etc/s-box/sing-box
    green "Sing-box 内核安装完成。"
}

# 随机端口生成
insport(){
    green "生成高位随机端口..."
    ports=()
    for i in {1..4}; do
        while true; do
            port=$(shuf -i 10000-65535 -n 1)
            if [[ -z $(ss -tunlp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]] && [[ ! " ${ports[*]} " =~ " $port " ]]; then
                ports+=($port)
                break
            fi
        done
    done
    port_vl_re=${ports[0]}
    port_vm_ws=${ports[1]}
    port_hy2=${ports[2]}
    port_tu=${ports[3]}
}

# 2. 申请 ACME 域名证书
apply_acme(){
    # 确保 v4 已初始化，提示里不再是空值
    v4v6

    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    green "必须使用真实域名进行安装 (自动申请证书)"
    green "请确保您的域名已解析到本机 IP: ${v4}"
    readp "请输入您的域名 (例如: example.com): " domain_name

    if [[ -z "$domain_name" ]]; then
        red "域名不能为空！" && exit 1
    fi

    mkdir -p /etc/s-box

    # 安装/更新 acme.sh
    green "安装/更新 acme.sh..."
    if [[ ! -x /root/.acme.sh/acme.sh ]]; then
        curl https://get.acme.sh | sh
    fi

    # 优先选择 Let's Encrypt 作为默认 CA，避免 ZeroSSL 需要 EAB 的问题
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    /root/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1 || true

    # --- helper: 尝试把现有证书直接安装到 /etc/s-box ---
    # 说明：很多机器上证书“已存在”，但 --issue 会返回非 0（例如 Skipping / Domains not changed），
    # 这不是失败。我们优先尝试 installcert：
    #   1) 先尝试 ECC（--ecc）
    #   2) 再尝试 RSA（不带 --ecc）
    acme_install_existing(){
        local d="$1"
        # ECC
        /root/.acme.sh/acme.sh --installcert -d "$d" \
            --fullchainpath /etc/s-box/cert.crt \
            --keypath /etc/s-box/private.key \
            --ecc >/dev/null 2>&1 && return 0
        # RSA
        /root/.acme.sh/acme.sh --installcert -d "$d" \
            --fullchainpath /etc/s-box/cert.crt \
            --keypath /etc/s-box/private.key \
            >/dev/null 2>&1 && return 0
        return 1
    }

    # 1) 若证书已存在（acme.sh 已签发过），直接安装即可；不需要占用/释放 80。
    if acme_install_existing "$domain_name"; then
        green "检测到 acme.sh 已存在证书，已直接安装到 /etc/s-box（无需重新签发）。"
    else
        # 2) 若不存在，则需要 Standalone 验证：此时才检查 80 端口占用。
        if ss -tulnp 2>/dev/null | awk '{print $5}' | grep -qE '(:|])80$'; then
            red "检测到 80 端口已被其他进程占用，Standalone 申请证书需要临时占用 80。"
            red "请先停止现有 Web 服务 (如 nginx/apache/caddy) 后再运行本脚本，或确保该域名证书已在 acme.sh 中存在。"
            exit 1
        fi

        # 临时开放 80 端口用于 ACME 验证（若启用了 UFW）
        ufw allow 80/tcp >/dev/null 2>&1 || true

        green "正在申请证书 (Stand-alone 模式，CA: Let's Encrypt)..."
        /root/.acme.sh/acme.sh --register-account -m "admin@$domain_name" --server letsencrypt >/dev/null 2>&1 || true

        # 使用 ECC 证书（ec-256）。注意：acme.sh 可能在“Domains not changed / Skipping”时返回非 0。
        /root/.acme.sh/acme.sh --issue -d "$domain_name" --standalone -k ec-256 --server letsencrypt
        issue_rc=$?

        if [[ $issue_rc -ne 0 ]]; then
            # 这里不立刻判失败：只要证书确实存在，就继续安装。
            if acme_install_existing "$domain_name"; then
                yellow "acme.sh --issue 返回非 0（可能是 Skipping/未到续期时间），但证书已存在，继续安装。"
            else
                red "证书申请失败！请检查域名解析是否正确、80 端口是否可被外网访问、以及防火墙/云厂商安全组。"
                exit 1
            fi
        else
            # issue 成功后再安装到 /etc/s-box
            if ! acme_install_existing "$domain_name"; then
                red "证书安装失败！(acme.sh 已签发但 installcert 失败)" && exit 1
            fi
        fi
    fi

    # 二次检查
    if [[ ! -s /etc/s-box/cert.crt || ! -s /etc/s-box/private.key ]]; then
        red "证书安装失败！未找到 /etc/s-box/cert.crt 或 /etc/s-box/private.key" && exit 1
    fi

    # 确保已安装自动续期计划任务
    /root/.acme.sh/acme.sh --install-cronjob >/dev/null 2>&1 || true
    green "已为 acme.sh 安装/更新自动续期任务 (cron)。"

    # 记录域名
    echo "$domain_name" > /etc/s-box/domain.log
}

ensure_domain_and_cert(){
    if [[ -f /etc/s-box/cert.crt && -s /etc/s-box/cert.crt && -f /etc/s-box/private.key && -s /etc/s-box/private.key && -f /etc/s-box/domain.log && -s /etc/s-box/domain.log ]]; then
        domain_name=$(head -n1 /etc/s-box/domain.log | tr -d '\r\n ')
        green "检测到已存在证书与域名：${yellow}${domain_name}${plain}，跳过 ACME 申请。"
    else
        apply_acme
    fi
}

# 3. 配置防火墙 (只开必要端口)
setup_firewall(){
    green "正在配置防火墙 (UFW)..."
    
    # 尝试检测 SSH 端口 (优先从 sshd -T 获取，兼容 /etc/ssh/sshd_config.d/)
    if command -v sshd >/dev/null 2>&1; then
        ssh_port=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')
    fi
    if [[ -z "$ssh_port" ]]; then
        ssh_port=$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | tail -n 1 | awk '{print $2}')
    fi
    if [[ -z "$ssh_port" ]]; then
        ssh_port=22
    fi
    
    # 重置 ufw
    echo "y" | ufw reset >/dev/null 2>&1
    ufw default deny incoming
    ufw default allow outgoing
    
    # 放行必要端口
    ufw allow "$ssh_port"/tcp comment "SSH"
    ufw allow 80/tcp comment "ACME"
    ufw allow 443/tcp comment "HTTPS"
    ufw allow "$port_vl_re"/tcp comment "Vless"
    ufw allow "$port_vm_ws"/tcp comment "Vmess"
    ufw allow "$port_hy2"/udp comment "Hysteria2"
    ufw allow "$port_tu"/udp comment "Tuic5"
    
    # 启用 ufw
    echo "y" | ufw enable
    green "防火墙已开启，仅放行 SSH($ssh_port) 和代理端口。"
}

# 生成配置
gen_config(){
    uuid=$(/etc/s-box/sing-box generate uuid)
    key_pair=$(/etc/s-box/sing-box generate reality-keypair)
    private_key_reality=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    public_key_reality=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
    short_id=$(/etc/s-box/sing-box generate rand --hex 4)
    echo "$public_key_reality" > /etc/s-box/public.key

    # 下载 geo 库
    wget -q -O /root/geoip.db https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.db
    wget -q -O /root/geosite.db https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.db

    # IP 策略
    v4v6
    if [[ -n $v4 ]]; then
        ipv="prefer_ipv4"
    else
        ipv="prefer_ipv6"
    fi
    
cat > /etc/s-box/sb.json <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-sb",
      "listen": "::",
      "listen_port": ${port_vl_re},
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
      "listen": "::",
      "listen_port": ${port_vm_ws},
      "users": [{"uuid": "${uuid}", "alterId": 0}],
      "transport": {
        "type": "ws",
        "path": "/${uuid}-vm",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      },
      "tls": {
        "enabled": true,
        "server_name": "${domain_name}",
        "certificate_path": "/etc/s-box/cert.crt",
        "key_path": "/etc/s-box/private.key"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-sb",
      "listen": "::",
      "listen_port": ${port_hy2},
      "users": [{"password": "${uuid}"}],
      "ignore_client_bandwidth": false,
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
    { "type": "direct", "tag": "direct", "domain_strategy": "${ipv}" },
    { "type": "block", "tag": "block" }
  ]
}
EOF
}

# 服务管理
sbservice(){
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
After=network.target nss-lookup.target
[Service]
User=root
WorkingDirectory=/root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    systemctl start sing-box
    systemctl restart sing-box
}

view_log(){
    if command -v journalctl >/dev/null 2>&1; then
        green "最近 100 行 sing-box 运行日志："
        journalctl -u sing-box --no-pager -n 100 2>/dev/null || red "未找到 sing-box 日志，服务可能尚未启动。"
    else
        red "当前系统不支持 journalctl，无法直接查看 systemd 日志。"
    fi
}

restart_singbox(){
    green "正在重启 sing-box 服务..."
    systemctl restart sing-box 2>/dev/null || {
        red "重启失败，请检查 sing-box 是否已安装。"
        return
    }
    sleep 1
    if systemctl is-active --quiet sing-box; then
        green "sing-box 已成功重启。"
    else
        red "sing-box 重启后状态异常，请使用 systemctl status sing-box 排查。"
    fi
}

update_core(){
    green "正在更新 Sing-box 内核..."
    systemctl stop sing-box 2>/dev/null || true
    inssb
    systemctl restart sing-box 2>/dev/null || {
        yellow "内核已更新，但 sing-box 重启失败，请手动检查 systemctl status sing-box。"
        return
    }
    green "Sing-box 内核已更新并重启完成。"
}

# 4. 更新与快捷方式
lnsb(){
    rm -rf /usr/bin/sb
    curl -L -o /usr/bin/sb -# --retry 2 --insecure "${UPDATE_URL}"
    chmod +x /usr/bin/sb
}

# 安装流程
install_singbox(){
    if [[ -f '/etc/systemd/system/sing-box.service' ]]; then
        red "已安装 Sing-box，请先卸载。" && exit
    fi
    
    install_depend
    enable_bbr      # 自动开启 BBR
    setup_tun
    inssb
    insport
    ensure_domain_and_cert  # 确认证书与域名 (如已有则复用)
    setup_firewall  # 自动配置 UFW 防火墙
    gen_config
    sbservice
    
    # 注册 cron 保活
    (crontab -l 2>/dev/null; echo "0 1 * * * systemctl restart sing-box") | crontab -
    
    lnsb
    green "安装完成！"
    sbshare
}

# 结果展示
sbshare(){
    # 确保每次调用都重新拿到当前 IP
    v4v6

    domain=$(cat /etc/s-box/domain.log 2>/dev/null)
    uuid=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[0].users[0].uuid')
    
    # 端口读取
    port_vl=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[0].listen_port')
    port_vm=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[1].listen_port')
    port_hy=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[2].listen_port')
    port_tu=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[3].listen_port')
    
    pk=$(cat /etc/s-box/public.key)
    sid=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[0].tls.reality.short_id[0]')
    vm_path=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[1].transport.path')
    # 从 sb.json 中读取 Reality 伪装域名，用于生成 VLESS 链接的 sni 参数
    reality_sni_share=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[0].tls.reality.handshake.server // .inbounds[0].tls.server_name // empty')
    if [[ -z "$reality_sni_share" ]]; then
        reality_sni_share="$reality_sni"
    fi

    # host 优先用 IPv4，没有就用域名
    host="$v4"
    if [[ -z "$host" ]]; then
        host="$domain"
    fi

    # 生成链接
    vl_link="vless://$uuid@$host:$port_vl?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$reality_sni_share&fp=chrome&pbk=$pk&sid=$sid&type=tcp&headerType=none#VL-$hostname"
    vm_link="vmess://$(echo -n "{\"add\":\"$host\",\"aid\":\"0\",\"host\":\"$domain\",\"id\":\"$uuid\",\"net\":\"ws\",\"path\":\"$vm_path\",\"port\":\"$port_vm\",\"ps\":\"VM-$hostname\",\"tls\":\"tls\",\"sni\":\"$domain\",\"type\":\"none\",\"v\":\"2\"}" | base64 -w 0)"
    hy_link="hysteria2://$uuid@$host:$port_hy?security=tls&alpn=h3&insecure=0&sni=$domain#HY2-$hostname"
    tu_link="tuic://$uuid:$uuid@$host:$port_tu?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=$domain&allow_insecure=0#TU5-$hostname"
    
    echo "$vl_link" > /etc/s-box/sub.txt
    echo "$vm_link" >> /etc/s-box/sub.txt
    echo "$hy_link" >> /etc/s-box/sub.txt
    echo "$tu_link" >> /etc/s-box/sub.txt
    
    sub_base64=$(base64 -w 0 < /etc/s-box/sub.txt)
    
    echo
    white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo -e "域名: ${green}$domain${plain}"
    echo -e "UUID: ${green}$uuid${plain}"
    echo
    echo -e "VLESS-Reality 端口: ${yellow}$port_vl${plain}"
    echo -e "VMess-WS-TLS  端口: ${yellow}$port_vm${plain}"
    echo -e "Hysteria2     端口: ${yellow}$port_hy${plain}"
    echo -e "Tuic V5       端口: ${yellow}$port_tu${plain}"
    echo
    red "🚀【 聚合订阅 (Base64) 】"
    echo -e "${yellow}$sub_base64${plain}"
    white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
}

client_conf(){
    if [[ ! -f /etc/s-box/sb.json ]]; then
        red "未找到 /etc/s-box/sb.json，请先完成服务端安装 (菜单 1)。"
        return
    fi
    if ! command -v jq >/dev/null 2>&1; then
        red "当前系统缺少 jq，请先安装依赖后重试。"
        return
    fi

    domain=$(cat /etc/s-box/domain.log 2>/dev/null | head -n1 | tr -d '\r\n ')
    if [[ -z "$domain" ]]; then
        red "未找到 /etc/s-box/domain.log 中的域名，请重新安装或修复。"
        return
    fi

    uuid=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[0].users[0].uuid')
    port_vl=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[0].listen_port')
    port_vm=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[1].listen_port')
    port_hy=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[2].listen_port')
    port_tu=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[3].listen_port')
    pk=$(cat /etc/s-box/public.key 2>/dev/null)
    sid=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[0].tls.reality.short_id[0]')

    # 优先从 sb.json 中读取 Reality 的伪装域名 (handshake.server 或 tls.server_name)
    reality_sni_client=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[0].tls.reality.handshake.server // .inbounds[0].tls.server_name // empty')
    if [[ -z "$reality_sni_client" ]]; then
        reality_sni_client="$reality_sni"
    fi

    if [[ -z "$uuid" || -z "$port_vl" || -z "$port_vm" || -z "$port_hy" || -z "$port_tu" || -z "$pk" || -z "$sid" ]]; then
        red "从服务端配置中提取必要参数失败，请检查 /etc/s-box/sb.json。"
        return
    fi

    # 获取当前服务器公网 IP，用于客户端直接连 IP；获取失败时退回域名
    v4v6
    host="$domain"
    if [[ -n "$v4" ]]; then
        host="$v4"
    fi

    green "以下为基于当前服务端自动生成的 Sing-box 客户端配置 (tun 全局模式，最新版模板)："
    echo
    cat <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "cache.db",
      "store_fakeip": true
    }
  },
  "dns": {
    "servers": [
      {
        "tag": "proxydns",
        "address": "tls://8.8.8.8/dns-query",
        "detour": "select"
      },
      {
        "tag": "localdns",
        "address": "h3://223.5.5.5/dns-query",
        "detour": "direct"
      },
      {
        "tag": "dns_fakeip",
        "address": "fakeip"
      }
    ],
    "rules": [
      {
        "clash_mode": "Global",
        "server": "proxydns"
      },
      {
        "clash_mode": "Direct",
        "server": "localdns"
      },
      {
        "rule_set": "geosite-cn",
        "server": "localdns"
      },
      {
        "rule_set": "geosite-geolocation-!cn",
        "server": "proxydns"
      },
      {
        "rule_set": "geosite-geolocation-!cn",
        "query_type": [
          "A",
          "AAAA"
        ],
        "server": "dns_fakeip"
      }
    ],
    "fakeip": {
      "enabled": true,
      "inet4_range": "198.18.0.0/15",
      "inet6_range": "fc00::/18"
    },
    "independent_cache": true,
    "final": "proxydns"
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
      "domain_strategy": "prefer_ipv4"
    }
  ],
  "outbounds": [
    {
      "tag": "select",
      "type": "selector",
      "default": "auto",
      "outbounds": [
        "auto",
        "vless-sb",
        "vmess-sb",
        "hy2-sb",
        "tuic5-sb"
      ]
    },
    {
      "type": "vless",
      "tag": "vless-sb",
      "server": "$host",
      "server_port": $port_vl,
      "uuid": "$uuid",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "$reality_sni_client",
        "utls": {
          "enabled": true,
          "fingerprint": "firefox"
        },
        "reality": {
          "enabled": true,
          "public_key": "$pk",
          "short_id": "$sid"
        }
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-sb",
      "server": "$host",
      "server_port": $port_vm,
      "uuid": "$uuid",
      "security": "auto",
      "packet_encoding": "packetaddr",
      "tls": {
        "enabled": true,
        "server_name": "$domain",
        "insecure": false,
        "utls": {
          "enabled": true,
          "fingerprint": "firefox"
        }
      },
      "transport": {
        "type": "ws",
        "path": "/$uuid-vm",
        "headers": {
          "Host": [
            "$domain"
          ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-sb",
      "server": "$host",
      "server_port": $port_hy,
      "password": "$uuid",
      "tls": {
        "enabled": true,
        "server_name": "$domain",
        "insecure": false,
        "alpn": [
          "h3"
        ]
      }
    },
    {
      "type": "tuic",
      "tag": "tuic5-sb",
      "server": "$host",
      "server_port": $port_tu,
      "uuid": "$uuid",
      "password": "$uuid",
      "congestion_control": "bbr",
      "udp_relay_mode": "native",
      "udp_over_stream": false,
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "server_name": "$domain",
        "insecure": false,
        "alpn": [
          "h3"
        ]
      }
    },
    {
      "tag": "direct",
      "type": "direct"
    },
    {
      "tag": "auto",
      "type": "urltest",
      "outbounds": [
        "vless-sb",
        "vmess-sb",
        "hy2-sb",
        "tuic5-sb"
      ],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "1m",
      "tolerance": 50,
      "interrupt_exist_connections": false
    }
  ],
  "route": {
    "rule_set": [
      {
        "tag": "geosite-geolocation-!cn",
        "type": "remote",
        "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/geolocation-!cn.srs",
        "download_detour": "select",
        "update_interval": "1d"
      },
      {
        "tag": "geosite-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/geolocation-cn.srs",
        "download_detour": "select",
        "update_interval": "1d"
      },
      {
        "tag": "geoip-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/cn.srs",
        "download_detour": "select",
        "update_interval": "1d"
      }
    ],
    "auto_detect_interface": true,
    "final": "select",
    "rules": [
      {
        "inbound": "tun-in",
        "action": "sniff"
      },
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "ip_is_private": true,
        "outbound": "direct"
      },
      {
        "clash_mode": "Direct",
        "outbound": "direct"
      },
      {
        "clash_mode": "Global",
        "outbound": "select"
      },
      {
        "rule_set": "geoip-cn",
        "outbound": "direct"
      },
      {
        "rule_set": "geosite-cn",
        "outbound": "direct"
      },
      {
        "rule_set": "geosite-geolocation-!cn",
        "outbound": "select"
      }
    ]
  }
}
EOF
    echo
    yellow "将以上 JSON 保存为本地 sing-box 客户端配置文件 (例如 client.json)，并以 root 运行 tun 模式即可。"
}

# 卸载
unins(){
    systemctl stop sing-box
    systemctl disable sing-box
    rm -rf /etc/s-box /usr/bin/sb /etc/systemd/system/sing-box.service /root/geoip.db /root/geosite.db
    # 恢复防火墙 (可选，这里仅删除规则可能比较复杂，建议直接重置或提示用户)
    echo "y" | ufw delete allow 80/tcp >/dev/null 2>&1
    green "卸载完成 (BBR 设置保留，防火墙规则请按需手动清理)。"
}

# 更新脚本
upsbyg(){
    lnsb
    green "脚本已更新，请重新运行 sb" && exit
}

# 菜单
clear
white "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~" 
white "Sing-box 四协议脚本 (强制域名证书 + 自动BBR + 严格防火墙版)"
white "脚本快捷方式：sb"
red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
green " 1. 安装 (需要准备好域名)" 
green " 2. 卸载"
green " 3. 查看节点订阅"
green " 4. 更新脚本"
green " 5. 查看运行日志"
green " 6. 重启 Sing-box 服务"
green " 7. 单独更新 Sing-box 内核"
green " 8. 显示客户端配置示例"
red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

readp "请选择: " Input
case "$Input" in  
 1 ) install_singbox;;
 2 ) unins;;
 3 ) sbshare;;
 5 ) view_log;;
 6 ) restart_singbox;;
 4 ) upsbyg;;
 7 ) update_core;;
 8 ) client_conf;;
 * ) exit 
esac