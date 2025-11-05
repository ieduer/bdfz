#!/usr/bin/env bash
#
# vps-boost.sh  一鍵初始化 VPS 終端體驗（通用穩定版）
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

echo "[1/5] 更新套件索引..."
eval "$UPDATE_CMD"

# 2. 安裝核心工具（失敗直接中止）
echo "[2/5] 安裝核心工具 (zsh curl git nano htop)..."
eval "$INSTALL_CMD zsh curl git nano htop"

# 3. 安裝輔助工具（失敗不終止，因為有些發行版名稱不同）
echo "[3/5] 安裝輔助工具 (lnav multitail fzf fd / ripgrep / bat)..."
# 依序嘗試常見名稱
OPTIONAL_PKGS="lnav multitail fzf fd-find fd ripgrep bat batcat"
for pkg in $OPTIONAL_PKGS; do
  if eval "$INSTALL_CMD $pkg" >/dev/null 2>&1; then
    echo "  - installed: $pkg"
  else
    echo "  - skipped (not found or failed): $pkg"
  fi
done

# 4. 嘗試把預設 shell 換成 zsh
ZSH_PATH="$(command -v zsh || true)"
if [ -n "$ZSH_PATH" ]; then
  if [ "$SHELL" != "$ZSH_PATH" ]; then
    echo "[4/5] 將預設 shell 改成 zsh (${ZSH_PATH})..."
    if [ "$(id -u)" -eq 0 ]; then
      # root 通常不用密碼
      chsh -s "$ZSH_PATH" "$(whoami)" || echo "警告：chsh 執行失敗，請稍後手動執行 'chsh -s $ZSH_PATH $(whoami)'"
    else
      # 非 root，可能要密碼
      if command -v sudo >/dev/null 2>&1; then
        echo "注意：接下來可能需要輸入您的帳號密碼以更換登入 shell。"
        sudo chsh -s "$ZSH_PATH" "$(whoami)" || echo "警告：自動 chsh 失敗，請手動執行：sudo chsh -s $ZSH_PATH $(whoami)"
      else
        echo "警告：無法自動 chsh，請手動執行：chsh -s $ZSH_PATH $(whoami)"
      fi
    fi
  else
    echo "[4/5] 略過 chsh，目前 shell 已是 zsh。"
  fi
else
  echo "警告：找不到 zsh 執行檔，但前面應該已安裝成功。請重新登入後確認。"
fi

# 5. 寫 ~/.zshrc，先備份舊的
ZSHRC="$HOME/.zshrc"
echo "[5/5] 寫入 ~/.zshrc ..."
if [ -f "$ZSHRC" ]; then
  BACKUP="$HOME/.zshrc.bak.$(date +%s)"
  mv "$ZSHRC" "$BACKUP"
  echo "  已備份原本的 ~/.zshrc -> $BACKUP"
fi

cat > "$ZSHRC" <<'EOF'
# ===== VPS ZSHRC (generic, safe) =====
setopt PROMPT_SUBST
autoload -Uz compinit && compinit

# 登入提示，避免以為在本機
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

# ===== prompt 區 =====
# 超過 3 秒顯示執行時間
REPORTTIME=3

# 每次 prompt 前打一條灰線，分隔輸出
precmd() {
  print -P '%F{238}──────────────────────────────────────────────%f'
}

# VPS 專用 prompt：不使用特殊字元，避免亂碼
# 範例：[VPS] 12:34:56 host /root (git:main) #
get_git_branch() {
  command git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return
  echo "(git:$(git rev-parse --abbrev-ref HEAD))"
}
PROMPT='%F{magenta}[VPS]%f %F{cyan}%D{%H:%M:%S}%f %F{red}%m%f %F{yellow}%~%f $(get_git_branch) %# '

# ===== systemd / journalctl helper =====
# 實時看服務並高亮錯誤
jwatch() {
  local svc="$1"
  local lines="${2:-80}"
  if [ -z "$svc" ]; then
    echo "usage: jwatch <service> [lines]"; return 1
  fi
  journalctl -u "$svc" -n "$lines" -f \
    | egrep --color=always 'FAILED|FAILURE|Failed|ERROR|exit-code|backoff|$'
}

# 看最近 N 行
jtail() {
  local svc="$1"
  local lines="${2:-200}"
  if [ -z "$svc" ]; then
    echo "usage: jtail <service> [lines]"; return 1
  fi
  journalctl -u "$svc" -n "$lines" \
    | egrep --color=always 'FAILED|FAILURE|Failed|ERROR|exit-code|$'
}

# 只列錯誤
jerr() {
  local svc="$1"
  if [ -z "$svc" ]; then
    echo "usage: jerr <service>"; return 1
  fi
  journalctl -u "$svc" -n 500 \
    | egrep -n 'FAILED|FAILURE|Failed|ERROR|exit-code'
}

# 用 lnav 看這個服務的流
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

# systemd 狀態的短版
sstatus() {
  local svc="$1"
  if [ -z "$svc" ]; then
    echo "usage: sstatus <service>"; return 1
  fi
  systemctl status "$svc" --no-pager -l
}
# ===== END =====
EOF

echo "=== Done. 請重新登入或執行 'source ~/.zshrc' 查看效果。 ==="