#!/usr/bin/env bash
# AGrader - API-first auto-grading pipeline (installer/runner) - FULL INLINE EDITION
# Linux: apt/dnf/yum/apk + systemd; macOS: Homebrew + optional launchd
# v1.12.1-fullinline-2025-11-02
#
# What's new vs v1.12.0 (FOCUS: item_id):
# - Robust item_id resolver with TTL cache + signals: score_404, score_422, verify_miss, ttl.
# - Validate cached item_id belongs to task_id; auto re-resolve if stale/mismatch.
# - On score failure (404/422 + mismatch hints), re-resolve item_id and retry once; persists new id.
# - State now records task_item_ts + task_item_hist for traceability.
# - Keep your 422-max parsing & clamp; no unrelated auth changes.

set -euo pipefail

APP_DIR="/opt/agrader"
VENV_DIR="$APP_DIR/venv"
ENV_FILE="$APP_DIR/.env"
SERVICE="agrader.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE}"
LAUNCHD_PLIST="${HOME}/Library/LaunchAgents/net.bdfz.agrader.plist"
PY_MAIN="$APP_DIR/main.py"

# Carry prompt values across
MONITOR_TASK_IDS_PROMPT=""
FULL_SCORE_MODE_PROMPT=""
FULL_SCORE_COMMENT_PROMPT=""

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

