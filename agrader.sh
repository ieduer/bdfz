#!/usr/bin/env bash
# AGrader - API-first auto-grading pipeline (installer/runner) - FULL INLINE EDITION
# Linux: apt/dnf/yum/apk + systemd; macOS: Homebrew + optional launchd
# v1.10.2-fullinline-2025-11-01

set -euo pipefail

APP_DIR="/opt/agrader"
VENV_DIR="$APP_DIR/venv"
ENV_FILE="$APP_DIR/.env"
SERVICE="agrader.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE}"
LAUNCHD_PLIST="${HOME}/Library/LaunchAgents/net.bdfz.agrader.plist"
PY_MAIN="$APP_DIR/main.py"

have() { command -v "$1" >/dev/null 2>&1; }

os_detect() {
  case "$(uname -s)" in
    Darwin) echo "mac";;
    Linux)  echo "linux";;
    *)      echo "other";;
  esac
}

ask() { local p="$1" var="$2" def="${3:-}"; local ans;
  if [ -n "${def}" ]; then read -r -p "$p [$def]: " ans || true; ans="${ans:-$def}";
  else read -r -p "$p: " ans || true; fi
  printf -v "$var" "%s" "$ans"
}
ask_secret() { local p="$1" var="$2"; local ans; read -r -s -p "$p: " ans || true; echo; printf -v "$var" "%s" "$ans"; }

# --- safe key=val updater (only touch the target key) ---
set_env_kv() {
  local key="$1"; shift
  local val="$*"
  [ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found"; return 1; }
  local esc="${val//\//\\/}"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i.bak -E "s#^${key}=.*#${key}=${esc}#" "$ENV_FILE"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
}

# --- always prompt for MONITOR_TASK_IDS (every run) ---
prompt_task_ids() {
  echo "[2.5/10] Configure Task IDs..."
  local cur=""
  if [ -f "$ENV_FILE" ]; then
    cur="$(grep -E '^MONITOR_TASK_IDS=' "$ENV_FILE" | cut -d= -f2- || true)"
  fi
  echo "Enter Task IDs (comma-separated), or paste URLs that contain /tasks/<id>."
  local ans norm
  while :; do
    read -r -p "Task IDs [${cur:-none}]: " ans || true
    ans="${ans:-$cur}"
    # 正規化：支援 URL / 純數字 / 逗號分隔
    norm="$(
      printf "%s\n" "$ans" \
      | tr ' ,;' '\n\n\n' \
      | sed -E 's#.*(/tasks/([0-9]+)).*#\2#; t; s#[^0-9]##g' \
      | awk 'length>0' \
      | paste -sd, - \
      | sed -E 's#,+#,#g; s#^,##; s#,$##'
    )"
    if [ -n "$norm" ]; then
      set_env_kv "MONITOR_TASK_IDS" "$norm"
      echo "→ MONITOR_TASK_IDS=${norm}"
      break
    fi
    echo "Empty. Please enter at least one ID."
  done
}

install_pkgs_linux() {
  echo "[1/10] Installing system dependencies (Linux)..."
  if have apt; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y \
      python3 python3-venv python3-pip curl unzip jq ca-certificates \
      tesseract-ocr tesseract-ocr-eng tesseract-ocr-chi-sim \
      poppler-utils ghostscript coreutils
  elif have dnf || have yum; then
    local YUM=$(have dnf && echo dnf || echo yum)
    $YUM install -y epel-release || true
    $YUM install -y python3 python3-pip python3-virtualenv curl unzip jq ca-certificates coreutils
    $YUM install -y tesseract poppler-utils ghostscript || true
    $YUM install -y tesseract-langpack-eng tesseract-langpack-chi_sim || true
    $YUM install -y tesseract-eng tesseract-chi_sim || true
  elif have apk; then
    apk add --no-cache \
      python3 py3-pip py3-venv curl unzip jq ca-certificates coreutils \
      tesseract-ocr poppler-utils ghostscript libxml2 libxslt \
      tesseract-ocr-data-eng tesseract-ocr-data-chi_sim || true
  else
    echo "Unsupported Linux package manager. Please install: python3/venv/pip, curl, jq, tesseract(+eng+chi_sim), poppler-utils, ghostscript, coreutils."
    exit 1
  fi
}

install_pkgs_macos() {
  echo "[1/10] Installing system dependencies (macOS/Homebrew)..."
  if ! have brew; then
    echo "Homebrew not found. Please install Homebrew first: https://brew.sh"
    exit 1
  fi
  brew update
  brew install jq tesseract poppler ghostscript python@3.12 coreutils || true
  if ! python3 -c 'import sys; sys.exit(0)' 2>/dev/null; then
    echo "python3 not found; ensure Homebrew python is linked."
    exit 1
  fi
}

ensure_env_patch() {
  [ -f "$ENV_FILE" ] || return 0
  cp -f "$ENV_FILE" "$ENV_FILE.bak.$(date +%s)" || true

  # ---- Logging defaults（不覆盖用户已有值）----
  grep -q '^LOG_FORMAT='  "$ENV_FILE" || echo 'LOG_FORMAT=%(asctime)s.%(msecs)03d %(levelname)s %(name)s - %(message)s' >> "$ENV_FILE"
  grep -q '^LOG_DATEFMT=' "$ENV_FILE" || echo 'LOG_DATEFMT=%Y-%m-%d %H:%M:%S' >> "$ENV_FILE"
  grep -q '^LOG_FILE='    "$ENV_FILE" || echo "LOG_FILE=${APP_DIR}/agrader.log" >> "$ENV_FILE"

  # ---- Prompt template path（新增，热加载友好）----
  grep -q '^PROMPT_TEMPLATE_PATH=' "$ENV_FILE" || echo "PROMPT_TEMPLATE_PATH=${APP_DIR}/prompt.txt" >> "$ENV_FILE"

  # ---- 权威端点（會覆蓋舊值，避免走錯路徑）----
  if grep -q '^SEIUE_SCORE_ENDPOINTS=' "$ENV_FILE"; then
    sed -i.bak -E 's#^SEIUE_SCORE_ENDPOINTS=.*#SEIUE_SCORE_ENDPOINTS=POST:/vnas/klass/items/{item_id}/scores/sync?async=true\&from_task=true:array#' "$ENV_FILE" || true
  else
    echo 'SEIUE_SCORE_ENDPOINTS=POST:/vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true:array' >> "$ENV_FILE"
  fi
  grep -q '^SEIUE_REVIEW_POST_TEMPLATE=' "$ENV_FILE" || \
    echo 'SEIUE_REVIEW_POST_TEMPLATE=/chalk/task/v2/assignees/{receiver_id}/tasks/{task_id}/reviews' >> "$ENV_FILE"
  grep -q '^SEIUE_VERIFY_SCORE_GET_TEMPLATE=' "$ENV_FILE" || \
    echo 'SEIUE_VERIFY_SCORE_GET_TEMPLATE=/vnas/common/items/{item_id}/scores?paginated=0&type=item_score' >> "$ENV_FILE"

  # ---- Strategy / concurrency：缺失才填（不覆盖已有值）----
  grep -q '^DRY_RUN='                 "$ENV_FILE" || echo 'DRY_RUN=0'                  >> "$ENV_FILE"
  grep -q '^VERIFY_AFTER_WRITE='      "$ENV_FILE" || echo 'VERIFY_AFTER_WRITE=1'       >> "$ENV_FILE"
  grep -q '^RETRY_FAILED='            "$ENV_FILE" || echo 'RETRY_FAILED=1'             >> "$ENV_FILE"
  grep -q '^STUDENT_WORKERS='         "$ENV_FILE" || echo 'STUDENT_WORKERS=1'          >> "$ENV_FILE"
  grep -q '^ATTACH_WORKERS='          "$ENV_FILE" || echo 'ATTACH_WORKERS=3'           >> "$ENV_FILE"
  grep -q '^AI_PARALLEL='             "$ENV_FILE" || echo 'AI_PARALLEL=1'              >> "$ENV_FILE"
  grep -q '^AI_MAX_RETRIES='          "$ENV_FILE" || echo 'AI_MAX_RETRIES=5'           >> "$ENV_FILE"
  grep -q '^AI_BACKOFF_BASE_SECONDS=' "$ENV_FILE" || echo 'AI_BACKOFF_BASE_SECONDS=2.5'>> "$ENV_FILE"
  grep -q '^AI_JITTER_SECONDS='       "$ENV_FILE" || echo 'AI_JITTER_SECONDS=0.8'      >> "$ENV_FILE"
  grep -q '^AI_FAILOVER='             "$ENV_FILE" || echo 'AI_FAILOVER=1'              >> "$ENV_FILE"
  grep -q '^MAX_ATTACHMENT_BYTES='    "$ENV_FILE" || echo 'MAX_ATTACHMENT_BYTES=25165824' >> "$ENV_FILE"
  grep -q '^OCR_LANG='                "$ENV_FILE" || echo 'OCR_LANG=chi_sim+eng'       >> "$ENV_FILE"

  # ---- Multi-key AI 轮询支持（新增，不覆盖已有值）----
  grep -q '^AI_KEY_STRATEGY='         "$ENV_FILE" || echo 'AI_KEY_STRATEGY=roundrobin' >> "$ENV_FILE"
  grep -q '^GEMINI_API_KEYS='         "$ENV_FILE" || echo 'GEMINI_API_KEYS='           >> "$ENV_FILE"
  grep -q '^DEEPSEEK_API_KEYS='       "$ENV_FILE" || echo 'DEEPSEEK_API_KEYS='         >> "$ENV_FILE"
}

