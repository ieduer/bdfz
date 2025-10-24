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
  MATCH=""
  IDS=""
  OUT_DIR=""
  ONLY_FAILED="0"
  HCON=12
  DCON=5
  LIMIT=""
  POST_RETRY=2
  AUTO_RUN="0"

  usage() {
    cat >&2 <<'USAGE'
用法:
  bash smartedu_fetch_all.sh [選項]

選項:
  -p PHASE         教育階段：小学|初中|高中|特殊教育|小学54|初中54    (預設: 高中)
  -s SUBJECTS      學科逗號分隔 (預設: 语文,数学,英语,思想政治,历史,地理,物理,化学,生物)
  -m KEYWORD       書名關鍵詞（子串匹配，可多詞以空格分隔）
  -i IDS           指定 contentId 列表，逗號分隔（跳過索引過濾，直達）
  -o OUT_DIR       自定義輸出目錄（預設: ./smartedu_textbooks）
  -R               僅重試上次失敗（讀 OUT_DIR/failed.json）
  -c N             解析直鏈並發 (HEAD 檢查)，預設 12
  -d N             下載並發，預設 5
  -n N             只處理前 N 本（調試用）
  -T N             整輪結束後自動重試 N 輪（預設 2；0=關閉）
  -y               非互動直跑（跳過交互選擇，使用當前參數）
  -h               顯示此幫助

示例:
  bash smartedu_fetch_all.sh -p 高中
  bash smartedu_fetch_all.sh -p 高中 -s 语文,数学 -m "必修 第一册" -T 3
  bash smartedu_fetch_all.sh -p 小学54 -o ~/Downloads/textbooks
USAGE
  }

  while getopts ":p:s:m:i:o:w:Rc:d:n:T:hy" opt; do
    case "$opt" in
      p) PHASE="$OPTARG" ;;
      s) SUBJECTS="$OPTARG" ;;
      m) MATCH="$OPTARG" ;;
      i) IDS="$OPTARG" ;;
      o) OUT_DIR="$OPTARG" ;;
      w) WEB_DIR="$OPTARG" ;;
      R) ONLY_FAILED="1" ;;
      c) HCON="$OPTARG" ;;
      d) DCON="$OPTARG" ;;
      n) LIMIT="$OPTARG" ;;
      T) POST_RETRY="$OPTARG" ;;
      y) AUTO_RUN="1" ;;
      h) usage; exit 0 ;;
      :) echo "錯誤：選項 -$OPTARG 需要一個參數。" >&2; usage; exit 2 ;;
      \?) echo "錯誤：未知選項 -$OPTARG" >&2; usage; exit 2 ;;
    esac
  done

  # ---- 交互式配置（默認開啟；用 -y 跳過） ----
  if [ "$AUTO_RUN" != "1" ] && [ -t 0 ]; then
    printf "\n================ 下載配置嚮導 ================\n"
    printf "只需選擇 教育階段 和 學科；其餘保持默認並自動開始。\n"

    # 教育階段（數字選擇）
    printf "\n[1] 教育階段：\n"
    printf "   1) 小学    2) 初中    3) 高中    4) 特殊教育    5) 小学54    6) 初中54\n"
    read -r -p "輸入數字 1-6（默認: $PHASE）: " ans
    case "$ans" in
      1) PHASE="小学";;
      2) PHASE="初中";;
      3) PHASE="高中";;
      4) PHASE="特殊教育";;
      5) PHASE="小学54";;
      6) PHASE="初中54";;
      "") : ;;
      *) printf "[i] 非法選擇，保持: %s\n" "$PHASE";;
    esac

    # 學科（僅此一步；留空沿用當前預設）
    printf "\n[2] 學科（逗號分隔，留空=全部預設）\n"
    printf "    當前: %s\n" "$SUBJECTS"
    read -r -p "輸入學科: " ans
    [ -n "$ans" ] && SUBJECTS="$ans"

    # 直接開始——不再詢問：僅重試/限制/重試輪數/輸出目錄/確認
  fi

  # 交互輸入後再做一次數值校驗
  int_re='^[0-9]+$'
  if ! [[ "$HCON" =~ $int_re ]]; then echo "[!] -c 必須為整數" >&2; exit 2; fi
  if ! [[ "$DCON" =~ $int_re ]]; then echo "[!] -d 必須為整數" >&2; exit 2; fi
  if [[ -n "$LIMIT" ]] && ! [[ "$LIMIT" =~ $int_re ]]; then echo "[!] -n 必須為整數" >&2; exit 2; fi
  if ! [[ "$POST_RETRY" =~ $int_re ]]; then echo "[!] -T 必須為整數" >&2; exit 2; fi

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
  export SMARTEDU_MATCH="$MATCH"
  export SMARTEDU_IDS="$IDS"
  # --- 確定輸出目錄（預設優先 /srv/smartedu_textbooks；否則用相對目錄） ---
  if [ -z "$OUT_DIR" ]; then
    if [ -d /srv/smartedu_textbooks ] || [ -w /srv ]; then
      OUT_DIR="/srv/smartedu_textbooks"
      mkdir -p "$OUT_DIR"
    else
      OUT_DIR="./smartedu_textbooks"
    fi
  fi
  export SMARTEDU_OUT_DIR="$OUT_DIR"
  echo "[i] 下載輸出目錄: $SMARTEDU_OUT_DIR"

  # --- 確定網頁根目錄（WEB_DIR）：未指定則默認 /srv/smartedu_textbooks，否則沿用 OUT_DIR ---
  if [ -z "${WEB_DIR:-}" ]; then
    if [ -d /srv/smartedu_textbooks ] || [ -w /srv ]; then
      WEB_DIR="/srv/smartedu_textbooks"
      mkdir -p "$WEB_DIR"
    else
      WEB_DIR="$OUT_DIR"
    fi
  fi
  export SMARTEDU_WEB_DIR="$WEB_DIR"
  echo "[i] 網頁根目錄: $SMARTEDU_WEB_DIR"
  export SMARTEDU_ONLY_FAILED="$ONLY_FAILED"
  export SMARTEDU_HCON="$HCON"
  export SMARTEDU_DCON="$DCON"
  export SMARTEDU_LIMIT="$LIMIT"
  export SMARTEDU_POST_RETRY="$POST_RETRY"
  export SMARTEDU_WEB_DIR="$WEB_DIR"
  export PYTHON_EXEC=1

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
    "PHASE","SUBJECTS","MATCH","IDS","OUT_DIR","WEB_DIR","ONLY_FAILED",
    "HCON","DCON","LIMIT","POST_RETRY"
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
    out_env = os.getenv("SMARTEDU_OUT_DIR")
    out_dir = Path(os.path.expanduser(out_env)) if out_env else Path.cwd() / "smartedu_textbooks"
    pr_raw = os.getenv("SMARTEDU_POST_RETRY", "2").strip()
    try: pr = max(0, min(5, int(pr_raw)))
    except ValueError: pr = 2
    web_env = os.getenv("SMARTEDU_WEB_DIR","").strip()
    web_dir = Path(os.path.expanduser(web_env)) if web_env else out_dir
    return Settings(
        PHASE=os.getenv("SMARTEDU_PHASE","高中"),
        SUBJECTS=[s.strip().replace(" ","") for s in os.getenv("SMARTEDU_SUBJ","语文,数学,英语,思想政治,历史,地理,物理,化学,生物").split(",") if s.strip()],
        MATCH=os.getenv("SMARTEDU_MATCH","").strip(),
        IDS=[s.strip() for s in os.getenv("SMARTEDU_IDS","").split(",") if s.strip()],
        OUT_DIR=out_dir,
        WEB_DIR=web_dir,
        ONLY_FAILED=os.getenv("SMARTEDU_ONLY_FAILED","0")=="1",
        HCON=int(os.getenv("SMARTEDU_HCON","12")),
        DCON=int(os.getenv("SMARTEDU_DCON","5")),
        LIMIT=int(v) if (v:=os.getenv("SMARTEDU_LIMIT","").strip()).isdigit() else None,
        POST_RETRY=pr,
    )