set_env_kv() {
  local key="$1"; shift
  local val="$*"
  [ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found"; return 1; }
  # 我們用 '#' 作分隔符，僅需轉義 '&'
  local esc="${val//&/\\&}"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i.bak -E "s#^${key}=.*#${key}=${esc}#" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

install_pkgs_linux() {
  echo "[1/12] Installing system dependencies (Linux)..."
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
  echo "[1/12] Installing system dependencies (macOS/Homebrew)..."
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

  # Logging defaults
  grep -q '^LOG_FORMAT='  "$ENV_FILE" || echo 'LOG_FORMAT=%(asctime)s.%(msecs)03d %(levelname)s %(name)s - %(message)s' >> "$ENV_FILE"
  grep -q '^LOG_DATEFMT=' "$ENV_FILE" || echo 'LOG_DATEFMT=%Y-%m-%d %H:%M:%S' >> "$ENV_FILE"
  grep -q '^LOG_FILE='    "$ENV_FILE" || echo "LOG_FILE=${APP_DIR}/agrader.log" >> "$ENV_FILE"
  grep -q '^LOG_LEVEL='   "$ENV_FILE" || echo 'LOG_LEVEL=INFO' >> "$ENV_FILE"

  # Prompt template
  grep -q '^PROMPT_TEMPLATE_PATH=' "$ENV_FILE" || echo "PROMPT_TEMPLATE_PATH=${APP_DIR}/prompt.txt" >> "$ENV_FILE"

  # Full-score mode defaults
  grep -q '^FULL_SCORE_MODE='     "$ENV_FILE" || echo 'FULL_SCORE_MODE=off' >> "$ENV_FILE"
  grep -q '^FULL_SCORE_COMMENT='  "$ENV_FILE" || echo 'FULL_SCORE_COMMENT=記得看高考真題。' >> "$ENV_FILE"

  # Canonical endpoints
  if grep -q '^SEIUE_SCORE_ENDPOINTS=' "$ENV_FILE"; then
    sed -i.bak -E 's#^SEIUE_SCORE_ENDPOINTS=.*#SEIUE_SCORE_ENDPOINTS=POST:/vnas/klass/items/{item_id}/scores/sync?async=true\&from_task=true:array#' "$ENV_FILE" || true
  else
    echo 'SEIUE_SCORE_ENDPOINTS=POST:/vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true:array' >> "$ENV_FILE"
  fi
  grep -q '^SEIUE_REVIEW_POST_TEMPLATE=' "$ENV_FILE" || \
    echo 'SEIUE_REVIEW_POST_TEMPLATE=/chalk/task/v2/assignees/{receiver_id}/tasks/{task_id}/reviews' >> "$ENV_FILE"
  grep -q '^SEIUE_VERIFY_SCORE_GET_TEMPLATE=' "$ENV_FILE" || \
    echo 'SEIUE_VERIFY_SCORE_GET_TEMPLATE=/vnas/common/items/{item_id}/scores?paginated=0&type=item_score' >> "$ENV_FILE"

  # Strategy / concurrency defaults
  grep -q '^DRY_RUN='                 "$ENV_FILE" || echo 'DRY_RUN=0'                  >> "$ENV_FILE"
  grep -q '^VERIFY_AFTER_WRITE='      "$ENV_FILE" || echo 'VERIFY_AFTER_WRITE=1'       >> "$ENV_FILE"
  grep -q '^REVERIFY_BEFORE_WRITE='   "$ENV_FILE" || echo 'REVERIFY_BEFORE_WRITE=1'    >> "$ENV_FILE"
  grep -q '^RETRY_ON_422_ONCE='       "$ENV_FILE" || echo 'RETRY_ON_422_ONCE=1'        >> "$ENV_FILE"
  grep -q '^STUDENT_WORKERS='         "$ENV_FILE" || echo 'STUDENT_WORKERS=1'          >> "$ENV_FILE"
  grep -q '^ATTACH_WORKERS='          "$ENV_FILE" || echo 'ATTACH_WORKERS=3'           >> "$ENV_FILE"
  grep -q '^AI_PARALLEL='             "$ENV_FILE" || echo 'AI_PARALLEL=1'              >> "$ENV_FILE"
  grep -q '^AI_MAX_RETRIES='          "$ENV_FILE" || echo 'AI_MAX_RETRIES=5'           >> "$ENV_FILE"
  grep -q '^AI_BACKOFF_BASE_SECONDS=' "$ENV_FILE" || echo 'AI_BACKOFF_BASE_SECONDS=2.5'>> "$ENV_FILE"
  grep -q '^AI_JITTER_SECONDS='       "$ENV_FILE" || echo 'AI_JITTER_SECONDS=0.8'      >> "$ENV_FILE"
  grep -q '^AI_FAILOVER='             "$ENV_FILE" || echo 'AI_FAILOVER=1'              >> "$ENV_FILE"
  grep -q '^MAX_ATTACHMENT_BYTES='    "$ENV_FILE" || echo 'MAX_ATTACHMENT_BYTES=25165824' >> "$ENV_FILE"
  grep -q '^OCR_LANG='                "$ENV_FILE" || echo 'OCR_LANG=chi_sim+eng'       >> "$ENV_FILE"

  # New scoring safeguards
  grep -q '^MAX_SCORE_CACHE_TTL='     "$ENV_FILE" || echo 'MAX_SCORE_CACHE_TTL=600'    >> "$ENV_FILE"
  grep -q '^SCORE_CLAMP_ON_MAX='      "$ENV_FILE" || echo 'SCORE_CLAMP_ON_MAX=1'       >> "$ENV_FILE"

  # AI keys strategy
  grep -q '^AI_KEY_STRATEGY='         "$ENV_FILE" || echo 'AI_KEY_STRATEGY=roundrobin' >> "$ENV_FILE"
  grep -q '^GEMINI_API_KEYS='         "$ENV_FILE" || echo 'GEMINI_API_KEYS='           >> "$ENV_FILE"
  grep -q '^DEEPSEEK_API_KEYS='       "$ENV_FILE" || echo 'DEEPSEEK_API_KEYS='         >> "$ENV_FILE"

  # Run mode & stop criteria
  grep -q '^RUN_MODE='        "$ENV_FILE" || echo 'RUN_MODE=watch' >> "$ENV_FILE"
  grep -q '^STOP_CRITERIA='   "$ENV_FILE" || echo 'STOP_CRITERIA=score_and_review' >> "$ENV_FILE"

  # --- item_id refresh strategy (NEW) ---
  grep -q '^ITEM_ID_REFRESH_ON=' "$ENV_FILE" || echo 'ITEM_ID_REFRESH_ON=score_404,score_422,verify_miss,ttl' >> "$ENV_FILE"
  grep -q '^ITEM_ID_CACHE_TTL='  "$ENV_FILE" || echo 'ITEM_ID_CACHE_TTL=900' >> "$ENV_FILE"
}

prompt_task_ids() {
  echo "[3/12] Configure Task IDs..."
  local cur=""
  if [ -f "$ENV_FILE" ]; then
    cur="$(grep -E '^MONITOR_TASK_IDS=' "$ENV_FILE" | cut -d= -f2- || true)"
  fi
  echo "Enter Task IDs (comma-separated), or paste URLs that contain /tasks/<id>."
  local ans norm
  while :; do
    read -r -p "Task IDs [${cur:-none}]: " ans || true
    ans="${ans:-$cur}"
    norm="$(
      printf "%s\n" "$ans" \
      | tr ' ,;' '\n\n\n' \
      | sed -E 's#.*(/tasks/([0-9]+)).*#\2#; t; s#[^0-9]##g' \
      | awk 'length>0' \
      | paste -sd, - \
      | sed -E 's#,+#,#g; s#^,##; s#,$##'
    )"
    if [ -n "$norm" ]; then
      MONITOR_TASK_IDS_PROMPT="$norm"
      set_env_kv "MONITOR_TASK_IDS" "$norm"
      echo "→ MONITOR_TASK_IDS=${norm}"
      break
    fi
    echo "Empty. Please enter at least one ID."
  done
}

prompt_mode() {
  echo "[4/12] Choose grading mode for these tasks:"
  echo "  1) Full score to every student (review: 記得看高考真題。)"
  echo "  2) Normal grading workflow"
  local sel; read -r -p "Select 1 or 2 [2]: " sel || true
  sel="${sel:-2}"
  if [ "$sel" = "1" ]; then
    local cmt; read -r -p "Full-score review comment [記得看高考真題。]: " cmt || true
    cmt="${cmt:-記得看高考真題。}"
    FULL_SCORE_MODE_PROMPT="all"
    FULL_SCORE_COMMENT_PROMPT="$cmt"
    set_env_kv "FULL_SCORE_MODE" "all"
    set_env_kv "FULL_SCORE_COMMENT" "$cmt"
    echo "→ FULL_SCORE_MODE=all"
    echo "→ FULL_SCORE_COMMENT=$cmt"
  else
    FULL_SCORE_MODE_PROMPT="off"
    set_env_kv "FULL_SCORE_MODE" "off"
    echo "→ FULL_SCORE_MODE=off"
  fi
}

write_project() {
  local IS_FRESH_INSTALL="${1:-0}"
  echo "[5/12] Writing project files..."
  mkdir -p "$APP_DIR" "$APP_DIR/work"

  local _TASKS="${MONITOR_TASK_IDS_PROMPT}"
  local _FSMODE="${FULL_SCORE_MODE_PROMPT}"
  local _FSCMT="${FULL_SCORE_COMMENT_PROMPT}"
  [ -z "$_TASKS" ] && _TASKS="$(grep -E '^MONITOR_TASK_IDS=' "$ENV_FILE" | cut -d= -f2- || true)"
  [ -z "$_FSMODE" ] && _FSMODE="$(grep -E '^FULL_SCORE_MODE=' "$ENV_FILE" | cut -d= -f2- || echo off)"
  [ -z "$_FSCMT" ] && _FSCMT="$(grep -E '^FULL_SCORE_COMMENT=' "$ENV_FILE" | cut -d= -f2- || echo 記得看高考真題。)"

  if [ "$IS_FRESH_INSTALL" -eq 1 ]; then
    echo "Fresh install — collecting credentials and defaults..."
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

    # Run mode and stop criteria
    ask "RUN_MODE (oneshot/watch)" RUN_MODE "watch"
    ask "STOP_CRITERIA (score|review|score_and_review)" STOP_CRITERIA "score_and_review"

    cat > "$ENV_FILE" <<EOF
# ---- Seiue ----
SEIUE_BASE=${SEIUE_BASE}
SEIUE_USERNAME=${SEIUE_USERNAME}
SEIUE_PASSWORD=${SEIUE_PASSWORD}
SEIUE_BEARER=${SEIUE_BEARER}
SEIUE_SCHOOL_ID=${SEIUE_SCHOOL_ID}
SEIUE_ROLE=${SEIUE_ROLE}
SEIUE_REFLECTION_ID=${SEIUE_REFLECTION_ID}
MONITOR_TASK_IDS=${_TASKS}
POLL_INTERVAL=${POLL_INTERVAL}

# ---- Endpoints ----
SEIUE_REVIEW_POST_TEMPLATE=/chalk/task/v2/assignees/{receiver_id}/tasks/{task_id}/reviews
SEIUE_SCORE_ENDPOINTS=POST:/vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true:array
SEIUE_VERIFY_SCORE_GET_TEMPLATE=/vnas/common/items/{item_id}/scores?paginated=0&type=item_score

# ---- AI ----
AI_PROVIDER=${AI_PROVIDER}
GEMINI_API_KEYS=
GEMINI_API_KEY=${GEMINI_API_KEY}
GEMINI_MODEL=${GEMINI_MODEL}
DEEPSEEK_API_KEYS=
DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY}
DEEPSEEK_MODEL=${DEEPSEEK_MODEL}
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

# ---- Extractor & limits ----
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
REVERIFY_BEFORE_WRITE=1
RETRY_ON_422_ONCE=1
STUDENT_WORKERS=1
ATTACH_WORKERS=3

# ---- Prompt template ----
PROMPT_TEMPLATE_PATH=${APP_DIR}/prompt.txt

# ---- Full-score mode ----
FULL_SCORE_MODE=${_FSMODE:-off}
FULL_SCORE_COMMENT=${_FSCMT:-記得看高考真題。}

# ---- Safeguards ----
MAX_SCORE_CACHE_TTL=600
SCORE_CLAMP_ON_MAX=1

# ---- Run & Stop ----
RUN_MODE=${RUN_MODE}
STOP_CRITERIA=${STOP_CRITERIA}

# ---- item_id refresh ----
ITEM_ID_REFRESH_ON=score_404,score_422,verify_miss,ttl
ITEM_ID_CACHE_TTL=900

# ---- Paths/State ----
STATE_PATH=${APP_DIR}/state.json
WORKDIR=${APP_DIR}/work
EOF
    chmod 600 "$ENV_FILE"
  else
    echo "Reusing existing $ENV_FILE"
  fi

  ensure_env_patch

  # requirements
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

  # prompt.txt
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

  # ----------------- Python files -----------------
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
    overall_max = 0.0
    perq: List[Dict[str, Any]] = []
    candidates = []
    for k in ["score_items","questions","problems","rubric","grading","grading_items"]:
      v = task.get(k) or task.get("custom_fields", {}).get(k)
      if isinstance(v, list) and v:
        candidates = v; break
    if candidates:
        for idx, it in enumerate(candidates):
            qid = str(it.get("id", f"q{idx+1}"))
            mx = it.get("max") or it.get("max_score") or it.get("full") or 0
            try: mx = float(mx)
            except: mx = 0.0
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
    s.headers.update({"User-Agent": "AGrader/1.12 (+login)","Accept": "application/json, text/plain, */*"})
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

  cat > "$APP_DIR/extractor.py" <<'PY'
import os, subprocess, mimetypes, logging
from typing import Tuple
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
        delay = min(base * (i + 1), 8)
        time.sleep(delay + random.uniform(0, jitter))

def _split_keys(s: str) -> List[str]:
    if not s: return []
    return [x.strip() for x in s.split(",") if x.strip()]

class AIClient:
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

    def _key_order(self, n: int):
        if n <= 0: return []
        if self.strategy == "random":
            idxs = list(range(n)); random.shuffle(idxs); return idxs
        return list(range(self._rr, n)) + list(range(0, self._rr))

    def _advance_rr(self, used_idx):
        if self.strategy == "roundrobin" and self.keys:
            self._rr = (used_idx + 1) % len(self.keys)

    def grade(self, prompt: str) -> dict:
        raw = self._call_llm(prompt)
        return self.parse_or_repair(raw, original_prompt=prompt)

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

    def repair_json(self, original_prompt: str, bad_text: str) -> str:
        to_fix = (bad_text or "").strip()
        fixed = self._repair_with_provider(self.provider, self.model, self.keys, to_fix)
        if fixed: return fixed
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

  cat > "$APP_DIR/seiue_api.py" <<'PY'
import os, logging, requests, threading, re, time
from typing import Dict, Any, List, Union, Optional, Tuple
from credentials import login, AuthResult
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

_login_lock = threading.Lock()

def _session_with_retries() -> requests.Session:
    s = requests.Session()
    r = Retry(total=5, backoff_factor=1.5, status_forcelist=(429,500,502,503,504), allowed_methods=frozenset({"GET","POST","PUT"}))
    s.mount("https://", HTTPAdapter(max_retries=r))
    s.headers.update({"Accept":"application/json, text/plain, */*","User-Agent":"AGrader/1.12"})
    return s

def _flatten_find_item_ids(obj: Union[Dict[str,Any], List[Any]]) -> List[int]:
    found: List[int] = []
    def walk(x):
        if isinstance(x, dict):
            # direct id only when object looks like klass/common item with related_data
            if "related_data" in x and "id" in x:
                try:
                    iv = int(x.get("id") or 0)
                    if iv>0: found.append(iv)
                except Exception:
                    pass
            for k,v in x.items():
                lk = str(k).lower()
                if lk.endswith("item_id") or lk.endswith("klass_item_id"):
                    try:
                        iv = int(v); 
                        if iv>0: found.append(iv)
                    except Exception:
                        pass
                walk(v)
        elif isinstance(x, list):
            for y in x: walk(y)
    walk(obj)
    # dedup keep order
    out=[]; seen=set()
    for i in found:
        if i not in seen:
            out.append(i); seen.add(i)
    return out

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
        # NOTE: keep minimal; your focus is item_id, not 401/403 logic
        r = request_fn()
        if getattr(r,"status_code",None) in (401,403):
            # single re-auth attempt
            if self._login_and_apply(): return request_fn()
        return r

    # -------- Task / Assignments --------
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

    # -------- Item detail / scoring --------
    def get_item_detail(self, item_id: int):
        # include related_data to verify task linkage
        url = self._url(f"/vnas/klass/items/{item_id}?expand=related_data%2Cassessment%2Cassessment_stage%2Cstage")
        r = self._with_refresh(lambda: self.session.get(url, timeout=30))
        if r.status_code >= 400: logging.error(f"[API] get_item_detail {r.status_code}: {(r.text or '')[:300]}"); r.raise_for_status()
        return r.json()

    def get_item_max_score(self, item_id: int) -> Optional[float]:
        try:
            d = self.get_item_detail(item_id) or {}
            for k in ("full_score","max_score","score_upper","full","max"):
                v = d.get(k)
                if v is not None:
                    try: return float(v)
                    except: pass
            for arrk in ("score_items","scoring_items","rules"):
                arr = d.get(arrk)
                if isinstance(arr, list) and arr:
                    tot = 0.0
                    for it in arr:
                        mx = it.get("full") or it.get("max") or it.get("max_score")
                        try: tot += float(mx or 0)
                        except: pass
                    if tot > 0: return tot
            asses = d.get("assessment") or {}
            for k in ("total_item_score","full_score","max_score"):
                v = asses.get(k)
                if v is not None:
                    try: return float(v)
                    except: pass
        except Exception as e:
            logging.debug(f"[ITEM] get_item_max_score fail: {e}")
        return None

    def verify_existing_score(self, item_id: int, owner_id: int) -> Optional[float]:
        path_tmpl = os.getenv("SEIUE_VERIFY_SCORE_GET_TEMPLATE","/vnas/common/items/{item_id}/scores?paginated=0&type=item_score")
        path = path_tmpl.format(item_id=item_id)
        url = self._url(path)
        r = self._with_refresh(lambda: self.session.get(url, timeout=30))
        if r.status_code >= 400:
            return None
        try:
            data = r.json()
            rows = data if isinstance(data,list) else (data.get("data") or data.get("items") or [])
            for row in rows:
                try:
                    if int(row.get("owner_id") or 0) == int(owner_id):
                        v = row.get("score")
                        return float(v) if v is not None else None
                except Exception:
                    continue
        except Exception:
            return None
        return None

    def parse_max_from_422(self, text: str) -> Optional[float]:
        if not text: return None
        m = re.search(r"满分\s*([0-9]+(?:\.[0-9]+)?)", text)
        if m:
            try: return float(m.group(1))
            except: pass
        m2 = re.search(r"(?:max(?:imum)?|<=)\s*([0-9]+(?:\.[0-9]+)?)", text, re.I)
        if m2:
            try: return float(m2.group(1))
            except: pass
        return None

    def _err_implies_item_mismatch(self, code:int, txt:str) -> bool:
        if code in (404,):
            return True
        if code == 422:
            hint = (txt or "").lower()
            for kw in ["不存在","已删除","不匹配","不属于","mismatch","not found","deleted","invalid item","belongs to another task"]:
                if kw in hint:
                    return True
        return False

    def is_item_valid_for_task(self, item_id:int, task_id:int) -> bool:
        try:
            d = self.get_item_detail(item_id) or {}
            rel = d.get("related_data") or {}
            tid = rel.get("task_id") or rel.get("task")
            if tid is None: 
                # Some deployments embed relation under "assessment" custom fields; fallback best-effort accept
                return True
            return int(tid) == int(task_id)
        except Exception:
            return False

    def resolve_item_id_candidates(self, task_id:int) -> List[int]:
        cands: List[int] = []
        try:
            t = self.get_task(task_id)
            cands += _flatten_find_item_ids(t)
        except Exception: pass
        try:
            assigns = self.get_assignments(task_id)
            cands += _flatten_find_item_ids(assigns)
        except Exception: pass

        cand_paths = [
            f"/vnas/klass/items?related_data.task_id={task_id}",
            f"/vnas/klass/items?related_data%5Btask_id%5D={task_id}",
            f"/vnas/common/items?related_data.task_id={task_id}",
            f"/vnas/common/items?related_data%5Btask_id%5D={task_id}",
            f"/vnas/klass/items?task_id={task_id}",
            f"/vnas/common/items?task_id={task_id}",
        ]
        for p in cand_paths:
            try:
                url = self._url(p)
                r = self._with_refresh(lambda: self.session.get(url, timeout=30))
                if r.status_code >= 400:
                    continue
                data = r.json()
                rows: List[Dict[str,Any]] = []
                if isinstance(data, list):
                    rows = data
                elif isinstance(data, dict):
                    rows = data.get("data") or data.get("items") or []
                for row in rows:
                    iid = int(row.get("id") or row.get("_id") or 0)
                    if iid <= 0: continue
                    rel = row.get("related_data") or {}
                    rel_tid = rel.get("task_id") or rel.get("task") or None
                    try:
                        if rel_tid is not None and int(rel_tid) != int(task_id):
                            continue
                    except Exception:
                        pass
                    cands.append(iid)
            except Exception:
                continue
        # dedup keep order
        out=[]; seen=set()
        for i in cands:
            if i not in seen:
                out.append(i); seen.add(i)
        return out

    def resolve_item_id(self, task_id: int) -> int:
        cands = self.resolve_item_id_candidates(task_id)
        if not cands:
            logging.error("[ITEM] Unable to resolve item_id for task %s", task_id); return 0
        # prefer the first candidate that validates
        for iid in cands:
            if self.is_item_valid_for_task(iid, task_id):
                logging.info("[ITEM] task %s -> item_id=%s (validated)", task_id, iid)
                return iid
        logging.info("[ITEM] task %s -> fallback item_id=%s (unvalidated)", task_id, cands[0])
        return cands[0]

    def post_review(self, receiver_id: int, task_id: int, content: str) -> bool:
        path_tmpl = os.getenv("SEIUE_REVIEW_POST_TEMPLATE","/chalk/task/v2/assignees/{receiver_id}/tasks/{task_id}/reviews")
        path = path_tmpl.format(receiver_id=receiver_id, task_id=task_id)
        url  = self._url(path)
        payload = {
            "result": "approved",
            "content": content,
            "reason": "",
            "attachments": [],
            "do_evaluation": False,
            "is_excellent_submission": False,
            "is_submission_changed": True,
        }
        r = self._with_refresh(lambda: self.session.post(url, json=payload, timeout=60))
        if 200 <= r.status_code < 300:
            logging.info(f"[API] Review posted for rid={receiver_id} task={task_id}")
            return True
        else:
            logging.warning(f"[API] Review failed: POST {path} -> {r.status_code} :: {(r.text or '')[:200]}")
            return False

    def post_item_score(self, item_id: int, owner_id: int, task_id: int, score: float, review: str = "") -> Tuple[bool,int,str]:
        path = f"/vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true"
        url  = self._url(path)
        payload = [{
            "owner_id": int(owner_id),
            "valid": True,
            "score": str(score),
            "review": review,
            "attachments": [],
            "related_data": {"task_id": int(task_id)},
            "type": "item_score",
            "status": "published"
        }]
        r = self._with_refresh(lambda: self.session.post(url, json=payload, timeout=60))
        txt = r.text or ""
        if 200 <= r.status_code < 300:
            return True, r.status_code, txt
        if r.status_code == 422 and ("分数已经存在" in txt or "already exists" in txt):
            return True, r.status_code, txt
        if r.status_code >= 400:
            logging.warning(f"[API] score failed: POST {path} -> {r.status_code} :: {txt[:200]}")
            return False, r.status_code, txt
        return False, r.status_code, txt

    def post_item_score_resilient(self, item_id:int, owner_id:int, task_id:int, score:float, review:str, allow_refresh:bool) -> Tuple[bool,int,str,int]:
        ok, code, txt = self.post_item_score(item_id=item_id, owner_id=owner_id, task_id=task_id, score=score, review=review)
        if ok or not allow_refresh:
            return ok, code, txt, item_id
        if self._err_implies_item_mismatch(code, txt):
            logging.warning("[ITEM] score error implies mismatch (code=%s). Re-resolving item_id for task %s ...", code, task_id)
            new_iid = self.resolve_item_id(task_id)
            if new_iid and new_iid != item_id:
                ok2, code2, txt2 = self.post_item_score(item_id=new_iid, owner_id=owner_id, task_id=task_id, score=score, review=review)
                return ok2, code2, txt2, new_iid
        return ok, code, txt, item_id
PY

  cat > "$APP_DIR/main.py" <<'PY'
import os, json, time, logging, re, threading, signal, sys
from typing import Dict, Any, List, Tuple, Optional
from dotenv import load_dotenv
from utilx import draftjs_to_text, scan_question_maxima, stable_hash, clamp
from extractor import file_to_text
from ai_providers import AIClient
from seiue_api import Seiue

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

def _parse_task_ids(raw: str) -> List[int]:
    if not raw: return []
    out: List[int] = []
    for seg in [s.strip() for s in raw.split(",") if s.strip()]:
        m = re.search(r"/tasks/(\d+)", seg)
        if m: out.append(int(m.group(1))); continue
        m2 = re.search(r"\b(\d{4,})\b", seg)
        if m2: out.append(int(m2.group(1)))
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
        "score_write": True,
        "review_all_existing": True,
        "score_all_on_start": True,
        "dry_run": as_bool(get("DRY_RUN","0"), False),
        "verify_after": as_bool(get("VERIFY_AFTER_WRITE","1")),
        "reverify_before": as_bool(get("REVERIFY_BEFORE_WRITE","1")),
        "retry_422_once": as_bool(get("RETRY_ON_422_ONCE","1")),
        "clamp_on_max": as_bool(get("SCORE_CLAMP_ON_MAX","1")),
        "max_cache_ttl": int(get("MAX_SCORE_CACHE_TTL","600") or "600"),
        "student_workers": int(get("STUDENT_WORKERS","1") or "1"),
        "attach_workers": int(get("ATTACH_WORKERS","3") or "3"),
        "ai_failover": as_bool(get("AI_FAILOVER","1")),
        "log_level": get("LOG_LEVEL","INFO"),
        "ai_strategy": get("AI_KEY_STRATEGY","roundrobin"),
        "prompt_path": get("PROMPT_TEMPLATE_PATH","/opt/agrader/prompt.txt"),
        "full_score_mode": (get("FULL_SCORE_MODE","off") or "off").lower(),
        "full_score_comment": get("FULL_SCORE_COMMENT","記得看高考真題。"),
        "run_mode": (get("RUN_MODE","watch") or "watch").lower(),
        "stop_criteria": (get("STOP_CRITERIA","score_and_review") or "score_and_review").lower(),
        "iid_refresh_on": (get("ITEM_ID_REFRESH_ON","score_404,score_422,verify_miss,ttl") or "").lower(),
        "iid_ttl": int(get("ITEM_ID_CACHE_TTL","900") or "900"),
    }