write_project() {
  echo "[2/10] Collecting initial configuration..."
  mkdir -p "$APP_DIR" "$APP_DIR/work"

  if [ ! -f "$ENV_FILE" ]; then
    echo "Enter Seiue API credentials/headers (auto OR manual)."
    ask "Seiue API Base" SEIUE_BASE "https://api.seiue.com"

    ask "Seiue Username (leave empty to skip auto-login)" SEIUE_USERNAME ""
    if [ -n "$SEIUE_USERNAME" ]; then
      ask_secret "Seiue Password" SEIUE_PASSWORD
    else
      SEIUE_PASSWORD=""
    fi

    ask "X-School-Id" SEIUE_SCHOOL_ID "3"
    ask "X-Role" SEIUE_ROLE "teacher"
    ask "X-Reflection-Id (manual; empty if auto-login)" SEIUE_REFLECTION_ID ""
    ask_secret "Bearer token (manual; empty if auto-login)" SEIUE_BEARER

    ask "Comma-separated Task IDs or URLs to monitor" MONITOR_TASK_IDS ""
    ask "Polling interval seconds" POLL_INTERVAL "10"

    echo
    echo "Choose AI provider:"
    echo "  1) gemini"
    echo "  2) deepseek"
    ask "Select 1/2" AI_CHOICE "2"
    if [ "$AI_CHOICE" = "2" ]; then
      AI_PROVIDER="deepseek"
      ask_secret "DeepSeek API Key (single; extra keys can be set later in DEEPSEEK_API_KEYS)" DEEPSEEK_API_KEY
      ask "DeepSeek Model" DEEPSEEK_MODEL "deepseek-reasoner"
      GEMINI_API_KEY=""; GEMINI_MODEL="gemini-2.5-pro"
    else
      AI_PROVIDER="gemini"
      ask_secret "Gemini API Key (single; extra keys can be set later in GEMINI_API_KEYS)" GEMINI_API_KEY
      ask "Gemini Model" GEMINI_MODEL "gemini-2.5-pro"
      DEEPSEEK_API_KEY=""; DEEPSEEK_MODEL="deepseek-reasoner"
    fi

    echo
    echo "Telegram (optional, ENTER to skip)"
    ask "Telegram Bot Token" TELEGRAM_BOT_TOKEN ""
    ask "Telegram Chat ID" TELEGRAM_CHAT_ID ""

    echo
    echo "Extraction limits"
    ask "Enable PDF OCR fallback after pdftotext fails? (1/0)" ENABLE_PDF_OCR_FALLBACK "1"
    ask "Max PDF pages allowed for OCR fallback" MAX_PDF_OCR_PAGES "20"
    ask "Max seconds allowed for OCR fallback (timeout)" MAX_PDF_OCR_SECONDS "120"
    ask "Notify via Telegram when skipping heavy OCR? (1/0)" TELEGRAM_VERBOSE "1"
    ask "Keep downloaded work files for debugging? (1/0)" KEEP_WORK_FILES "0"

    echo
    echo "Logging options:"
    ask "LOG_LEVEL (DEBUG/INFO/WARN/ERROR)" LOG_LEVEL "INFO"
    ask "LOG_FILE path" LOG_FILE "$APP_DIR/agrader.log"
    LOG_FORMAT="%(asctime)s.%(msecs)03d %(levelname)s %(name)s - %(message)s"
    LOG_DATEFMT="%Y-%m-%d %H:%M:%S"

  cat > "$ENV_FILE" <<EOF
# ---- Seiue ----
SEIUE_BASE=${SEIUE_BASE}
SEIUE_USERNAME=${SEIUE_USERNAME}
SEIUE_PASSWORD=${SEIUE_PASSWORD}
SEIUE_BEARER=${SEIUE_BEARER}
SEIUE_SCHOOL_ID=${SEIUE_SCHOOL_ID}
SEIUE_ROLE=${SEIUE_ROLE}
SEIUE_REFLECTION_ID=${SEIUE_REFLECTION_ID}
MONITOR_TASK_IDS=${MONITOR_TASK_IDS}
POLL_INTERVAL=${POLL_INTERVAL}

# ---- Endpoints ----
SEIUE_REVIEW_POST_TEMPLATE=/chalk/task/v2/assignees/{receiver_id}/tasks/{task_id}/reviews
SEIUE_SCORE_ENDPOINTS=POST:/vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true:array
SEIUE_VERIFY_SCORE_GET_TEMPLATE=/vnas/common/items/{item_id}/scores?paginated=0&type=item_score

# ---- AI ----
AI_PROVIDER=${AI_PROVIDER}
# 支持多 Key（逗号分隔），与单 Key 并行存在，程序会合并去重
GEMINI_API_KEYS=
GEMINI_API_KEY=${GEMINI_API_KEY}
GEMINI_MODEL=${GEMINI_MODEL}
DEEPSEEK_API_KEYS=
DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY}
DEEPSEEK_MODEL=${DEEPSEEK_MODEL}

# 轮换与退避
AI_KEY_STRATEGY=roundrobin
AI_PARALLEL=1
AI_MAX_RETRIES=5
AI_BACKOFF_BASE_SECONDS=2.5
AI_JITTER_SECONDS=0.8
AI_FAILOVER=1

# ---- Telegram ----
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
TELEGRAM_VERBOSE=1

# ---- Extractor & resource limits ----
MAX_ATTACHMENT_BYTES=25165824
OCR_LANG=chi_sim+eng
ENABLE_PDF_OCR_FALLBACK=${ENABLE_PDF_OCR_FALLBACK}
MAX_PDF_OCR_PAGES=${MAX_PDF_OCR_PAGES}
MAX_PDF_OCR_SECONDS=${MAX_PDF_OCR_SECONDS}
KEEP_WORK_FILES=${KEEP_WORK_FILES}

