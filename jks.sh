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

  while getopts ":p:s:m:i:o:Rc:d:n:T:hy" opt; do
    case "$opt" in
      p) PHASE="$OPTARG" ;;
      s) SUBJECTS="$OPTARG" ;;
      m) MATCH="$OPTARG" ;;
      i) IDS="$OPTARG" ;;
      o) OUT_DIR="$OPTARG" ;;
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
  export SMARTEDU_OUT_DIR="${OUT_DIR:-./smartedu_textbooks}"
  export SMARTEDU_ONLY_FAILED="$ONLY_FAILED"
  export SMARTEDU_HCON="$HCON"
  export SMARTEDU_DCON="$DCON"
  export SMARTEDU_LIMIT="$LIMIT"
  export SMARTEDU_POST_RETRY="$POST_RETRY"
  export PYTHON_EXEC=1

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
SmartEdu 批量下載器 (polyglot v4.3)
- 整輪結束後自動重試 N 輪（預設 2，環境變量 SMARTEDU_POST_RETRY 或 -T 調整）。
"""
from __future__ import annotations

import os, re, json, asyncio, aiohttp, aiofiles, time, logging, traceback
from logging import handlers
from pathlib import Path
from urllib.parse import quote
from typing import List, Dict, Any, Tuple, Optional
from collections import namedtuple
from tqdm import tqdm

# ---------------- HTML 索引生成 ----------------

async def write_html(out_dir: Path, items: List[Dict[str, Any]], failed: List[Dict[str, Any]]):
    # 構建主題集合與條目 HTML
    def esc(s: str) -> str:
        return (s or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    subjects = sorted({it.get("subject", "綜合") for it in items})
    li_ok = []
    for it in items:
        p = Path(it.get("path", ""))
        try:
            rel = os.path.relpath(p, out_dir)
        except Exception:
            rel = p.name
        href = quote(rel.replace(os.sep, "/"), safe="/")
        li_ok.append(f'<li data-subj="{esc(it.get("subject",""))}" data-title="{esc(it.get("title",""))}">'
                     f'<a href="{href}" target="_blank" download>{esc(it.get("title","未命名教材"))}</a>'
                     f'<span class="subj">{esc(it.get("subject",""))}</span>'
                     '</li>')

    li_fail = []
    for it in failed or []:
        p = Path(it.get("path", ""))
        try:
            rel = os.path.relpath(p, out_dir)
        except Exception:
            rel = p.name
        href = quote(rel.replace(os.sep, "/"), safe="/")
        li_fail.append(f'<li data-subj="{esc(it.get("subject",""))}" data-title="{esc(it.get("title",""))}">'
                       f'<a href="{href}" target="_blank">{esc(it.get("title","未命名教材"))}</a>'
                       f' <code>未完成/失敗</code>'
                       '</li>')

    html = f"""<!doctype html>
