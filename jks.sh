# =============================================================================
# smartedu_fetch_all.sh  ——  Shell + Python polyglot (v1.0)
# -----------------------------------------------------------------------------
# 新增：
#  • 整輪結束後自動重試（預設 2 輪，可用 -T N 調整；0 表示關閉）。
#  • 每輪重試僅針對上輪失敗清單，成功即寫回 index.json，仍失敗保留到 failed.json。
#  • 最終若仍有失敗，清晰提示用戶可再次運行或用 -R 僅重試失敗。
# 其他：
#  • 保持 v4.2 的穩定性：多主機索引/詳情、Referer 完整、HEAD/Range 探測、斷點續傳、去重、詳盡日誌。
# -----------------------------------------------------------------------------
# 用法：
#   bash smartedu_fetch_all.sh -p 高中
#   bash smartedu_fetch_all.sh -p 高中 -s 语文,数学 -m "必修 第一册" -T 3
#   bash smartedu_fetch_all.sh -R -o ./output_dir
# =============================================================================

# ---- 如果以 python 方式調用，直接跳過 Shell 部分 ----
if [ -n "${PYTHON_EXEC:-}" ]; then
  :
else
  set -euo pipefail

  # 調試模式：DEBUG=1 時打印執行細節
  if [ "${DEBUG:-0}" = "1" ]; then set -x; fi

  # 記錄當前工作目錄，避免 /dev/fd 路徑造成相對路徑混亂
  PWD_ABS="$(pwd)"

  # 對於 apt 系統，預設為非互動模式，避免安裝中途停下
  if command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive}
  fi

  # 預設參數
  PHASE="高中"
  SUBJECTS="语文,数学,英语,思想政治,历史,地理,物理,化学,生物"
  FORCE_OVERWRITE="0"
  CATALOG_ONLY="0"
  WORKER_URL=""
  HCON=12
  DCON=5
  POST_RETRY=2
  
  # ---- 交互式配置（始終開啟） ----
  if [ -t 0 ]; then
    printf "\n================ 📚 智慧教育教材下載器 ================\n"
    printf "歡迎使用！本工具將幫助您下載國家教材或生成目錄。\n\n"

    # 1. 模式選擇
    printf "👉 [1/4] 請問您想做什麼？\n"
    printf "   1) 下載教材 PDF 到本地（默認，適合打印或離線閱讀）\n"
    printf "   2) 僅生成網站目錄（不下載 PDF，生成一個網頁版目錄）\n"
    read -r -p "請輸入數字 [1-2] (默認 1): " ans
    if [ "$ans" = "2" ]; then
        CATALOG_ONLY="1"
        printf "\n   [i] 已選擇「僅目錄模式」。將生成包含下載鏈接的網頁。\n"
        if [ -z "$WORKER_URL" ]; then
             printf "   [?] 請輸入 Cloudflare Worker 代理地址 (可選，防止 403 錯誤)\n"
             printf "       (如果沒有，可直接回車，但直接鏈接可能失效)\n"
             read -r -p "       Worker URL: " w_ans
             [ -n "$w_ans" ] && WORKER_URL="$w_ans"
        fi
    else
        CATALOG_ONLY="0"
    fi

    # 2. 教育階段
    printf "\n👉 [2/4] 選擇教育階段：\n"
    printf "   1) 小学    2) 初中    3) 高中 (默認)    4) 特殊教育    5) 小学54    6) 初中54\n"
    read -r -p "請輸入數字 [1-6]: " ans
    case "$ans" in
      1) PHASE="小学";;
      2) PHASE="初中";;
      3) PHASE="高中";;
      4) PHASE="特殊教育";;
      5) PHASE="小学54";;
      6) PHASE="初中54";;
      *) [ -z "$PHASE" ] && PHASE="高中";;
    esac
    printf "   [i] 已選擇: %s\n" "$PHASE"

    # 3. 學科選擇 (Simplified menu)
    printf "\n👉 [3/4] 選擇學科：\n"
    printf "   0) 全部下載 (默認)\n"
    
    # Common subjects list
    menu_subjs=("语文" "数学" "英语" "物理" "化学" "生物" "历史" "地理" "思想政治" "科学" "道德与法治" "信息技术" "体育" "音乐" "美术")
    i=1
    for s in "${menu_subjs[@]}"; do
        printf "   %2d) %-10s" "$i" "$s"
        if [ $((i % 4)) -eq 0 ]; then echo ""; fi
        i=$((i+1))
    done
    echo ""
    printf "   Tip: 可輸入多個數字(如 1,2,3) 或直接輸入學科名稱\n"
    
    read -r -p "請輸入 (默認 0): " ans
    if [ -n "$ans" ]; then
        if [ "$ans" = "0" ]; then
            # Keep default SUBJECTS but maybe expand it if user wants ALL?
            # Actually default SUBJECTS in env variable is quite limited. 
            # If user selects ALL (0), we should probably set it to a very broad list or special value.
            # For now, let's set it to the full menu list plus defaults to be safe.
            SUBJECTS="语文,数学,英语,物理,化学,生物,历史,地理,思想政治,科学,道德与法治,信息技术,体育与健康,音乐,美术,艺术,劳动,综合实践活动"
        elif [[ "$ans" =~ ^[0-9,]+$ ]]; then
            # Parse numbers
            new_subjs=""
            IFS=',' read -ra ADDR <<< "$ans"
            for id in "${ADDR[@]}"; do
                idx=$((id-1))
                if [ $idx -ge 0 ] && [ $idx -lt ${#menu_subjs[@]} ]; then
                    if [ -z "$new_subjs" ]; then new_subjs="${menu_subjs[$idx]}"; else new_subjs="$new_subjs,${menu_subjs[$idx]}"; fi
                fi
            done
            [ -n "$new_subjs" ] && SUBJECTS="$new_subjs"
        else
            # Assume manual text input
            SUBJECTS="$ans"
        fi
    fi
    printf "   [i] 已選擇: %s\n" "$SUBJECTS"

    # 4. 強制覆蓋
    if [ "$CATALOG_ONLY" = "0" ]; then
        printf "\n👉 [4/4] 是否重新下載已存在且完整的文件？\n"
        read -r -p "輸入 y 重新下載，直接回車跳過 (默認跳過): " ans
        if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
             FORCE_OVERWRITE="1"
        fi
    fi

    printf "\n✅ 配置完成！即將開始任務...\n"
    printf "==============================================\n\n"
    sleep 1
  fi

  # 若使用強制模式，詢問是否清除舊 PDF
  if [ "$FORCE_OVERWRITE" = "1" ] && [ -t 0 ]; then
    # 檢查輸出目錄是否存在 PDF 文件
    _CHECK_DIR="./smartedu_textbooks"
    
    if [ -d "$_CHECK_DIR" ]; then
      _PDF_COUNT=$(find "$_CHECK_DIR" -name "*.pdf" -type f 2>/dev/null | wc -l | tr -d ' ')
      if [ "$_PDF_COUNT" -gt 0 ]; then
        printf "\n⚠️  發現 %s 個現有 PDF 文件在 %s\n" "$_PDF_COUNT" "$_CHECK_DIR"
        printf "    強制模式會重新下載所有文件，但不會自動刪除舊文件。\n"
        read -r -p "是否在開始前清除所有舊 PDF？(y/N): " ans
        if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
          printf "[*] 正在清除舊 PDF 文件..."
          find "$_CHECK_DIR" -name "*.pdf" -type f -delete 2>/dev/null
          find "$_CHECK_DIR" -name "*.part" -type f -delete 2>/dev/null
          printf " 完成\n"
        else
          printf "[i] 保留舊文件，新下載將覆蓋同名文件\n"
        fi
      fi
    fi
  fi

  # 交互輸入後再做一次數值校驗
  int_re='^[0-9]+$'
  # 交互輸入後再做一次數值校驗 (Optional, kept for safety)
  int_re='^[0-9]+$'
  if ! [[ "$HCON" =~ $int_re ]]; then HCON=12; fi
  if ! [[ "$DCON" =~ $int_re ]]; then DCON=5; fi

  # --- 權限與包管理器偵測 ---
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then SUDO="sudo"; else SUDO=""; fi
  have() { command -v "$1" >/dev/null 2>&1; }
  pm=""
  if have apt-get; then pm=apt; elif have apt; then pm=apt; elif have dnf; then pm=dnf; elif have yum; then pm=yum; elif have pacman; then pm=pacman; elif have zypper; then pm=zypper; elif have apk; then pm=apk; elif have brew; then pm=brew; fi

  # --- 安裝 Python 與 pip/venv，涵蓋主流發行版 ---
  install_python() {
    echo "[*] 準備 Python 環境... (pkgmgr=$pm)"
    case "$pm" in
      apt)
        $SUDO apt-get update -y -qq || true
        if [ -n "$SUDO" ]; then
          $SUDO env DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive} \
            apt-get install -y -qq \
              -o Dpkg::Options::=--force-confdef \
              -o Dpkg::Options::=--force-confnew \
              python3 python3-venv python3-pip ca-certificates
        else
          env DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive} \
            apt-get install -y -qq \
              -o Dpkg::Options::=--force-confdef \
              -o Dpkg::Options::=--force-confnew \
              python3 python3-venv python3-pip ca-certificates
        fi
        ;;
      dnf)
        $SUDO dnf install -y python3 python3-pip
        ;;
      yum)
        $SUDO yum install -y python3 python3-pip
        ;;
      pacman)
        $SUDO pacman -Sy --noconfirm python python-pip
        ;;
      zypper)
        $SUDO zypper -n install python3 python3-pip
        ;;
      apk)
        $SUDO apk add --no-cache python3 py3-pip ca-certificates
        ;;
      brew)
        brew update >/dev/null || true
        brew install python || true
        ;;
      *)
        echo "[!] 未識別的包管理器，請手動安裝 python3/pip。" >&2
        ;;
    esac

    # 若缺 ensurepip，嘗試修復
    if ! python3 - <<'PY' 2>/dev/null
import ensurepip; print('ok')
PY
    then
      echo "[*] 嘗試啟用 ensurepip..."
      python3 -m ensurepip --upgrade >/dev/null 2>&1 || true
    fi

    # 若仍無 pip，使用 get-pip 引導
    if ! python3 -m pip --version >/dev/null 2>&1; then
      echo "[*] 使用 get-pip 引導安裝 pip..."
      TMPPIP="$(mktemp -t getpip_XXXX).py"
      if have curl; then curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "$TMPPIP"; elif have wget; then wget -qO "$TMPPIP" https://bootstrap.pypa.io/get-pip.py; else echo "[!] 需要 curl 或 wget 下載 get-pip.py" >&2; exit 1; fi
      python3 "$TMPPIP" >/dev/null
      rm -f "$TMPPIP"
    fi
  }

  if ! have python3; then
    if [ -z "$pm" ]; then echo "[!] 未檢測到包管理器且系統無 python3，請先手動安裝。" >&2; exit 1; fi
    install_python
  else
    # 某些 Debian/Ubuntu 精簡鏡像雖有 python3 但缺 venv 模塊
    if [ "$pm" = apt ] && ! python3 -c 'import venv' 2>/dev/null; then
      echo "[*] 安裝 python3-venv ..."; $SUDO apt-get update -y -qq; \
      if [ -n "$SUDO" ]; then
        $SUDO env DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive} apt-get install -y -qq python3-venv
      else
        env DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive} apt-get install -y -qq python3-venv
      fi
    fi
    # 若無 pip 亦補齊
    if ! python3 -m pip --version >/dev/null 2>&1; then
      install_python
    fi
  fi

  # --- 建立虛擬環境（失敗則修復後重試，仍失敗 fallback 系統 Python） ---
  # 允許外部強制使用系統 Python：USE_SYSTEM_PY=1 bash jks.sh ...
  if [ "${USE_SYSTEM_PY:-0}" = "1" ]; then
    echo "[i] 已指定 USE_SYSTEM_PY=1，跳過 venv 構建，直接使用系統 Python。"
  fi

  VENV_DIR="${VENV_DIR:-$PWD_ABS/.venv}"
  if [ "${USE_SYSTEM_PY:-0}" != "1" ]; then
    if [ ! -d "$VENV_DIR" ]; then
      echo "[*] 創建虛擬環境 $VENV_DIR"
      if ! python3 -m venv "$VENV_DIR" 2>/tmp/venv.err; then
        echo "[!] venv 建立失敗，嘗試修復..."
        if [ "$pm" = apt ]; then
          if [ -n "$SUDO" ]; then
            $SUDO env DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive} apt-get install -y -qq python3-venv || true
          else
            env DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive} apt-get install -y -qq python3-venv || true
          fi
        fi
        python3 -m ensurepip --upgrade >/dev/null 2>&1 || true
        if ! python3 -m venv "$VENV_DIR" 2>>/tmp/venv.err; then
          echo "[!] 仍無法建立 venv，將改用系統 Python 繼續（建議稍後修復 venv）。" >&2
          USE_SYSTEM_PY=1
        fi
      fi
    fi
  fi

  if [ "${USE_SYSTEM_PY:-0}" != "1" ]; then
    if [ -f "$VENV_DIR/bin/activate" ] && [ -x "$VENV_DIR/bin/python3" ]; then
      # shellcheck disable=SC1091
      . "$VENV_DIR/bin/activate"
      echo "[i] 已啟用虛擬環境：$VENV_DIR"
    else
      echo "[!] venv 構建不完整，找不到 $VENV_DIR/bin/activate 或 python3；將改用系統 Python 繼續。" >&2
      USE_SYSTEM_PY=1
      if [ -f /tmp/venv.err ]; then
        echo "[i] venv 建立錯誤摘要：" >&2
        tail -n 50 /tmp/venv.err >&2 || true
      fi
      echo "[i] 當前工作目錄：$PWD_ABS；VENV_DIR=$VENV_DIR"
      echo "[i] 目錄列舉："; ls -la "$PWD_ABS" || true
    fi
  fi

  # 安裝依賴
  echo "[i] 使用的 Python: $(command -v python3)"
  python3 --version || true
  python3 -m pip install -U pip wheel setuptools >/dev/null
  python3 -m pip install -U aiohttp aiofiles tqdm >/dev/null

  export SMARTEDU_PHASE="$PHASE"
  export SMARTEDU_SUBJ="$SUBJECTS"
  # --- 確定輸出目錄（固定為 ./smartedu_textbooks） ---
  OUT_DIR="./smartedu_textbooks"
  mkdir -p "$OUT_DIR"
  export SMARTEDU_OUT_DIR="$OUT_DIR"
  echo "[i] 下載輸出目錄: $SMARTEDU_OUT_DIR"

  # 網頁生成已移除
  export SMARTEDU_HCON="$HCON"
  export SMARTEDU_DCON="$DCON"
  export SMARTEDU_POST_RETRY="$POST_RETRY"
  export SMARTEDU_FORCE="$FORCE_OVERWRITE"
  export SMARTEDU_CATALOG_ONLY="$CATALOG_ONLY"
  export SMARTEDU_WORKER_URL="$WORKER_URL"
  export PYTHON_EXEC=1

  # --- 清理孤立的 .part 文件（超過 24 小時） ---
  cleanup_stale_parts() {
    local dir="$1"
    if [ ! -d "$dir" ]; then return; fi
    local count=0
    while IFS= read -r -d '' f; do
      rm -f "$f" && count=$((count + 1))
    done < <(find "$dir" -name "*.part" -type f -mmin +1440 -print0 2>/dev/null)
    if [ "$count" -gt 0 ]; then
      echo "[i] 已清理 $count 個孤立的 .part 文件"
    fi
  }
  cleanup_stale_parts "$OUT_DIR"

  # --- 配置 Nginx PDF 訪問專用日誌（若系統有 nginx） ---
  setup_nginx_pdf_logging() {
    if ! command -v nginx >/dev/null 2>&1; then return; fi
    local cfg="/etc/nginx/conf.d/textbook_pdf_logging.conf"
    if [ -f "$cfg" ]; then
      echo "[i] Nginx PDF logging 已存在: $cfg"; return;
    fi
    echo "[*] 配置 Nginx PDF 專用訪問日誌..."
    $SUDO tee "$cfg" >/dev/null <<'NG'
# 在 http 區塊生效：按請求 URI 是否為 .pdf 決定是否記錄
map $request_uri $is_textbook_pdf {
  default 0;
  ~*\.pdf$ 1;
}
log_format textbook '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for" "$http_cf_connecting_ip" '
                    'host=$host uri=$request_uri bytes=$bytes_sent '
                    'sent_type=$sent_http_content_type';
access_log /var/log/nginx/textbook_access.log textbook if=$is_textbook_pdf;
NG
    $SUDO nginx -t && $SUDO systemctl reload nginx || echo "[!] Nginx 配置測試/重載失敗，請手動檢查。"
  }
  setup_nginx_pdf_logging

  echo "[🚀] 啟動 Python 下載器..."
  TMP_PY="$(mktemp)"
  awk '/^# >>>PYTHON>>>$/{p=1;next} /^# <<<PYTHON<<</{p=0} p' "$0" > "$TMP_PY"
  exec python3 "$TMP_PY"
  echo "[!] 無法啟動 Python 子進程，請檢查上方日誌。" >&2
  exit 1
fi

# >>>PYTHON>>>
# -*- coding: utf-8 -*-
"""
SmartEdu 批量下載器 (polyglot v5.0)
- 從「下載環節」徹底去重：規範命名（去掉 __hash/_hash/-日期/時間戳 尾綴），下載前基於 Content-Length + 現有文件進行判斷，已存在且更大/相等則跳過。
- 斷點續傳：.part 檔自動續下；下載完成後原子替換。
- 成功後即刻更新 index.json 與 index.html（最後一版頁面樣式），學科導航點擊如「語文」會同時顯示初中/高中等所有學段已下載教材。
- 真正去重輸出到網頁：同學科 + 同「規範書名」只顯示一條，保留體積更大的版本。
- 自動重試輪：整輪失敗清單可再試 N 輪（SMARTEDU_POST_RETRY；預設 2；0=關閉）。
"""
from __future__ import annotations

import os, re, json, asyncio, aiohttp, aiofiles, time, logging
import shutil
from logging import handlers
from pathlib import Path
from urllib.parse import quote
from typing import List, Dict, Any, Tuple, Optional
from collections import namedtuple
from tqdm import tqdm

# ---------------- 基本配置 / 常量 ----------------
Settings = namedtuple("Settings", [
    "PHASE","SUBJECTS","FORCE","CATALOG_ONLY","WORKER_URL",
    "HCON","DCON","POST_RETRY"
])

PHASE_TAGS = {
    "小学": ["小学"],
    "初中": ["初中"],
    "高中": ["高中", "普通高中"],
    "特殊教育": ["特殊教育"],
    "小学54": ["小学（五•四学制）", "小学（五·四学制）"],
    "初中54": ["初中（五•四学制）", "初中（五·四学制）"],
}

ORDER_SUBJ = ["语文","数学","英语","物理","化学","生物","思想政治","历史","地理"]
SUBJ_RANK = {v:i for i,v in enumerate(ORDER_SUBJ)}
CLS = {"语文":"yuwen","数学":"shuxue","英语":"yingyu","物理":"wuli","化学":"huaxue","生物":"shengwu","思想政治":"zhengzhi","历史":"lishi","地理":"dili"}
THEME = {
  "yuwen":   {"chip":"#C2410C","title":"#F59E0B","name":"#F8B76B","grad":"linear-gradient(135deg,#fb923c40,#fed7aa33)","border":"#fb923c","tint":"#2b1a12"},
  "shuxue":  {"chip":"#0D9488","title":"#34D399","name":"#7FE3C8","grad":"linear-gradient(135deg,#14b8a640,#99f6e433)","border":"#2dd4bf","tint":"#10201f"},
  "yingyu":  {"chip":"#2563EB","title":"#60A5FA","name":"#9EC5FF","grad":"linear-gradient(135deg,#3b82f640,#93c5fd33)","border":"#60a5fa","tint":"#121a2b"},
  "wuli":    {"chip":"#7C3AED","title":"#A78BFA","name":"#D2C3FF","grad":"linear-gradient(135deg,#8b5cf640,#c4b5fd33)","border":"#a78bfa","tint":"#191331"},
  "huaxue":  {"chip":"#16A34A","title":"#86EFAC","name":"#BFF5D2","grad":"linear-gradient(135deg,#22c55e40,#bbf7d033)","border":"#86efac","tint":"#0e1e14"},
  "shengwu": {"chip":"#059669","title":"#34D399","name":"#86EBCF","grad":"linear-gradient(135deg,#10b98140,#6ee7b733)","border":"#34d399","tint":"#0c1f1a"},
  "zhengzhi":{"chip":"#D97706","title":"#FBBF24","name":"#FFD683","grad":"linear-gradient(135deg,#f59e0b40,#fde68a33)","border":"#fbbf24","tint":"#261a08"},
  "lishi":   {"chip":"#EA580C","title":"#FB923C","name":"#FFC39C","grad":"linear-gradient(135deg,#f9731640,#fdba7433)","border":"#fb923c","tint":"#29170e"},
  "dili":    {"chip":"#0EA5E9","title":"#67E8F9","name":"#A8F4FE","grad":"linear-gradient(135deg,#06b6d440,#a5f3fc33)","border":"#67e8f9","tint":"#0d1f28"},
}

S_FILE_HOSTS = [
    "https://s-file-1.ykt.cbern.com.cn",
    "https://s-file-2.ykt.cbern.com.cn",
    "https://s-file-3.ykt.cbern.com.cn",
]
R_HOSTS = [
    "https://r1-ndr-oversea.ykt.cbern.com.cn",
    "https://r2-ndr-oversea.ykt.cbern.com.cn",
    "https://r3-ndr-oversea.ykt.cbern.com.cn",
    "https://r1-ndr.ykt.cbern.com.cn",
    "https://r2-ndr.ykt.cbern.com.cn",
    "https://r3-ndr.ykt.cbern.com.cn",
]
ENTRY_PATH = "/zxx/ndrs/resources/tch_material/version/data_version.json"
BASE_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6_1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118 Safari/537.36",
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "zh-CN,zh;q=0.9",
}

# ---------------- 日誌 ----------------
LOGGER = logging.getLogger("smartedu")
def setup_logging(out_dir: Path):
    LOGGER.setLevel(logging.DEBUG)
    LOGGER.handlers.clear()
    ch = logging.StreamHandler()
    ch.setLevel(logging.INFO)
    ch.setFormatter(logging.Formatter("[%(asctime)s] %(levelname)s - %(message)s", datefmt="%H:%M:%S"))
    out_dir.mkdir(parents=True, exist_ok=True)
    fh = handlers.RotatingFileHandler(out_dir / "smartedu_download.log", maxBytes=10_000_000, backupCount=2, encoding="utf-8")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(logging.Formatter("[%(asctime)s] %(levelname)s %(name)s:%(lineno)d - %(message)s", datefmt="%Y-%m-%d %H:%M:%S"))
    LOGGER.addHandler(ch); LOGGER.addHandler(fh)

# ---------------- 工具 ----------------
def esc(s: str) -> str:
    return (s or "").replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")

def have_pdf_head(p: Path) -> bool:
    try:
        if not p.exists() or p.stat().st_size < 100*1024: return False
        with open(p,'rb') as f: return f.read(5) == b'%PDF-'
    except Exception: return False

HEX = r"[0-9a-fA-F]{6,}"
TS  = r"\d{10,14}"
DATE= r"\d{8}"
TAIL_PAT = re.compile(rf"(?:__|_|-)(?:{HEX}|{TS}|{DATE})$", re.IGNORECASE)
PAREN_HASH_TS = re.compile(rf"\((?:{HEX}|{TS}|{DATE})\)$", re.IGNORECASE)

def canon_title(s: str) -> str:
    s = (s or "").strip().replace("（","(").replace("）",")")
    s = PAREN_HASH_TS.sub("", s)
    while True:
        t = TAIL_PAT.sub("", s)
        if t == s: break
        s = t
    return re.sub(r"\s+", " ", s) or "未命名教材"

def canon_filename(name_or_title: str) -> str:
    base = canon_title(name_or_title)
    if not base.lower().endswith(".pdf"): base += ".pdf"
    safe = re.sub(r'[\\/:*?"<>|]', "_", base)
    safe = re.sub(r"\s+", " ", safe)
    return safe

def logic_key(subject: str, name_or_title: str) -> str:
    key = canon_title(name_or_title)
    key = re.sub(r"\s+", "", key)
    key = key.replace("（","(").replace("）",")")
    return f"{subject}::{key}"

def load_settings_from_env() -> Settings:
    pr_raw = os.getenv("SMARTEDU_POST_RETRY", "2").strip()
    try: pr = max(0, min(5, int(pr_raw)))
    except ValueError: pr = 2
    force = os.getenv("SMARTEDU_FORCE", "0") == "1"
    return Settings(
        PHASE=os.getenv("SMARTEDU_PHASE","高中"),
        SUBJECTS=[s.strip().replace(" ","") for s in os.getenv("SMARTEDU_SUBJ","语文,数学,英语,思想政治,历史,地理,物理,化学,生物").split(",") if s.strip()],
        HCON=int(os.getenv("SMARTEDU_HCON","12")),
        DCON=int(os.getenv("SMARTEDU_DCON","5")),
        POST_RETRY=pr,
        FORCE=force,
        CATALOG_ONLY=os.getenv("SMARTEDU_CATALOG_ONLY","0")=="1",
        WORKER_URL=os.getenv("SMARTEDU_WORKER_URL","").strip(),
    )

def build_referer(book_id: str) -> str:
    return (f"https://basic.smartedu.cn/tchMaterial/detail"
            f"?contentType=assets_document&contentId={book_id}"
            f"&catalogType=tchMaterial&subCatalog=tchMaterial")

# ---------------- 遠端資源抓取 ----------------
async def get_json(session: aiohttp.ClientSession, url: str) -> Optional[Dict | List]:
    for i in range(3):
        try:
            async with session.get(url, headers=BASE_HEADERS, timeout=30) as resp:
                txt = await resp.text()
                if resp.status == 200 and ("json" in (resp.headers.get("Content-Type","") or "").lower() or txt[:1] in "[{"):
                    return json.loads(txt)
        except (aiohttp.ClientError, asyncio.TimeoutError):
            await asyncio.sleep(1.2 * (i+1))
    return None

async def get_data_urls(session: aiohttp.ClientSession) -> List[str]:
    for base in S_FILE_HOSTS:
        js = await get_json(session, base + ENTRY_PATH)
        if isinstance(js, dict):
            field = js.get("urls") or js.get("url")
            urls: List[str] = []
            if isinstance(field, str):
                urls = [u.strip() for u in field.split(",") if u.strip()]
            elif isinstance(field, list):
                urls = [str(u).strip() for u in field if str(u).strip()]
            if urls: return urls
    return []

