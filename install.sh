#!/usr/bin/env bash
# Seiue Auto Attendance - Installer (Refactored)
# OS: macOS/Homebrew-friendly, also works on Linux
# Installs saa.py and sets up venv in ~/.seiue-auto-attendance

set -euo pipefail

# --- escalate to root for setup (but we will run the app as the real user) ---
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "此腳本需要 root 權限來安裝依賴與寫檔，正在使用 sudo 提權..."
  exec sudo -E bash "$0" "$@"
fi

# --- pretty output ---
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'
info()    { echo -e "${C_BLUE}INFO:${C_RESET} $1"; }
success() { echo -e "${C_GREEN}SUCCESS:${C_RESET} $1"; }
error()   { echo -e "${C_RED}ERROR:${C_RESET} $1" >&2; }
warn()    { echo -e "${C_YELLOW}WARNING:${C_RESET} $1"; }

# --- real user / paths ---
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo ~"$REAL_USER")
INSTALL_DIR="${REAL_HOME}/.seiue-auto-attendance"
VENV_DIR="${INSTALL_DIR}/venv"
PYTHON_SCRIPT_NAME="saa.py"
RUNNER_SCRIPT_NAME="run.sh"
ENV_FILE_NAME=".env"
OS_TYPE="$(uname -s)"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Proxy passthrough if present
PROXY_ENV="$(env | grep -i -E '^(http_proxy|https_proxy|no_proxy|HTTP_PROXY|HTTPS_PROXY|NO_PROXY)=' || true)"
[ -n "${PROXY_ENV}" ] && info "檢測到代理，安裝階段將沿用。"

# Helper to run commands as the real user (not root)
run_as_user() {
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$REAL_USER" -- "$@"
  else
    sudo -u "$REAL_USER" -- "$@"
  fi
}

# ----------------- Pre-flight Environment Checks -----------------
check_environment() {
  info "--- 正在執行環境預檢 ---"
  local all_ok=true

  # 0. Check for source file
  if [ ! -f "${SCRIPT_DIR}/saa.py" ]; then
      error "未在當前目錄找到 saa.py。請確保 saa.py 與 install.sh 在同一目錄下。"
      exit 1
  fi

  # 1. Check Internet Connectivity
  if ! curl -fsS --head --connect-timeout 5 "https://passport.seiue.com/login?school_id=3" >/dev/null; then
    error "無法連到 https://passport.seiue.com，請檢查網路或代理/防火牆。"
    all_ok=false
  fi

  if [ "$OS_TYPE" = "Darwin" ]; then
    # 2. Check bash version (Warning only)
    if [[ "${BASH_VERSION%%.*}" -lt 4 ]]; then
      warn "偵測到 macOS 內建的舊版 bash ($BASH_VERSION)。"
      warn "目前腳本應可相容，但建議透過 'brew install bash' 升級以獲得最佳體驗。"
    fi

    # 3. Check for Homebrew
    if ! command -v brew >/dev/null 2>&1; then
      error "Homebrew 未安裝。此腳本需要 Homebrew 來管理 Python 環境。"
      error "請執行以下指令安裝 Homebrew："
      echo -e "${C_YELLOW}/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"${C_RESET}"
      all_ok=false
    fi

    # 4. Check for Apple Command Line Tools
    if ! xcode-select -p >/dev/null 2>&1; then
      error "Apple 命令列工具 (Command Line Tools) 未安裝。"
      error "它提供了 pip 安裝某些套件時所需的編譯器。"
      error "請在終端機執行以下指令安裝："
      echo -e "${C_YELLOW}xcode-select --install${C_RESET}"
      all_ok=false
    fi
  fi

  if [ "$all_ok" = false ]; then
    error "環境檢查未通過，請修正上述問題後重新執行腳本。"
    exit 1
  fi
  success "環境預檢通過。"
}


get_user_input() {
  info "請輸入您的 Seiue 憑證。"
  read -p "Seiue 用戶名: " SEIUE_USERNAME
  if [ -z "$SEIUE_USERNAME" ]; then
    error "用戶名不能為空。"; exit 1
  fi
  read -s -p "Seiue 密碼: " SEIUE_PASSWORD; echo
  if [ -z "$SEIUE_PASSWORD" ]; then
    error "密碼不能為空。"; exit 1
  fi
  export SEIUE_USERNAME SEIUE_PASSWORD
  return 0
}

# ----------------- Setup Environment -----------------
setup_environment() {
  info "正在設定工作目錄: ${INSTALL_DIR}"

  # Non-destructive reinstall logic
  if [ -d "${INSTALL_DIR}" ]; then
    echo ""
    read -p "偵測到已存在的安裝。要執行全新安裝嗎？ (這將會刪除日誌與憑證) [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
      info "正在執行全新安裝，將移除舊目錄..."
      rm -rf "${INSTALL_DIR}"
    else
      info "將在現有目錄上更新腳本 (保留資料)..."
    fi
  fi

  mkdir -p "${INSTALL_DIR}"
  chown -R "$REAL_USER:$(id -gn "$REAL_USER")" "$INSTALL_DIR"

  info "正在準備基礎 Python 環境..."
  local BASE_PY_PATH=""
  if [ "$OS_TYPE" = "Darwin" ]; then
    if [ -x "/opt/homebrew/bin/python3" ]; then
      BASE_PY_PATH="/opt/homebrew/bin/python3"
    elif [ -x "/usr/local/bin/python3" ]; then
      BASE_PY_PATH="/usr/local/bin/python3"
    else
      BASE_PY_PATH="$(run_as_user bash -lc 'command -v python3' || true)"
    fi
    if [ -z "$BASE_PY_PATH" ]; then
      error "在用戶 ${REAL_USER} 的環境中未找到 python3，請先用 Homebrew 安裝：brew install python"
      exit 1
    fi
  else
    BASE_PY_PATH="python3"
  fi
  info "基礎 Python 路徑: ${BASE_PY_PATH}"

  info "Verifying Python version..."
  if ! run_as_user "$BASE_PY_PATH" -c 'import sys; exit(0) if sys.version_info >= (3, 7) else exit(1)'; then
    error "Python 3.7+ is required. The detected version at '${BASE_PY_PATH}' is too old."
    exit 1
  fi

  info "正在創建獨立的 Python 虛擬環境 (venv)..."
  run_as_user "$BASE_PY_PATH" -m venv "$VENV_DIR"
  local VENV_PY="${VENV_DIR}/bin/python"

  info "升級 venv 內 pip..."
  run_as_user env ${PROXY_ENV} "$VENV_PY" -m pip install -q --upgrade pip

  info "安裝 Python 依賴（requests, pytz, urllib3）..."
  run_as_user env ${PROXY_ENV} "$VENV_PY" -m pip install -q requests pytz urllib3
  success "Python 虛擬環境與依賴已就緒。"

  # --- Copy Python Script ---
  info "安裝 Python 腳本..."
  install -m 0644 -o "$REAL_USER" -g "$(id -gn "$REAL_USER")" "${SCRIPT_DIR}/saa.py" "${INSTALL_DIR}/${PYTHON_SCRIPT_NAME}"
  success "Python 腳本已安裝。"
}


create_credentials_file() {
  info "寫入憑證到 ${ENV_FILE_NAME}（600 權限）..."
  run_as_user bash -lc "printf 'SEIUE_USERNAME=%q\nSEIUE_PASSWORD=%q\n' \"$SEIUE_USERNAME\" \"$SEIUE_PASSWORD\" > '${INSTALL_DIR}/${ENV_FILE_NAME}'"
  if [ -n "$PROXY_ENV" ]; then
    run_as_user bash -lc "env | grep -i -E '^(http_proxy|https_proxy|no_proxy|HTTP_PROXY|HTTPS_PROXY|NO_PROXY)=' | sed 's/^/export /' >> '${INSTALL_DIR}/${ENV_FILE_NAME}'"
  fi
  run_as_user chmod 600 "${INSTALL_DIR}/${ENV_FILE_NAME}"
  success "憑證文件已創建。"
}

create_runner() {
  info "創建快捷啟動腳本..."
  run_as_user bash -c "cat > '${INSTALL_DIR}/${RUNNER_SCRIPT_NAME}'" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")" || exit 1
if [ -f ./.env ]; then
  set -a; source ./.env; set +a
else
  echo "錯誤: ~/.seiue-auto-attendance/.env 未找到" >&2
  exit 1
fi
if [ -z "${SEIUE_USERNAME:-}" ] || [ -z "${SEIUE_PASSWORD:-}" ]; then
  echo "錯誤: .env 未提供 SEIUE_USERNAME/SEIUE_PASSWORD" >&2
  exit 1
fi
exec ./venv/bin/python ./saa.py
EOF
  run_as_user chmod +x "${INSTALL_DIR}/${RUNNER_SCRIPT_NAME}"
  success "快捷啟動腳本創建成功。"
}

# ----------------- Main function -----------------
main() {
  INSTALLER_LOCKDIR="/tmp/seiue_installer.lock"
  if ! mkdir "$INSTALLER_LOCKDIR" 2>/dev/null; then
    error "安裝腳本已在另一個終端運行，請等待其完成。"
    exit 1
  fi
  trap 'rmdir "$INSTALLER_LOCKDIR"' EXIT

  echo -e "${C_GREEN}--- Seiue 自動考勤安裝 (v1.1 Refactored) ---${C_RESET}"
  
  check_environment
  get_user_input
  setup_environment
  create_credentials_file
  create_runner

  : "${AUTO_RUN:=1}"
  if [ "${AUTO_RUN}" = "1" ]; then
    echo -e "${C_BLUE}INFO:${C_RESET} \n所有設定已完成！現在將首次運行考勤腳本...\n--------------------------------------------------"
    run_as_user bash "${INSTALL_DIR}/${RUNNER_SCRIPT_NAME}"
    echo "--------------------------------------------------"
    success "首次運行結束。以後你可以直接執行： ${C_YELLOW}${INSTALL_DIR}/run.sh${C_RESET}"
  else
    success "安裝完成。你可以手動啟動： ${C_YELLOW}${INSTALL_DIR}/run.sh${C_RESET}"
  fi
}

main