<html lang=zh-CN>
<head>
<meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>SmartEdu 本地教材索引</title>
<style>
  :root {{ --bg:#0b0d10; --fg:#e6edf3; --muted:#9aa4ad; --accent:#6ab7ff; --chip:#1f2937; }}
  * {{ box-sizing: border-box; }}
  body {{ margin:0; font:14px/1.6 -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'PingFang SC', 'Noto Sans CJK SC', 'Hiragino Sans GB', 'Microsoft YaHei', sans-serif; background:var(--bg); color:var(--fg); }}
  header {{ padding:16px 20px; border-bottom:1px solid #11161c; position:sticky; top:0; background:rgba(11,13,16,.9); backdrop-filter: blur(8px); }}
  h1 {{ margin:0 0 6px; font-size:18px; }}
  .muted {{ color:var(--muted); }}
  .row {{ display:flex; flex-wrap:wrap; gap:10px; align-items:center; }}
  select, input[type="search"] {{ background:#0f141a; color:var(--fg); border:1px solid #17212b; border-radius:8px; padding:8px 10px; outline:none; min-width:180px; }}
  main {{ padding:18px 20px; }}
  ul {{ list-style:none; padding:0; margin:0; display:grid; grid-template-columns: repeat(auto-fill, minmax(280px,1fr)); gap:10px; }}
  li {{ background:#0f141a; border:1px solid #161f29; border-radius:10px; padding:10px 12px; display:flex; justify-content:space-between; align-items:center; gap:10px; }}
  li a {{ color:var(--fg); text-decoration:none; }}
  li a:hover {{ color:var(--accent); text-decoration:underline; }}
  li .subj {{ color:var(--muted); font-size:12px; background:var(--chip); padding:2px 6px; border-radius:999px; }}
  section {{ margin-top:22px; }}
  code {{ background:#111820; color:#c9defc; padding:2px 6px; border-radius:6px; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }}
</style>
</head>
<body>
  <header>
    <h1>SmartEdu 本地教材索引</h1>
    <div class=row>
      <div class=muted>共 <b id=cntAll>{len(items)}</b> 本；失敗 <b id=cntFail>{len(failed or [])}</b> 本</div>
      <select id=selSubj>
        <option value="">全部學科</option>
        {''.join(f'<option value="{esc(s)}">{esc(s)}</option>' for s in subjects)}
      </select>
      <input id=kw type=search placeholder="關鍵詞過濾（書名）">
    </div>
  </header>
  <main>
    <section>
      <h3 class=muted>已完成</h3>
      <ul id=listOk>
        {''.join(li_ok)}
      </ul>
    </section>
    <section>
      <h3 class=muted>未完成/失敗</h3>
      <ul id=listFail>
        {''.join(li_fail) if li_fail else '<li class="muted">無</li>'}
      </ul>
    </section>
  </main>
<script>
(function(){
  const sel=document.getElementById('selSubj');
  const kw=document.getElementById('kw');
  const listOk=document.getElementById('listOk');
  const listFail=document.getElementById('listFail');
  function apply(){
    const s=sel.value.trim();
    const k=kw.value.trim().toLowerCase();
    for(const ul of [listOk, listFail]){
      for(const li of ul.querySelectorAll('li')){
        const subj=li.getAttribute('data-subj')||'';
        const title=(li.getAttribute('data-title')||'').toLowerCase();
        const okSubj=!s || subj.includes(s);
        const okKw=!k || title.includes(k);
        li.style.display=(okSubj && okKw)?'flex':'none';
      }
    }
  }
  sel.addEventListener('change', apply);
  kw.addEventListener('input', apply);
})();
</script>
</body>
</html>
"""
    async with aiofiles.open(out_dir / "index.html", "w", encoding="utf-8") as f:
        await f.write(html)

# ---------------- 設定 ----------------
Settings = namedtuple("Settings", [
    "PHASE", "SUBJECTS", "MATCH", "IDS", "OUT_DIR", "ONLY_FAILED",
    "HCON", "DCON", "LIMIT", "POST_RETRY"
])

def load_settings_from_env() -> Settings:
    out_env = os.getenv("SMARTEDU_OUT_DIR")
    out_dir = Path(os.path.expanduser(out_env)) if out_env else Path.cwd() / "smartedu_textbooks"
    pr_raw = os.getenv("SMARTEDU_POST_RETRY", "2").strip()
    try:
        pr = max(0, min(5, int(pr_raw)))  # 0..5 合理範圍
    except ValueError:
        pr = 2
    return Settings(
        PHASE=os.getenv("SMARTEDU_PHASE", "高中"),
        SUBJECTS=[s.strip() for s in os.getenv("SMARTEDU_SUBJ", "语文,数学,英语,思想政治,历史,地理,物理,化学,生物").split(",") if s.strip()],
        MATCH=os.getenv("SMARTEDU_MATCH", "").strip(),
        IDS=[s.strip() for s in os.getenv("SMARTEDU_IDS", "").split(",") if s.strip()],
        OUT_DIR=out_dir,
        ONLY_FAILED=os.getenv("SMARTEDU_ONLY_FAILED", "0") == "1",
        HCON=int(os.getenv("SMARTEDU_HCON", "12")),
        DCON=int(os.getenv("SMARTEDU_DCON", "5")),
        LIMIT=int(raw) if (raw := os.getenv("SMARTEDU_LIMIT", "").strip()).isdigit() else None,
        POST_RETRY=pr,
    )

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
PHASE_TAGS = {
    "小学": ["小学"],
    "初中": ["初中"],
    "高中": ["高中", "普通高中"],
    "特殊教育": ["特殊教育"],
    "小学54": ["小学（五•四学制）", "小学（五·四学制）"],
    "初中54": ["初中（五•四学制）", "初中（五·四学制）"],
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
    LOGGER.addHandler(ch)
    LOGGER.addHandler(fh)

# ---------------- 小工具 ----------------

def safe_name(s: str) -> str:
    s = re.sub(r'[\\/:*?"<>|]', "_", (s or "").strip())
    return re.sub(r"\s+", " ", s) or "未命名教材"


def book_tags(book: Dict[str, Any]) -> List[str]:
    return [t.get("tag_name", "") for t in (book.get("tag_list") or [])]


def match_phase_subject_keyword(book: Dict[str, Any], settings: Settings) -> bool:
    tags = book_tags(book)
    wants_phase = PHASE_TAGS.get(settings.PHASE, [])
    if wants_phase and not any(any(w in t for w in wants_phase) for t in tags):
        return False
    if settings.SUBJECTS and not any(any(s in t for s in settings.SUBJECTS) for t in tags):
        return False
    if settings.MATCH:
        title = (book.get("title") or (book.get("global_title") or {}).get("zh-CN") or "").lower()
        if not all(k.lower() in title for k in settings.MATCH.split()):
            return False
    return True


async def get_json(session: aiohttp.ClientSession, url: str) -> Optional[Dict | List]:
    for i in range(3):
        try:
            async with session.get(url, headers=BASE_HEADERS, timeout=30) as resp:
                txt = await resp.text()
                if resp.status == 200 and ("json" in (resp.headers.get("Content-Type", "") or "").lower() or txt[:1] in "[{"):
                    return json.loads(txt)
        except (aiohttp.ClientError, asyncio.TimeoutError) as e:
            LOGGER.debug("JSON 請求失敗 %s (%d/3): %s", url, i+1, e)
        await asyncio.sleep(1.2 * (i + 1))
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
            if urls:
                return urls
    return []


async def fetch_all_books(session: aiohttp.ClientSession, urls: List[str]) -> List[Dict[str, Any]]:
    books: List[Dict[str, Any]] = []
    for url in urls:
        js = await get_json(session, url)
        if isinstance(js, list):
            books.extend(js)
    return books


def build_referer(book_id: str) -> str:
    return ("https://basic.smartedu.cn/tchMaterial/detail"
            f"?contentType=assets_document&contentId={book_id}"
            "&catalogType=tchMaterial&subCatalog=tchMaterial")


def derive_filename(item: dict, book_id: str) -> Optional[str]:
    stor = item.get("ti_storage") or (item.get("ti_storages") or [None])[0]
    if isinstance(stor, str) and ".pkg/" in stor:
        tail = stor.replace("cs_path:${ref-path}", "").lstrip("/")
        fname = tail.split(".pkg/", 1)[-1]
        base = fname.split("/")[-1] if fname else None
        if base:
            return base
    fname = item.get("ti_filename")
    if isinstance(fname, str) and fname.lower().endswith(".pdf"):
        return fname.split("/")[-1]
    title = item.get("ti_title") or item.get("title")
    if isinstance(title, str) and title.strip():
        t = title.strip()
        if not t.lower().endswith(".pdf"):
            t += ".pdf"
        return t
    return None


def candidates_from_detail(book_id: str, items: List[dict]) -> List[str]:
    urls = []
    for it in items:
        if (it.get("ti_format") or it.get("format") or "").lower() != "pdf":
            continue
        fname = derive_filename(it, book_id)
        if not fname:
            continue
        raw = f"esp/assets/{book_id}.pkg/{fname}"
        enc = f"esp/assets/{book_id}.pkg/{quote(fname)}"
        for host in R_HOSTS:
            urls.append(f"{host}/edu_product/{raw}")
            urls.append(f"{host}/edu_product/{enc}")
    for host in R_HOSTS:
        urls.append(f"{host}/edu_product/esp/assets/{book_id}.pkg/pdf.pdf")
    # 去重
    seen, dedup = set(), []
    for u in urls:
        if u not in seen:
            seen.add(u); dedup.append(u)
    return dedup


async def resolve_candidates(session: aiohttp.ClientSession, book_id: str) -> List[str]:
    for base in S_FILE_HOSTS:
        js = await get_json(session, f"{base}/zxx/ndrv2/resources/tch_material/details/{book_id}.json")
        if isinstance(js, dict):
            items = js.get("ti_items") or []
            if items:
                return candidates_from_detail(book_id, items)
    return [f"{h}/edu_product/esp/assets/{book_id}.pkg/pdf.pdf" for h in R_HOSTS]


async def probe_url_exists(session: aiohttp.ClientSession, url: str, referer: str) -> bool:
    # 優先 HEAD；不支持則用 Range=0-1 的 GET（返回 206 視為存在）
    headers = {**BASE_HEADERS, "Referer": referer}
    try:
        async with session.head(url, headers=headers, timeout=20, allow_redirects=True) as r:
            if r.status == 200:
                ct = (r.headers.get("Content-Type", "") or "").lower()
                if "pdf" in ct or url.lower().endswith(".pdf"):
                    cl = r.headers.get("Content-Length")
                    if cl is None or int(cl) > 50 * 1024:
                        return True
    except Exception:
        pass
    # fallback
    try:
        headers["Range"] = "bytes=0-1"
        async with session.get(url, headers=headers, timeout=20, allow_redirects=True) as r:
            if r.status in (200, 206):
                ct = (r.headers.get("Content-Type", "") or "").lower()
                if "pdf" in ct or url.lower().endswith(".pdf"):
                    return True
    except Exception:
        return False
    return False


def is_valid_pdf(path: Path) -> bool:
    try:
        if not path.exists() or path.stat().st_size < 100 * 1024:
            return False
        with open(path, "rb") as f:
            head = f.read(5)
        return head == b"%PDF-"
    except Exception:
        return False


async def download_pdf(session: aiohttp.ClientSession, url: str, dest: Path, book_id: str) -> bool:
    # 若已有完整文件，跳過
    if is_valid_pdf(dest):
        LOGGER.info("文件已存在，跳過: %s", dest.name)
        return True
    tmp = dest.with_suffix(".part")
    start = tmp.stat().st_size if tmp.exists() else 0
    headers = {**BASE_HEADERS, "Referer": build_referer(book_id)}
    if start > 0:
        headers["Range"] = f"bytes={start}-"
    for attempt in range(3):
        try:
            async with session.get(url, headers=headers, timeout=180) as r:
                if r.status not in {200, 206}:
                    LOGGER.debug("下載 HTTP %s: %s", r.status, url)
                    await asyncio.sleep(2.0 * (attempt + 1))
                    continue
                dest.parent.mkdir(parents=True, exist_ok=True)
                mode = "ab" if (start > 0 and r.status == 206) else "wb"
                async with aiofiles.open(tmp, mode) as f:
                    async for chunk in r.content.iter_chunked(1<<14):
                        await f.write(chunk)
                tmp.replace(dest)
                return is_valid_pdf(dest)
        except (aiohttp.ClientError, asyncio.TimeoutError) as e:
            LOGGER.debug("下載異常 %s (try %d/3): %s", url, attempt+1, e)
            await asyncio.sleep(2.5 * (attempt + 1))
    LOGGER.warning("下載失敗: %s", url)
    return False


async def resolve_one(session: aiohttp.ClientSession, sem: asyncio.Semaphore, book: Dict[str, Any], subjects: List[str]) -> Optional[Tuple[str, str, str, str, Path]]:
    async with sem:
        bid = book.get("id") or book.get("content_id")
        if not bid:
            return None
        title = safe_name(book.get("title") or (book.get("global_title") or {}).get("zh-CN") or bid)
        tags = book_tags(book)
        subj = next((s for s in subjects if any(s in t for t in tags)), "綜合")
        cands = await resolve_candidates(session, bid)
        ref = build_referer(bid)
        for u in cands:
            if await probe_url_exists(session, u, ref):
                return (bid, title, subj, u, Path("/dev/null"))  # 佔位，實際路徑稍後生成
        return None


async def run_normal_mode(session: aiohttp.ClientSession, settings: Settings):
    # 構建書目
    if settings.IDS:
        books = [{"id": i, "title": i, "tag_list": [{"tag_name": settings.PHASE}]} for i in settings.IDS]
    else:
        LOGGER.info("🔎 讀取遠程數據索引...")
        data_urls = await get_data_urls(session)
        if not data_urls:
            LOGGER.error("無法獲取數據索引 URL 列表！"); return
        all_books = await fetch_all_books(session, data_urls)
        LOGGER.info("📚 總書目數: %d", len(all_books))
        books = [b for b in all_books if match_phase_subject_keyword(b, settings)]
    if settings.LIMIT is not None:
        books = books[:settings.LIMIT]
    LOGGER.info("🎯 篩選後，準備處理 %d 本書。", len(books))
    if not books:
        return

    # 解析
    sem_head = asyncio.Semaphore(settings.HCON)
    resolve_tasks = [asyncio.create_task(resolve_one(session, sem_head, b, settings.SUBJECTS)) for b in books]
    resolved_raw: List[Tuple[str, str, str, str, Path]] = []
    for fut in tqdm(asyncio.as_completed(resolve_tasks), total=len(resolve_tasks), desc="解析直鏈", ncols=100):
        r = await fut
        if r: resolved_raw.append(r)
    LOGGER.info("🔗 解析完成（直鏈有效）: %d 本", len(resolved_raw))

    # 讀取既有 index.json，按 book_id 重用已下載路徑，避免下一輪改名後重下
    existing_map: Dict[str, Path] = {}
    try:
        idx_path = settings.OUT_DIR / "index.json"
        if idx_path.exists():
            async with aiofiles.open(idx_path, "r", encoding="utf-8") as f:
                old_items = json.loads(await f.read())
            for it in old_items or []:
                bid0 = str(it.get("id", "")).strip()
                p0 = it.get("path")
                if bid0 and isinstance(p0, str) and p0.strip():
                    existing_map[bid0] = Path(p0)
    except Exception as e:
        LOGGER.debug("讀取 index.json 失敗: %s", e)

    # 填寫實際保存路徑，處理命名衝突；優先沿用既有路徑
    resolved: List[Tuple[str, str, str, str, Path]] = []
    used_paths = set(existing_map.values())
    collisions, reused = 0, 0
    for bid, title, subj, url, _ in resolved_raw:
        # 若已有記錄，優先沿用（即使文件暫不完整也會用同一路徑以便續傳）
        if bid in existing_map:
            dest = existing_map[bid]
            reused += 1
        else:
            subj_dir = settings.OUT_DIR / subj
            base = subj_dir / f"{title}.pdf"
            dest = base
            # 若與既有路徑/本輪路徑衝突（或磁碟已有同名），追加內容ID後綴
            if dest in used_paths or base.exists():
                collisions += 1
                cand = subj_dir / f"{title}__{bid[:8]}.pdf"
                idx = 2
                while cand in used_paths or cand.exists():
                    cand = subj_dir / f"{title}__{bid[:8]}_{idx}.pdf"
                    idx += 1
                dest = cand
        used_paths.add(dest)
        resolved.append((bid, title, subj, url, dest))

    LOGGER.info("🔗 解析完成: %d 本；計劃下載: %d 本（命名衝突自動處理 %d；沿用既有路徑 %d）",
                len(resolved_raw), len(resolved), collisions, reused)

    # 預掃：已存在且有效的直接計入成功清單，不建下載任務，避免再次全量進度條
    index_success, failed_list = [], []
    already_ok: List[Tuple[str, str, str, str, Path]] = []
    work_list: List[Tuple[str, str, str, str, Path]] = []
    for meta in resolved:
        bid, title, subj, url, dest = meta
        if is_valid_pdf(dest):
            already_ok.append(meta)
            index_success.append({
                "id": bid, "title": title, "subject": subj,
                "pdf_url": url, "path": str(dest)
            })
        else:
            work_list.append(meta)

    LOGGER.info("📦 已存在且有效: %d，本次需要下載: %d", len(already_ok), len(work_list))

    # 下載（首輪）：僅對需要下載的項目建立任務
    success, failed = len(already_ok), 0
    if work_list:
        down_tasks = [asyncio.create_task(download_pdf(session, url, dest, bid)) for (bid, title, subj, url, dest) in work_list]
        for fut, meta in zip(tqdm(asyncio.as_completed(down_tasks), total=len(down_tasks), desc="PDF 下載", ncols=100), work_list):
            ok = await fut
            bid, title, subj, url, dest = meta
            if ok:
                success += 1
                index_success.append({"id": bid, "title": title, "subject": subj, "pdf_url": url, "path": str(dest)})
            else:
                failed += 1
                failed_list.append({"id": bid, "title": title, "subject": subj, "url": url, "path": str(dest)})
    else:
        LOGGER.info("🎉 全部文件已完整，無需下載。")

    # 自動重試（僅針對失敗項）
    rounds = settings.POST_RETRY
    for round_idx in range(1, rounds + 1):
        if not failed_list:
            break
        LOGGER.info("🔁 自動重試 第 %d/%d 輪：待重試 %d 本", round_idx, rounds, len(failed_list))
        tasks = [asyncio.create_task(download_pdf(session, it["url"], Path(it["path"]), it["id"])) for it in failed_list]
        new_failed = []
        for fut, it in zip(tqdm(asyncio.as_completed(tasks), total=len(tasks), desc=f"重試輪 {round_idx}", ncols=100), list(failed_list)):
            if await fut:
                success += 1
                index_success.append({"id": it["id"], "title": it["title"], "subject": it["subject"], "pdf_url": it["url"], "path": it["path"]})
            else:
                new_failed.append(it)
        failed = len(new_failed)
        failed_list = new_failed
        if new_failed:
            await asyncio.sleep(1.0 * round_idx)  # 輕微退避

    # 輸出
    async with aiofiles.open(settings.OUT_DIR / "index.json", "w", encoding="utf-8") as f:
        await f.write(json.dumps(index_success, ensure_ascii=False, indent=2))
    async with aiofiles.open(settings.OUT_DIR / "failed.json", "w", encoding="utf-8") as f:
        await f.write(json.dumps(failed_list, ensure_ascii=False, indent=2))
    # 生成靜態網頁索引，使用本地相對路徑，避免 403 防盜鏈
    await write_html(settings.OUT_DIR, index_success, failed_list)
    LOGGER.info("🌐 網頁索引: %s", settings.OUT_DIR / "index.html")

    retried = settings.POST_RETRY if settings.POST_RETRY else 0
    LOGGER.info("✅ 總結：成功 %d，仍失敗 %d（自動重試輪數 %d）", success, len(failed_list), retried)
    LOGGER.info("📄 索引: %s", settings.OUT_DIR / "index.json")
    if failed_list:
        LOGGER.warning("⚠️ 仍有 %d 本下載失敗。可再次運行本腳本（將僅續傳未完成部分），或使用 -R 僅重試失敗清單。", len(failed_list))


async def run_retry_mode(session: aiohttp.ClientSession, settings: Settings):
    failed_path = settings.OUT_DIR / "failed.json"
    if not failed_path.exists():
        LOGGER.error("重試模式失敗：未找到 %s", failed_path); return
    async with aiofiles.open(failed_path, "r", encoding="utf-8") as f:
        items = json.loads(await f.read())
    if not items:
        LOGGER.info("🎉 失敗記錄為空，無需重試。"); return
    tasks = [asyncio.create_task(download_pdf(session, it["url"], Path(it["path"]), it["id"])) for it in items]
    new_failed = []
    ok = 0
    for fut, it in zip(tqdm(asyncio.as_completed(tasks), total=len(tasks), desc="重試下載", ncols=100), items):
        if await fut:
            ok += 1
        else:
            new_failed.append(it)
    async with aiofiles.open(failed_path, "w", encoding="utf-8") as f:
        await f.write(json.dumps(new_failed, ensure_ascii=False, indent=2))
    LOGGER.info("✅ 重試完成：成功 %d，仍失敗 %d", ok, len(new_failed))
    # 重新生成索引頁
    try:
        async with aiofiles.open(settings.OUT_DIR / "index.json", "r", encoding="utf-8") as f:
            items2 = json.loads(await f.read())
    except Exception:
        items2 = []
    await write_html(settings.OUT_DIR, items2, new_failed)
    LOGGER.info("🌐 網頁索引: %s", settings.OUT_DIR / "index.html")


async def main():
    settings = load_settings_from_env()
    setup_logging(settings.OUT_DIR)
    LOGGER.info("🎛️ 階段:%s 科目:%s 關鍵詞:%s IDS:%d 自動重試:%d", settings.PHASE, ",".join(settings.SUBJECTS) or "全部", settings.MATCH or "無", len(settings.IDS), settings.POST_RETRY)
    LOGGER.info("📁 下載目錄: %s", settings.OUT_DIR)
    t0 = time.time()
    async with aiohttp.ClientSession(headers=BASE_HEADERS) as session:
        if settings.ONLY_FAILED:
            await run_retry_mode(session, settings)
        else:
            await run_normal_mode(session, settings)
    LOGGER.info("⏱️ 總耗時: %.2f 秒", time.time() - t0)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n⛔ 已手動中斷")
    except Exception:
        LOGGER.critical("致命錯誤:\n%s", traceback.format_exc())
# <<<PYTHON<<<