def build_referer(book_id: str) -> str:
    return ("https://basic.smartedu.cn/tchMaterial/detail"
            f"?contentType=assets_document&amp;contentId={book_id}"
            "&amp;catalogType=tchMaterial&amp;subCatalog=tchMaterial")

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
    if st.MATCH:
        title = (book.get("title") or (book.get("global_title") or {}).get("zh-CN") or "").lower()
        if not all(k.lower() in title for k in st.MATCH.split()): return False
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

# --- 合併現有文件映射：primary 覆蓋 secondary，保留更大者 ---
def merge_maps(primary: Dict[str,Any], secondary: Dict[str,Any]) -> Dict[str,Any]:
    """按 key 合併，保留 size 更大者；相等時保留路徑更短者。"""
    out = dict(secondary)
    for k,v in primary.items():
        ov = out.get(k)
        if not ov:
            out[k]=v; continue
        try:
            sz1 = int(v.get("size") or 0)
            sz2 = int(ov.get("size") or 0)
        except Exception:
            sz1 = int(v.get("size") or 0); sz2 = int(ov.get("size") or 0)
        if (sz1 > sz2) or (sz1==sz2 and len(str(v.get("path",""))) < len(str(ov.get("path","")))):
            out[k]=v
    return out

def mirror_to_web_dir(out_dir: Path, web_dir: Path, combined: Dict[str,Any]) -> None:
    """把 OUT_DIR 的文件鏡像到 WEB_DIR：若目標不存在或更小則覆蓋，保留目錄結構。"""
    for it in combined.values():
        p = Path(it.get("path",""))
        src = (out_dir / p) if not p.is_absolute() else p
        if not src.exists(): 
            continue
        try:
            rel = src.relative_to(out_dir)
        except Exception:
            continue
        dst = web_dir / rel
        try:
            dst.parent.mkdir(parents=True, exist_ok=True)
            if (not dst.exists()) or (dst.stat().st_size < src.stat().st_size):
                shutil.copy2(src, dst)
        except Exception as e:
            LOGGER.warning("鏡像到網頁目錄失敗: %s -> %s (%s)", src, dst, e)