# ---- Logging ----
LOG_LEVEL=${LOG_LEVEL}
LOG_FILE=${LOG_FILE}
LOG_FORMAT=${LOG_FORMAT}
LOG_DATEFMT=${LOG_DATEFMT}

# ---- Strategy ----
SCORE_WRITE=1
REVIEW_ALL_EXISTING=1
SCORE_GIVE_ALL_ON_START=1
DRY_RUN=0
VERIFY_AFTER_WRITE=1
RETRY_FAILED=1

# ---- Concurrency ----
STUDENT_WORKERS=1
ATTACH_WORKERS=3

# ---- Prompt template ----
PROMPT_TEMPLATE_PATH=${APP_DIR}/prompt.txt

# ---- Paths/State ----
STATE_PATH=${APP_DIR}/state.json
WORKDIR=${APP_DIR}/work
EOF
    chmod 600 "$ENV_FILE"
  else
    echo "Reusing existing $ENV_FILE"
  fi

  # 只补缺省，不覆盖已有；但端点強制收斂；并添加多Key键位与 PROMPT 路径
  ensure_env_patch

  echo "[3/10] Writing project files..."

  # ---------- requirements ----------
  cat > "$APP_DIR/requirements.txt" <<'EOF'
requests==2.32.3
urllib3==2.2.3
python-dotenv==1.0.1
pytz==2024.2
Pillow==10.4.0
pytesseract==0.3.13
pdfminer.six==20231228
python-docx==1.1.2
python-pptx==0.6.23
lxml==5.3.0
EOF

  # ---------- prompt.txt (可热编辑) ----------
  cat > "$APP_DIR/prompt.txt" <<'EOF'
You are a strict Chinese language grader.

Task: {task_title}
Student: {student_name} ({student_id})
Max Score: {max_score}
Per-Question Schema (JSON): {per_question_json}

The student's submission text is below (UTF-8). Use rubric and constraints to grade.
---
{assignment_text}
---

Output ONLY a valid JSON object with this exact shape, nothing else:
{"per_question":[{"id":"...","score":float,"comment":"..."}],"overall":{"score":float,"comment":"..."}}
EOF

  # ---------- utilx.py ----------
  cat > "$APP_DIR/utilx.py" <<'PY'
import json, hashlib
from typing import Dict, Any, List, Tuple

def draftjs_to_text(content_json: str) -> str:
    try:
        data = json.loads(content_json)
        blocks = data.get("blocks", [])
        return "\n".join(b.get("text","") for b in blocks).strip()
    except Exception:
        return content_json

def clamp(v: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, v))

def scan_question_maxima(task: Dict[str, Any]) -> Tuple[List[Dict[str, Any]], float]:
    overall_max = 100.0
    perq: List[Dict[str, Any]] = []
    candidates = []
    for k in ["score_items","questions","problems","rubric","grading","grading_items"]:
        v = task.get(k) or task.get("custom_fields", {}).get(k)
        if isinstance(v, list):
            candidates = v; break
    if candidates:
        for idx, it in enumerate(candidates):
            qid = str(it.get("id", f"q{idx+1}"))
            mx = it.get("max") or it.get("max_score") or it.get("full") or 100
            try: mx = float(mx)
            except: mx = 100.0
            perq.append({"id": qid, "max": mx})
        overall_max = sum(q["max"] for q in perq)
    else:
        cm = task.get("custom_fields", {})
        maybe_max = cm.get("max_score") or cm.get("full") or task.get("max_score")
        if maybe_max:
            try: overall_max = float(maybe_max)
            except: pass
    return perq, overall_max

def stable_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8","ignore")).hexdigest()
PY

  # ---------- credentials.py ----------
  cat > "$APP_DIR/credentials.py" <<'PY'
import logging, requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

class AuthResult:
    def __init__(self, ok: bool, token: str = "", reflection_id: str = "", detail: str = ""):
        self.ok = ok; self.token = token; self.reflection_id = reflection_id; self.detail = detail

def _session_with_retries() -> requests.Session:
    s = requests.Session()
    r = Retry(total=5, backoff_factor=1.5, status_forcelist=(429,500,502,503,504), allowed_methods=frozenset({"GET","POST"}))
    s.mount("https://", HTTPAdapter(max_retries=r))
    s.headers.update({"User-Agent": "AGrader/1.10 (+login)","Accept": "application/json, text/plain, */*"})
    return s

def login(username: str, password: str) -> AuthResult:
    try:
        sess = _session_with_retries()
        login_url = "https://passport.seiue.com/login?school_id=3&type=account&from=null&redirect_url=null"
        auth_url  = "https://passport.seiue.com/authorize"
        login_form = {"email": username, "login": username, "username": username, "password": password}
        lr = sess.post(login_url, headers={"Referer": login_url,"Origin": "https://passport.seiue.com","Content-Type": "application/x-www-form-urlencoded"}, data=login_form, timeout=30)
        auth_form = {"client_id":"GpxvnjhVKt56qTmnPWH1sA","response_type":"token"}
        ar = sess.post(auth_url, headers={"Referer": "https://chalk-c3.seiue.com/","Origin": "https://chalk-c3.seiue.com","Content-Type": "application/x-www-form-urlencoded"}, data=auth_form, timeout=30)
        ar.raise_for_status()
        j = ar.json() or {}
        token = j.get("access_token",""); reflection = j.get("active_reflection_id","")
        if token and reflection: return AuthResult(True, token, str(reflection))
        return AuthResult(False, detail=f"Missing token/reflection_id keys={list(j.keys())}")
    except requests.RequestException as e:
        logging.error(f"[AUTH] {e}", exc_info=True); return AuthResult(False, detail=str(e))
PY

  # ---------- extractor.py ----------
  cat > "$APP_DIR/extractor.py" <<'PY'
import os, subprocess, mimetypes, logging
from typing import Tuple, List
from PIL import Image
import pytesseract

def _run(cmd: list, input_bytes: bytes=None, timeout=180) -> Tuple[int, bytes, bytes]:
    import subprocess as sp
    p = sp.Popen(cmd, stdin=sp.PIPE if input_bytes else None, stdout=sp.PIPE, stderr=sp.PIPE)
    out, err = p.communicate(input=input_bytes, timeout=timeout); return p.returncode, out, err

def _pdf_pages(path: str) -> int:
    try:
        code, out, _ = _run(["pdfinfo", path], timeout=20)
        if code == 0:
            for line in out.decode("utf-8","ignore").splitlines():
                if line.lower().startswith("pages:"): return int(line.split(":")[1].strip())
    except Exception: pass
    return -1

