#!/usr/bin/env bash
#
# vps-boost.sh  一鍵初始化 VPS 終端體驗（通用穩定版 + 自動進 zsh + 顯示本機IP + bash守門）
# ------------------------------------------------------------
set -e

echo "=== VPS quick boost (generic, safe) starting ==="

# 0. 準備 sudo（不是 root 就用 sudo）
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "錯誤：腳本不是以 root 執行，且系統沒有 sudo，無法安裝套件。請使用 root 或先安裝 sudo。"
    exit 1
  fi
fi

# 1. 找包管理器
PKG_MANAGER=""
UPDATE_CMD=""
INSTALL_CMD=""
if command -v apt >/dev/null 2>&1; then
  PKG_MANAGER="apt"
  UPDATE_CMD="$SUDO apt update -y"
  INSTALL_CMD="$SUDO apt install -y"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MANAGER="dnf"
  UPDATE_CMD="$SUDO dnf -y update"
  INSTALL_CMD="$SUDO dnf install -y"
elif command -v yum >/dev/null 2>&1; then
  PKG_MANAGER="yum"
  UPDATE_CMD="$SUDO yum -y update"
  INSTALL_CMD="$SUDO yum install -y"
else
  echo "錯誤：找不到支援的包管理器 (apt/dnf/yum)。"
  exit 1
fi

echo "[1/7] 更新套件索引..."
eval "$UPDATE_CMD"

# 2. 安裝核心工具（失敗直接中止）
echo "[2/7] 安裝核心工具 (zsh curl git nano htop)..."
eval "$INSTALL_CMD zsh curl git nano htop"

# 3. 安裝輔助工具（失敗不終止）
echo "[3/7] 安裝輔助工具 (lnav multitail fzf fd / ripgrep / bat)..."
OPTIONAL_PKGS="lnav multitail fzf fd-find fd ripgrep bat batcat"
for pkg in $OPTIONAL_PKGS; do
  if eval "$INSTALL_CMD $pkg" >/dev/null 2>&1; then
    echo "  - installed: $pkg"
  else
    echo "  - skipped (not found or failed): $pkg"
  fi
done

# 4. 嘗試把預設 shell 換成 zsh（能換就換，不能換也別死）
ZSH_PATH="$(command -v zsh || true)"
if [ -n "$ZSH_PATH" ]; then
  if [ "$SHELL" != "$ZSH_PATH" ]; then
    echo "[4/7] 將預設 shell 改成 zsh ($ZSH_PATH)..."
    if [ "$(id -u)" -eq 0 ]; then
      chsh -s "$ZSH_PATH" "$(whoami)" || echo "警告：chsh 執行失敗，請稍後手動執行 'chsh -s $ZSH_PATH $(whoami)'"
    else
      if command -v sudo >/dev/null 2>&1; then
        echo "注意：接下來可能需要輸入您的帳號密碼以更換登入 shell。"
        sudo chsh -s "$ZSH_PATH" "$(whoami)" || echo "警告：自動 chsh 失敗，請手動執行：sudo chsh -s $ZSH_PATH $(whoami)"
      else
        echo "警告：無法自動 chsh，請手動執行：chsh -s $ZSH_PATH $(whoami)"
      fi
    fi
  else
    echo "[4/7] 略過 chsh，目前 shell 已是 zsh。"
  fi
else
  echo "警告：找不到 zsh 執行檔，但前面應該已安裝成功。請重新登入後確認。"
fi

# 5. 寫 ~/.zshrc，先備份舊的
ZSHRC="$HOME/.zshrc"
echo "[5/7] 寫入 ~/.zshrc ..."
if [ -f "$ZSHRC" ]; then
  BACKUP="$HOME/.zshrc.bak.$(date +%s)"
  mv "$ZSHRC" "$BACKUP"
  echo "  已備份原本的 ~/.zshrc -> $BACKUP"
fi

cat > "$ZSHRC" <<'EOF'
# ===== VPS ZSHRC (generic, safe) =====

# 如果被人在 bash 裡 source，就退出，提醒去用 zsh
if [ -n "$BASH_VERSION" ]; then
  echo "This is a zsh config. Run 'zsh' first, then 'source ~/.zshrc'."
  return 0 2>/dev/null || exit 0
fi

setopt PROMPT_SUBST
autoload -Uz compinit && compinit

# 登入提示
echo ">>> [VPS] .zshrc loaded at $(date) on $(hostname) <<<"

# 有 bat / batcat 就用來當 cat
if command -v bat >/dev/null 2>&1; then
  alias cat='bat -pp'
elif command -v batcat >/dev/null 2>&1; then
  alias cat='batcat -pp'
fi

# Debian/Ubuntu 的 fd 叫 fdfind
if command -v fdfind >/dev/null 2>&1; then
  alias fd='fdfind'
fi

# 取本機 IP，優先 ip，再 hostname -I
_vps_ip() {
  local _ip=""
  if command -v ip >/dev/null 2>&1; then
    _ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
  fi
  if [ -z "$_ip" ]; then
    _ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  if [ -z "$_ip" ]; then
    _ip="unknown"
  fi
  echo "$_ip"
}
VPS_IP=$(_vps_ip)

# ===== prompt 區 =====
REPORTTIME=3

precmd() {
  print -P '%F{238}──────────────────────────────────────────────%f'
}

# 不用特殊字元，避免亂碼；加上 [VPS <IP>]
get_git_branch() {
  command git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return
  echo "(git:$(git rev-parse --abbrev-ref HEAD))"
}
PROMPT="%F{magenta}[VPS ${VPS_IP}]%f %F{cyan}%D{%H:%M:%S}%f %F{red}%m%f %F{yellow}%~%f \$(get_git_branch) %# "

# ===== systemd / journalctl helper =====
jwatch() {
  local svc="$1"
  local lines="${2:-80}"
  if [ -z "$svc" ]; then
    echo "usage: jwatch <service> [lines]"; return 1
  fi
  journalctl -u "$svc" -n "$lines" -f \
    | egrep --color=always 'FAILED|FAILURE|Failed|ERROR|exit-code|backoff|$'
}

jtail() {
  local svc="$1"
  local lines="${2:-200}"
  if [ -z "$svc" ]; then
    echo "usage: jtail <service> [lines]"; return 1
  fi
  journalctl -u "$svc" -n "$lines" \
    | egrep --color=always 'FAILED|FAILURE|Failed|ERROR|exit-code|$'
}

jerr() {
  local svc="$1"
  if [ -z "$svc" ]; then
    echo "usage: jerr <service>"; return 1
  fi
  journalctl -u "$svc" -n 500 \
    | egrep -n 'FAILED|FAILURE|Failed|ERROR|exit-code'
}

jflow() {
  local svc="$1"
  if [ -z "$svc" ]; then
    echo "usage: jflow <service>"; return 1
  fi
  journalctl -u "$svc" -f | lnav
}

# 模糊找檔（有 fzf 才能用）
fo() {
  if ! command -v fzf >/dev/null 2>&1; then
    echo "fzf not installed"; return 1
  fi
  local file
  file=$(fd . . 2>/dev/null | fzf --height 40%) || return
  ${EDITOR:-nano} "$file"
}

# 一鍵拉遠端腳本
rinstall() {
  local url="$1"
  if [ -z "$url" ]; then
    echo "usage: rinstall <raw-sh-url>"; return 1
  fi
  curl -fsSL "$url" | bash
}

# systemd 狀態短版
sstatus() {
  local svc="$1"
  if [ -z "$svc" ]; then
    echo "usage: sstatus <service>"; return 1
  fi
  systemctl status "$svc" --no-pager -l
}
# ===== END =====
EOF

# 6. 在 bashrc / profile 加自動跳 zsh，防止 ssh 默認進 bash
echo "[6/7] 寫入 ~/.bashrc 跳轉到 zsh ..."
BASHRC="$HOME/.bashrc"
BASH_SNIPPET='
# auto-switch-to-zsh (added by vps-boost)
if [ -t 1 ] && command -v zsh >/dev/null 2>&1; then
  if [ -z "$ZSH_VERSION" ]; then
    exec zsh
  fi
fi
'
if [ -f "$BASHRC" ]; then
  # 避免重複寫
  if ! grep -q "auto-switch-to-zsh (added by vps-boost)" "$BASHRC"; then
    printf "%s\n" "$BASH_SNIPPET" >> "$BASHRC"
  fi
else
  printf "%s\n" "$BASH_SNIPPET" > "$BASHRC"
fi

echo "[7/7] 寫入 ~/.profile 跳轉到 zsh (作為備援) ..."
PROFILE="$HOME/.profile"
if [ -f "$PROFILE" ]; then
  if ! grep -q "auto-switch-to-zsh (added by vps-boost)" "$PROFILE"; then
    printf "%s\n" "$BASH_SNIPPET" >> "$PROFILE"
  fi
else
  printf "%s\n" "$BASH_SNIPPET" > "$PROFILE"
fi

echo "=== 所有設定寫入完成，切換到 zsh ==="

# 7. 當前這次也直接進 zsh
if [ -x /usr/bin/zsh ]; then
  exec /usr/bin/zsh
elif command -v zsh >/dev/null 2>&1; then
  exec "$(command -v zsh)"
else
  echo "警告：找不到 zsh 執行檔，請手動執行 'zsh'"
fi