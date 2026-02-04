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

# 检查 systemd 是否存在
if ! command -v systemctl >/dev/null 2>&1; then
    red "错误：当前系统未检测到 systemd。"
    red "本脚本严重依赖 systemd 管理服务，无法繼續。"
    exit 1
fi

# 安全的 UFW 放行函數 (處理 comment 兼容性)
ufw_allow(){
    local port="$1" proto="$2" comment="$3"
    if [[ -z "$comment" ]]; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1
    else
        # 嘗試帶 comment 添加
        if ! ufw allow "${port}/${proto}" comment "${comment}" >/dev/null 2>&1; then
             # fallback: 不帶 comment
             ufw allow "${port}/${proto}" >/dev/null 2>&1
        fi
    fi
}

export sbfiles="/etc/s-box/sb.json"
case $(uname -m) in
    armv7l) cpu=armv7;;
    aarch64) cpu=arm64;;
    x86_64) cpu=amd64;;
    *) red "目前脚本不支持$(uname -m)架构" && exit;;
esac

hostname=$(hostname)
# VLESS-Reality 伪装域名，可通过环境变量 REALITY_SNI 覆盖
reality_sni="${REALITY_SNI:-www.apple.com}"

# 1. 自动开启 BBR (无需交互)
enable_bbr(){
    local needs_update=false
    
    # 检查是否已配置 fq 和 bbr
    if ! grep -q "net.core.default_qdisc = fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        needs_update=true
    fi
    
    if ! grep -q "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        needs_update=true
    fi
    
    if [[ "$needs_update" == "true" ]]; then
        green "正在自动开启 BBR 加速..."
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

# 获取 IP (带缓存，避免重复请求)
_v4_cache=""
_v6_cache=""
v4v6(){
    # 如果已缓存且非强制刷新，直接使用
    if [[ -z "$_v4_cache" ]]; then
        _v4_cache=$(curl -s4m5 icanhazip.com -k 2>/dev/null || echo "")
    fi
    if [[ -z "$_v6_cache" ]]; then
        _v6_cache=$(curl -s6m5 icanhazip.com -k 2>/dev/null || echo "")
    fi
    v4="$_v4_cache"
    v6="$_v6_cache"
}

# 强制刷新 IP 缓存
v4v6_refresh(){
    _v4_cache=""
    _v6_cache=""
    v4v6
}

# 安装 Sing-box 核心
inssb(){
    green "下载并安装 Sing-box 内核..."
    mkdir -p /etc/s-box

    # 支持环境变量指定版本，否则从 GitHub API 获取最新版本
    if [[ -n "${SB_VERSION:-}" ]]; then
        sbcore="$SB_VERSION"
        green "使用指定版本: $sbcore"
    else
        # 从 GitHub 官方 API 获取最新版本号 (tag_name 形如 v1.13.0)
        sbcore=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//')
        
        # API fallback: 如果 API 失败（rate limit 等），尝试从 releases 页面抓取
        if [[ -z "$sbcore" ]]; then
            yellow "GitHub API 获取失败，尝试 fallback..."
            sbcore=$(curl -fsSL "https://github.com/SagerNet/sing-box/releases/latest" 2>/dev/null | grep -oP 'releases/tag/v\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        fi
        
        if [[ -z "$sbcore" ]]; then
            red "无法获取 sing-box 最新版本号。"
            red "可尝试：export SB_VERSION=1.11.0 后重新运行脚本指定版本。"
            exit 1
        fi
    fi

    sbname="sing-box-$sbcore-linux-$cpu"
    sburl="https://github.com/SagerNet/sing-box/releases/download/v${sbcore}/${sbname}.tar.gz"

    green "准备下载版本: ${sbcore} (${sbname})"
    curl -fL -o /etc/s-box/sing-box.tar.gz -# --retry 2 "$sburl" || {
        red "下载 sing-box 内核失败，请检查网络或 GitHub 访问。"
        exit 1
    }

    # ========== 供应链安全校验 ==========
    # 1. 检查文件类型是否为 gzip
    local file_type=$(file -b /etc/s-box/sing-box.tar.gz 2>/dev/null)
    if ! echo "$file_type" | grep -qi "gzip\|tar"; then
        red "下载的文件不是有效的 tar.gz 格式（可能被劫持或返回了 HTML 错误页）"
        red "文件类型: $file_type"
        rm -f /etc/s-box/sing-box.tar.gz
        exit 1
    fi

    # 2. 解压并校验
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
    
    # 3. Sanity check: 验证二进制是否可执行并返回版本
    local installed_ver=$(/etc/s-box/sing-box version 2>/dev/null | head -1 | awk '{print $NF}')
    if [[ -z "$installed_ver" ]]; then
        red "sing-box 二进制无法执行，可能已损坏或不匹配当前架构。"
        rm -f /etc/s-box/sing-box
        exit 1
    fi
    green "Sing-box 内核安装完成，版本: $installed_ver"
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

    # 安装/更新 acme.sh（带安全验证）
    green "安装/更新 acme.sh..."
    if [[ ! -x /root/.acme.sh/acme.sh ]]; then
        # 下載到臨時文件，驗證後再執行
        curl -fsSL -o /tmp/acme_install.sh https://get.acme.sh || {
            red "下載 acme.sh 安裝腳本失敗"
            exit 1
        }
        
        # 驗證是 shell 腳本而非 HTML
        local acme_type=$(file -b /tmp/acme_install.sh 2>/dev/null)
        if ! echo "$acme_type" | grep -qi "shell\|script\|text\|ASCII"; then
            red "acme.sh 安裝腳本下載異常（非腳本文件）"
            rm -f /tmp/acme_install.sh
            exit 1
        fi
        
        sh /tmp/acme_install.sh
        rm -f /tmp/acme_install.sh
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
        # 2) 若不存在，则需要申请证书
        local acme_mode="standalone"
        local nginx_webroot=""
        
        # 檢查 80 端口占用情況
        local port80_pid=$(ss -tulnp 2>/dev/null | grep -E '(:|])80[[:space:]]' | awk '{print $NF}' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | head -1)
        
        if [[ -n "$port80_pid" ]]; then
            local p_name=$(ps -p "$port80_pid" -o comm= 2>/dev/null)
            yellow "檢測到 80 端口已被進程 [${p_name:-未知}] (PID: $port80_pid) 占用。"
            
            if [[ "$p_name" == "nginx" ]]; then
                yellow "識別到 Nginx 正在運行。"
                echo
                yellow "請選擇證書申請方式："
                yellow "  [1] Webroot 模式 (推薦 - 使用現有 Nginx 的 webroot 目錄)"
                yellow "  [2] Nginx 模式 (需要域名已在 Nginx 配置中存在)"
                yellow "  [3] 臨時停止 Nginx，使用 Standalone 模式"
                readp "   請選擇 [1/2/3]: " nginx_choice
                
                case "${nginx_choice:-1}" in
                    1)
                        acme_mode="webroot"
                        # 嘗試檢測常見 webroot 路徑
                        if [[ -d /var/www/html ]]; then
                            nginx_webroot="/var/www/html"
                        elif [[ -d /usr/share/nginx/html ]]; then
                            nginx_webroot="/usr/share/nginx/html"
                        else
                            readp "   請輸入 Nginx webroot 路徑 (默認 /var/www/html): " custom_webroot
                            nginx_webroot="${custom_webroot:-/var/www/html}"
                            mkdir -p "$nginx_webroot"
                        fi
                        green "使用 Webroot 模式，路徑: $nginx_webroot"
                        ;;
                    2)
                        acme_mode="nginx"
                        yellow "注意：Nginx 模式需要該域名已在 Nginx 配置中存在 server block。"
                        ;;
                    3)
                        acme_mode="standalone"
                        yellow "臨時停止 Nginx..."
                        systemctl stop nginx 2>/dev/null || service nginx stop 2>/dev/null
                        ;;
                    *)
                        acme_mode="webroot"
                        nginx_webroot="/var/www/html"
                        mkdir -p "$nginx_webroot"
                        ;;
                esac
            else
                red "Standalone 模式需要占用 80 端口。請先停止該服務 (service $p_name stop)。"
                exit 1
            fi
        fi

        green "正在申请证书 (模式: $acme_mode, CA: Let's Encrypt)..."
        /root/.acme.sh/acme.sh --register-account -m "admin@$domain_name" --server letsencrypt >/dev/null 2>&1 || true

        local issue_rc=0
        
        if [[ "$acme_mode" == "standalone" ]]; then
            ufw allow 80/tcp >/dev/null 2>&1 || true
            /root/.acme.sh/acme.sh --issue -d "$domain_name" -k ec-256 --server letsencrypt --standalone
            issue_rc=$?
            # 如果之前停止了 Nginx，重啟它
            if [[ -n "$port80_pid" ]]; then
                systemctl start nginx 2>/dev/null || service nginx start 2>/dev/null
                green "Nginx 已重新啟動。"
            fi
        elif [[ "$acme_mode" == "nginx" ]]; then
            /root/.acme.sh/acme.sh --issue -d "$domain_name" -k ec-256 --server letsencrypt --nginx
            issue_rc=$?
            # 如果 nginx 模式失敗，嘗試 webroot 作為 fallback
            if [[ $issue_rc -ne 0 ]]; then
                yellow "Nginx 模式失敗（域名可能未在 Nginx 配置中），嘗試 Webroot 模式..."
                nginx_webroot="/var/www/html"
                mkdir -p "$nginx_webroot"
                /root/.acme.sh/acme.sh --issue -d "$domain_name" -k ec-256 --server letsencrypt -w "$nginx_webroot"
                issue_rc=$?
            fi
        elif [[ "$acme_mode" == "webroot" ]]; then
            /root/.acme.sh/acme.sh --issue -d "$domain_name" -k ec-256 --server letsencrypt -w "$nginx_webroot"
            issue_rc=$?
        fi

        if [[ $issue_rc -ne 0 ]]; then
            if acme_install_existing "$domain_name"; then
                yellow "acme.sh --issue 返回非 0，但证书已存在，继续安装。"
            else
                red "证书申请失败！请检查："
                red "  1. 域名 $domain_name 是否已解析到本機 IP"
                red "  2. 防火牆/安全組是否放行 80 端口"
                red "  3. Nginx 配置是否正確指向 webroot 目錄"
                exit 1
            fi
        else
            if ! acme_install_existing "$domain_name"; then
                red "证书安装失败！" && exit 1
            fi
        fi
    fi

    # 二次检查
    if [[ ! -s /etc/s-box/cert.crt || ! -s /etc/s-box/private.key ]]; then
        red "证书安装失败！未找到 /etc/s-box/cert.crt 或 /etc/s-box/private.key" && exit 1
    fi
    
    # 收紧私钥权限
    chmod 600 /etc/s-box/private.key
    
    # 輸出證書類型與校驗域名
    local cert_type="Unknown"
    local cert_expiry=""
    if command -v openssl >/dev/null 2>&1; then
        local key_algo=$(openssl x509 -in /etc/s-box/cert.crt -noout -text 2>/dev/null | grep -i "Public Key Algorithm" | head -1)
        if echo "$key_algo" | grep -qi "ec\|ecdsa"; then
            cert_type="ECC (ECDSA)"
        elif echo "$key_algo" | grep -qi "rsa"; then
            cert_type="RSA"
        fi
        cert_expiry=$(openssl x509 -in /etc/s-box/cert.crt -noout -enddate 2>/dev/null | cut -d= -f2)
        
        # 校验 SAN 是否包含域名
        if ! openssl x509 -in /etc/s-box/cert.crt -noout -text | grep -A1 "Subject Alternative Name" | grep -q "$domain_name"; then
            red "⚠️ 严重警告：证书 Subject Alternative Name (SAN) 不包含域名 $domain_name"
            red "这可能导致客户端 TLS 握手失败（域名不匹配）。请检查证书源。"
        else
            green "✅ 证书域名匹配校验通过 ($domain_name)"
        fi
    fi
    green "證書類型: ${yellow}${cert_type}${plain}"
    [[ -n "$cert_expiry" ]] && green "證書到期: ${yellow}${cert_expiry}${plain}"

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