def file_to_text(path: str, ocr_lang: str="chi_sim+eng", size_cap: int=25*1024*1024) -> str:
    if not os.path.exists(path): return "[[error: file not found]]"
    sz = os.path.getsize(path)
    if sz > size_cap: return f"[[skipped: file too large ({sz} bytes)]]"
    mt, _ = mimetypes.guess_type(path); ext = (os.path.splitext(path)[1] or "").lower()

    if ext == ".pdf" or (mt and mt.endswith("pdf")):
        try:
            code, out, _ = _run(["pdftotext", "-layout", path, "-"], timeout=120)
            if code == 0 and out.strip(): return out.decode("utf-8","ignore")
        except Exception as e: logging.warning(f"[EXTRACT] pdftotext failed: {e}", exc_info=True)
        enable_fallback = os.getenv("ENABLE_PDF_OCR_FALLBACK","1") not in ("0","false","False")
        max_pages = int(os.getenv("MAX_PDF_OCR_PAGES","20")); pages = _pdf_pages(path)
        if (not enable_fallback) or (pages > 0 and pages > max_pages):
            return f"[[skipped: pdf ocr fallback disabled or too large (pages={pages}, size={sz})]]"
        import tempfile
        tmpdir = tempfile.mkdtemp(prefix="pdfocr_"); prefix = os.path.join(tmpdir, "pg")
        code, _, err = _run(["pdftoppm", "-r", "200", path, prefix], timeout=int(os.getenv("MAX_PDF_OCR_SECONDS","120")))
        if code != 0: return f"[[error: pdftoppm {err.decode('utf-8','ignore')[:200]}]]"
        texts=[]
        for f in sorted(os.listdir(tmpdir)):
          if f.startswith("pg") and (f.endswith(".ppm") or f.endswith(".png") or f.endswith(".jpg")):
            try: texts.append(pytesseract.image_to_string(Image.open(os.path.join(tmpdir,f)), lang=ocr_lang))
            except Exception as e: logging.error(f"[OCR] {e}", exc_info=True); texts.append(f"[[error: tesseract {e}]]")
        return ("\n".join(texts).strip() or "[[error: ocr empty]]")

    if ext in [".png",".jpg",".jpeg",".bmp",".tiff",".webp"] or (mt and mt.startswith("image/")):
        try: return pytesseract.image_to_string(Image.open(path), lang=ocr_lang) or "[[error: image ocr empty]]"
        except Exception as e: logging.error(f"[EXTRACT] {e}", exc_info=True); return f"[[error: image ocr exception: {repr(e)}]]"

    if ext == ".docx":
        try:
            import docx; return "\n".join(p.text for p in docx.Document(path).paragraphs)
        except Exception as e: logging.error(f"[EXTRACT] {e}", exc_info=True); return f"[[error: docx extract exception: {repr(e)}]]"

    if ext == ".pptx":
        try:
            from pptx import Presentation; lines=[]; prs=Presentation(path)
            for s in prs.slides:
                for shp in s.shapes:
                    if hasattr(shp,"text"): lines.append(shp.text)
            return "\n".join(lines) or "[[error: pptx no text]]"
        except Exception as e: logging.error(f"[EXTRACT] {e}", exc_info=True); return f"[[error: pptx extract exception: {repr(e)}]]"

    try:
        with open(path,"rb") as f: return f.read().decode("utf-8","ignore")
    except Exception as e: logging.error(f"[EXTRACT] {e}", exc_info=True); return f"[[error: unknown file read exception: {repr(e)}]]"
PY

  # ---------- ai_providers.py ----------
  cat > "$APP_DIR/ai_providers.py" <<'PY'
import os, time, json, requests, logging, random, re
from typing import List

def _as_bool(x, default=True):
    if x is None: return default
    s = str(x).strip().lower()
    return s not in ("0","false","no","off")

def _backoff_loop():
    max_retries = int(os.getenv("AI_MAX_RETRIES","5"))
    base = float(os.getenv("AI_BACKOFF_BASE_SECONDS","1.5"))
    jitter = float(os.getenv("AI_JITTER_SECONDS","0.5"))
    for i in range(max_retries):
        yield i
        time.sleep((base ** i) + random.uniform(0, jitter))

def _split_keys(s: str) -> List[str]:
    if not s: return []
    return [x.strip() for x in s.split(",") if x.strip()]

class AIClient:
    """
    - 同厂多 Key：根据 AI_KEY_STRATEGY=roundrobin|random 轮询
    - 429/5xx：切换 Key，指数退避
    - JSON 修复：先尝试“当前 provider 的所有 Key”；若失败且 AI_FAILOVER=1，再尝试备用 provider 的 Key
    - 可观测性：成功用到谁 -> [AI][USE]；谁完成修复 -> [AI][REPAIR]
    """
    def __init__(self, provider: str, model: str, key: str):
        self.provider = provider
        self.model = model
        self._rr = 0
        self.strategy = os.getenv("AI_KEY_STRATEGY","roundrobin").lower()

        ring = []
        if provider == "gemini":
            ring += _split_keys(os.getenv("GEMINI_API_KEYS",""))
            if key: ring.append(key or os.getenv("GEMINI_API_KEY",""))
        elif provider == "deepseek":
            ring += _split_keys(os.getenv("DEEPSEEK_API_KEYS",""))
            if key: ring.append(key or os.getenv("DEEPSEEK_API_KEY",""))
        else:
            if key: ring.append(key)

        seen=set(); self.keys=[]
        for k in ring:
            if k and k not in seen:
                self.keys.append(k); seen.add(k)
        if not self.keys:
            self.keys = [key] if key else [""]

    # ---------- 通用 Key 迭代 ----------
    def _key_order(self, n: int):
        if n <= 0: return []
        if self.strategy == "random":
            idxs = list(range(n)); random.shuffle(idxs); return idxs
        return list(range(self._rr, n)) + list(range(0, self._rr))

    def _advance_rr(self, used_idx):
        if self.strategy == "roundrobin" and self.keys:
            self._rr = (used_idx + 1) % len(self.keys)

    # ---------- 对外主接口 ----------
    def grade(self, prompt: str) -> dict:
        raw = self._call_llm(prompt)
        return self.parse_or_repair(raw, original_prompt=prompt)

    # ---------- 解析与修复 ----------
    def parse_or_repair(self, text: str, original_prompt: str = "") -> dict:
        text = (text or "").strip()
        if not text:
            fixed = self.repair_json(original_prompt, text)
            return self._safe_json_or_fallback(fixed or text)

        if text.startswith("{"):
            try: return json.loads(text)
            except Exception: pass
        m = re.search(r"\{.*\}", text, re.S)
        if m:
            try: return json.loads(m.group(0))
            except Exception: pass

        fixed = self.repair_json(original_prompt, text)
        return self._safe_json_or_fallback(fixed or text)

    def _safe_json_or_fallback(self, s: str):
        try:
            if isinstance(s, dict): return s
            if isinstance(s, str):
                s = s.strip()
                if s.startswith("{"): return json.loads(s)
                m = re.search(r"\{.*\}", s, re.S)
                if m: return json.loads(m.group(0))
        except Exception as e:
            logging.error(f"[AI] JSON parse failed after repair: {e}", exc_info=True)
        return {"per_question": [], "overall": {"score": 0.0, "comment": (s[:200] if s else "AI empty")}}

    # ---------- LLM 调度 ----------
    def _call_llm(self, prompt: str) -> str:
        if self.provider == "gemini":
            return self._gemini(prompt)
        elif self.provider == "deepseek":
            return self._deepseek(prompt)
        else:
            raise ValueError("Unknown AI provider")

    def _gemini(self, prompt: str) -> str:
        body = {"contents":[{"parts":[{"text": prompt}]}], "generationConfig":{"temperature":0.2}}
        for _ in _backoff_loop():
            order = self._key_order(len(self.keys))
            for idx in order:
                key = self.keys[idx]
                url = f"https://generativelanguage.googleapis.com/v1beta/models/{self.model}:generateContent?key={key}"
                try:
                    r = requests.post(url, json=body, timeout=180)
                    if r.status_code == 429 or (500 <= r.status_code < 600):
                        logging.warning("[AI] Gemini %s; switch key #%d/%d", r.status_code, idx+1, len(self.keys)); continue
                    r.raise_for_status()
                    data = r.json()
                    logging.info("[AI][USE] provider=gemini model=%s key_index=%d/%d", self.model, idx+1, len(self.keys))
                    self._advance_rr(idx)
                    try:
                        return data["candidates"][0]["content"]["parts"][0]["text"]
                    except Exception:
                        return json.dumps(data)[:4000]
                except requests.RequestException as e:
                    code = getattr(e.response,'status_code',type(e).__name__)
                    logging.warning("[AI] Gemini exception (%s); switch key #%d/%d", code, idx+1, len(self.keys)); continue
        return ""

    def _deepseek(self, prompt: str) -> str:
        body={"model": self.model,"messages":[{"role":"system","content":"You are a strict grader. Output ONLY valid JSON per schema."},{"role":"user","content": prompt}],"temperature":0.2}
        for _ in _backoff_loop():
            order = self._key_order(len(self.keys))
            for idx in order:
                key = self.keys[idx]
                url = "https://api.deepseek.com/chat/completions"
                headers={"Authorization": f"Bearer {key}"}
                try:
                    r = requests.post(url, headers=headers, json=body, timeout=180)
                    if r.status_code == 429 or (500 <= r.status_code < 600):
                        logging.warning("[AI] DeepSeek %s; switch key #%d/%d", r.status_code, idx+1, len(self.keys)); continue
                    r.raise_for_status()
                    data = r.json()
                    logging.info("[AI][USE] provider=deepseek model=%s key_index=%d/%d", self.model, idx+1, len(self.keys))
                    self._advance_rr(idx)
                    return data.get("choices",[{}])[0].get("message",{}).get("content","")
                except requests.RequestException as e:
                    code = getattr(e.response,'status_code',type(e).__name__)
                    logging.warning("[AI] DeepSeek exception (%s); switch key #%d/%d", code, idx+1, len(self.keys)); continue
        return ""

    # ---------- 统一 JSON 修复 ----------
    def repair_json(self, original_prompt: str, bad_text: str) -> str:
        to_fix = (bad_text or "").strip()

        # 1) 当前 provider 的 keys
        fixed = self._repair_with_provider(self.provider, self.model, self.keys, to_fix)
        if fixed: return fixed

        # 2) 允许跨厂修复
        if _as_bool(os.getenv("AI_FAILOVER","1"), True):
            if self.provider == "gemini":
                alt_provider, alt_model = "deepseek", os.getenv("DEEPSEEK_MODEL","deepseek-reasoner")
                alt_keys = _split_keys(os.getenv("DEEPSEEK_API_KEYS","")) or _split_keys(os.getenv("DEEPSEEK_API_KEY",""))
            else:
                alt_provider, alt_model = "gemini", os.getenv("GEMINI_MODEL","gemini-2.5-pro")
                alt_keys = _split_keys(os.getenv("GEMINI_API_KEYS","")) or _split_keys(os.getenv("GEMINI_API_KEY",""))
            fixed = self._repair_with_provider(alt_provider, alt_model, alt_keys, to_fix, mark_alt=True)
            if fixed: return fixed

        return to_fix

    def _repair_with_provider(self, provider: str, model: str, keys: List[str], text: str, mark_alt: bool=False) -> str:
        if not keys: return ""
        def _order(n): 
            if self.strategy == "random":
                idxs = list(range(n)); random.shuffle(idxs); return idxs
            return list(range(n))

        sys_prompt = "You are a JSON fixer. Return ONLY the corrected JSON object. No code fences. No commentary."
        if provider == "deepseek":
            for _ in _backoff_loop():
                for idx in _order(len(keys)):
                    key = keys[idx]
                    try:
                        url = "https://api.deepseek.com/chat/completions"
                        headers={"Authorization": f"Bearer {key}"}
                        user = "The following is not valid JSON. Please fix it and return only the corrected JSON object.\n\n<<<\n"+(text or "")+"\n>>>"
                        r = requests.post(url, headers=headers, json={"model": model,"messages":[{"role":"system","content":sys_prompt},{"role":"user","content": user}],"temperature":0.0}, timeout=120)
                        if r.status_code == 429 or (500 <= r.status_code < 600): continue
                        r.raise_for_status()
                        data = r.json()
                        logging.info("[AI][REPAIR] provider=deepseek%s", " (failover)" if mark_alt else "")
                        return data.get("choices",[{}])[0].get("message",{}).get("content","")
                    except requests.RequestException:
                        continue
            return ""
        elif provider == "gemini":
            instr = "The following is not valid JSON. Please fix it and return only the corrected JSON object."
            for _ in _backoff_loop():
                for idx in _order(len(keys)):
                    key = keys[idx]
                    try:
                        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={key}"
                        body = {"contents":[{"parts":[{"text": instr+"\n\n<<<\n"+(text or "")+"\n>>>\n"}]}], "generationConfig":{"temperature":0.0}}
                        r = requests.post(url, json=body, timeout=120)
                        if r.status_code == 429 or (500 <= r.status_code < 600): continue
                        r.raise_for_status()
                        data = r.json()
                        logging.info("[AI][REPAIR] provider=gemini%s", " (failover)" if mark_alt else "")
                        return data["candidates"][0]["content"]["parts"][0]["text"]
                    except requests.RequestException:
                        continue
            return ""
        else:
            return ""
PY

  # ---------- seiue_api.py ----------
  cat > "$APP_DIR/seiue_api.py" <<'PY'
import os, logging, requests, threading
from typing import Dict, Any, List
from credentials import login, AuthResult
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

_login_lock = threading.Lock()

def _session_with_retries() -> requests.Session:
    s = requests.Session()
    r = Retry(total=5, backoff_factor=1.5, status_forcelist=(429,500,502,503,504), allowed_methods=frozenset({"GET","POST","PUT"}))
    s.mount("https://", HTTPAdapter(max_retries=r))
    s.headers.update({"Accept":"application/json, text/plain, */*","User-Agent":"AGrader/1.10"})
    return s

class Seiue:
    def __init__(self, base: str, bearer: str, school_id: str, role: str, reflection_id: str, username: str="", password: str=""):
        self.base = (base or "https://api.seiue.com").rstrip("/")
        self.username = username; self.password = password
        self.school_id = str(school_id or "3"); self.role = role or "teacher"
        self.reflection_id = str(reflection_id) if reflection_id else ""; self.bearer = bearer or ""
        self.session = _session_with_retries(); self._init_headers()
        if not self.bearer and self.username and self.password: self._login_and_apply()

    def _init_headers(self):
        if self.bearer: self.session.headers.update({"Authorization": f"Bearer {self.bearer}"})
        if self.school_id: self.session.headers.update({"X-School-Id": self.school_id, "x-school-id": self.school_id})
        if self.role: self.session.headers.update({"X-Role": self.role, "x-role": self.role})
        if self.reflection_id: self.session.headers.update({"X-Reflection-Id": self.reflection_id, "x-reflection-id": self.reflection_id})

    def _login_and_apply(self) -> bool:
        if not (self.username and self.password): return False
        with _login_lock:
            if self.bearer:
                self._init_headers(); return True
            logging.info("[AUTH] Auto-login...")
            res: AuthResult = login(self.username, self.password)
            if res.ok:
                self.bearer = res.token
                if res.reflection_id: self.reflection_id = str(res.reflection_id)
                self._init_headers(); logging.info("[AUTH] OK"); return True
            logging.error(f"[AUTH] Failed: {res.detail}")
            return False

    def _url(self, path: str) -> str:
        if path.startswith("http"): return path
        if not path.startswith("/"): path = "/" + path
        return self.base + path

    def _with_refresh(self, request_fn):
        r = request_fn()
        if getattr(r,"status_code",None) in (401,403):
            logging.warning("[AUTH] 401/403; re-auth...")
            if self._login_and_apply(): return request_fn()
        return r

    # --- tasks & assignments ---
    def get_task(self, task_id: int):
        url = self._url(f"/chalk/task/v2/tasks/{task_id}")
        r = self._with_refresh(lambda: self.session.get(url, timeout=60))
        if r.status_code >= 400: logging.error(f"[API] get_task {r.status_code}: {(r.text or '')[:500]}"); r.raise_for_status()
        return r.json()

    def get_tasks_bulk(self, task_ids: List[int]):
        if not task_ids: return {}
        ids = ",".join(str(i) for i in sorted(set(task_ids)))
        url = self._url(f"/chalk/task/v2/tasks?id_in={ids}&expand=group")
        r = self._with_refresh(lambda: self.session.get(url, timeout=60))
        if r.status_code >= 400: logging.error(f"[API] get_tasks_bulk {r.status_code}: {(r.text or '')[:500]}"); r.raise_for_status()
        arr = r.json() or []
        out = {}
        for obj in arr:
            tid = int(obj.get("id", 0) or 0)
            if tid: out[tid] = obj
        return out

    def get_assignments(self, task_id: int):
        url = self._url(f"/chalk/task/v2/tasks/{task_id}/assignments?expand=is_excellent,assignee,team,submission,review")
        r = self._with_refresh(lambda: self.session.get(url, timeout=60))
        if r.status_code >= 400: logging.error(f"[API] get_assignments {r.status_code}: {(r.text or '')[:500]}"); r.raise_for_status()
        return r.json()

    # --- items (full_score / pathname / progress) ---
    def get_item_detail(self, item_id: int):
        url = self._url(f"/vnas/klass/items/{item_id}")
        r = self._with_refresh(lambda: self.session.get(url, timeout=30))
        if r.status_code >= 400: logging.error(f"[API] get_item_detail {r.status_code}: {(r.text or '')[:300]}"); r.raise_for_status()
        return r.json()

    # --- files ---
    def get_file_signed_url(self, file_id: str) -> str:
        url = self._url(f"/chalk/netdisk/files/{file_id}/url")
        r = self._with_refresh(lambda: self.session.get(url, allow_redirects=False, timeout=60))
        if r.status_code in (301,302) and "Location" in r.headers: return r.headers["Location"]
        try:
            j = r.json()
            if isinstance(j, dict) and j.get("url"): return j["url"]
        except Exception: pass
        if r.status_code >= 400: logging.error(f"[API] file url {r.status_code}: {(r.text or '')[:500]}"); r.raise_for_status()
        return ""

    def download(self, url: str) -> bytes:
        r = self._with_refresh(lambda: self.session.get(url, timeout=120))
        if r.status_code >= 400: logging.error(f"[API] download {r.status_code}: {(r.text or '')[:200]}"); r.raise_for_status()
        return r.content

    # --- review & score ---
    def post_review(self, receiver_id: int, task_id: int, content: str, result="approved"):
        path = os.getenv("SEIUE_REVIEW_POST_TEMPLATE","/chalk/task/v2/assignees/{receiver_id}/tasks/{task_id}/reviews").format(receiver_id=receiver_id, task_id=task_id)
        url = self._url(path)
        body = {"result": result, "content": content, "reason": "","attachments": [], "do_evaluation": False, "is_submission_changed": False}
        r = self._with_refresh(lambda: self.session.post(url, json=body, timeout=60))
        if r.status_code not in (200,201): logging.error(f"[API] post_review {r.status_code}: {(r.text or '')[:400]}"); r.raise_for_status()
        return r.json()

    def post_item_score(self, item_id: int, owner_id: int, task_id: int, score: float) -> bool:
        path = f"/vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true"
        url  = self._url(path)
        payload = [{
            "owner_id": int(owner_id),
            "valid": True,
            "score": str(score),
            "review": "",
            "attachments": [],
            "related_data": {"task_id": int(task_id)},
            "type": "item_score",
            "status": "published"
        }]
        r = self._with_refresh(lambda: self.session.post(url, json=payload, timeout=60))
        if 200 <= r.status_code < 300:
            return True
        if r.status_code == 422 and ("分数已经存在" in (r.text or "") or "already exists" in (r.text or "")):
            return True
        logging.warning(f"[API] score failed: POST {path} -> {r.status_code} :: {(r.text or '')[:200]}")
        if r.status_code >= 400: r.raise_for_status()
        return False
PY

  # ---------- main.py ----------
  cat > "$APP_DIR/main.py" <<'PY'
import os, json, time, logging, re, threading, signal, statistics
from typing import Dict, Any, List, Tuple
from dotenv import load_dotenv
from utilx import draftjs_to_text, scan_question_maxima, clamp, stable_hash
from extractor import file_to_text
from ai_providers import AIClient
from seiue_api import Seiue

# -------------------- logging --------------------
def setup_logging():
    level = os.getenv("LOG_LEVEL","INFO").upper()
    level_map = {"DEBUG": logging.DEBUG, "INFO": logging.INFO, "WARN": logging.WARN, "WARNING": logging.WARN, "ERROR": logging.ERROR}
    log_level = level_map.get(level, logging.INFO)
    log_file = os.getenv("LOG_FILE","/opt/agrader/agrader.log")
    fmt = os.getenv("LOG_FORMAT","%(asctime)s.%(msecs)03d %(levelname)s %(name)s - %(message)s")
    datefmt = os.getenv("LOG_DATEFMT","%Y-%m-%d %H:%M:%S")
    logging.basicConfig(level=log_level, format=fmt, datefmt=datefmt)
    try:
        fh = logging.FileHandler(log_file, encoding="utf-8", mode="a")
        fh.setLevel(log_level); fh.setFormatter(logging.Formatter(fmt, datefmt=datefmt))
        logging.getLogger().addHandler(fh)
    except Exception: logging.warning(f"Cannot open LOG_FILE={log_file} for writing.")
    if log_level == logging.DEBUG: logging.getLogger("urllib3").setLevel(logging.INFO)

# -------------------- Telegram --------------------
def tg_enabled(cfg): return bool(cfg.get("tg_token")) and bool(cfg.get("tg_chat"))
def tg_send(cfg, text):
    if not tg_enabled(cfg): return
    import requests
    url = f"https://api.telegram.org/bot{cfg['tg_token']}/sendMessage"
    data = {"chat_id": cfg["tg_chat"], "text": text, "parse_mode": "HTML", "disable_web_page_preview": True}
    try:
        requests.post(url, data=data, timeout=15)
    except Exception as e:
        logging.warning(f"[TG] {e}")

# -------------------- env/state --------------------
def _parse_task_ids(raw: str) -> List[int]:
    if not raw: return []
    out: List[int] = []
    for seg in [s.strip() for s in raw.split(",") if s.strip()]:
        m = re.search(r"/tasks/(\d+)", seg)
        if m:
            out.append(int(m.group(1))); continue
        m2 = re.search(r"\b(\d{4,})\b", seg)
        if m2:
            out.append(int(m2.group(1)))
    dedup=[]; seen=set()
    for x in out:
        if x not in seen:
            dedup.append(x); seen.add(x)
    return dedup

def load_env():
    load_dotenv(os.getenv("ENV_PATH",".env")); env=os.environ; get=lambda k,d="": env.get(k,d)
    def as_bool(x: str, default=True):
        if x is None or x == "": return default
        return x not in ("0","false","False","no","NO")
    return {
        "base": get("SEIUE_BASE","https://api.seiue.com"),
        "username": get("SEIUE_USERNAME",""),
        "password": get("SEIUE_PASSWORD",""),
        "bearer": get("SEIUE_BEARER",""),
        "school_id": get("SEIUE_SCHOOL_ID","3"),
        "role": get("SEIUE_ROLE","teacher"),
        "reflection_id": get("SEIUE_REFLECTION_ID",""),
        "task_ids": _parse_task_ids(get("MONITOR_TASK_IDS","")),
        "interval": int(get("POLL_INTERVAL","10") or "10"),
        "workdir": get("WORKDIR","/opt/agrader/work"),
        "state_path": get("STATE_PATH","/opt/agrader/state.json"),
        "ocr_lang": get("OCR_LANG","chi_sim+eng"),
        "max_attach": int(get("MAX_ATTACHMENT_BYTES","25165824") or "25165824"),
        "ai_provider": get("AI_PROVIDER","deepseek"),
        "gemini_key": get("GEMINI_API_KEY",""),
        "gemini_model": get("GEMINI_MODEL","gemini-2.5-pro"),
        "deepseek_key": get("DEEPSEEK_API_KEY",""),
        "deepseek_model": get("DEEPSEEK_MODEL","deepseek-reasoner"),
        "ai_parallel": int(get("AI_PARALLEL","1") or "1"),
        "tg_token": get("TELEGRAM_BOT_TOKEN",""),
        "tg_chat": get("TELEGRAM_CHAT_ID",""),
        "tg_verbose": as_bool(get("TELEGRAM_VERBOSE","1")),
        "score_write": as_bool(get("SCORE_WRITE","1")),
        "review_all_existing": as_bool(get("REVIEW_ALL_EXISTING","1")),
        "score_all_on_start": as_bool(get("SCORE_GIVE_ALL_ON_START","1")),
        "dry_run": as_bool(get("DRY_RUN","0")),
        "verify_after": as_bool(get("VERIFY_AFTER_WRITE","1")),
        "retry_failed": as_bool(get("RETRY_FAILED","1")),
        "student_workers": int(get("STUDENT_WORKERS","1") or "1"),
        "attach_workers": int(get("ATTACH_WORKERS","3") or "3"),
        "ai_failover": as_bool(get("AI_FAILOVER","1")),
        "log_level": get("LOG_LEVEL","INFO"),
        "ai_strategy": get("AI_KEY_STRATEGY","roundrobin"),
        "prompt_path": get("PROMPT_TEMPLATE_PATH","/opt/agrader/prompt.txt"),
    }

def load_state(path: str) -> Dict[str, Any]:
    try:
        with open(path,"r") as f: data = json.load(f)
        data.setdefault("processed", {})            # processed[task_id][receiver_id] = {hash, score, comment}
        data.setdefault("failed", [])               # list of {task_id, receiver_id, reason}
        data.setdefault("reported_complete", {})    # reported_complete[task_id] = hash of snapshot
        return data
    except Exception:
        return {"processed": {}, "failed": [], "reported_complete": {}}

def save_state(path: str, st: Dict[str, Any]):
    tmp = path + ".tmp"
    with open(tmp,"w",encoding="utf-8") as f: json.dump(st, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)

# -------- Prompt template (hot reload by mtime) --------
_prompt_cache = {"path": None, "mtime": 0.0, "text": ""}

def _load_prompt_template(path: str) -> str:
    try:
        st = os.stat(path)
        if (_prompt_cache["path"] != path) or (st.st_mtime != _prompt_cache["mtime"]):
            with open(path, "r", encoding="utf-8") as f:
                _prompt_cache.update({"path": path, "mtime": st.st_mtime, "text": f.read()})
    except Exception:
        _prompt_cache["text"] = (
            "You are a strict Chinese language grader.\n\n"
            "Task: {task_title}\nStudent: {student_name} ({student_id})\n"
            "Max Score: {max_score}\nPer-Question Schema (JSON): {per_question_json}\n\n"
            "---\n{assignment_text}\n---\n"
            'Output ONLY JSON: {"per_question":[...],"overall":{"score":...,"comment":"..."}}'
        )
    return _prompt_cache["text"]

def build_prompt(cfg: Dict[str,Any], task: dict, assignment: dict, extracted_text: str, perq: list, overall_max: float) -> str:
    tpl = _load_prompt_template(cfg.get("prompt_path","/opt/agrader/prompt.txt"))
    task_title = (task.get("title") or task.get("name") or "").strip()
    u = (assignment.get("assignee") or {})
    student_name = (u.get("name") or u.get("real_name") or "").strip()
    student_id = str(u.get("id") or assignment.get("receiver_id") or "")
    ctx = {
        "task_title": task_title,
        "student_name": student_name,
        "student_id": student_id,
        "assignment_text": (extracted_text or "").strip(),
        "max_score": float(overall_max or 100.0),
        "per_question_json": json.dumps(perq or [], ensure_ascii=False),
    }
    try: return tpl.format(**ctx)
    except Exception:
        return (
            f"You are a strict grader.\nTask: {task_title}\nStudent: {student_name}({student_id})\n"
            f"Max Score: {ctx['max_score']}\nSchema: {ctx['per_question_json']}\n---\n{ctx['assignment_text']}\n---\n"
            'Output ONLY JSON: {"per_question":[...],"overall":{"score":...,"comment":"..."}}'
        )

# -------------------- graceful stop --------------------
_stop = threading.Event()
def _sigterm(_s,_f): 
    logging.info("[EXEC] Caught signal 15; graceful shutdown...")
    _stop.set()
signal.signal(signal.SIGTERM, _sigterm)
signal.signal(signal.SIGINT, _sigterm)

# -------------------- core --------------------
def main_loop(cfg: Dict[str,Any]):
    if not cfg["task_ids"]:
        logging.warning("[EXEC] No MONITOR_TASK_IDS configured.")
        time.sleep(cfg["interval"])
        return

    api = Seiue(
        base=cfg["base"], bearer=cfg["bearer"], school_id=cfg["school_id"], role=cfg["role"],
        reflection_id=cfg["reflection_id"], username=cfg["username"], password=cfg["password"]
    )
    logging.info("[EXEC] Monitoring tasks=%s with STUDENT_WORKERS=%s ATTACH_WORKERS=%s AI_PARALLEL=%s",
                 cfg["task_ids"], cfg["student_workers"], cfg["attach_workers"], cfg["ai_parallel"])

    state = load_state(cfg["state_path"])

    tasks_meta = api.get_tasks_bulk(cfg["task_ids"])
    for task_id in cfg["task_ids"]:
        if _stop.is_set(): break
        try:
            task = tasks_meta.get(task_id) or api.get_task(task_id)
        except Exception as e:
            logging.error(f"[TASK {task_id}] load failed: {e}")
            continue

        perq, overall_max = scan_question_maxima(task)
        try:
            items = api.get_assignments(task_id) or []
        except Exception as e:
            logging.error(f"[TASK {task_id}] assignments failed: {e}")
            continue

        total = len(items)
        done_cnt = 0
        processed_map = state["processed"].setdefault(str(task_id), {})

        # 任务开场 Telegram
        if tg_enabled(cfg):
            tg_send(cfg, f"📘 <b>Task {task_id}</b> started · total: <b>{total}</b>")

        for idx, asg in enumerate(items, start=1):
            if _stop.is_set(): break
            rid = int(asg.get("receiver_id") or (asg.get("assignee") or {}).get("id") or 0)
            name = ((asg.get("assignee") or {}).get("name") or "").strip() or "?"
            # 跳过已处理（哈希匹配）
            submission = (asg.get("submission") or {})
            content_json = submission.get("content") or ""
            text0 = draftjs_to_text(content_json) if content_json else ""
            attach_ids = []
            files = (submission.get("attachments") or []) + (submission.get("files") or [])
            for f in files:
                fid = f.get("id") or f.get("_id") or f.get("file_id")
                if fid: attach_ids.append(str(fid))

            # 组装可比对的输入 hash
            fingerprint = stable_hash(text0 + "|" + ",".join(sorted(attach_ids)))
            prev = processed_map.get(str(rid))
            if prev and prev.get("hash") == fingerprint and not cfg["score_all_on_start"]:
                done_cnt += 1
                continue

            # 无提交：直接 0 分评语
            if (not text0) and (not attach_ids):
                score = 0.0
                comment = "学生未提交古诗文背默作业，总分0分。"
                ok_flag = True
                if cfg["score_write"] and not cfg["dry_run"]:
                    try:
                        # optional: 写评语
                        api.post_review(receiver_id=rid, task_id=task_id, content=comment)
                    except Exception as e:
                        logging.warning(f"[REVIEW][TASK {task_id}] rid={rid} review fail: {e}")
                    # optional: 写分
                    try:
                        # 若该任务对应 item_id，可在此读取后写分，这里保持与现有逻辑一致（留空实现）
                        pass
                    except Exception as e:
                        logging.warning(f"[SCORE][TASK {task_id}] rid={rid} score write fail: {e}")

                processed_map[str(rid)] = {"hash": fingerprint, "score": score, "comment": comment}
                done_cnt += 1
                logging.info("[DONE][TASK %s] %d/%d rid=%s name=%s score=%.1f comment=%s",
                             task_id, done_cnt, total, rid, name, score, comment)

                if cfg["tg_verbose"]:
                    tg_send(cfg, f"🧑‍🎓 <b>{name}</b> · <code>{rid}</code>\n<b>Score:</b> {score}\n{comment}")
                continue

            # 有文本或附件：抽取文本
            extracted = text0
            if attach_ids:
                for fid in attach_ids:
                    if _stop.is_set(): break
                    try:
                        url = api.get_file_signed_url(fid)
                        if not url: continue
                        blob = api.download(url)
                        if len(blob) > cfg["max_attach"]:
                            if cfg["tg_verbose"]:
                                tg_send(cfg, f"📎 Skip large file for <b>{name}</b> ({len(blob)} bytes)")
                            continue
                        tmp = os.path.join(cfg["workdir"], f"{task_id}_{rid}_{fid}")
                        with open(tmp,"wb") as w: w.write(blob)
                        txt = file_to_text(tmp, ocr_lang=cfg["ocr_lang"], size_cap=cfg["max_attach"])
                        extracted += ("\n\n" + txt)
                    except Exception as e:
                        logging.warning(f"[ATTACH][TASK {task_id}] rid={rid} file {fid} failed: {e}")

            # 调用 AI
            provider = cfg["ai_provider"]
            model = cfg["gemini_model"] if provider=="gemini" else cfg["deepseek_model"]
            key   = cfg["gemini_key"]   if provider=="gemini" else cfg["deepseek_key"]
            client = AIClient(provider=provider, model=model, key=key)
            prompt = build_prompt(cfg, task, asg, extracted, perq, overall_max)
            try:
                j = client.grade(prompt)
                overall = j.get("overall") or {}
                score = float(overall.get("score") or 0.0)
                comment = str(overall.get("comment") or "").strip() or "（无评语）"
            except Exception as e:
                score, comment = 0.0, f"自动评分失败：{e}"

            # 写回评语与分数（按你的策略开关）
            ok_flag = True
            if cfg["score_write"] and not cfg["dry_run"]:
                try:
                    api.post_review(receiver_id=rid, task_id=task_id, content=comment)
                except Exception as e:
                    ok_flag = False
                    logging.warning(f"[REVIEW][TASK {task_id}] rid={rid} review fail: {e}")

                # （如需写 item_score，可在此接入 item_id 逻辑）
                # 留空：保留你现有“任务=背默”的 0 分直给策略

            processed_map[str(rid)] = {"hash": fingerprint, "score": score, "comment": comment}
            done_cnt += 1
            logging.info("[DONE][TASK %s] %d/%d rid=%s name=%s score=%.1f comment=%s",
                         task_id, done_cnt, total, rid, name, score, comment)

            if cfg["tg_verbose"]:
                tg_send(cfg, f"🧑‍🎓 <b>{name}</b> · <code>{rid}</code>\n<b>Score:</b> {score}\n{comment}")

            save_state(cfg["state_path"], state)
            if _stop.is_set(): break

        # 任务汇总
        try:
            all_scores = [v.get("score",0.0) for v in (state["processed"].get(str(task_id)) or {}).values()]
            avg = (sum(all_scores)/len(all_scores)) if all_scores else 0.0
            zero_cnt = sum(1 for s in all_scores if not s)
            msg = f"✅ <b>Task {task_id}</b> done {done_cnt}/{total}\nAvg: {avg:.2f} · Zero: {zero_cnt}"
            logging.info("[SUMMARY][TASK %s] %s", task_id, msg)
            if tg_enabled(cfg): tg_send(cfg, msg)
        except Exception as e:
            logging.warning(f"[SUMMARY][TASK {task_id}] fail: {e}")

        save_state(cfg["state_path"], state)

    # 单轮结束，返回由外层 while 控制节奏
    time.sleep(cfg["interval"])

if __name__ == "__main__":
    setup_logging()
    while True:
        try:
            cfg = load_env()      # ← 每轮开始重读 .env（热加载）
            main_loop(cfg)        # ← 单轮后返回，外层控制 sleep 与重读
            if _stop.is_set(): break
        except KeyboardInterrupt:
            break
        except Exception as e:
            logging.exception("[FATAL] %s", e)
            time.sleep(3)
PY

  # ---------- systemd (Linux) ----------
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=AGrader - Seiue auto-grader
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
Environment=ENV_PATH=${ENV_FILE}
ExecStart=${VENV_DIR}/bin/python ${PY_MAIN}
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SERVICE_PATH"
}

create_venv_and_install() {
  echo "[4/10] Creating venv and installing requirements..."
  python3 -m venv "$VENV_DIR"
  "${VENV_DIR}/bin/pip" install --upgrade pip >/dev/null
  "${VENV_DIR}/bin/pip" install -r "$APP_DIR/requirements.txt"
}

enable_start_linux() {
  echo "[5/10] Writing systemd service (Linux)..."
  systemctl daemon-reload
  echo "[6/10] Stopping existing service if running..."
  systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  echo "[7/10] Enabling and starting..."
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  systemctl start "$SERVICE"
  echo "[8/10] Done. Logs:"
  journalctl -u "$SERVICE" -n 20 --no-pager || true
  echo "Tail: journalctl -u $SERVICE -f"
  echo "[9/10] Edit config anytime: sudo nano $ENV_FILE"
  echo "[10/10] Re-run: sudo systemctl restart $SERVICE"
  cat <<'EOT'

How to stop (graceful):
  sudo systemctl stop agrader.service
Resume:
  sudo systemctl start agrader.service   # 或 restart
EOT
}

main() {
  case "$(os_detect)" in
    linux) install_pkgs_linux ;;
    mac)   install_pkgs_macos ;;
    *)     echo "Unsupported OS"; exit 1 ;;
  esac

  echo "[2/10] Collecting initial configuration..."
  mkdir -p "$APP_DIR" "$APP_DIR/work"
  if [ ! -f "$ENV_FILE" ]; then
    echo "Creating new $ENV_FILE ..."
  else
    echo "Reusing existing $ENV_FILE"
  fi

  # 始终提示 Task IDs
  prompt_task_ids

  write_project
  create_venv_and_install

  if [ "$(os_detect)" = "linux" ]; then
    enable_start_linux
  else
    echo "On macOS: you can run manually -> ${VENV_DIR}/bin/python ${PY_MAIN}"
    echo "Or create a launchd plist at: $LAUNCHD_PLIST (not auto-generated here)."
  fi
}

main "$@"