async def download_pdf(session: aiohttp.ClientSession, url: str, dest: Path, referer: str) -> bool:
    if have_pdf_head(dest):
        LOGGER.info("已存在有效 PDF，跳過: %s", dest.name); return True
    tmp = dest.with_suffix(".part")
    start = tmp.stat().st_size if tmp.exists() else 0
    headers = {**BASE_HEADERS, "Referer": referer}
    if start>0: headers["Range"]=f"bytes={start}-"
    for attempt in range(3):
        try:
            async with session.get(url, headers=headers, timeout=180) as r:
                if r.status not in (200,206):
                    LOGGER.debug("下載 HTTP %s: %s", r.status, url); await asyncio.sleep(2*(attempt+1)); continue
                dest.parent.mkdir(parents=True, exist_ok=True)
                mode = "ab" if (start>0 and r.status==206) else "wb"
                async with aiofiles.open(tmp, mode) as f:
                    async for chunk in r.content.iter_chunked(1<<14):
                        await f.write(chunk)
                tmp.replace(dest)
                return have_pdf_head(dest)
        except (aiohttp.ClientError, asyncio.TimeoutError) as e:
            LOGGER.debug("下載異常 (%d/3) %s", attempt+1, e); await asyncio.sleep(2.5*(attempt+1))
    LOGGER.warning("下載失敗: %s", url)
    return False