def book_tags(book: Dict[str,Any]) -> List[str]:
    return [t.get("tag_name","") for t in (book.get("tag_list") or [])]

def match_phase_subject_keyword(book: Dict[str, Any], st: Settings) -> bool:
    tags = book_tags(book)
    wants = PHASE_TAGS.get(st.PHASE, [])
    if wants and not any(any(w in t for w in wants) for t in tags): return False
    if st.SUBJECTS and not any(any(s in t for s in st.SUBJECTS) for t in tags): return False
    return True

def derive_filename(item: dict, book_id: str) -> Optional[str]:
    stor = item.get("ti_storage") or (item.get("ti_storages") or [None])[0]
    if isinstance(stor, str) and ".pkg/" in stor:
        tail = stor.replace("cs_path:${ref-path}", "").lstrip("/")
        fname = tail.split(".pkg/", 1)[-1]
        base = fname.split("/")[-1] if fname else None
        if base: return base
    fname = item.get("ti_filename")
    if isinstance(fname, str) and fname.lower().endswith(".pdf"):
        return fname.split("/")[-1]
    title = item.get("ti_title") or item.get("title")
    if isinstance(title, str) and title.strip():
        t = title.strip()
        if not t.lower().endswith(".pdf"): t += ".pdf"
        return t
    return None

def candidates_from_detail(book_id: str, items: List[dict]) -> List[str]:
    urls=[]
    for it in items:
        if (it.get("ti_format") or it.get("format") or "").lower() != "pdf": continue
        fname = derive_filename(it, book_id)
        if not fname: continue
        raw = f"esp/assets/{book_id}.pkg/{fname}"
        enc = f"esp/assets/{book_id}.pkg/{quote(fname)}"
        for host in R_HOSTS:
            urls.append(f"{host}/edu_product/{raw}")
            urls.append(f"{host}/edu_product/{enc}")
    for host in R_HOSTS:
        urls.append(f"{host}/edu_product/esp/assets/{book_id}.pkg/pdf.pdf")
    dedup=[]
    seen=set()
    for u in urls:
        if u not in seen: seen.add(u); dedup.append(u)
    return dedup

async def resolve_candidates(session: aiohttp.ClientSession, book_id: str) -> List[str]:
    for base in S_FILE_HOSTS:
        js = await get_json(session, f"{base}/zxx/ndrv2/resources/tch_material/details/{book_id}.json")
        if isinstance(js, dict):
            items = js.get("ti_items") or []
            if items: return candidates_from_detail(book_id, items)
    return [f"{h}/edu_product/esp/assets/{book_id}.pkg/pdf.pdf" for h in R_HOSTS]

async def probe_url(session: aiohttp.ClientSession, url: str, referer: str) -> Tuple[bool, Optional[int]]:
    headers = {**BASE_HEADERS, "Referer": referer}
    try:
        async with session.head(url, headers=headers, timeout=20, allow_redirects=True) as r:
            if r.status == 200:
                cl = r.headers.get("Content-Length")
                ct = (r.headers.get("Content-Type","") or "").lower()
                if ("pdf" in ct or url.lower().endswith(".pdf")) and (cl is None or int(cl) > 50*1024):
                    return True, int(cl) if cl else None
    except Exception:
        pass
    # fallback range GET
    try:
        headers["Range"] = "bytes=0-1"
        async with session.get(url, headers=headers, timeout=20, allow_redirects=True) as r:
            if r.status in (200,206):
                cl = r.headers.get("Content-Length")
                ct = (r.headers.get("Content-Type","") or "").lower()
                return ("pdf" in ct or url.lower().endswith(".pdf")), int(cl) if cl else None
    except Exception:
        return False, None
    return False, None

# ---------------- 下載與去重 ----------------
def existing_index(out_dir: Path) -> List[Dict[str,Any]]:
    idx = out_dir / "index.json"
    if idx.exists():
        try: return json.loads(idx.read_text("utf-8"))
        except Exception: return []
    return []

def build_existing_map(out_dir: Path) -> Dict[str, Dict[str,Any]]:
    m={}
    for it in existing_index(out_dir):
        subj = it.get("subject") or "綜合"
        key  = logic_key(subj, it.get("title") or Path(it.get("path","")).stem)
        m[key] = it
    # 同時從磁碟掃描補全（避免手工移動導致索引漏）
    for p in out_dir.rglob("*.pdf"):
        rel = p.relative_to(out_dir).as_posix()
        subj_guess = next((s for s in ORDER_SUBJ if f"/{s}/" in ("/"+rel+"/")), "綜合")
        key = logic_key(subj_guess, p.stem)
        if key not in m:
            m[key] = {"title": canon_title(p.stem), "subject": subj_guess, "phase": "", "path": str(p), "size": p.stat().st_size}
    return m


async def download_pdf(session: aiohttp.ClientSession, url: str, dest: Path, referer: str, force: bool = False) -> bool:
    """Download PDF with exponential backoff retry and optional force overwrite."""
    # Skip if already exists and not forcing
    if not force and have_pdf_head(dest):
        LOGGER.info("已存在有效 PDF，跳過: %s", dest.name)
        return True
    
    # Force mode: remove existing file to ensure fresh download
    if force and dest.exists():
        try:
            dest.unlink()
            LOGGER.info("強制模式：刪除舊版本 %s", dest.name)
        except Exception as e:
            LOGGER.warning("刪除舊文件失敗: %s (%s)", dest.name, e)
    
    tmp = dest.with_suffix(".part")
    start = tmp.stat().st_size if tmp.exists() else 0
    headers = {**BASE_HEADERS, "Referer": referer}
    if start > 0 and not force:
        headers["Range"] = f"bytes={start}-"
    elif force and tmp.exists():
        # Force mode: start fresh
        tmp.unlink()
        start = 0
    
    max_retries = 4
    for attempt in range(max_retries):
        # Exponential backoff: 1s, 2s, 4s, 8s
        backoff = 2 ** attempt
        try:
            async with session.get(url, headers=headers, timeout=180) as r:
                if r.status not in (200, 206):
                    LOGGER.debug("下載 HTTP %s: %s", r.status, url)
                    await asyncio.sleep(backoff)
                    continue
                
                dest.parent.mkdir(parents=True, exist_ok=True)
                mode = "ab" if (start > 0 and r.status == 206) else "wb"
                total_size = int(r.headers.get("Content-Length", 0)) + start
                downloaded = start
                
                async with aiofiles.open(tmp, mode) as f:
                    async for chunk in r.content.iter_chunked(1 << 14):
                        await f.write(chunk)
                        downloaded += len(chunk)
                
                # Validate minimum file size (at least 100KB for a real PDF)
                if tmp.stat().st_size < 100 * 1024:
                    LOGGER.warning("下載文件過小，可能損壞: %s (%d bytes)", dest.name, tmp.stat().st_size)
                    await asyncio.sleep(backoff)
                    continue
                
                tmp.replace(dest)
                if have_pdf_head(dest):
                    LOGGER.info("✅ 下載完成: %s (%.1f MB)", dest.name, dest.stat().st_size / 1024 / 1024)
                    return True
                else:
                    LOGGER.warning("下載完成但非有效 PDF: %s", dest.name)
                    return False
                    
        except (aiohttp.ClientError, asyncio.TimeoutError) as e:
            LOGGER.debug("下載異常 (%d/%d) %s - 等待 %ds", attempt + 1, max_retries, e, backoff)
            await asyncio.sleep(backoff)
        except Exception as e:
            LOGGER.warning("下載未預期錯誤: %s (%s)", url, e)
            await asyncio.sleep(backoff)
    
    LOGGER.warning("下載失敗（已重試 %d 次）: %s", max_retries, url)
    return False

# ---------------- HTML 生成已移除（僅保留下載功能） ----------------
# 如需網站功能，請使用獨立的 web 生成工具

# ---------------- 主流程 ----------------
async def resolve_all_books(session: aiohttp.ClientSession, st: Settings) -> List[Dict[str,Any]]:
    LOGGER.info("🔎 讀取遠程索引...")
    urls = await get_data_urls(session)
    if not urls:
        LOGGER.error("無法獲取 data_version.json 的 urls。"); return []
    books: List[Dict[str,Any]] = []
    for url in urls:
        js = await get_json(session, url)
        if isinstance(js, list): books.extend(js)
    books = [b for b in books if match_phase_subject_keyword(b, st)]
    LOGGER.info("目標條目: %d", len(books))
    return books

async def resolve_one_book(session: aiohttp.ClientSession, book: Dict[str,Any], st: Settings, sem: asyncio.Semaphore) -> Optional[Tuple[str,str,str,str,Optional[int]]]:
    """Resolve a single book's download URL with semaphore limiting."""
    async with sem:
        bid = book.get("id") or book.get("content_id")
        if not bid:
            return None
        title = canon_title(book.get("title") or (book.get("global_title") or {}).get("zh-CN") or bid)
        subj = next((s for s in st.SUBJECTS if any(s in t for t in book_tags(book))), "綜合")
        ref = build_referer(bid)
        urls = await resolve_candidates(session, bid)
        for u in urls:
            ok, rlen = await probe_url(session, u, ref)
            if ok:
                return (bid, title, subj, u, rlen)
        return None

async def main():
    st = load_settings_from_env()
    out_dir = Path("./smartedu_textbooks")
    setup_logging(out_dir)
    LOGGER.info("📁 下載目錄: %s", out_dir)
    LOGGER.info("階段=%s | 學科=%s | 強制覆蓋=%s | 自動重試輪=%d | 僅目錄模式=%s",
                st.PHASE, ",".join(st.SUBJECTS), st.FORCE, st.POST_RETRY, st.CATALOG_ONLY)

    timeout = aiohttp.ClientTimeout(total=None, sock_connect=20, sock_read=180)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        books = await resolve_all_books(session, st)
        
        if not books:
            LOGGER.warning("沒有匹配的條目。")

        # 構建現有文件映射
        exist_map = build_existing_map(out_dir)

        # ========= 真正並發解析直鏈 =========
        sem = asyncio.Semaphore(st.HCON)
        queue: List[Tuple[str,str,str,str,Optional[int]]] = []
        
        if books:
            LOGGER.info("🔗 並發解析 %d 本教材的下載鏈接（並發數: %d）...", len(books), st.HCON)
            
            tasks = [resolve_one_book(session, b, st, sem) for b in books]
            pbar = tqdm(total=len(tasks), desc="解析直鏈", unit="本")
            
            for coro in asyncio.as_completed(tasks):
                result = await coro
                pbar.update(1)
                if result:
                    queue.append(result)
            
            pbar.close()
            LOGGER.info("✅ 成功解析 %d / %d 本", len(queue), len(books))

        failures: List[Dict[str,Any]] = []
        if st.CATALOG_ONLY:
            LOGGER.info("📚 僅目錄模式：跳過下載，生成直接鏈接...")
            for bid, title, subj, url, rlen in queue:
                key = logic_key(subj, title)
                # 記錄為遠程項目
                exist_map[key] = {
                    "title": title, "subject": subj, "phase": st.PHASE,
                    "url": url, "size": rlen or 0, "is_remote": True,
                    "referer": build_referer(bid),
                    "path": f"REMOTE/{bid}/{canon_filename(title)}" # 虛擬路徑
                }
        else:
            # 下載（支持斷點與跳過），按 DCON 控制並發
            async def worker(items):
                for bid, title, subj, url, rlen in items:
                    # 目錄：out/學段/學科/
                    dest_dir = out_dir / st.PHASE / subj
                    dest_dir.mkdir(parents=True, exist_ok=True)
                    dest = dest_dir / canon_filename(title)
                    key  = logic_key(subj, title)
    
                    # 強制模式跳過所有存在性檢查
                    if not st.FORCE:
                        # 若已有相同 key 的文件（任何學段），且檔案有效、大小 >= 遠端（若已知），跳過
                        exist = exist_map.get(key)
                        if exist:
                            p = Path(exist.get("path",""))
                            p = (out_dir/p) if not p.is_absolute() else p
                            if p.exists() and have_pdf_head(p):
                                if rlen is None or p.stat().st_size >= rlen:
                                    LOGGER.info("跳過（已存在更大/相等）: %s", title)
                                    continue
    
                        # 若目標路徑已有有效 PDF，亦跳過
                        if have_pdf_head(dest):
                            LOGGER.info("跳過（本地已完整）: %s", dest.name)
                            continue
    
                    ok = await download_pdf(session, url, dest, build_referer(bid), force=st.FORCE)
                    if ok:
                        exist_map[key] = {"title": title, "subject": subj, "phase": st.PHASE, "path": str(dest.relative_to(out_dir)), "size": dest.stat().st_size}
                    else:
                        failures.append({"id": bid, "title": title, "subject": subj, "phase": st.PHASE, "url": url})
    
                # 拆分給 DCON 個 worker
                if queue:
                    chunks = [queue[i::max(1,st.DCON)] for i in range(max(1,st.DCON))]
                    tasks = [asyncio.create_task(worker(ch)) for ch in chunks]
                    await asyncio.gather(*tasks)
    
                # 自動重試輪：只針對失敗清單，再跑 st.POST_RETRY 輪
                for round_i in range(st.POST_RETRY):
                    if not failures: break
                    LOGGER.info("♻️ 自動重試輪 %d / %d，剩餘 %d 本", round_i+1, st.POST_RETRY, len(failures))
                    retrying = failures; failures=[]
                    # 重新解析+下載
                    q2=[]
                    for f in retrying:
                        bid=f["id"]; title=f["title"]; subj=f["subject"]; ref=build_referer(bid)
                        urls = await resolve_candidates(session, bid)
                        chosen=None; rlen=None
                        for u in urls:
                            ok, rlen = await probe_url(session, u, ref)
                            if ok: chosen=u; break
                        if chosen: q2.append((bid,title,subj,chosen,rlen))
                    if q2:
                        chunks = [q2[i::max(1,st.DCON)] for i in range(max(1,st.DCON))]
                        tasks = [asyncio.create_task(worker(ch)) for ch in chunks]
                        await asyncio.gather(*tasks)

        # —— 生成 index.json 與頁面 —— 
        items = []
        
        # 遍歷 exist_map (包含本地與遠程)
        # Scan out_dir to be sure about local files? 
        # But exist_map is updated during download. 
        # Let's trust exist_map + pure scan to be safe? 
        # The safest way is to rebuild exist_map from disk for local files if not skipping checks.
        # But we just downloaded. 
        # Let's iterate exist_map.
        
        for k, v in exist_map.items():
            if v.get("is_remote"):
                items.append(v)
            else:
                p = Path(v.get("path",""))
                abs_p = (out_dir/p) if not p.is_absolute() else p
                if abs_p.exists() and have_pdf_head(abs_p):
                    v["size"] = abs_p.stat().st_size
                    v["title"]= canon_title(v.get("title") or abs_p.stem)
                    try:
                       rel = abs_p.relative_to(out_dir).as_posix()
                    except:
                       rel = str(abs_p)
                    v["path"] = rel
                    items.append(v)
        
        # 保存索引
        items.sort(key=lambda x: (x.get("subject",""), x.get("title","")))
        (out_dir / "index.json").write_text(json.dumps(items, ensure_ascii=False, indent=2), "utf-8")
        LOGGER.info("📝 索引已保存: %s/index.json (共 %d 條)", out_dir, len(items))

        # 網站生成已移除 - 僅保留下載和索引功能
        
        if failures:
            LOGGER.error("❌ 以下 %d 本下載失敗 (已重試 %d 輪):", len(failures), st.POST_RETRY)
            for f in failures:
                LOGGER.error("   [%s] %s | %s", f["subject"], f["title"], f["id"])
            (out_dir / "failed.json").write_text(json.dumps(failures, ensure_ascii=False, indent=2), "utf-8")
            LOGGER.warning("仍失敗 %d 本；詳見 failed.json，可用 -R 僅重試失敗。", len(failures))
        else:
            try: (out_dir/"failed.json").unlink()
            except FileNotFoundError: pass
            if not st.CATALOG_ONLY and queue:
                LOGGER.info("🎉 所有任務完成！")
            else:
                LOGGER.info("✅ 本輪全部成功或已存在（去重跳過）。")

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass