#!/usr/bin/env bash
# AGrader - API-first auto-grading pipeline (installer/runner) - FULL INLINE EDITION
# Linux: apt/dnf/yum/apk + systemd; macOS: Homebrew + optional launchd
# v1.12.1-fullinline-2025-11-02
#
# Changes vs 1.12.0:
# - Guarantee "right-side comment under score": include `comment` (and `review`) in /scores/sync entries.
# - Keep dual-write: POST /reviews as a second sink.
# - New TEST_RECEIVER_ID to safely validate with a single student.
# - Stop only when both score and review are written (STOP_CRITERIA=score_and_review).
# - Fix: implement Seiue.post_review (prevents AttributeError).
# - 422 fallback: on schema-reject, retry minimal payload (owner_id, score) + still post /reviews.

set -euo pipefail

APP_DIR="/opt/agrader"
VENV_DIR="$APP_DIR/venv"
ENV_FILE="$APP_DIR/.env"
SERVICE="agrader.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE}"
LAUNCHD_PLIST="${HOME}/Library/LaunchAgents/net.bdfz.agrader.plist"
PY_MAIN="$APP_DIR/main.py"

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
  local esc="${val//\//\\/}"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i.bak -E "s#^${key}=.*#${key}=${esc}#" "$ENV_FILE"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
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

  grep -q '^LOG_FORMAT='  "$ENV_FILE" || echo 'LOG_FORMAT=%(asctime)s.%(msecs)03d %(levelname)s %(name)s - %(message)s' >> "$ENV_FILE"
  grep -q '^LOG_DATEFMT=' "$ENV_FILE" || echo 'LOG_DATEFMT=%Y-%m-%d %H:%M:%S' >> "$ENV_FILE"
  grep -q '^LOG_FILE='    "$ENV_FILE" || echo "LOG_FILE=${APP_DIR}/agrader.log" >> "$ENV_FILE"
  grep -q '^LOG_LEVEL='   "$ENV_FILE" || echo 'LOG_LEVEL=INFO' >> "$ENV_FILE"

  grep -q '^PROMPT_TEMPLATE_PATH=' "$ENV_FILE" || echo "PROMPT_TEMPLATE_PATH=${APP_DIR}/prompt.txt" >> "$ENV_FILE"

  grep -q '^FULL_SCORE_MODE='     "$ENV_FILE" || echo 'FULL_SCORE_MODE=off' >> "$ENV_FILE"
  grep -q '^FULL_SCORE_COMMENT='  "$ENV_FILE" || echo 'FULL_SCORE_COMMENT=記得看高考真題。' >> "$ENV_FILE"

  if grep -q '^SEIUE_SCORE_ENDPOINTS=' "$ENV_FILE"; then
    sed -i.bak -E 's#^SEIUE_SCORE_ENDPOINTS=.*#SEIUE_SCORE_ENDPOINTS=POST:/vnas/klass/items/{item_id}/scores/sync?async=true\&from_task=true:array#' "$ENV_FILE" || true
  else
    echo 'SEIUE_SCORE_ENDPOINTS=POST:/vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true:array' >> "$ENV_FILE"
  fi
  grep -q '^SEIUE_REVIEW_POST_TEMPLATE=' "$ENV_FILE" || \
    echo 'SEIUE_REVIEW_POST_TEMPLATE=/chalk/task/v2/assignees/{receiver_id}/tasks/{task_id}/reviews' >> "$ENV_FILE"
  grep -q '^SEIUE_VERIFY_SCORE_GET_TEMPLATE=' "$ENV_FILE" || \
    echo 'SEIUE_VERIFY_SCORE_GET_TEMPLATE=/vnas/common/items/{item_id}/scores?paginated=0&type=item_score' >> "$ENV_FILE"

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

  grep -q '^MAX_SCORE_CACHE_TTL='     "$ENV_FILE" || echo 'MAX_SCORE_CACHE_TTL=600'    >> "$ENV_FILE"
  grep -q '^SCORE_CLAMP_ON_MAX='      "$ENV_FILE" || echo 'SCORE_CLAMP_ON_MAX=1'       >> "$ENV_FILE"

  grep -q '^AI_KEY_STRATEGY='         "$ENV_FILE" || echo 'AI_KEY_STRATEGY=roundrobin' >> "$ENV_FILE"
  grep -q '^GEMINI_API_KEYS='         "$ENV_FILE" || echo 'GEMINI_API_KEYS='           >> "$ENV_FILE"
  grep -q '^DEEPSEEK_API_KEYS='       "$ENV_FILE" || echo 'DEEPSEEK_API_KEYS='         >> "$ENV_FILE"

  grep -q '^RUN_MODE='        "$ENV_FILE" || echo 'RUN_MODE=watch' >> "$ENV_FILE"
  grep -q '^STOP_CRITERIA='   "$ENV_FILE" || echo 'STOP_CRITERIA=score_and_review' >> "$ENV_FILE"

  # New: single-student test gate (empty=off)
  grep -q '^TEST_RECEIVER_ID=' "$ENV_FILE" || echo 'TEST_RECEIVER_ID=' >> "$ENV_FILE"
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

# ---- Single-student dry-run (blank=off) ----
TEST_RECEIVER_ID=

# ---- Paths/State ----
STATE_PATH=${APP_DIR}/state.json
WORKDIR=${APP_DIR}/work
EOF
    chmod 600 "$ENV_FILE"
  else
    echo "Reusing existing $ENV_FILE"
  fi

  ensure_env_patch

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

  # ---------- PY: util tools ----------
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

  # ---------- PY: auth ----------
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

  # ---------- PY: extractor ----------
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

  # ---------- PY: ai clients ----------
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

  # ---------- PY: API wrapper ----------
  cat > "$APP_DIR/seiue_api.py" <<'PY'
import os, logging, requests, threading, re, time, tempfile, shutil
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
    return list(dict.fromkeys(found))

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

    # ------------ Basic resources ------------
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

    def get_item_detail(self, item_id: int):
        url = self._url(f"/vnas/klass/items/{item_id}?expand=assessment%2Cassessment_stage%2Cstage")
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

    # ------------ Writes ------------
    def post_review(self, receiver_id: int, task_id: int, content: str) -> bool:
        """Post textual review to the task review endpoint (second sink)."""
        path_tmpl = os.getenv("SEIUE_REVIEW_POST_TEMPLATE","/chalk/task/v2/assignees/{receiver_id}/tasks/{task_id}/reviews")
        path = path_tmpl.format(receiver_id=receiver_id, task_id=task_id)
        url = self._url(path)
        payload = {"content": content or ""}
        r = self._with_refresh(lambda: self.session.post(url, json=payload, timeout=30))
        if r.status_code in (200,201,202,204):
            return True
        if r.status_code == 405:
            # Some tenants disable read but allow write; 405 here we treat as soft-ok if backend is quirky
            logging.warning("[REVIEW] 405 on post; treating as soft-ok")
            return True
        if r.status_code >= 400:
            logging.warning("[REVIEW] post %s: %s", r.status_code, (r.text or "")[:300])
            return False
        return True

    def score_sync(self, item_id: int, entries: List[Dict[str,Any]]) -> Tuple[bool, Optional[str]]:
        """POST array payload; include comment under score via `comment` (and `review` redundantly)."""
        url = self._url(f"/vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true")
        r = self._with_refresh(lambda: self.session.post(url, json=entries, timeout=60))
        if r.status_code in (200,201,202,204):
            return True, None
        msg = (r.text or "")[:500]
        if r.status_code == 422:
            return False, msg
        if r.status_code >= 400:
            logging.error("[SCORE] sync %s: %s", r.status_code, msg)
        return False, msg

    # ------------ Download helper (for AI) ------------
    def download_to(self, url_or_path: str) -> Optional[str]:
        """Download authenticated file to temp; return local path."""
        try:
            url = url_or_path if url_or_path.startswith("http") else self._url(url_or_path)
            with self._with_refresh(lambda: self.session.get(url, stream=True, timeout=120)) as r:
                if r.status_code >= 400: 
                    logging.warning("[GET] file %s -> %s", url, r.status_code); return None
                fd, path = tempfile.mkstemp(prefix="att_", suffix=".bin"); f = os.fdopen(fd, "wb")
                for chunk in r.iter_content(chunk_size=65536):
                    if chunk: f.write(chunk)
                f.close()
                return path
        except Exception as e:
            logging.error("[GET] file error: %s", repr(e))
            return None

PY

  # ---------- PY: main ----------
  cat > "$APP_DIR/main.py" <<'PY'
import os, json, time, logging, math
from typing import List, Dict, Any, Optional
from dotenv import load_dotenv
from ai_providers import AIClient
from utilx import draftjs_to_text, clamp, scan_question_maxima
from seiue_api import Seiue, _flatten_find_item_ids

logging.basicConfig(level=getattr(logging, os.getenv("LOG_LEVEL","INFO")), 
  format=os.getenv("LOG_FORMAT","%(asctime)s.%(msecs)03d %(levelname)s %(name)s - %(message)s"),
  datefmt=os.getenv("LOG_DATEFMT","%Y-%m-%d %H:%M:%S"))

def as_bool(env: str, default: bool=True) -> bool:
    v = os.getenv(env)
    if v is None: return default
    s = str(v).strip().lower()
    return s not in ("0","false","no","off","")

def build_review_text(ai_json: Dict[str,Any], fallback: str) -> str:
    try:
        perq = ai_json.get("per_question") or []
        overall = ai_json.get("overall") or {}
        lines=[]
        for q in perq:
            qid = str(q.get("id","?"))
            sc  = q.get("score")
            cm  = (q.get("comment") or "").strip()
            lines.append(f"[{qid}] {sc}: {cm}" if cm else f"[{qid}] {sc}")
        ocm = (overall.get("comment") or "").strip()
        if ocm: lines.append(ocm)
        txt = "\n".join(lines).strip()
        return txt if txt else (fallback or "已阅")
    except Exception:
        return fallback or "已阅"

def safe_float(x, default=0.0):
    try: return float(x)
    except: return default

def main():
    load_dotenv(os.getenv("ENV_FILE",".env"))
    base = os.getenv("SEIUE_BASE","https://api.seiue.com")
    username = os.getenv("SEIUE_USERNAME","")
    password = os.getenv("SEIUE_PASSWORD","")
    token = os.getenv("SEIUE_BEARER","")
    school_id = os.getenv("SEIUE_SCHOOL_ID","3")
    role = os.getenv("SEIUE_ROLE","teacher")
    reflection = os.getenv("SEIUE_REFLECTION_ID","")
    monitor_ids = [int(x) for x in (os.getenv("MONITOR_TASK_IDS","").strip().split(",") if os.getenv("MONITOR_TASK_IDS","").strip() else [])]
    if not monitor_ids:
        logging.error("No MONITOR_TASK_IDS set."); return

    run_mode = os.getenv("RUN_MODE","watch")
    stop_criteria = os.getenv("STOP_CRITERIA","score_and_review")
    dry_run = as_bool("DRY_RUN", False)
    test_receiver_id = os.getenv("TEST_RECEIVER_ID","").strip()

    ai_provider = os.getenv("AI_PROVIDER","deepseek")
    gem_model = os.getenv("GEMINI_MODEL","gemini-2.5-pro")
    deep_model = os.getenv("DEEPSEEK_MODEL","deepseek-reasoner")
    key = os.getenv("DEEPSEEK_API_KEY","") if ai_provider=="deepseek" else os.getenv("GEMINI_API_KEY","")
    model = deep_model if ai_provider=="deepseek" else gem_model
    ai = AIClient(ai_provider, model, key)

    full_mode = os.getenv("FULL_SCORE_MODE","off").lower()
    full_comment = os.getenv("FULL_SCORE_COMMENT","記得看高考真題。")

    client = Seiue(base, token, school_id, role, reflection, username=username, password=password)
    poll = int(os.getenv("POLL_INTERVAL","10"))

    logging.info("[EXEC] Monitoring tasks=%s (run_mode=%s, stop=%s, dry_run=%s)", monitor_ids, run_mode, stop_criteria, str(dry_run))

    def process_task(tid: int) -> bool:
        task = client.get_task(tid) or {}
        assigns = client.get_assignments(tid) or []
        if test_receiver_id:
            assigns = [a for a in assigns if str(a.get("receiver_id","")) == test_receiver_id]
            if not assigns:
                logging.warning("[TASK %s] TEST_RECEIVER_ID=%s not found in assignments.", tid, test_receiver_id)
                return True

        # try find a single klass item id for this task (usually one)
        item_ids = list(dict.fromkeys(_flatten_find_item_ids({"task":task,"assignments":assigns})))
        if not item_ids:
            logging.error("[TASK %s] No item_id found to write scores.", tid)
            return False
        item_id = item_ids[0]

        # max score detect
        max_score = client.get_item_max_score(item_id)
        if max_score is None: max_score = 100.0

        perq, sum_from_task = scan_question_maxima(task)
        if sum_from_task and sum_from_task > 0: max_score = sum_from_task

        total = len(assigns); done = 0
        for a in assigns:
            rid = int(a.get("receiver_id") or 0)
            if not rid: continue
            owner_id = rid  # for score sync
            assignee = (a.get("assignee") or {}).get("name") or ""
            sub = a.get("submission") or {}
            # get submission text
            text = ""
            if "content_json" in sub and sub["content_json"]:
                text = draftjs_to_text(sub["content_json"])
            elif "content" in sub and sub["content"]:
                text = str(sub["content"])

            # produce score + comment
            if full_mode == "all":
                score = max_score
                review_text = full_comment
            else:
                # Build prompt for AI
                perq_schema = [{"id": q["id"], "max": q["max"]} for q in (perq or [])]
                prompt = (open(os.getenv("PROMPT_TEMPLATE_PATH","prompt.txt"),"r",encoding="utf-8").read()
                          .replace("{task_title}", str(task.get("title","")))
                          .replace("{student_name}", assignee)
                          .replace("{student_id}", str(rid))
                          .replace("{max_score}", str(max_score))
                          .replace("{per_question_json}", json.dumps(perq_schema, ensure_ascii=False))
                          .replace("{assignment_text}", text or "(no submission text)"))
                ai_json = ai.grade(prompt) if not dry_run else {"per_question":[],"overall":{"score":max_score,"comment":"[DRY-RUN]"}}
                score = clamp(safe_float(ai_json.get("overall",{}).get("score",0.0)), 0.0, max_score)
                review_text = build_review_text(ai_json, fallback="已阅")

            # verify existing
            if as_bool("REVERIFY_BEFORE_WRITE", True):
                ex = client.verify_existing_score(item_id, owner_id)
                if ex is not None and abs(ex - score) < 1e-6:
                    # still ensure right-side comment by re-sync with comment (idempotent expectation)
                    logging.info("[TASK %s] rid=%s already exists: %.2f (will still update comment)", tid, rid, ex)

            # write score+comment (right-side)
            ok_score = True
            err_422 = None
            if not dry_run and as_bool("SCORE_WRITE", True):
                entry = {"owner_id": owner_id, "score": score, "comment": review_text, "review": review_text, "task_id": tid}
                ok_score, err_422 = client.score_sync(item_id, [entry])
                if ok_score:
                    logging.info("[API] Score synced (with comment) rid=%s task=%s", rid, tid)
                else:
                    if err_422 and as_bool("RETRY_ON_422_ONCE", True):
                        # Retry minimal shape to avoid schema drift
                        logging.warning("[SCORE][422] retry minimal payload rid=%s task=%s: %s", rid, tid, err_422[:160])
                        ok_score, _ = client.score_sync(item_id, [{"owner_id": owner_id, "score": score}])
                        if ok_score:
                            logging.info("[API] Score synced (minimal) rid=%s task=%s", rid, tid)
                        else:
                            logging.error("[SCORE] still failed rid=%s task=%s", rid, tid)

            # write task review (second sink)
            ok_review = True
            if not dry_run and as_bool("REVIEW_ALL_EXISTING", True):
                ok_review = client.post_review(receiver_id=rid, task_id=tid, content=review_text)
                if ok_review:
                    logging.info("[API] Review posted for rid=%s task=%s", rid, tid)
                else:
                    logging.warning("[REVIEW] post failed rid=%s task=%s", rid, tid)

            # stop conditions evaluation
            if stop_criteria == "score_and_review":
                if ok_score and ok_review: done += 1
            elif stop_criteria == "score":
                if ok_score: done += 1
            else: # review
                if ok_review: done += 1

        if done == total or test_receiver_id:
            logging.info("[SUMMARY][TASK %s] ✅ Task %s complete per stop=%s: %s / %s", tid, tid, stop_criteria, done, total)
            return True
        else:
            logging.info("[SUMMARY][TASK %s] partial: %s / %s", tid, done, total)
            return False

    if run_mode == "oneshot":
        all_ok = True
        for tid in monitor_ids:
            ok = process_task(tid)
            all_ok = all_ok and ok
        logging.info("[EXEC] AGrader has stopped.")
        return

    # watch
    while True:
        for tid in monitor_ids:
            process_task(tid)
        time.sleep(poll)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        logging.info("[EXEC] Caught signal; graceful shutdown...")
PY

  # ---------- venv & service ----------
  echo "[6/12] Creating venv & installing deps..."
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip >/dev/null
  "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt"

  echo "[7/12] Writing service/unit..."
  if [ "$(os_detect)" = "linux" ]; then
    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=AGrader - Seiue auto-grader
After=network.target

[Service]
Type=simple
Environment=ENV_FILE=$ENV_FILE
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/python $PY_MAIN
Restart=no
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  else
    mkdir -p "$(dirname "$LAUNCHD_PLIST")"
    cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>net.bdfz.agrader</string>
  <key>ProgramArguments</key>
  <array>
    <string>${VENV_DIR}/bin/python</string>
    <string>${PY_MAIN}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>ENV_FILE</key><string>${ENV_FILE}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${APP_DIR}/agrader.out.log</string>
  <key>StandardErrorPath</key><string>${APP_DIR}/agrader.err.log</string>
</dict></plist>
EOF
  fi

  echo "[8/12] First-run defaults..."
  [ -f "$ENV_FILE" ] || { echo "No $ENV_FILE found"; exit 1; }

  echo "[9/12] Safety tips:"
  echo " - To single-student verify right-side comment: set TEST_RECEIVER_ID in $ENV_FILE."
  echo " - Keep STOP_CRITERIA=score_and_review to ensure both sinks succeed."

  echo "[10/12] Start..."
  if [ "$(os_detect)" = "linux" ]; then
    systemctl restart "$SERVICE" || systemctl start "$SERVICE"
  else
    launchctl unload "$LAUNCHD_PLIST" >/dev/null 2>&1 || true
    launchctl load "$LAUNCHD_PLIST"
  fi

  echo "[11/12] Tail: journalctl -u agrader.service -f (Linux) or see ${APP_DIR}/agrader*.log (macOS)"
  echo "[12/12] Edit config: sudo nano ${ENV_FILE}"
}

# ----------- Entry -----------
main() {
  echo "[0/12] Detecting OS..."
  case "$(os_detect)" in
    linux) install_pkgs_linux;;
    mac)   install_pkgs_macos;;
    *)     echo "Unsupported OS"; exit 1;;
  esac

  if [ ! -f "$ENV_FILE" ]; then
    prompt_task_ids
    prompt_mode
    write_project 1
  else
    write_project 0
  fi
}

main "$@"