# ---------------- HTML 生成（最終版樣式，無 Template 佔位風險） ----------------
def render_html(out_dir: Path, items: List[Dict[str,Any]]):
    # —— 合併 & 真正去重（同學科 + 規範書名，保留更大者） ——
    collected={}
    for it in items:
        subj = it.get("subject") or "綜合"
        title= canon_title(it.get("title") or Path(it.get("path","")).stem)
        path = Path(it.get("path",""))
        if not (out_dir/path).exists(): 
            # 兼容存儲為絕對路徑
            if path.exists(): pass
            else: continue
        size = (out_dir/path).stat().st_size if (out_dir/path).exists() else path.stat().st_size
        key  = logic_key(subj, title)
        old  = collected.get(key)
        if (not old) or (size > old["_size"]) or (size==old["_size"] and len(str(path))<len(old["_rel"])):
            collected[key]={"_rel":str(path), "_size":size, "_disp":title, "subject":subj, "_fname":Path(path).name}

    # —— 分組與排序 ——
    by={}
    for v in collected.values():
        by.setdefault(v["subject"], []).append(v)
    subjects = sorted(by.keys(), key=lambda s:(SUBJ_RANK.get(s,999), s))
    for s in subjects:
        by[s].sort(key=lambda v: v["_disp"])

    # —— chips —— 
    def anchor(s:str): return f"subj-{s.replace(' ','-')}"
    chips = ['<a class="chip chip--all" data-all="1" href="#">全部</a>']
    for s in ORDER_SUBJ:
        if s in by:
            chips.append(f'<a class="chip chip--{CLS.get(s,"generic")}" href="#{esc(anchor(s))}" data-subj="{esc(s)}">{esc(s)}</a>')
    chips_html="".join(chips)

    # —— 科目 CSS —— 
    subject_css=[]
    for subj,cls in CLS.items():
        th = THEME[cls]
        subject_css.append(
f""".chip--{cls}{{background:{th['chip']};border-color:#1e2833;color:#fff;}}
.section--{cls} .name{{color:{th['name']};}}
.section--{cls} > h2{{color:{th['title']};}}
""")
    subject_css="".join(subject_css)

    # —— sections —— 
    sections=[]
    for s in subjects:
        cls = CLS.get(s,"generic")
        th  = THEME.get(cls, THEME["yingyu"])
        cards=[]
        for v in by[s]:
            rel = v["_rel"].replace(os.sep,"/")
            href = quote(rel, safe="/")
            size_mb = f"{(v['_size']/1024/1024):.1f}MB"
            cards.append(
                f'<li class="card" data-title="{esc(v["_disp"])}">'
                f'  <a class="card-link" href="{href}" target="_blank" download title="{esc(v["_fname"])}">'
                f'    <div class="thumb" aria-hidden="true" style="background:{th["grad"]};border-color:{th["border"]}"><span>📄</span></div>'
                f'    <div class="meta">'
                f'      <div class="name">{esc(v["_disp"])}</div>'
                f'      <div class="filesize">{esc(size_mb)}</div>'
                f'      <div class="subj subj--{cls}">{esc(s)}</div>'
                f'    </div>'
                f'  </a>'
                f'</li>'
            )
        sections.append(
            f'<section id="{esc(anchor(s))}" class="section section--{cls}" style="background:{THEME[cls]["tint"]}33">'
            f'  <h2>{esc(s)}</h2>'
            f'  <ul class="grid">{"".join(cards)}</ul>'
            f'</section>'
        )

    HTML_TMPL = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>BDFZ- Suen 教材庫</title>
<link rel="icon" href="https://img.bdfz.net/20250503004.webp" type="image/jpeg">
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="icon" type="image/png" sizes="32x32" href="/favicon-32x32.png">
<link rel="icon" type="image/png" sizes="16x16" href="/favicon-16x16.png">
<link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">
<style>
  :root { --bg:#0b0d10; --fg:#e6edf3; --muted:#9aa4ad; --line:#161f29; --card:#0f141a; --accent:#6ab7ff; }
  * { box-sizing:border-box; }
  body { margin:0; font:14px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'PingFang SC','Noto Sans CJK SC','Hiragino Sans GB','Microsoft YaHei',sans-serif; background:var(--bg); color:var(--fg); }
  header { position:sticky; top:0; z-index:10; padding:10px 12px 10px; border-bottom:1px solid #11161c; background:rgba(11,13,16,.92); backdrop-filter: blur(8px); }
  .container { max-width: 1280px; margin: 0 auto; }
  .center { display:flex; justify-content:center; align-items:center; flex-wrap:wrap; gap:8px; }
  .chips { padding:4px 0 6px; }
  .chip { display:inline-block; padding:6px 12px; border-radius:999px; white-space:nowrap; color:#fff; text-decoration:none; border:1px solid #1e2833; }
  .chip--all { background:#374151; }
  .toolbar { margin-top:6px; gap:8px; }
  .btn, .link { color:#cbd5e1; text-decoration:none; background:#0f141a; border:1px solid #17212b; border-radius:8px; padding:6px 10px; }
  .btn:hover, .link:hover { border-color:#2a3644; color:var(--accent); cursor:pointer;}
  input[type="search"] { background:#0f141a; color:#e6edf3; border:1px solid #17212b; border-radius:8px; padding:6px 10px; min-width:200px; outline:none; }
  main { padding:18px 12px; }
  .page { max-width:1280px; margin:0 auto; }
  section { margin:18px 0 28px; border-radius:14px; padding:8px 10px 12px; }
  section>h2 { font-size:16px; margin:6px 0 12px; text-align:center; scroll-margin-top: 120px; color:#dbe7f3; }
  .grid { list-style:none; padding:0; margin:0 auto; display:grid; grid-template-columns:repeat(auto-fill,minmax(280px,1fr)); gap:12px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:12px; }
  .card-link { display:flex; align-items:center; gap:12px; padding:12px; color:inherit; text-decoration:none; }
  .thumb { width:40px; height:52px; border-radius:8px; border:1px solid #24425e; display:flex; align-items:center; justify-content:center; flex:0 0 auto; }
  .thumb span { font-size:16px; }
  .meta { min-width:0; display:flex; flex-direction:column; gap:6px; }
  .name { font-size:14px; white-space:normal; word-break:break-all; overflow:visible; }
  .filesize { font-size:12px; color:#9aa4ad; }
  .subj { color:#9aa4ad; font-size:12px; }
  /* SUBJECT_CSS */
  @media (max-width: 720px) {
    .container { padding:0 6px; }
    .page { padding:0 4px; }
    input[type="search"] { min-width: 56vw; }
    .grid { grid-template-columns:repeat(auto-fill,minmax(220px,1fr)); gap:10px; }
    .thumb { width:36px; height:48px; }
    section>h2 { scroll-margin-top: 150px; }
  }
  .toast { position:fixed; right:16px; bottom:16px; background:#0f141a; border:1px solid #1f2a37; color:#e6edf3; padding:10px 12px; border-radius:10px; box-shadow:0 10px 30px rgba(0,0,0,.4); display:none; max-width:70vw; }
</style>
</head>
<body>
  <header>
    <div class="container">
      <div class="center chips">/*CHIPS*/</div>
      <div class="center toolbar">
        <input id="kw" type="search" placeholder="關鍵詞篩選（書名）">
        <a class="link" href="https://bdfz.net/posts/jks/" target="_blank" rel="noopener">About</a>
      </div>
    </div>
  </header>
  <main>
    <div class="page">
      /*SECTIONS*/
    </div>
  </main>
  <div id="toast" class="toast"></div>
<script>
(function(){
  const kw=document.getElementById('kw');
  function apply(){
    const k=kw.value.trim().toLowerCase();
    for(const li of document.querySelectorAll('.card')){
      const title=(li.getAttribute('data-title')||'').toLowerCase();
      li.style.display=(!k||title.includes(k))?'block':'none';
    }
  }
  kw.addEventListener('input', apply);

  // 学科 chips：點擊後只顯示該學科，滾動到標題；“全部”恢復
  const chips=document.querySelectorAll('.chip');
  chips.forEach(ch=>{
    ch.addEventListener('click', (e)=>{
      const all = ch.dataset.all === '1';
      if(all){
        e.preventDefault();
        document.querySelectorAll('section').forEach(sec=>sec.style.display='block');
        window.scrollTo({top:0, behavior:'smooth'}); return;
      }
      const subj = ch.dataset.subj; if(!subj) return;
      e.preventDefault();
      const id = 'subj-' + subj.replace(/\\s+/g,'-');
      const sec = document.getElementById(id);
      if(sec){
        document.querySelectorAll('section').forEach(s=>s.style.display='none');
        sec.style.display='block';
        sec.querySelector('h2')?.scrollIntoView({behavior:'smooth', block:'start'});
      }
      chips.forEach(x=>x.style.outline='none');
      ch.style.outline='2px solid rgba(255,255,255,.25)'; ch.style.outlineOffset='2px';
    });
  });
})();
</script>
</body>
</html>
"""
    chips_html = chips_html
    sections_html = "".join(sections)
    html = (HTML_TMPL
            .replace("/*SUBJECT_CSS*/", subject_css)
            .replace("/*CHIPS*/", chips_html)
            .replace("/*SECTIONS*/", sections_html))
    (out_dir/"index.html").write_text(html, "utf-8")

# ---------------- 主流程 ----------------
async def resolve_all_books(session: aiohttp.ClientSession, st: Settings) -> List[Dict[str,Any]]:
    # 指定 IDS 直達
    if st.IDS:
        return [{"id": i, "title": i, "tag_list":[{"tag_name": st.PHASE}]} for i in st.IDS]

    LOGGER.info("🔎 讀取遠程索引...")
    urls = await get_data_urls(session)
    if not urls:
        LOGGER.error("無法獲取 data_version.json 的 urls。"); return []
    books: List[Dict[str,Any]] = []
    for url in urls:
        js = await get_json(session, url)
        if isinstance(js, list): books.extend(js)
    books = [b for b in books if match_phase_subject_keyword(b, st)]
    if st.LIMIT: books = books[:st.LIMIT]
    LOGGER.info("目標條目: %d", len(books))
    return books

async def main():
    st = load_settings_from_env()
    out_dir: Path = st.OUT_DIR
    web_dir: Path = st.WEB_DIR
    setup_logging(out_dir)
    LOGGER.info("📁 下載目錄: %s", out_dir)
    LOGGER.info("🌐 網頁目錄: %s", web_dir)
    LOGGER.info("階段=%s | 學科=%s | 匹配='%s' | 只重試失敗=%s | 自動重試輪=%d",
                st.PHASE, ",".join(st.SUBJECTS), st.MATCH, st.ONLY_FAILED, st.POST_RETRY)

    timeout = aiohttp.ClientTimeout(total=None, sock_connect=20, sock_read=180)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        books = await resolve_all_books(session, st)
        if not books:
            LOGGER.warning("沒有匹配的條目。仍將刷新網頁索引。")

        # 構建現有文件映射（合併 OUT_DIR 與 WEB_DIR，保留更大者）
        exist_map = merge_maps(build_existing_map(out_dir), build_existing_map(web_dir))

        # 準備下載隊列（解析直鏈）
        sem = asyncio.Semaphore(st.HCON)
        queue: List[Tuple[str,str,str,str,Optional[int]]] = []  # (bid,title,subj,url,remote_len)
        pbar = tqdm(total=len(books), desc="解析直鏈", unit="本")
        for book in books:
            async with sem:
                bid = book.get("id") or book.get("content_id")
                title = canon_title(book.get("title") or (book.get("global_title") or {}).get("zh-CN") or bid)
                subj  = next((s for s in st.SUBJECTS if any(s in t for t in book_tags(book))), "綜合")
                if not bid: pbar.update(1); continue
                ref = build_referer(bid)
                urls = await resolve_candidates(session, bid)
                remote_len = None
                chosen = None
                # 取第一個探測可用的直鏈，同時獲取 Content-Length
                for u in urls:
                    ok, rlen = await probe_url(session, u, ref)
                    if ok:
                        chosen=u; remote_len=rlen; break
                if not chosen:
                    pbar.update(1); continue
                queue.append((bid, title, subj, chosen, remote_len))
                pbar.update(1)
        pbar.close()

        # 下載（支持斷點與跳過），按 DCON 控制並發
        async def worker(items):
            for bid, title, subj, url, rlen in items:
                # 目錄：out/學段/學科/
                dest_dir = out_dir / st.PHASE / subj
                dest_dir.mkdir(parents=True, exist_ok=True)
                dest = dest_dir / canon_filename(title)
                key  = logic_key(subj, title)

                # 若已有相同 key 的文件（任何學段），且檔案有效、大小 >= 遠端（若已知），跳過
                exist = exist_map.get(key)
                if exist:
                    p = Path(exist.get("path",""))
                    p = (out_dir/p) if not p.is_absolute() else p
                    if p.exists() and have_pdf_head(p):
                        if rlen is None or p.stat().st_size >= rlen:
                            LOGGER.info("跳過（已存在更大/相等）: %s", title); 
                            continue

                # 若目標路徑已有有效 PDF，亦跳過
                if have_pdf_head(dest):
                    LOGGER.info("跳過（本地已完整）: %s", dest.name); 
                    continue

                ok = await download_pdf(session, url, dest, build_referer(bid))
                if ok:
                    exist_map[key] = {"title": title, "subject": subj, "phase": st.PHASE, "path": str(dest.relative_to(out_dir)), "size": dest.stat().st_size}
                else:
                    failures.append({"id": bid, "title": title, "subject": subj, "phase": st.PHASE, "url": url})

        # 拆分給 DCON 個 worker
        failures: List[Dict[str,Any]] = []
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

        # —— 把 OUT_DIR 的新增/更大檔鏡像到 WEB_DIR —— 
        mirror_to_web_dir(out_dir, web_dir, exist_map)

        # —— 以 WEB_DIR 為準重建 index.json 與頁面 —— 
        web_map = build_existing_map(web_dir)
        items = []
        for k,it in web_map.items():
            p = Path(it["path"])
            abs_p = (web_dir/p) if not p.is_absolute() else p
            if abs_p.exists() and have_pdf_head(abs_p):
                it["size"] = abs_p.stat().st_size
                it["title"]= canon_title(it.get("title") or p.stem)
                try:
                    rel = abs_p.relative_to(web_dir).as_posix()
                except Exception:
                    rel = str(abs_p)
                it["path"] = rel
                items.append(it)
        (web_dir/"index.json").write_text(json.dumps(items, ensure_ascii=False, indent=2), "utf-8")

        # 失敗清單
        if failures:
            (out_dir/"failed.json").write_text(json.dumps(failures, ensure_ascii=False, indent=2), "utf-8")
            LOGGER.warning("仍失敗 %d 本；詳見 failed.json，可用 -R 僅重試失敗。", len(failures))
        else:
            try: (out_dir/"failed.json").unlink()
            except FileNotFoundError: pass
            LOGGER.info("✅ 本輪全部成功或已存在（去重跳過）。")

        # 生成最終版網頁（寫入 WEB_DIR）
        render_html(web_dir, items)
        LOGGER.info("🧭 已更新 %s", (web_dir/"index.html"))

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass