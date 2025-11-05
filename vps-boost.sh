#!/usr/bin/env bash
#
# vps-boost.sh  一鍵初始化 VPS 終端體驗
# - 安裝 zsh 等工具
# - 寫 ~/.zshrc（含 [VPS IP]）
# - 在 ~/.bashrc / ~/.profile 加「自動跳 zsh 並在 zsh 結束後 exit」
# - 不會在腳本最後再幫你開一層 zsh，避免要 exit 兩次
# ------------------------------------------------------------
set -e

echo "=== VPS quick boost (generic, safe) starting ==="

# 0. 準備 sudo
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "錯誤：請用 root 或先裝 sudo 再跑。"
    exit 1
  fi
fi

# 1. 找包管理器
if command -v apt >/dev/null 2>&1; then
  UPDATE_CMD="$SUDO apt update -y"
  INSTALL_CMD="$SUDO apt install -y"
elif command -v dnf >/dev/null 2>&1; then
  UPDATE_CMD="$SUDO dnf -y update"
  INSTALL_CMD="$SUDO dnf install -y"
elif command -v yum >/dev/null 2>&1; then
  UPDATE_CMD="$SUDO yum -y update"
  INSTALL_CMD="$SUDO yum install -y"
else
  echo "錯誤：不認得的包管理器。"
  exit 1
fi

echo "[1/7] 更新套件索引..."
eval "$UPDATE_CMD"

# 2. 核心工具
echo "[2/7] 安裝核心工具..."
eval "$INSTALL_CMD zsh curl git nano htop"

# 3. 輔助工具（失敗不退出）
echo "[3/7] 安裝輔助工具..."
for pkg in lnav multitail fzf fd-find fd ripgrep bat batcat; do
  if eval "$INSTALL_CMD $pkg" >/dev/null 2>&1; then
    echo "  - installed: $pkg"
  else
    echo "  - skipped: $pkg"
  fi
done

# 4. 嘗試 chsh（能換就換，不行就靠 bashrc）
ZSH_PATH="$(command -v zsh || true)"
if [ -n "$ZSH_PATH" ]; then
  if [ "$SHELL" != "$ZSH_PATH" ]; then
    echo "[4/7] 嘗試把預設 shell 換成 zsh ..."
    if [ "$(id -u)" -eq 0 ]; then
      chsh -s "$ZSH_PATH" "$(whoami)" || echo "警告：chsh 失敗，之後靠 ~/.bashrc 自動跳。"
    else
      if command -v sudo >/dev/null 2>&1; then
        echo "注意：可能要你輸密碼來換 shell。"
        sudo chsh -s "$ZSH_PATH" "$(whoami)" || echo "警告：請手動：sudo chsh -s $ZSH_PATH $(whoami)"
      else
        echo "警告：沒有 sudo，請手動：chsh -s $ZSH_PATH $(whoami)"
      fi
    fi
  fi
else
  echo "警告：找不到 zsh，但下面的檔案還是會寫。"
fi

# 5. 寫 ~/.zshrc
ZSHRC="$HOME/.zshrc"
echo "[5/7] 寫入 ~/.zshrc ..."
if [ -f "$ZSHRC" ]; then
  mv "$ZSHRC" "$HOME/.zshrc.bak.$(date +%s)"
fi
cat > "$ZSHRC" <<'EOF'
# ===== VPS ZSHRC =====
# 防呆：如果被 bash source，就退出
if [ -n "$BASH_VERSION" ]; then
  echo "This is a zsh config. Run 'zsh' first."
  return 0 2>/dev/null || exit 0
fi

setopt PROMPT_SUBST
autoload -Uz compinit && compinit

# 顯示載入
echo ">>> [VPS] .zshrc loaded at $(date) on $(hostname) <<<"

# cat 美化
if command -v bat >/dev/null 2>&1; then
  alias cat='bat -pp'
elif command -v batcat >/dev/null 2>&1; then
  alias cat='batcat -pp'
fi

# fd 名稱差異
if command -v fdfind >/dev/null 2>&1; then
  alias fd='fdfind'
fi

# 取 IP
_vps_ip() {
  local _ip=""
  if command -v ip >/dev/null 2>&1; then
    _ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
  fi
  if [ -z "$_ip" ]; then
    _ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  [ -z "$_ip" ] && _ip="unknown"
  echo "$_ip"
}
VPS_IP=$(_vps_ip)

# 分隔線
precmd() {
  print -P '%F{238}──────────────────────────────────────────────%f'
}

# git 分支
get_git_branch() {
  command git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return
  echo "(git:$(git rev-parse --abbrev-ref HEAD))"
}

# 最終 prompt
REPORTTIME=3
PROMPT="%F{magenta}[VPS ${VPS_IP}]%f %F{cyan}%D{%H:%M:%S}%f %F{red}%m%f %F{yellow}%~%f \$(get_git_branch) %# "

# journalctl 小工具
jwatch() {
  local svc="$1"; local lines="${2:-80}"
  [ -z "$svc" ] && { echo "usage: jwatch <service> [lines]"; return 1; }
  journalctl -u "$svc" -n "$lines" -f \
    | egrep --color=always 'FAILED|FAILURE|Failed|ERROR|exit-code|backoff|$'
}
jtail() {
  local svc="$1"; local lines="${2:-200}"
  [ -z "$svc" ] && { echo "usage: jtail <service> [lines]"; return 1; }
  journalctl -u "$svc" -n "$lines" \
    | egrep --color=always 'FAILED|FAILURE|Failed|ERROR|exit-code|$'
}
jerr() {
  local svc="$1"
  [ -z "$svc" ] && { echo "usage: jerr <service>"; return 1; }
  journalctl -u "$svc" -n 500 \
    | egrep -n 'FAILED|FAILURE|Failed|ERROR|exit-code'
}
jflow() {
  local svc="$1"
  [ -z "$svc" ] && { echo "usage: jflow <service>"; return 1; }
  journalctl -u "$svc" -f | lnav
}

fo() {
  command -v fzf >/dev/null 2>&1 || { echo "fzf not installed"; return 1; }
  local file
  file=$(fd . . 2>/dev/null | fzf --height 40%) || return
  ${EDITOR:-nano} "$file"
}

rinstall() {
  local url="$1"
  [ -z "$url" ] && { echo "usage: rinstall <raw-sh-url>"; return 1; }
  curl -fsSL "$url" | bash
}

sstatus() {
  local svc="$1"
  [ -z "$svc" ] && { echo "usage: sstatus <service>"; return 1; }
  systemctl status "$svc" --no-pager -l
}
# ===== END =====
EOF

# 6. 在 bashrc / profile 加「自動跳 zsh 然後 exit」
echo "[6/7] 寫入自動跳 zsh 到 ~/.bashrc / ~/.profile ..."
BASH_SNIPPET='
# auto-switch-to-zsh (vps-boost)
if [ -t 1 ] && command -v zsh >/dev/null 2>&1; then
  if [ -z "$ZSH_VERSION" ]; then
    zsh
    exit
  fi
fi
'
if [ -f "$HOME/.bashrc" ]; then
  grep -q "auto-switch-to-zsh (vps-boost)" "$HOME/.bashrc" || printf "%s\n" "$BASH_SNIPPET" >> "$HOME/.bashrc"
else
  printf "%s\n" "$BASH_SNIPPET" > "$HOME/.bashrc"
fi

if [ -f "$HOME/.profile" ]; then
  grep -q "auto-switch-to-zsh (vps-boost)" "$HOME/.profile" || printf "%s\n" "$BASH_SNIPPET" >> "$HOME/.profile"
else
  printf "%s\n" "$BASH_SNIPPET" > "$HOME/.profile"
fi

echo "[7/7] 完成。"
echo "=== Done. 下次 ssh 登進來就是自動 zsh；這次這個 shell 你正常 exit 一次就走了。 ==="