def load_state(path: str) -> Dict[str, Any]:
    try:
        with open(path,"r") as f: data = json.load(f)
        data.setdefault("processed", {})
        data.setdefault("failed", [])
        data.setdefault("reported_complete", {})
        data.setdefault("task_item", {})
        data.setdefault("task_item_ts", {})
        data.setdefault("task_item_hist", {})
        return data
    except Exception:
        return {"processed": {}, "failed": [], "reported_complete": {}, "task_item": {}, "task_item_ts": {}, "task_item_hist": {}}

def save_state(path: str, st: Dict[str, Any]):
    tmp = path + ".tmp"
    with open(tmp,"w",encoding="utf-8") as f: json.dump(st, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)

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

def meets_stop_criteria(entry: Dict[str,Any], criteria: str) -> bool:
    r_ok = bool(entry.get("review_ok"))
    s_ok = bool(entry.get("score_ok"))
    c = (criteria or "score_and_review").lower()
    if c in ("both","score_and_review","review_and_score"): return r_ok and s_ok
    if c in ("score","score_only"): return s_ok
    if c in ("review","review_only"): return r_ok
    return r_ok and s_ok

_stop = threading.Event()
def _sigterm(_s,_f):
    logging.info("[EXEC] Caught signal; graceful shutdown...")
    _stop.set()
signal.signal(signal.SIGTERM, _sigterm)
signal.signal(signal.SIGINT, _sigterm)

_item_max_cache: Dict[int, Tuple[float, float]] = {}  # item_id -> (value, ts)

def _get_item_max(api: Seiue, task: dict, item_id: int, fallback: float, ttl: int) -> float:
    now = time.time()
    if item_id > 0:
        if item_id in _item_max_cache:
            v, ts = _item_max_cache[item_id]
            if now - ts < ttl:
                return v
    ms = None
    if item_id > 0:
        ms = api.get_item_max_score(item_id)
    if ms is None or ms <= 0:
        if fallback and fallback > 0:
            ms = float(fallback)
        else:
            ms = 100.0
    _item_max_cache[item_id] = (float(ms), now)
    return float(ms)

def _is_task_complete(state: dict, task_id: int, total_assignments: int, criteria: str) -> bool:
    if total_assignments == 0:
        return False
    processed_map = state.get("processed", {}).get(str(task_id), {})
    ok_count = 0
    for _rid, entry in processed_map.items():
        if entry.get("status") == "ok" and meets_stop_criteria(entry, criteria):
            ok_count += 1
    return ok_count >= total_assignments

def _iid_should_refresh(cfg, signal_type:str) -> bool:
    on = (cfg.get("iid_refresh_on") or "").split(",")
    on = [x.strip() for x in on if x.strip()]
    return signal_type in on

def _ensure_valid_item_id(cfg, api:Seiue, state:dict, task_id:int) -> int:
    now = time.time()
    cached_iid = int(state["task_item"].get(str(task_id) or "0") or 0)
    last_ts = float(state["task_item_ts"].get(str(task_id) or "0") or 0.0)
    need_validate = False
    if cached_iid <= 0:
        need_validate = True
    elif _iid_should_refresh(cfg,"ttl") and (now - last_ts >= cfg["iid_ttl"]):
        need_validate = True

    if not need_validate and cached_iid>0:
        # quick linkage check
        try:
            if not api.is_item_valid_for_task(cached_iid, task_id):
                need_validate = True
                logging.warning("[ITEM] Cached item_id %s no longer valid for task %s, will re-resolve.", cached_iid, task_id)
        except Exception:
            need_validate = True

    if need_validate:
        iid = api.resolve_item_id(task_id)
        if iid>0:
            state["task_item"][str(task_id)] = iid
            state["task_item_ts"][str(task_id)] = now
            hist = state["task_item_hist"].setdefault(str(task_id), [])
            if not hist or hist[-1] != iid:
                hist.append(iid)
            save_state(cfg["state_path"], state)
            return iid
        else:
            return cached_iid
    return cached_iid

def main_pass(cfg: Dict[str,Any]):
    if not cfg["task_ids"]:
        logging.warning("[EXEC] No MONITOR_TASK_IDS configured.")
        return

    api = Seiue(
        base=cfg["base"], bearer=cfg["bearer"], school_id=cfg["school_id"], role=cfg["role"],
        reflection_id=cfg["reflection_id"], username=cfg["username"], password=cfg["password"]
    )
    logging.info("[EXEC] Monitoring tasks=%s (run_mode=%s, stop=%s, dry_run=%s)", cfg["task_ids"], cfg["run_mode"], cfg["stop_criteria"], cfg["dry_run"])

    state = load_state(cfg["state_path"])
    all_tasks_assignments = {}

    try:
        os.makedirs(cfg["workdir"], exist_ok=True)
    except Exception as e:
        logging.warning(f"[WORKDIR] cannot create {cfg['workdir']}: {e}")

    tasks_meta = api.get_tasks_bulk(cfg["task_ids"])
    for task_id in cfg["task_ids"]:
        if _stop.is_set(): break
        try:
            task = tasks_meta.get(task_id) or api.get_task(task_id)
        except Exception as e:
            logging.error(f"[TASK {task_id}] load failed: {e}")
            continue

        perq, overall_max_from_task = scan_question_maxima(task)
        try:
            items = api.get_assignments(task_id) or []
            all_tasks_assignments[task_id] = items
        except Exception as e:
            logging.error(f"[TASK {task_id}] assignments failed: {e}")
            continue

        total = len(items)
        if _is_task_complete(state, task_id, total, cfg["stop_criteria"]):
            logging.info(f"[TASK {task_id}] already complete ({total} students, criteria={cfg['stop_criteria']}). Skipping.")
            continue

        iid = _ensure_valid_item_id(cfg, api, state, task_id)
        if iid<=0:
            logging.error("[TASK %s] item_id unresolved; will still send reviews but skip scores this round.", task_id)

        success_cnt = 0
        processed_map = state["processed"].setdefault(str(task_id), {})

        if tg_enabled(cfg):
            tg_send(cfg, f"📘 <b>Task {task_id}</b> started · total: <b>{total}</b> · stop=<code>{cfg['stop_criteria']}</code>")

        # -------- FULL MODE --------
        if (cfg.get("full_score_mode") or "off") == "all":
            max_score = _get_item_max(api, task, iid, overall_max_from_task, cfg["max_cache_ttl"])
            review_comment = cfg.get("full_score_comment") or "記得看高考真題。"
            for idx, asg in enumerate(items, start=1):
                if _stop.is_set(): break
                rid = int(asg.get("receiver_id") or (asg.get("assignee") or {}).get("id") or 0)
                name = ((asg.get("assignee") or {}).get("name") or "").strip() or "?"

                entry = {"review_ok": False, "score_ok": False, "score": None, "comment": review_comment, "hash": None}

                # Review
                if not cfg["dry_run"]:
                    try:
                        entry["review_ok"] = api.post_review(receiver_id=rid, task_id=task_id, content=review_comment)
                    except Exception as e:
                        logging.warning(f"[REVIEW][TASK {task_id}] rid={rid} review post failed: {e}", exc_info=True)
                else:
                    entry["review_ok"] = False

                desired = float(max_score)

                # pre-verify existing score
                if cfg["reverify_before"] and iid > 0 and not cfg["dry_run"]:
                    try:
                        exist = api.verify_existing_score(iid, rid)
                        if exist is not None:
                            entry["score_ok"] = True
                            entry["score"] = float(exist)
                            processed_map[str(rid)] = {"status": "ok" if meets_stop_criteria(entry, cfg["stop_criteria"]) else "partial", **entry}
                            success_cnt += 1 if processed_map[str(rid)]["status"]=="ok" else 0
                            logging.info("[FULL][OK*existing][TASK %s] %d/%d rid=%s name=%s (already exists: %.2f)", task_id, idx, total, rid, name, exist)
                            save_state(cfg["state_path"], state)
                            continue
                        else:
                            if _iid_should_refresh(cfg,"verify_miss"):
                                new_iid = _ensure_valid_item_id(cfg, api, state, task_id)
                                if new_iid != iid and new_iid>0:
                                    iid = new_iid
                                    max_score = _get_item_max(api, task, iid, overall_max_from_task, cfg["max_cache_ttl"])
                    except Exception:
                        pass

                wrote = False
                if iid > 0:
                    if cfg["dry_run"]:
                        wrote = False
                    else:
                        allow_refresh = _iid_should_refresh(cfg,"score_404") or _iid_should_refresh(cfg,"score_422")
                        ok, code, txt, new_iid = api.post_item_score_resilient(item_id=iid, owner_id=rid, task_id=task_id, score=desired, review=review_comment, allow_refresh=allow_refresh)
                        if new_iid != iid and new_iid>0:
                            iid = new_iid
                            state["task_item"][str(task_id)] = iid
                            state["task_item_ts"][str(task_id)] = time.time()
                            hist = state["task_item_hist"].setdefault(str(task_id), [])
                            if not hist or hist[-1] != iid: hist.append(iid)
                            save_state(cfg["state_path"], state)
                        if not ok and code == 422 and cfg["retry_422_once"]:
                            parsed = api.parse_max_from_422(txt)
                            if parsed and parsed > 0:
                                desired = min(desired, parsed)
                                ok2, code2, txt2, _ = api.post_item_score_resilient(item_id=iid, owner_id=rid, task_id=task_id, score=desired, review=review_comment, allow_refresh=False)
                                wrote = ok2
                            else:
                                wrote = False
                        else:
                            wrote = ok
                else:
                    logging.error(f"[SCORE][TASK {task_id}] rid={rid} skipped (item_id unresolved)")

                if wrote:
                    entry["score_ok"] = True
                    entry["score"] = desired
                    status = "ok" if meets_stop_criteria(entry, cfg["stop_criteria"]) else "partial"
                    processed_map[str(rid)] = {"status": status, **entry}
                    success_cnt += 1 if status=="ok" else 0
                    logging.info("[FULL][DONE][TASK %s] %d/%d rid=%s name=%s score=%.2f status=%s", task_id, idx, total, rid, name, desired, status)
                    if tg_enabled(cfg) and cfg["tg_verbose"] and status=="ok":
                        tg_send(cfg, f"🧑‍🎓 <b>{name}</b> · <code>{rid}</code>\n<b>Score:</b> {desired}\n{review_comment}")
                else:
                    status = "dryrun" if cfg["dry_run"] else "fail"
                    processed_map[str(rid)] = {"status": status, **entry, "score_wanted": desired}
                    logging.info("[FULL][%s][TASK %s] %d/%d rid=%s name=%s score_wanted=%.2f", status.upper(), task_id, idx, total, rid, name, desired)

                save_state(cfg["state_path"], state)

            try:
                msg = f"✅ <b>Task {task_id}</b> FULL-SCORED (ok per stop={cfg['stop_criteria']}): <b>{success_cnt}</b> / {total}"
                logging.info("[SUMMARY][TASK %s] %s", task_id, msg)
                if tg_enabled(cfg): tg_send(cfg, msg)
            except Exception as e:
                logging.warning(f"[SUMMARY][TASK {task_id}] fail: {e}")
            continue

        # -------- NORMAL MODE --------
        for idx, asg in enumerate(items, start=1):
            if _stop.is_set(): break
            rid = int(asg.get("receiver_id") or (asg.get("assignee") or {}).get("id") or 0)
            name = ((asg.get("assignee") or {}).get("name") or "").strip() or "?"
            submission = (asg.get("submission") or {})
            content_json = submission.get("content") or ""
            text0 = draftjs_to_text(content_json) if content_json else ""
            attach_ids = []
            files = (submission.get("attachments") or []) + (submission.get("files") or [])
            for f in files:
                fid = f.get("id") or f.get("_id") or f.get("file_id")
                if fid: attach_ids.append(str(fid))

            fingerprint = stable_hash(text0 + "|" + ",".join(sorted(attach_ids)))

            prev = processed_map.get(str(rid))
            if prev and prev.get("status") == "ok" and prev.get("hash") == fingerprint and meets_stop_criteria(prev, cfg["stop_criteria"]):
                logging.debug("[SKIP][TASK %s] %d/%d rid=%s (no change)", task_id, idx, total, rid)
                success_cnt += 1
                continue

            extracted = text0
            entry = {"review_ok": False, "score_ok": False, "hash": fingerprint, "score": None, "comment": None}

            # blank submission
            if not (extracted or "").strip():
                score, comment = 0.0, "学生未提交作业内容。"
                entry["comment"] = comment
                if not cfg["dry_run"]:
                    try: entry["review_ok"] = api.post_review(receiver_id=rid, task_id=task_id, content=comment)
                    except Exception as e: logging.warning(f"[REVIEW][TASK {task_id}] rid={rid} review post failed: {e}")

                wrote = False
                if iid > 0 and not cfg["dry_run"]:
                    allow_refresh = _iid_should_refresh(cfg,"score_404") or _iid_should_refresh(cfg,"score_422")
                    ok, code, txt, new_iid = api.post_item_score_resilient(item_id=iid, owner_id=rid, task_id=task_id, score=score, review=comment, allow_refresh=allow_refresh)
                    if new_iid != iid and new_iid>0:
                        iid = new_iid
                        state["task_item"][str(task_id)] = iid
                        state["task_item_ts"][str(task_id)] = time.time()
                        hist = state["task_item_hist"].setdefault(str(task_id), [])
                        if not hist or hist[-1] != iid: hist.append(iid)
                        save_state(cfg["state_path"], state)
                    wrote = ok
                elif iid<=0:
                    logging.error(f"[SCORE][TASK {task_id}] rid={rid} skipped (item_id unresolved)")

                if wrote:
                    entry["score_ok"] = True
                    entry["score"] = score
                    status = "ok" if meets_stop_criteria(entry, cfg["stop_criteria"]) else "partial"
                else:
                    status = "dryrun" if cfg["dry_run"] else "fail"
                    entry["score_wanted"] = score
                processed_map[str(rid)] = {"status": status, **entry}
                success_cnt += 1 if status=="ok" else 0
                logging.info("[DONE/BLANK][TASK %s] %d/%d rid=%s name=%s score=%.1f status=%s", task_id, idx, total, rid, name, entry.get("score") or score, status)
                save_state(cfg["state_path"], state)
                continue

            # AI grading
            provider = cfg["ai_provider"]
            model = cfg["gemini_model"] if provider=="gemini" else cfg["deepseek_model"]
            key   = cfg["gemini_key"]   if provider=="gemini" else cfg["deepseek_key"]
            client = AIClient(provider=provider, model=model, key=key)

            tpl = _load_prompt_template(cfg.get("prompt_path","/opt/agrader/prompt.txt"))
            task_title = (task.get("title") or task.get("name") or "").strip()
            u = (asg.get("assignee") or {})
            student_name = (u.get("name") or u.get("real_name") or "").strip()
            student_id = str(u.get("id") or asg.get("receiver_id") or "")
            perq, overall_max_from_task = scan_question_maxima(task)
            ctx = {
                "task_title": task_title,
                "student_name": student_name,
                "student_id": student_id,
                "assignment_text": (extracted or "").strip(),
                "max_score": float(overall_max_from_task or 100.0),
                "per_question_json": json.dumps(perq or [], ensure_ascii=False),
            }
            try:
                prompt = tpl.format(**ctx)
            except Exception:
                prompt = f"You are a strict grader.\nTask: {task_title}\nStudent: {student_name}({student_id})\n---\n{ctx['assignment_text']}\n---"

            try:
                j = client.grade(prompt)
                overall = j.get("overall") or {}
                ai_score = float(overall.get("score") or 0.0)
                comment = str(overall.get("comment") or "").strip() or "（无评语）"
            except Exception as e:
                ai_score, comment = 0.0, f"自动评分失败：{e}"

            entry["comment"] = comment

            if not cfg["dry_run"]:
                try: entry["review_ok"] = Seiue.post_review(api, receiver_id=rid, task_id=task_id, content=comment)
                except Exception as e: logging.warning(f"[REVIEW][TASK {task_id}] rid={rid} review post failed: {e}")

            max_score = _get_item_max(api, task, iid, overall_max_from_task, cfg["max_cache_ttl"])
            desired = clamp(ai_score, 0.0, max_score) if cfg["clamp_on_max"] else ai_score

            if cfg["reverify_before"] and iid > 0 and not cfg["dry_run"]:
                try:
                    exist = api.verify_existing_score(iid, rid)
                    if exist is not None:
                        entry["score_ok"] = True
                        entry["score"] = float(exist)
                        status = "ok" if meets_stop_criteria(entry, cfg["stop_criteria"]) else "partial"
                        processed_map[str(rid)] = {"status": status, **entry}
                        success_cnt += 1 if status=="ok" else 0
                        logging.info("[DONE][OK*existing][TASK %s] %d/%d rid=%s name=%s (already exists: %.2f) status=%s", task_id, idx, total, rid, name, exist, status)
                        save_state(cfg["state_path"], state)
                        continue
                    else:
                        if _iid_should_refresh(cfg,"verify_miss"):
                            new_iid = _ensure_valid_item_id(cfg, api, state, task_id)
                            if new_iid != iid and new_iid>0:
                                iid = new_iid
                                max_score = _get_item_max(api, task, iid, overall_max_from_task, cfg["max_cache_ttl"])
                except Exception:
                    pass

            wrote = False
            if iid > 0 and not cfg["dry_run"]:
                allow_refresh = _iid_should_refresh(cfg,"score_404") or _iid_should_refresh(cfg,"score_422")
                ok, code, txt, new_iid = api.post_item_score_resilient(item_id=iid, owner_id=rid, task_id=task_id, score=desired, review=comment, allow_refresh=allow_refresh)
                if new_iid != iid and new_iid>0:
                    iid = new_iid
                    state["task_item"][str(task_id)] = iid
                    state["task_item_ts"][str(task_id)] = time.time()
                    hist = state["task_item_hist"].setdefault(str(task_id), [])
                    if not hist or hist[-1] != iid: hist.append(iid)
                    save_state(cfg["state_path"], state)
                if not ok and code == 422 and cfg["retry_422_once"]:
                    parsed = api.parse_max_from_422(txt)
                    if parsed and parsed > 0:
                        desired = min(desired, parsed)
                        ok2, code2, txt2, _ = api.post_item_score_resilient(item_id=iid, owner_id=rid, task_id=task_id, score=desired, review=comment, allow_refresh=False)
                        wrote = ok2
                    else:
                        wrote = False
                else:
                    wrote = ok
            elif iid<=0:
                logging.error(f"[SCORE][TASK {task_id}] rid={rid} skipped (item_id unresolved)")

            if wrote:
                entry["score_ok"] = True
                entry["score"] = desired
                status = "ok" if meets_stop_criteria(entry, cfg["stop_criteria"]) else "partial"
            else:
                status = "dryrun" if cfg["dry_run"] else "fail"
                entry["score_wanted"] = desired
            processed_map[str(rid)] = {"status": status, **entry}
            success_cnt += 1 if status=="ok" else 0
            logging.info("[DONE][TASK %s] %d/%d rid=%s name=%s score=%s status=%s", task_id, idx, total, rid, name, entry.get("score"), status)
            save_state(cfg["state_path"], state)

        if _is_task_complete(state, task_id, len(items), cfg["stop_criteria"]):
            logging.info(f"[TASK {task_id}] completed under stop={cfg['stop_criteria']}.")
            if tg_enabled(cfg):
                tg_send(cfg, f"✅ Task <b>{task_id}</b> complete under <code>{cfg['stop_criteria']}</code>.")

    # Return whether all tasks are done (for oneshot decision)
    final_state = load_state(cfg["state_path"])
    for task_id, items in [(t, all_tasks_assignments.get(t, [])) for t in cfg["task_ids"]]:
        if not _is_task_complete(final_state, task_id, len(items), cfg["stop_criteria"]):
            return False
    return True

if __name__ == "__main__":
    setup_logging()
    while not _stop.is_set():
        cfg = load_env()
        all_done = main_pass(cfg)
        if cfg["run_mode"] == "oneshot":
            break
        if all_done:
            logging.info("[EXEC] All tasks complete. Shutting down.")
            if tg_enabled(cfg):
                tg_send(cfg, "🎉 All tasks completed. AGrader is shutting down.")
            break
        logging.info("[EXEC] Sleeping %d seconds...", cfg["interval"])
        time.sleep(cfg["interval"])
    logging.info("[EXEC] AGrader has stopped.")
    sys.exit(0)
PY

  # --------------- systemd (Linux) ---------------
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=AGrader - Seiue auto-grader
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
Environment=ENV_PATH=${ENV_FILE}
ExecStart=${VENV_DIR}/bin/python ${PY_MAIN}
Restart=on-failure
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SERVICE_PATH"
}

create_venv_and_install() {
  echo "[6/12] Creating venv and installing requirements..."
  python3 -m venv "$VENV_DIR"
  "${VENV_DIR}/bin/pip" install --upgrade pip >/dev/null
  "${VENV_DIR}/bin/pip" install -r "$APP_DIR/requirements.txt"
}

enable_start_linux() {
  echo "[7/12] Writing systemd service (Linux)..."
  systemctl daemon-reload
  echo "[8/12] Stopping existing service if running..."
  systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  echo "[9/12] Enabling and starting..."
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  systemctl start "$SERVICE"
  echo "[10/12] Logs (last 20):"
  journalctl -u "$SERVICE" -n 20 --no-pager || true
  echo "Tail: journalctl -u $SERVICE -f"
  echo "[11/12] Edit config: sudo nano $ENV_FILE"
  echo "[12/12] Restart: sudo systemctl restart $SERVICE"
  cat <<'EOT'

Graceful stop:
  sudo systemctl stop agrader.service
Resume:
  sudo systemctl start agrader.service
EOT
}

stop_existing() {
  echo "[PRE] Stopping any previous AGrader processes/services..."
  if [ "$(os_detect)" = "linux" ]; then
    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  elif [ "$(os_detect)" = "mac" ]; then
    [ -f "$LAUNCHD_PLIST" ] && launchctl unload "$LAUNCHD_PLIST" >/dev/null 2>&1 || true
  fi
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f "${VENV_DIR}/bin/python ${PY_MAIN}" >/dev/null 2>&1 && pkill -f "${VENV_DIR}/bin/python ${PY_MAIN}" || true
    pgrep -f "${PY_MAIN}" >/dev/null 2>&1 && pkill -f "${PY_MAIN}" || true
  else
    pkill -f "${VENV_DIR}/bin/python ${PY_MAIN}" 2>/dev/null || true
    pkill -f "${PY_MAIN}" 2>/dev/null || true
  fi
  sleep 1
}

main() {
  case "$(os_detect)" in
    linux) install_pkgs_linux ;;
    mac)   install_pkgs_macos ;;
    *)     echo "Unsupported OS"; exit 1 ;;
  esac

  echo "[2/12] Collecting initial configuration..."
  mkdir -p "$APP_DIR" "$APP_DIR/work"

  local IS_FRESH_INSTALL=0
  if [ ! -f "$ENV_FILE" ]; then
    echo "Creating new $ENV_FILE ..."
    : > "$ENV_FILE"
    IS_FRESH_INSTALL=1
  else
    echo "Reusing existing $ENV_FILE"
  fi

  stop_existing
  prompt_task_ids
  prompt_mode

  write_project "$IS_FRESH_INSTALL"
  create_venv_and_install

  if [ "$(os_detect)" = "linux" ]; then
    enable_start_linux
  else
    echo "On macOS: run manually -> ${VENV_DIR}/bin/python ${PY_MAIN}"
    echo "Optionally create a launchd plist at: $LAUNCHD_PLIST (not created automatically)."
  fi
}

main "$@"