# 3. 配置防火墙 (安全模式：只添加必要端口)
setup_firewall(){
    green "正在配置防火墙 (UFW - 安全模式)..."
    
    # ========== 端口保留功能（預設關閉，避免意外暴露內部服務）==========
    # 可通過 PRESERVE_EXISTING_PORTS=1 環境變量啟用
    local preserve_tcp_ports=()
    local preserve_udp_ports=()
    
    if [[ "${PRESERVE_EXISTING_PORTS:-0}" == "1" ]]; then
        yellow "⚠️  PRESERVE_EXISTING_PORTS=1 已啟用，將保留現有監聽端口"
        yellow "⚠️  警告：這可能會暴露內部服務（如 Redis/MongoDB），請確認風險！"
        
        local existing_tcp_ports=$(ss -tlnp 2>/dev/null | awk 'NR>1 {print $4}' | grep -oE '[0-9]+$' | sort -u)
        local existing_udp_ports=$(ss -ulnp 2>/dev/null | awk 'NR>1 {print $4}' | grep -oE '[0-9]+$' | sort -u)
        
        for port in $existing_tcp_ports; do
            # 排除本腳本即將使用的端口
            if [[ "$port" != "$port_vl_re" && "$port" != "$port_vm_ws" ]]; then
                preserve_tcp_ports+=("$port")
            fi
        done
        
        for port in $existing_udp_ports; do
            if [[ "$port" != "$port_hy2" && "$port" != "$port_tu" ]]; then
                preserve_udp_ports+=("$port")
            fi
        done
        
        # 顯示檢測到的端口
        if [[ ${#preserve_tcp_ports[@]} -gt 0 || ${#preserve_udp_ports[@]} -gt 0 ]]; then
            yellow "檢測到以下正在使用的端口，將予以保留："
            [[ ${#preserve_tcp_ports[@]} -gt 0 ]] && echo -e "  TCP: ${preserve_tcp_ports[*]}"
            [[ ${#preserve_udp_ports[@]} -gt 0 ]] && echo -e "  UDP: ${preserve_udp_ports[*]}"
        fi
    fi
    
    # ========== 第二步：檢測 SSH 端口（使用最可靠的方法）==========
    local ssh_port=""
    
    # 方法 0（最穩）：從當前 SSH 會話反推端口
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        ssh_port=$(echo "$SSH_CONNECTION" | awk '{print $4}' 2>/dev/null)
        if [[ -n "$ssh_port" ]]; then
            green "從當前 SSH 會話檢測到端口: $ssh_port"
        fi
    fi
    
    # 方法 1：從 ss 獲取 sshd 實際監聽端口
    if [[ -z "$ssh_port" ]]; then
        ssh_port=$(ss -tlnp 2>/dev/null | grep -E 'sshd|"ssh"' | awk '{print $4}' | grep -oE '[0-9]+$' | head -1)
    fi
    
    # 方法 2：sshd -T（可能受 Include 影響）
    if [[ -z "$ssh_port" ]] && command -v sshd >/dev/null 2>&1; then
        ssh_port=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')
    fi
    
    # 方法 3：從配置文件讀取
    if [[ -z "$ssh_port" ]]; then
        ssh_port=$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | tail -n 1 | awk '{print $2}')
    fi
    
    # 預設值
    if [[ -z "$ssh_port" ]]; then
        ssh_port=22
        yellow "無法自動檢測 SSH 端口，使用預設值 22"
    fi
    
    # 顯示檢測結果供用戶確認
    green "將放行 SSH 端口: $ssh_port"
    
    # ========== 第三步：檢查 UFW 狀態並決定策略 ==========
    local ufw_status=$(ufw status 2>/dev/null | head -1)
    
    if echo "$ufw_status" | grep -qi "inactive"; then
        # UFW 未啟用，首次設置
        green "UFW 未啟用，進行首次安全配置..."
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
    else
        # UFW 已啟用，增量添加規則
        green "UFW 已啟用，採用增量模式（保留現有規則）..."
    fi
    
    # ========== 第四步：添加必要端口（不會重複添加） ==========
    # SSH 端口（最重要，首先確保）
    ufw_allow "$ssh_port" tcp "SSH"
    
    # 保留現有 TCP 端口
    for port in "${preserve_tcp_ports[@]}"; do
        [[ -n "$port" ]] && ufw_allow "$port" tcp "Preserved"
    done
    
    # 保留現有 UDP 端口
    for port in "${preserve_udp_ports[@]}"; do
        [[ -n "$port" ]] && ufw_allow "$port" udp "Preserved"
    done
    
    # Sing-box 代理端口
    ufw_allow 80 tcp "ACME"
    ufw_allow 443 tcp "HTTPS"
    ufw_allow "$port_vl_re" tcp "VLESS-Reality"
    ufw_allow "$port_vm_ws" tcp "VMess-WS"
    ufw_allow "$port_hy2" udp "Hysteria2"
    ufw_allow "$port_tu" udp "TUIC5"
    
    # ========== 第五步：詢問是否啟用 UFW ==========
    local ufw_was_inactive=false
    if echo "$ufw_status" | grep -qi "inactive"; then
        ufw_was_inactive=true
    fi
    
    # 記錄本腳本添加的端口，供卸載時清理
    cat > /etc/s-box/firewall_ports.log <<EOF
# 本腳本添加的防火牆端口（卸載時自動清理）
SSH_PORT=$ssh_port
VLESS_PORT=$port_vl_re
VMESS_PORT=$port_vm_ws
HY2_PORT=$port_hy2
TUIC_PORT=$port_tu
EOF
    
    if [[ "$ufw_was_inactive" == "true" ]]; then
        yellow "═══════════════════════════════════════════════════════════════════"
        yellow "  ⚠️  UFW 防火牆目前未啟用"
        yellow "  啟用後將會阻止所有未明確放行的入站連接"
        yellow "  請確認雲廠商安全組已放行相應端口！"
        yellow "═══════════════════════════════════════════════════════════════════"
        echo
        readp "   是否啟用 UFW 防火牆？[y/N]: " enable_ufw_choice
        if [[ "$enable_ufw_choice" =~ ^[Yy]$ ]]; then
            echo "y" | ufw enable >/dev/null 2>&1
            green "UFW 已啟用。"
        else
            yellow "已跳過 UFW 啟用。端口規則已添加，UFW 啟用後將生效。"
            yellow "手動啟用: ufw enable"
        fi
    else
        green "UFW 已是啟用狀態，規則已添加。"
    fi
    
    green "防火墙配置完成！"
    echo -e "  SSH端口: ${yellow}$ssh_port${plain}"
    echo -e "  VLESS-Reality: ${yellow}$port_vl_re/tcp${plain}"
    echo -e "  VMess-WS: ${yellow}$port_vm_ws/tcp${plain}"
    echo -e "  Hysteria2: ${yellow}$port_hy2/udp${plain}"
    echo -e "  TUIC5: ${yellow}$port_tu/udp${plain}"
    [[ ${#preserve_tcp_ports[@]} -gt 0 ]] && echo -e "  保留的TCP端口: ${yellow}${preserve_tcp_ports[*]}${plain}"
    [[ ${#preserve_udp_ports[@]} -gt 0 ]] && echo -e "  保留的UDP端口: ${yellow}${preserve_udp_ports[*]}${plain}"
}

# 生成配置
gen_config(){
    uuid=$(/etc/s-box/sing-box generate uuid)
    key_pair=$(/etc/s-box/sing-box generate reality-keypair)
    private_key_reality=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    public_key_reality=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
    short_id=$(/etc/s-box/sing-box generate rand --hex 4)
    echo "$public_key_reality" > /etc/s-box/public.key

    # GeoIP/GeoSite 資料庫下載（預設關閉，因為服務端配置未啟用分流）
    # 可通過 DOWNLOAD_GEO_DB=1 環境變量啟用
    if [[ "${DOWNLOAD_GEO_DB:-0}" == "1" ]]; then
        green "下载 GeoIP/GeoSite 数据库..."
        local geo_primary="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest"
        local geo_fallback="https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release"
        
        # GeoIP
        wget -q -O /root/geoip.db "${geo_primary}/geoip.db" 2>/dev/null
        if [[ ! -s /root/geoip.db ]]; then
            wget -q -O /root/geoip.db "${geo_fallback}/geoip.db" 2>/dev/null
        fi
        
        # GeoSite
        wget -q -O /root/geosite.db "${geo_primary}/geosite.db" 2>/dev/null
        if [[ ! -s /root/geosite.db ]]; then
            wget -q -O /root/geosite.db "${geo_fallback}/geosite.db" 2>/dev/null
        fi
    fi

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
    { "type": "direct", "tag": "direct", "domain_strategy": "${ipv}" }
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
ExecStartPre=/etc/s-box/sing-box check -c /etc/s-box/sb.json
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


# 安裝後自檢
post_install_check(){
    green "正在進行安裝後自檢..."
    if systemctl is-active --quiet sing-box; then
        green "✅ sing-box 服務已運行"
    else
        red "❌ sing-box 服務未運行"
        systemctl status sing-box --no-pager -n 10
    fi

    # 端口監聽檢查
    green "檢查端口監聽狀態..."
    local ports=("$port_vl_re/tcp" "$port_vm_ws/tcp" "$port_hy2/udp" "$port_tu/udp")
    for p in "${ports[@]}"; do
        local port="${p%/*}"
        local proto="${p#*/}"
        if [[ "$proto" == "tcp" ]]; then
            if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
                green "✅ TCP $port 正在監聽"
            else
                yellow "⚠️ TCP $port 未監聽 (可能是服務啟動延遲或配置錯誤)"
            fi
        else
            if ss -ulnp 2>/dev/null | grep -q ":${port} "; then
                green "✅ UDP $port 正在監聽"
            else
                yellow "⚠️ UDP $port 未監聽 (可能是 UDP 綁定失敗)"
            fi
        fi
    done

    # 配置檢查
    green "驗證配置文件語法..."
    if /etc/s-box/sing-box check -c /etc/s-box/sb.json >/dev/null 2>&1; then
        green "✅ 配置文件校驗通過"
    else
        red "❌ 配置文件校驗失敗"
        /etc/s-box/sing-box check -c /etc/s-box/sb.json
    fi
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
    
    # 下载更新（不使用 --insecure，程序文件必须 TLS 验证）
    curl -fsSL -o /tmp/sb_update.sh --retry 2 "${UPDATE_URL}" || {
        red "下载更新失败，请检查网络或 GitHub 访问。"
        return 1
    }
    
    # 验证下载的是脚本而不是 HTML 错误页
    local file_type=$(file -b /tmp/sb_update.sh 2>/dev/null)
    if ! echo "$file_type" | grep -qi "shell\|script\|text\|ASCII"; then
        red "下载的文件不是有效的 shell 脚本（可能被劫持或返回了 HTML）"
        red "文件类型: $file_type"
        rm -f /tmp/sb_update.sh
        return 1
    fi
    
    # 基本语法检查
    if ! bash -n /tmp/sb_update.sh 2>/dev/null; then
        red "下载的脚本语法错误，拒绝更新。"
        rm -f /tmp/sb_update.sh
        return 1
    fi
    
    # 內容完整性校驗（防止被中間人篡改內容但保留腳本格式）
    if ! grep -q "Sing-Box 四協議一鍵安裝腳本" /tmp/sb_update.sh; then
        red "更新脚本校验失败：未檢測到預期標識，可能被篡改或下載不完整。"
        rm -f /tmp/sb_update.sh
        return 1
    fi
    
    mv /tmp/sb_update.sh /usr/bin/sb
    chmod +x /usr/bin/sb
    green "脚本更新成功。"
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
    
    # 不再自动注册每日重启 cron (会导致用户断流)
    # 如需自动重启，可手动添加: (crontab -l; echo "0 4 * * * systemctl restart sing-box") | crontab -
    
    lnsb
    green "安装完成！"
    
    # 進行安裝後自檢
    post_install_check
    
    # 3. 如果使用了 Nginx 模式，或者檢測到 Nginx 運行，提示重載
    if pgrep -x "nginx" >/dev/null; then
        yellow "檢測到 Nginx 正在運行。"
        readp "   是否重載 Nginx 以應用新證書？[Y/n]: " nginx_reload
        if [[ "${nginx_reload:-y}" =~ ^[Yy]$ ]]; then
            systemctl reload nginx 2>/dev/null || service nginx reload 2>/dev/null
            green "Nginx 已重載。"
        fi
    fi

    sbshare
}

# 结果展示
sbshare(){
    # 确保每次调用都重新拿到当前 IP
    v4v6

    domain=$(cat /etc/s-box/domain.log 2>/dev/null | head -n1 | tr -d '\r\n ')
    
    # 直接使用 jq 读取配置，无需 sed 处理（sb.json 不含行注释）
    uuid=$(jq -r '.inbounds[0].users[0].uuid' /etc/s-box/sb.json 2>/dev/null)
    
    # 端口读取
    port_vl=$(jq -r '.inbounds[0].listen_port' /etc/s-box/sb.json 2>/dev/null)
    port_vm=$(jq -r '.inbounds[1].listen_port' /etc/s-box/sb.json 2>/dev/null)
    port_hy=$(jq -r '.inbounds[2].listen_port' /etc/s-box/sb.json 2>/dev/null)
    port_tu=$(jq -r '.inbounds[3].listen_port' /etc/s-box/sb.json 2>/dev/null)
    
    pk=$(cat /etc/s-box/public.key 2>/dev/null)
    sid=$(jq -r '.inbounds[0].tls.reality.short_id[0]' /etc/s-box/sb.json 2>/dev/null)
    # 从服务端配置读取 VMess WS 路径，确保客户端一致
    vm_path=$(jq -r '.inbounds[1].transport.path' /etc/s-box/sb.json 2>/dev/null)
    # 从 sb.json 中读取 Reality 伪装域名
    reality_sni_share=$(jq -r '.inbounds[0].tls.reality.handshake.server // .inbounds[0].tls.server_name // empty' /etc/s-box/sb.json 2>/dev/null)
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
    
    # 使用 jq 安全構建 VMess JSON
    vm_json=$(jq -n \
        --arg add "$host" \
        --arg aid "0" \
        --arg host "$domain" \
        --arg id "$uuid" \
        --arg net "ws" \
        --arg path "$vm_path" \
        --arg port "$port_vm" \
        --arg ps "VM-$hostname" \
        --arg tls "tls" \
        --arg sni "$domain" \
        --arg type "none" \
        --arg v "2" \
        '{add:$add, aid:$aid, host:$host, id:$id, net:$net, path:$path, port:$port, ps:$ps, tls:$tls, sni:$sni, type:$type, v:$v}')
    vm_link="vmess://$(echo -n "$vm_json" | base64 -w 0)"
    
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

    # 直接使用 jq 读取配置（sb.json 不含行注释，无需 sed 处理）
    uuid=$(jq -r '.inbounds[0].users[0].uuid' /etc/s-box/sb.json 2>/dev/null)
    port_vl=$(jq -r '.inbounds[0].listen_port' /etc/s-box/sb.json 2>/dev/null)
    port_vm=$(jq -r '.inbounds[1].listen_port' /etc/s-box/sb.json 2>/dev/null)
    port_hy=$(jq -r '.inbounds[2].listen_port' /etc/s-box/sb.json 2>/dev/null)
    port_tu=$(jq -r '.inbounds[3].listen_port' /etc/s-box/sb.json 2>/dev/null)
    pk=$(cat /etc/s-box/public.key 2>/dev/null)
    sid=$(jq -r '.inbounds[0].tls.reality.short_id[0]' /etc/s-box/sb.json 2>/dev/null)
    # 从服务端读取 VMess WS 路径，确保客户端配置一致
    vm_path=$(jq -r '.inbounds[1].transport.path' /etc/s-box/sb.json 2>/dev/null)

    reality_sni_client=$(jq -r '.inbounds[0].tls.reality.handshake.server // .inbounds[0].tls.server_name // empty' /etc/s-box/sb.json 2>/dev/null)
    if [[ -z "$reality_sni_client" ]]; then
        reality_sni_client="$reality_sni"
    fi

    if [[ -z "$uuid" || -z "$port_vl" || -z "$port_vm" || -z "$port_hy" || -z "$port_tu" || -z "$pk" || -z "$sid" || -z "$vm_path" ]]; then
        red "从服务端配置中提取必要参数失败，请检查 /etc/s-box/sb.json。"
        return
    fi

    v4v6
    host="$domain"
    if [[ -n "$v4" ]]; then
        host="$v4"
    fi

    # 顯示版本選擇菜單
    echo
    green "══════════════════════════════════════════════════════════════"
    green "          請選擇客戶端配置版本"
    green "──────────────────────────────────────────────────────────────"
    yellow "  [1] 🆕 1.12+ / 最新版 (推薦 - 使用 Rule Actions)"
    yellow "  [2] 📦 iOS SFI 1.11.x (傳統 Inbound Fields)"
    yellow "  [0] ↩️  返回主菜單"
    green "══════════════════════════════════════════════════════════════"
    echo
    readp "   選擇版本 [0-2]: " ver_choice
    
    case "$ver_choice" in
        1) show_client_conf_latest "$host" "$domain" "$uuid" "$port_vl" "$port_vm" "$port_hy" "$port_tu" "$pk" "$sid" "$reality_sni_client" "$vm_path";;
        2) show_client_conf_legacy "$host" "$domain" "$uuid" "$port_vl" "$port_vm" "$port_hy" "$port_tu" "$pk" "$sid" "$reality_sni_client" "$vm_path";;
        0|*) return;;
    esac
}

# ==================== 1.12+ 最新版客戶端配置 ====================
show_client_conf_latest(){
    local host="$1" domain="$2" uuid="$3" port_vl="$4" port_vm="$5" port_hy="$6" port_tu="$7" pk="$8" sid="$9" reality_sni_client="${10}" vm_path="${11}"
    
    green "══════════════════════════════════════════════════════════════"
    green "  Sing-box 1.12+ / 最新版 客戶端配置 (tun 全局模式)"
    green "  ✅ 使用 Rule Actions (新語法)"
    green "══════════════════════════════════════════════════════════════"
    echo
    cat <<EOF
{
  "log": { "disabled": false, "level": "info", "timestamp": true },
  "experimental": {
    "cache_file": { "enabled": true, "path": "cache.db", "store_fakeip": true },
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "external_ui": "ui",
      "secret": "",
      "default_mode": "rule"
    }
  },
  "dns": {
    "servers": [
      { "tag": "proxydns", "address": "tls://8.8.8.8", "detour": "select" },
      { "tag": "localdns", "address": "https://223.5.5.5/dns-query", "detour": "direct" },
      { "tag": "dns_fakeip", "address": "fakeip" }
    ],
    "rules": [
      { "clash_mode": "Global", "server": "proxydns" },
      { "clash_mode": "Direct", "server": "localdns" },
      { "rule_set": "geosite-cn", "server": "localdns" },
      { "rule_set": "geosite-geolocation-!cn", "server": "proxydns" },
      { "rule_set": "geosite-geolocation-!cn", "query_type": ["A", "AAAA"], "server": "dns_fakeip" }
    ],
    "fakeip": { "enabled": true, "inet4_range": "198.18.0.0/15", "inet6_range": "fc00::/18" },
    "independent_cache": false,
    "final": "proxydns"
  },
  "inbounds": [
    {
      "type": "tun", "tag": "tun-in",
      "address": ["172.19.0.1/30", "fd00::1/126"],
      "auto_route": true, "strict_route": true
    }
  ],
  "outbounds": [
    { "tag": "select", "type": "selector", "default": "auto", "outbounds": ["auto", "vless-sb", "vmess-sb", "hy2-sb", "tuic5-sb"] },
    {
      "type": "vless", "tag": "vless-sb", "server": "$host", "server_port": $port_vl,
      "uuid": "$uuid", "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true, "server_name": "$reality_sni_client",
        "utls": { "enabled": true, "fingerprint": "firefox" },
        "reality": { "enabled": true, "public_key": "$pk", "short_id": "$sid" }
      }
    },
    {
      "type": "vmess", "tag": "vmess-sb", "server": "$host", "server_port": $port_vm,
      "uuid": "$uuid", "security": "auto", "packet_encoding": "packetaddr",
      "tls": { "enabled": true, "server_name": "$domain", "insecure": false, "utls": { "enabled": true, "fingerprint": "firefox" } },
      "transport": { "type": "ws", "path": "$vm_path", "headers": { "Host": ["$domain"] } }
    },
    {
      "type": "hysteria2", "tag": "hy2-sb", "server": "$host", "server_port": $port_hy,
      "password": "$uuid",
      "tls": { "enabled": true, "server_name": "$domain", "insecure": false, "alpn": ["h3"] }
    },
    {
      "type": "tuic", "tag": "tuic5-sb", "server": "$host", "server_port": $port_tu,
      "uuid": "$uuid", "password": "$uuid", "congestion_control": "bbr", "udp_relay_mode": "native",
      "tls": { "enabled": true, "server_name": "$domain", "insecure": false, "alpn": ["h3"] }
    },
    { "tag": "direct", "type": "direct" },
    {
      "tag": "auto", "type": "urltest",
      "outbounds": ["vless-sb", "vmess-sb", "hy2-sb", "tuic5-sb"],
      "url": "https://www.gstatic.com/generate_204", "interval": "1m", "tolerance": 50
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
      { "protocol": "dns", "action": "hijack-dns" },
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
    yellow "📌 適用於: Sing-box 1.12.0+, 1.13.x, 最新版本"
    yellow "📌 將以上 JSON 保存為 client.json，以 root 運行 tun 模式即可"
}

# ==================== iOS SFI 1.11.4 客戶端配置 ====================
show_client_conf_legacy(){
    local host="$1" domain="$2" uuid="$3" port_vl="$4" port_vm="$5" port_hy="$6" port_tu="$7" pk="$8" sid="$9" reality_sni_client="${10}" vm_path="${11}"
    
    green "══════════════════════════════════════════════════════════════"
    green "  Sing-box iOS SFI 1.11.4 客戶端配置 (tun 全局模式)"
    green "  📱 適用於 iOS Sing-box (SFI) 1.11.x 版本"
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
    { "tag": "select", "type": "selector", "default": "auto", "outbounds": ["auto", "vless-sb", "vmess-sb", "hy2-sb", "tuic5-sb"] },
    {
      "type": "vless", "tag": "vless-sb", "server": "$host", "server_port": $port_vl,
      "uuid": "$uuid", "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true, "server_name": "$reality_sni_client",
        "utls": { "enabled": true, "fingerprint": "firefox" },
        "reality": { "enabled": true, "public_key": "$pk", "short_id": "$sid" }
      }
    },
    {
      "type": "vmess", "tag": "vmess-sb", "server": "$host", "server_port": $port_vm,
      "uuid": "$uuid", "security": "auto", "packet_encoding": "packetaddr",
      "tls": {
        "enabled": true, "server_name": "$domain", "insecure": false,
        "utls": { "enabled": true, "fingerprint": "firefox" }
      },
      "transport": { "type": "ws", "path": "$vm_path", "headers": { "Host": "$domain" } }
    },
    {
      "type": "hysteria2", "tag": "hy2-sb", "server": "$host", "server_port": $port_hy,
      "password": "$uuid",
      "tls": { "enabled": true, "server_name": "$domain", "insecure": false, "alpn": ["h3"] }
    },
    {
      "type": "tuic", "tag": "tuic5-sb", "server": "$host", "server_port": $port_tu,
      "uuid": "$uuid", "password": "$uuid", "congestion_control": "bbr", "udp_relay_mode": "native",
      "udp_over_stream": false, "zero_rtt_handshake": false, "heartbeat": "10s",
      "tls": { "enabled": true, "server_name": "$domain", "insecure": false, "alpn": ["h3"] }
    },
    { "tag": "direct", "type": "direct" },
    {
      "tag": "auto", "type": "urltest",
      "outbounds": ["vless-sb", "vmess-sb", "hy2-sb", "tuic5-sb"],
      "url": "https://www.gstatic.com/generate_204", "interval": "1m", "tolerance": 50,
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
      { "protocol": "dns", "action": "hijack-dns" },
      { "inbound": "tun-in", "action": "sniff" },
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
    yellow "📌 適用於: iOS Sing-box (SFI) 1.11.x 版本"
    yellow "📌 將以上 JSON 保存為配置文件，導入到 SFI 即可使用"
}

# 卸载
unins(){
    systemctl stop sing-box 2>/dev/null
    systemctl disable sing-box 2>/dev/null
    
    # 清理防火牆規則（安全解析端口日誌，不使用 source）
    if [[ -f /etc/s-box/firewall_ports.log ]]; then
        green "正在清理防火牆規則..."
        
        # 安全解析：只讀取特定格式的行，避免執行任意代碼
        local VLESS_PORT=$(grep '^VLESS_PORT=' /etc/s-box/firewall_ports.log 2>/dev/null | cut -d= -f2)
        local VMESS_PORT=$(grep '^VMESS_PORT=' /etc/s-box/firewall_ports.log 2>/dev/null | cut -d= -f2)
        local HY2_PORT=$(grep '^HY2_PORT=' /etc/s-box/firewall_ports.log 2>/dev/null | cut -d= -f2)
        local TUIC_PORT=$(grep '^TUIC_PORT=' /etc/s-box/firewall_ports.log 2>/dev/null | cut -d= -f2)
        
        # 刪除本腳本添加的端口規則
        [[ -n "$VLESS_PORT" ]] && ufw delete allow "$VLESS_PORT"/tcp >/dev/null 2>&1
        [[ -n "$VMESS_PORT" ]] && ufw delete allow "$VMESS_PORT"/tcp >/dev/null 2>&1
        [[ -n "$HY2_PORT" ]] && ufw delete allow "$HY2_PORT"/udp >/dev/null 2>&1
        [[ -n "$TUIC_PORT" ]] && ufw delete allow "$TUIC_PORT"/udp >/dev/null 2>&1
        
        # 80/443 可能被其他服務使用，詢問是否刪除
        yellow "端口 80/443 可能被其他服務使用，是否刪除這些規則？"
        readp "   刪除 80/443 規則？[y/N]: " del_common_ports
        if [[ "$del_common_ports" =~ ^[Yy]$ ]]; then
            ufw delete allow 80/tcp >/dev/null 2>&1
            ufw delete allow 443/tcp >/dev/null 2>&1
            green "已刪除 80/443 端口規則。"
        fi
        
        green "防火牆規則已清理。"
    else
        yellow "未找到防火牆端口記錄，可能需要手動清理 UFW 規則。"
        yellow "使用 'ufw status numbered' 查看並 'ufw delete <number>' 刪除。"
    fi
    
    rm -rf /etc/s-box /usr/bin/sb /etc/systemd/system/sing-box.service /root/geoip.db /root/geosite.db
    systemctl daemon-reload 2>/dev/null
    green "卸载完成 (BBR 设置保留)。"
}

# 更新脚本
upsbyg(){
    lnsb
    green "脚本已更新，请重新运行 sb" && exit
}

# ==================== 漸層動畫 Banner ====================
show_banner(){
    # Subtle gradient: Blue → Purple → Lavender
    local C1="\033[38;5;75m"   # Soft Blue
    local C2="\033[38;5;111m"  # Light Blue  
    local C3="\033[38;5;147m"  # Light Purple
    local C4="\033[38;5;183m"  # Lavender
    local G="\033[38;5;114m"   # Muted Green
    local D="\033[38;5;245m"   # Gray
    local W="\033[1;37m"       # White
    local R="\033[0m"
    
    clear
    
    # BDFZ-SUEN - Clean gradient style without borders
    echo
    echo -e "${C1}    ██████╗ ${C2}██████╗ ${C3}███████╗${C4}███████╗  ${C1}███████╗${C2}██╗   ██╗${C3}███████╗${C4}███╗   ██╗${R}"
    sleep 0.02
    echo -e "${C1}    ██╔══██╗${C2}██╔══██╗${C3}██╔════╝${C4}╚══███╔╝  ${C1}██╔════╝${C2}██║   ██║${C3}██╔════╝${C4}████╗  ██║${R}"
    sleep 0.02
    echo -e "${C2}    ██████╔╝${C3}██║  ██║${C3}█████╗  ${C4}  ███╔╝   ${C1}███████╗${C2}██║   ██║${C3}█████╗  ${C4}██╔██╗ ██║${R}"
    sleep 0.02
    echo -e "${C2}    ██╔══██╗${C3}██║  ██║${C4}██╔══╝  ${C4} ███╔╝    ${C1}╚════██║${C2}██║   ██║${C3}██╔══╝  ${C4}██║╚██╗██║${R}"
    sleep 0.02
    echo -e "${C3}    ██████╔╝${C4}██████╔╝${C4}██║     ${C3}███████╗  ${C1}███████║${C2}╚██████╔╝${C3}███████╗${C4}██║ ╚████║${R}"
    sleep 0.02
    echo -e "${C3}    ╚═════╝ ${C4}╚═════╝ ${C4}╚═╝     ${C3}╚══════╝  ${C1}╚══════╝${C2} ╚═════╝ ${C3}╚══════╝${C4}╚═╝  ╚═══╝${R}"
    echo
    echo -e "${W}              Sing-Box Multi-Protocol Installer ${G}v2.0${R}"
    echo -e "${D}         VLESS-Reality · VMess-WS · Hysteria2 · TUIC V5${R}"
    echo
}

# ==================== 系統狀態顯示 ====================
show_status(){
    local C="\033[0;36m"   # 青色
    local G="\033[0;32m"   # 綠色
    local Y="\033[0;33m"   # 黃色
    local W="\033[1;37m"   # 白色粗體
    local R="\033[0m"
    
    # 檢查 sing-box 狀態
    local sb_status
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        sb_status="${G}● 運行中${R}"
    elif [[ -f /etc/systemd/system/sing-box.service ]]; then
        sb_status="${Y}○ 已停止${R}"
    else
        sb_status="${Y}◌ 未安裝${R}"
    fi
    
    # 獲取版本 (如果已安裝)
    local sb_ver=""
    if [[ -x /etc/s-box/sing-box ]]; then
        sb_ver=$(/etc/s-box/sing-box version 2>/dev/null | head -n1 | awk '{print $NF}')
        [[ -n "$sb_ver" ]] && sb_ver=" v${sb_ver}"
    fi
    
    # 獲取系統信息
    local ip_addr=$(curl -s4 --max-time 2 ip.sb 2>/dev/null || echo "N/A")
    local mem_info=$(free -h 2>/dev/null | awk '/^Mem:/{print $3"/"$2}' || echo "N/A")
    local cpu_cores=$(nproc 2>/dev/null || echo "?")
    local uptime_info=$(uptime -p 2>/dev/null | sed 's/up //' | sed 's/ day/d/g' | sed 's/ hour/h/g' | sed 's/ minute/m/g' | sed 's/s,/,/g' || echo "N/A")
    
    echo -e "   ${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
    echo -e "   ${C}狀態:${R} $sb_status${sb_ver}    ${C}快捷命令:${R} sb    ${C}系統:${R} $(uname -s) $(uname -m)"
    echo -e "   ${C}IP:${R} ${W}${ip_addr}${R}    ${C}內存:${R} ${mem_info}    ${C}CPU:${R} ${cpu_cores}核    ${C}運行:${R} ${uptime_info}"
    echo -e "   ${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
}

# ==================== 菜單 ====================
show_menu(){
    local G="\033[0;32m"   # 綠色
    local Y="\033[0;33m"   # 黃色
    local C="\033[0;36m"   # 青色
    local W="\033[1;37m"   # 白色粗體
    local R="\033[0m"
    
    echo
    echo -e "   ${W}◆ 安裝與管理${R}"
    echo -e "   ${G}  [1]${R} 🛠️  安裝 Sing-box (需準備域名)"
    echo -e "   ${G}  [2]${R} 🗑️  卸載 Sing-box"
    echo -e "   ${G}  [3]${R} ⬆️  更新 Sing-box 內核"
    echo
    echo -e "   ${W}◆ 節點與配置${R}"
    echo -e "   ${C}  [4]${R} 📋 查看節點訂閱鏈接"
    echo -e "   ${C}  [5]${R} 📱 顯示客戶端配置示例"
    echo
    echo -e "   ${W}◆ 運維操作${R}"
    echo -e "   ${Y}  [6]${R} 📜 查看運行日誌"
    echo -e "   ${Y}  [7]${R} 🔄 重啟 Sing-box 服務"
    echo -e "   ${Y}  [8]${R} 📥 更新此腳本"
    echo
    echo -e "   ${W}◆ 退出${R}"
    echo -e "   ${R}  [0]${R} ❌ 退出腳本"
    echo
}

# 主程序入口
show_banner
show_status
show_menu

readp "   請選擇操作 [0-8]: " Input
echo

case "$Input" in  
    1 ) install_singbox;;
    2 ) unins;;
    3 ) update_core;;
    4 ) sbshare;;
    5 ) client_conf;;
    6 ) view_log;;
    7 ) restart_singbox;;
    8 ) upsbyg;;
    0 ) green "再見！" && exit 0;;
    * ) yellow "無效選項，請重新運行腳本。" && exit 1
esac