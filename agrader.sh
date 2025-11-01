#!/usr/bin/env bash
# AGrader - API-first auto-grading pipeline (installer/runner)
# Linux: apt/yum/apk + systemd; macOS: Homebrew + optional launchd
set -euo pipefail

APP_DIR="/opt/agrader"
VENV_DIR="$APP_DIR/venv"
ENV_FILE="$APP_DIR/.env"
SERVICE="agrader.service"
LAUNCHD_PLIST="${HOME}/Library/LaunchAgents/net.bdfz.agrader.plist"

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

  # Logging defaults
  if ! grep -q '^LOG_FORMAT=' "$ENV_FILE"; then
    echo 'LOG_FORMAT=%(asctime)s.%(msecs)03d %(levelname)s %(name)s - %(message)s' >> "$ENV_FILE"
  elif grep -Eiq '^LOG_FORMAT=.*(%Y|%m|%d|%H|%M|%S)' "$ENV_FILE"; then
    sed -i.bak -E 's#^LOG_FORMAT=.*#LOG_FORMAT=%(asctime)s.%(msecs)03d %(levelname)s %(name)s - %(message)s#' "$ENV_FILE" || true
  fi
  grep -q '^LOG_DATEFMT=' "$ENV_FILE" || echo 'LOG_DATEFMT=%Y-%m-%d %H:%M:%S' >> "$ENV_FILE"

  # Confirmed endpoints
  grep -q '^SEIUE_REVIEW_POST_TEMPLATE=' "$ENV_FILE" || \
    echo 'SEIUE_REVIEW_POST_TEMPLATE=/chalk/task/v2/assignees/{receiver_id}/tasks/{task_id}/reviews' >> "$ENV_FILE"

  if ! grep -q '^SEIUE_SCORE_ENDPOINTS=' "$ENV_FILE"; then
    echo 'SEIUE_SCORE_ENDPOINTS=POST:/vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true:array;PUT:/vnas/common/items/{item_id}/scores?type=item_score:array;PUT:/common/items/{item_id}/scores?type=item_score:array;POST:/vnas/common/items/{item_id}/scores?type=item_score:array;POST:/common/items/{item_id}/scores?type=item_score:array' >> "$ENV_FILE"
  fi

  # Verify GET
  grep -q '^SEIUE_VERIFY_SCORE_GET_TEMPLATE=' "$ENV_FILE" || \
    echo 'SEIUE_VERIFY_SCORE_GET_TEMPLATE=/vnas/common/items/{item_id}/scores?paginated=0&type=item_score' >> "$ENV_FILE"

  # Strategy toggles / concurrency / AI backoff
  grep -q '^DRY_RUN=' "$ENV_FILE" || echo 'DRY_RUN=0' >> "$ENV_FILE"
  grep -q '^VERIFY_AFTER_WRITE=' "$ENV_FILE" || echo 'VERIFY_AFTER_WRITE=1' >> "$ENV_FILE"
  grep -q '^RETRY_FAILED=' "$ENV_FILE" || echo 'RETRY_FAILED=1' >> "$ENV_FILE"
  grep -q '^STUDENT_WORKERS=' "$ENV_FILE" || echo 'STUDENT_WORKERS=2' >> "$ENV_FILE"
  grep -q '^ATTACH_WORKERS=' "$ENV_FILE"  || echo 'ATTACH_WORKERS=3'  >> "$ENV_FILE"
  grep -q '^AI_PARALLEL=' "$ENV_FILE"     || echo 'AI_PARALLEL=2'     >> "$ENV_FILE"
  grep -q '^AI_MAX_RETRIES=' "$ENV_FILE"  || echo 'AI_MAX_RETRIES=7'  >> "$ENV_FILE"
  grep -q '^AI_BACKOFF_BASE_SECONDS=' "$ENV_FILE" || echo 'AI_BACKOFF_BASE_SECONDS=2.2' >> "$ENV_FILE"
  grep -q '^AI_JITTER_SECONDS=' "$ENV_FILE" || echo 'AI_JITTER_SECONDS=0.8' >> "$ENV_FILE"
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

    ask "Comma-separated Task IDs or URLs to monitor" MONITOR_TASK_IDS
    ask "Polling interval seconds" POLL_INTERVAL "10"

    echo
    echo "Choose AI provider:"
    echo "  1) gemini"
    echo "  2) deepseek"
    ask "Select 1/2" AI_CHOICE "1"
    if [ "$AI_CHOICE" = "2" ]; then
      AI_PROVIDER="deepseek"
      ask_secret "DeepSeek API Key" DEEPSEEK_API_KEY
      ask "DeepSeek Model" DEEPSEEK_MODEL "deepseek-reasoner"
      GEMINI_API_KEY=""; GEMINI_MODEL="gemini-2.5-pro"
    else
      AI_PROVIDER="gemini"
      ask_secret "Gemini API Key" GEMINI_API_KEY
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

    DRY_RUN="0"
    VERIFY_AFTER_WRITE="1"
    RETRY_FAILED="1"
    STUDENT_WORKERS="2"
    ATTACH_WORKERS="3"
    AI_PARALLEL="2"
    AI_MAX_RETRIES="7"
    AI_BACKOFF_BASE_SECONDS="2.2"
    AI_JITTER_SECONDS="0.8"

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
SEIUE_SCORE_ENDPOINTS=POST:/vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true:array;PUT:/vnas/common/items/{item_id}/scores?type=item_score:array;PUT:/common/items/{item_id}/scores?type=item_score:array;POST:/vnas/common/items/{item_id}/scores?type=item_score:array;POST:/common/items/{item_id}/scores?type=item_score:array
SEIUE_VERIFY_SCORE_GET_TEMPLATE=/vnas/common/items/{item_id}/scores?paginated=0&type=item_score

# ---- AI ----
AI_PROVIDER=${AI_PROVIDER}
GEMINI_API_KEY=${GEMINI_API_KEY}
GEMINI_MODEL=${GEMINI_MODEL}
DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY}
DEEPSEEK_MODEL=${DEEPSEEK_MODEL}
AI_PARALLEL=${AI_PARALLEL}
AI_MAX_RETRIES=${AI_MAX_RETRIES}
AI_BACKOFF_BASE_SECONDS=${AI_BACKOFF_BASE_SECONDS}
AI_JITTER_SECONDS=${AI_JITTER_SECONDS}

# ---- Telegram ----
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
TELEGRAM_VERBOSE=${TELEGRAM_VERBOSE}

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

# ---- Strategy & Safety ----
SCORE_WRITE=1
REVIEW_ALL_EXISTING=1
SCORE_GIVE_ALL_ON_START=1
DRY_RUN=${DRY_RUN}
VERIFY_AFTER_WRITE=${VERIFY_AFTER_WRITE}
RETRY_FAILED=${RETRY_FAILED}

# ---- Concurrency ----
STUDENT_WORKERS=${STUDENT_WORKERS}
ATTACH_WORKERS=${ATTACH_WORKERS}

# ---- Paths/State ----
STATE_PATH=${APP_DIR}/state.json
WORKDIR=${APP_DIR}/work
EOF
    chmod 600 "$ENV_FILE"
  else
    echo "Reusing existing $ENV_FILE"
    ensure_env_patch
  fi

  echo "[3/10] Writing project files..."
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

  cat > "$APP_DIR/AGRADER_DEPLOY.md" <<'EOF'
# AGrader (Seiue API-first auto-grading)

Flow: fetch assignments → extract submission (DraftJS + attachments OCR) → AI grade (Gemini/DeepSeek) → clamp to authoritative full_score → POST review + POST/PUT score → GET verify → Telegram notify.

Robust JSON: If AI returns invalid JSON, the system attempts json.loads → regex extraction → **AI self-repair** ("The following is not valid JSON. Please fix it and return only the corrected JSON object.").

Isolation & State:
- Each student is processed in an isolated try/except. Failures are logged, notified via Telegram, and appended into `state.json -> failed` with reason and timestamp.
- Optional `RETRY_FAILED=1`: failed cases become eligible for re-run.
- `reported_complete`: remember which `item_id` has already sent the "all graded (actual/expected)" message.

Authoritative scoring:
- For each task's `item_id`, call `GET /vnas/klass/items/{item_id}` to fetch `full_score`, `pathname`, `completed_scores_counts`.
- Clamping strictly uses `full_score`.
- After successful scoring, if `actual == expected`, send a Telegram "完成度" message once.

Prompt context:
- Enrich with task `group` (class_name, grade_names, subject_name), `expected_take_minutes`, and item `pathname`.

Bulk tasks:
- Use `GET /chalk/task/v2/tasks?id_in=...&expand=group` to fetch task metadata for all monitored tasks in one call.

Concurrency:
- Attachments: ThreadPool (`ATTACH_WORKERS`).
- Students: ThreadPool (`STUDENT_WORKERS`) with independent `AI_PARALLEL` semaphore to throttle LLM concurrency.
EOF

  # utilx.py
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

  # credentials.py
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
    s.headers.update({"User-Agent": "AGrader/1.7 (+login)","Accept": "application/json, text/plain, */*"})
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

  # extractor.py
  cat > "$APP_DIR/extractor.py" <<'PY'
import os, subprocess, tempfile, mimetypes, logging
from typing import Tuple
from PIL import Image
import pytesseract
def _run(cmd: list, input_bytes: bytes=None, timeout=180) -> Tuple[int, bytes, bytes]:
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE if input_bytes else None, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
        from tempfile import mkdtemp
        tmpdir = mkdtemp(prefix="pdfocr_"); prefix = os.path.join(tmpdir, "pg")
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

  # ai_providers.py —— 強韌 JSON + 429 退避
  cat > "$APP_DIR/ai_providers.py" <<'PY'
import os, time, json, requests, logging, random, re

def _backoff_loop():
    max_retries = int(os.getenv("AI_MAX_RETRIES","5")); base = float(os.getenv("AI_BACKOFF_BASE_SECONDS","1.5")); jitter = float(os.getenv("AI_JITTER_SECONDS","0.5"))
    for i in range(max_retries):
        yield i; time.sleep((base ** i) + random.uniform(0, jitter))

class AIClient:
    def __init__(self, provider: str, model: str, key: str):
        self.provider = provider; self.model = model; self.key = key

    def grade(self, prompt: str) -> dict:
        raw = self._call_llm(prompt)
        return self.parse_or_repair(raw)

    def parse_or_repair(self, text: str) -> dict:
        text = (text or "").strip()
        if text.startswith("{"):
            try: return json.loads(text)
            except Exception: pass
        m = re.search(r"\{.*\}", text, re.S)
        if m:
            try: return json.loads(m.group(0))
            except Exception: pass
        try:
            fixed = self.repair_json(text)
            if isinstance(fixed, dict): return fixed
            if isinstance(fixed, str):
                fixed = fixed.strip()
                if fixed.startswith("{"): return json.loads(fixed)
                mm = re.search(r"\{.*\}", fixed, re.S)
                if mm: return json.loads(mm.group(0))
        except Exception as e:
            logging.error(f"[AI] JSON repair failed: {e}", exc_info=True)
        return {"per_question": [], "overall": {"score": 0, "comment": (text[:200] if text else "AI empty")}}

    def _call_llm(self, prompt: str) -> str:
        if self.provider == "gemini":
            return self._gemini(prompt)
        elif self.provider == "deepseek":
            return self._deepseek(prompt)
        else:
            raise ValueError("Unknown AI provider")

    def _gemini(self, prompt: str) -> str:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{self.model}:generateContent?key={self.key}"
        body = {"contents":[{"parts":[{"text": prompt}]}], "generationConfig":{"temperature":0.2}}
        for _ in _backoff_loop():
            r = requests.post(url, json=body, timeout=180)
            if r.status_code == 429: logging.warning("[AI] Gemini 429; retry..."); continue
            r.raise_for_status()
            data = r.json()
            try: return data["candidates"][0]["content"]["parts"][0]["text"]
            except Exception: return json.dumps(data)[:4000]
        return ""

    def _deepseek(self, prompt: str) -> str:
        url = "https://api.deepseek.com/chat/completions"; headers={"Authorization": f"Bearer {self.key}"}
        body={"model": self.model,"messages":[{"role":"system","content":"You are a strict grader. Output ONLY valid JSON per schema."},{"role":"user","content": prompt}],"temperature":0.2}
        for _ in _backoff_loop():
            r = requests.post(url, headers=headers, json=body, timeout=180)
            if r.status_code == 429: logging.warning("[AI] DeepSeek 429; retry..."); continue
            r.raise_for_status()
            data = r.json()
            return data.get("choices",[{}])[0].get("message",{}).get("content","")
        return ""

    def repair_json(self, bad_text: str) -> dict | str:
        if self.provider == "gemini":
            url = f"https://generativelanguage.googleapis.com/v1beta/models/{self.model}:generateContent?key={self.key}"
            instr = "The following is not valid JSON. Please fix it and return only the corrected JSON object."
            body = {"contents":[{"parts":[{"text": instr+"\n\n<<<\n"+(bad_text or "")+"\n>>>\n"}]}], "generationConfig":{"temperature":0.0}}
            r = requests.post(url, json=body, timeout=120); r.raise_for_status()
            data = r.json()
            return data["candidates"][0]["content"]["parts"][0]["text"]
        else:
            url = "https://api.deepseek.com/chat/completions"; headers={"Authorization": f"Bearer {self.key}"}
            sys_prompt = "You are a JSON fixer. Return ONLY the corrected JSON object. No code fences. No commentary."
            user = "The following is not valid JSON. Please fix it and return only the corrected JSON object.\n\n<<<\n"+(bad_text or "")+"\n>>>"
            body={"model": self.model,"messages":[{"role":"system","content":sys_prompt},{"role":"user","content": user}],"temperature":0.0}
            r = requests.post(url, headers=headers, json=body, timeout=120); r.raise_for_status()
            data = r.json()
            return data.get("choices",[{}])[0].get("message",{}).get("content","")
PY

  # seiue_api.py —— 修復 join & 打分端點多回退
  cat > "$APP_DIR/seiue_api.py" <<'PY'
import os, logging, requests
from typing import Dict, Any, List
from credentials import login, AuthResult
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

def _session_with_retries() -> requests.Session:
    s = requests.Session()
    r = Retry(total=5, backoff_factor=1.5, status_forcelist=(429,500,502,503,504), allowed_methods=frozenset({"GET","POST","PUT"}))
    s.mount("https://", HTTPAdapter(max_retries=r))
    s.headers.update({"Accept":"application/json, text/plain, */*","User-Agent":"AGrader/1.8"})
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
        logging.info("[AUTH] Auto-login...")
        res: AuthResult = login(self.username, self.password)
        if res.ok:
            self.bearer = res.token
            if res.reflection_id: self.reflection_id = str(res.reflection_id)
            self._init_headers(); logging.info("[AUTH] OK"); return True
        logging.error(f"[AUTH] Failed: {res.detail}"); return False

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
        """
        Canonical first:
          POST /vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true   (array body)

        Extra fallbacks (optional, via SEIUE_SCORE_ENDPOINTS; semicolon-separated):
          e.g.  PUT:/vnas/common/items/{item_id}/scores?type=item_score:array
                POST:/vnas/common/items/{item_id}/scores?type=item_score:array
                PUT:/common/items/{item_id}/scores?type=item_score:array
        """
        endpoints: List[tuple] = [("POST", f"/vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true", "array")]

        raw = (os.getenv("SEIUE_SCORE_ENDPOINTS", "") or "").strip()
        if raw:
            for seg in raw.split(";"):
                seg = seg.strip()
                if not seg:
                    continue
                parts = seg.split(":")
                if len(parts) < 2:
                    continue
                method = parts[0].strip().upper()
                body_hint = "array"
                if len(parts) == 2:
                    path = parts[1].strip()
                else:
                    body_hint = parts[-1].strip().lower()
                    path = ":".join(parts[1:-1]).strip()
                if "{item_id}" in path:
                    path = path.format(item_id=item_id)
                endpoints.append((method, path, body_hint))

        payload_array = [{
            "owner_id": int(owner_id),
            "valid": True,
            "score": str(score),
            "review": "",
            "attachments": [],
            "related_data": {"task_id": int(task_id)},
            "type": "item_score",
            "status": "published"
        }]
        payload_object = {
            "owner_id": int(owner_id),
            "valid": True,
            "score": str(score),
            "review": "",
            "attachments": [],
            "related_data": {"task_id": int(task_id)},
            "type": "item_score",
            "status": "published"
        }

        last = None
        for method, path, hint in endpoints:
            url = self._url(path)
            data = payload_array if hint == "array" else payload_object

            def _do():
                if method == "POST":
                    return self.session.post(url, json=data, timeout=60)
                if method == "PUT":
                    return self.session.put(url, json=data, timeout=60)
                return self.session.request(method, url, json=data, timeout=60)

            r = self._with_refresh(_do)
            last = r
            if 200 <= r.status_code < 300:
                return True
            logging.warning(f"[API] score failed: {method} {path} -> {r.status_code} :: {(r.text or '')[:200]}")

        if last is not None and last.status_code >= 400:
            last.raise_for_status()
        return False
PY

  # main.py —— 併發、隔離、權威滿分、完成度通知
  cat > "$APP_DIR/main.py" <<'PY'
import os, json, time, logging, sys, re, tempfile, threading, concurrent.futures as cf
from typing import Dict, Any, List, Tuple
from dotenv import load_dotenv
from utilx import draftjs_to_text, scan_question_maxima, clamp, stable_hash
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
    seen=set(); dedup=[]
    for x in out:
        if x not in seen:
            dedup.append(x); seen.add(x)
    return dedup

def load_env():
    load_dotenv(os.getenv("ENV_PATH",".env")); env=os.environ; get=lambda k,d="": env.get(k,d)
    def as_bool(x: str, default=True):
        if x is None or x == "": return default
        return x not in ("0","false","False","no","NO")
    raw_task_ids = get("MONITOR_TASK_IDS","")
    task_ids = _parse_task_ids(raw_task_ids)
    return {
        "base": get("SEIUE_BASE","https://api.seiue.com"),
        "username": get("SEIUE_USERNAME",""),
        "password": get("SEIUE_PASSWORD",""),
        "bearer": get("SEIUE_BEARER",""),
        "school_id": get("SEIUE_SCHOOL_ID","3"),
        "role": get("SEIUE_ROLE","teacher"),
        "reflection_id": get("SEIUE_REFLECTION_ID",""),
        "task_ids": task_ids,
        "interval": int(get("POLL_INTERVAL","10")),
        "workdir": get("WORKDIR","/opt/agrader/work"),
        "state_path": get("STATE_PATH","/opt/agrader/state.json"),
        "ocr_lang": get("OCR_LANG","chi_sim+eng"),
        "max_attach": int(get("MAX_ATTACHMENT_BYTES","25165824")),
        "ai_provider": get("AI_PROVIDER","gemini"),
        "gemini_key": get("GEMINI_API_KEY",""),
        "gemini_model": get("GEMINI_MODEL","gemini-2.5-pro"),
        "deepseek_key": get("DEEPSEEK_API_KEY",""),
        "deepseek_model": get("DEEPSEEK_MODEL","deepseek-reasoner"),
        "ai_parallel": int(get("AI_PARALLEL","2") or "2"),
        "tg_token": get("TELEGRAM_BOT_TOKEN",""),
        "tg_chat": get("TELEGRAM_CHAT_ID",""),
        "tg_verbose": as_bool(get("TELEGRAM_VERBOSE","1")),
        "score_write": as_bool(get("SCORE_WRITE","1")),
        "review_all_existing": as_bool(get("REVIEW_ALL_EXISTING","1")),
        "score_all_on_start": as_bool(get("SCORE_GIVE_ALL_ON_START","1")),
        "dry_run": as_bool(get("DRY_RUN","0")),
        "verify_after": as_bool(get("VERIFY_AFTER_WRITE","1")),
        "retry_failed": as_bool(get("RETRY_FAILED","1")),
        "student_workers": int(get("STUDENT_WORKERS","2") or "2"),
        "attach_workers": int(get("ATTACH_WORKERS","3") or "3"),
    }

def load_state(path: str) -> Dict[str, Any]:
    try:
        with open(path,"r") as f: data = json.load(f)
        data.setdefault("processed", {}); data.setdefault("scored", {}); data.setdefault("failed", []); data.setdefault("reported_complete", {})
        return data
    except Exception:
        return {"processed": {}, "scored": {}, "failed": [], "reported_complete": {}}

def save_state(path: str, st: Dict[str, Any]):
    tmp = path + ".tmp"; 
    with open(tmp,"w") as f: json.dump(st, f, ensure_ascii=False)
    os.replace(tmp, path)

def telegram_notify(token: str, chat: str, text: str):
    if not token or not chat: return
    import requests
    try:
        requests.post(f"https://api.telegram.org/bot{token}/sendMessage", json={"chat_id": chat,"text": text,"parse_mode": "HTML","disable_web_page_preview": True}, timeout=20)
    except Exception as e: logging.error(f"[TG] {e}", exc_info=True)

def extract_submission_text(sub: Dict[str,Any]) -> str:
    t = sub.get("content_text","") or sub.get("content","")
    try:
        if isinstance(t,str) and t.strip().startswith("{"): return draftjs_to_text(t)
        if isinstance(t,str): return t
    except Exception: pass
    return ""

def build_prompt(task: Dict[str,Any], item_meta: Dict[str,Any], stu: Dict[str,Any], sub_text: str, attach_texts: List[str], perq, overall_max) -> str:
    task_title = task.get("title","(untitled)")
    task_content_raw = task.get("content",""); task_content = task_content_raw
    try:
        if task_content_raw and task_content_raw.strip().startswith("{"): task_content = draftjs_to_text(task_content_raw)
    except Exception: pass

    g = task.get("group") or {}
    class_name = g.get("class_name",""); grade_names = g.get("grade_names",""); subject_name = g.get("subject_name",""); course_full = g.get("name","")
    expected_min = task.get("expected_take_minutes") or task.get("expected_take_minites") or ""
    pathname = item_meta.get("pathname") or []
    if isinstance(pathname, list): path_str = " / ".join([str(x) for x in pathname if x])
    else: path_str = str(pathname) if pathname else ""

    lines=[]
    lines.append("你是嚴格而公正的語文老師，請只輸出符合 JSON Schema 的結果。"); lines.append("")
    ctx = []
    if grade_names: ctx.append(f"{grade_names}")
    if class_name: ctx.append(f"{class_name}")
    if subject_name: ctx.append(f"{subject_name}")
    if course_full and course_full not in ctx: ctx.append(course_full)
    if path_str: ctx.append(f"[{path_str}]")
    if expected_min: ctx.append(f"預計用時≈{expected_min}分鐘")
    if ctx: lines.append("課程/任務背景：" + " · ".join(ctx))

    lines.append("\n== 任務說明 =="); lines.append(f"標題：{task_title}"); lines.append(f"要求：\n{task_content}")
    lines.append("\n== 學生信息 =="); lines.append(f"姓名：{stu.get('name','')}  ID：{stu.get('id','')}")
    lines.append("\n== 學生提交（正文） =="); lines.append(sub_text[:20000])
    if attach_texts:
        lines.append("\n== 附件文字（合併提取） ==")
        for i, t in enumerate(attach_texts,1): lines.append(f"[附件{i} | len={len(t)}]\n{t[:20000]}")

    lines.append("\n== 評分約束 ==")
    if perq:
        lines.append("分題滿分："); 
        for q in perq: lines.append(f"- {q['id']}: max {q['max']}")
        lines.append(f"總分上限 = {overall_max}")
    else:
        lines.append(f"未提供分題規則；總分上限 = {overall_max}")

    lines.append("""
== OUTPUT JSON SCHEMA ==
{
  "per_question": [{"id":"<qid>","score": <0..max>,"comment":"<=100 chars"}],
  "overall": {"score": <0..overall_max>, "comment":"<=200 chars"}
}
規則：切勿超過滿分；能整數就整數；中文簡潔評語；不要多餘鍵。""")
    return "\n".join(lines)

def _download_and_extract_attach(api: Seiue, fid: str, workdir: str, ocr_lang: str, size_cap: int) -> str:
    try:
        url = api.get_file_signed_url(str(fid))
        blob = api.download(url)
        ext = os.path.splitext(url.split("?")[0])[1] or ".bin"
        fp = tempfile.NamedTemporaryFile(delete=False, dir=workdir, suffix=ext)
        fp.write(blob); fp.close()
        txt = file_to_text(fp.name, ocr_lang=ocr_lang, size_cap=size_cap)
        if os.getenv("KEEP_WORK_FILES","0") not in ("1","true","True"):
            try: os.remove(fp.name)
            except Exception: pass
        return txt
    except Exception as e:
        logging.error(f"[ATTACH] {repr(e)}", exc_info=True)
        return f"[[error: {repr(e)}]]"

def process_student(job: Dict[str,Any]) -> Dict[str,Any]:
    """
    Worker executed in thread pool; each gets its own Seiue session and AI client.
    Returns a dict with status and state merge instructions.
    """
    cfg = job["cfg"]
    api = Seiue(cfg["base"], cfg["bearer"], cfg["school_id"], cfg["role"], cfg["reflection_id"], cfg["username"], cfg["password"])
    ai_key = cfg["gemini_key"] if cfg["ai_provider"] == "gemini" else cfg["deepseek_key"]
    ai_model = cfg["gemini_model"] if cfg["ai_provider"] == "gemini" else cfg["deepseek_model"]
    ai_client = AIClient(cfg["ai_provider"], ai_model, ai_key)

    task_id = job["task_id"]
    task_obj = job["task_obj"]
    item_id = job["item_id"]
    item_meta = job["item_meta"]
    perq = job["perq"]
    overall_max = job["overall_max"]
    attach_workers = job["attach_workers"]
    ai_sem: threading.Semaphore = job["ai_sem"]

    a = job["assignment"]
    assignee = a.get("assignee") or {}
    receiver_id = int(assignee.get("id") or 0)
    if not receiver_id: 
        return {"ok": False, "err": "no receiver", "task_id": task_id}

    sub = a.get("submission") or {}
    assignment_id = str(a.get("id") or f"{task_id}-{receiver_id}")
    updated = sub.get("updated_at") or sub.get("created_at") or ""
    sig = stable_hash((sub.get("content_text") or sub.get("content") or "") + "|" + (updated or ""))
    sub_id = str(sub.get("id") or assignment_id)

    # Extract submission + attachments concurrently
    try:
        sub_text = extract_submission_text(sub)
    except Exception as e:
        sub_text = f"[[error: sub extract {repr(e)}]]"

    attach_texts: List[str] = []
    fids = []
    for att in (sub.get("attachments") or []):
        fid = att.get("id") or att.get("file_id") or att.get("oss_key") or ""
        if fid: fids.append(str(fid))
    if fids:
        with cf.ThreadPoolExecutor(max_workers=attach_workers) as tp:
            futs = [tp.submit(_download_and_extract_attach, api, fid, cfg["workdir"], cfg["ocr_lang"], cfg["max_attach"]) for fid in fids]
            for fu in cf.as_completed(futs):
                try: attach_texts.append(fu.result())
                except Exception as e: attach_texts.append(f"[[error: attach future {repr(e)}]]")

    # Build prompt & call AI (guarded by AI_PARALLEL semaphore)
    prompt = build_prompt(task_obj, item_meta, assignee, sub_text, attach_texts, perq, overall_max)
    try:
        with ai_sem:
            result = ai_client.grade(prompt)  # robust JSON parsing + repair inside
    except Exception as e:
        # report failure but continue other students
        return {"ok": False, "err": f"AI grade exception: {repr(e)}", "task_id": task_id, "assignment_id": assignment_id, "receiver_id": receiver_id, "sig": sig}

    # Normalize scores
    perq_scores = []
    for q in (result.get("per_question") or []):
        try:
            qid = str(q.get("id",""))
            raw = float(q.get("score",0))
            # find max for qid if provided
            mx = None
            for qq in perq:
                if str(qq["id"]) == qid:
                    mx = float(qq["max"]); break
            if mx is None: mx = overall_max
            perq_scores.append({"id": qid, "score": float(clamp(raw, 0, mx)), "max": mx, "comment": (q.get("comment") or "")[:100]})
        except Exception:
            continue

    overall = result.get("overall") or {}
    try:
        oscore = float(overall.get("score", 0.0))
    except Exception:
        oscore = 0.0
    oscore = float(clamp(oscore, 0, overall_max))
    ocomment = (overall.get("comment") or "")[:200]

    # Compose teacher review text
    lines=[]
    if perq_scores:
        lines.append("分題得分：")
        for q in perq_scores:
            lines.append(f"- {q['id']}: {int(q['score']) if q['score'].is_integer() else q['score']}/{int(q['max']) if float(q['max']).is_integer() else q['max']}  {q['comment']}")
    lines.append(f"\n總評：{ocomment}")
    review_text = "\n".join(lines)

    # Write back (review + score) and verify
    if cfg["dry_run"]:
        wrote = True; verified = True
    else:
        # review
        try:
            _ = api.post_review(receiver_id, task_id, review_text, result="approved")
        except Exception as e:
            # still attempt score even if review fails
            logging.error(f"[REVIEW] {assignment_id} -> {repr(e)}", exc_info=True)
        # score
        try:
            wrote = api.post_item_score(item_id, receiver_id, task_id, oscore)
        except Exception as e:
            return {"ok": False, "err": f"score write exception: {repr(e)}", "task_id": task_id, "assignment_id": assignment_id, "receiver_id": receiver_id, "sig": sig}

        # verify
        verified = True
        if cfg["verify_after"]:
            try:
                path = os.getenv("SEIUE_VERIFY_SCORE_GET_TEMPLATE","/vnas/common/items/{item_id}/scores?paginated=0&type=item_score").format(item_id=item_id)
                url = api._url(path)
                r = api._with_refresh(lambda: api.session.get(url, timeout=30))
                r.raise_for_status()
                arr = r.json() or []
                found = False
                for rec in arr:
                    if int(rec.get("owner_id") or 0) == receiver_id:
                        found = True; break
                verified = found
            except Exception as e:
                logging.error(f"[VERIFY] {assignment_id} -> {repr(e)}", exc_info=True)
                verified = False

    return {
        "ok": True, "task_id": task_id, "assignment_id": assignment_id, "receiver_id": receiver_id,
        "sig": sig, "score": oscore, "verified": bool(verified)
    }

def main():
    setup_logging()
    cfg = load_env()
    os.makedirs(cfg["workdir"], exist_ok=True)
    state = load_state(cfg["state_path"])

    # bootstrap API session for metadata calls
    api0 = Seiue(cfg["base"], cfg["bearer"], cfg["school_id"], cfg["role"], cfg["reflection_id"], cfg["username"], cfg["password"])

    # Pull tasks in bulk
    task_ids = cfg["task_ids"]
    tasks_map: Dict[int, Any] = {}
    if task_ids:
        tasks_map = api0.get_tasks_bulk(task_ids)
        # backfill individually if some not returned
        for tid in task_ids:
            if tid not in tasks_map:
                try: tasks_map[tid] = api0.get_task(tid)
                except Exception as e: logging.error(f"[TASK] {tid} -> {repr(e)}", exc_info=True)

    jobs=[]
    task_ctx={}
    for task_id, task_obj in tasks_map.items():
        # item_id from custom_fields
        item_id = None
        cm = task_obj.get("custom_fields") or {}
        for k in ("item_id","score_item_id","klass_item_id"):
            if cm.get(k): item_id = int(cm.get(k)); break
        if not item_id:
            logging.warning(f"[TASK] {task_id} missing item_id; skip scoring but still can review.")
            item_meta = {}
        else:
            try:
                item_meta = api0.get_item_detail(item_id)
            except Exception as e:
                logging.error(f"[ITEM] {item_id} -> {repr(e)}", exc_info=True)
                item_meta = {}

        perq, overall_max = scan_question_maxima(task_obj)
        # override with authoritative full_score
        try:
            fs = item_meta.get("full_score")
            if fs is not None:
                overall_max = float(fs)
        except Exception: pass

        task_ctx[task_id] = {"item_id": item_id, "item_meta": item_meta, "perq": perq, "overall_max": overall_max}

        # assignments
        try:
            assigns = api0.get_assignments(task_id) or []
        except Exception as e:
            logging.error(f"[ASSIGN] task {task_id} -> {repr(e)}", exc_info=True)
            assigns = []

        for a in assigns:
            assignee = a.get("assignee") or {}
            if not assignee.get("id"): continue

            sub = a.get("submission") or {}
            updated = sub.get("updated_at") or sub.get("created_at") or ""
            sig = stable_hash((sub.get("content_text") or sub.get("content") or "") + "|" + (updated or ""))
            assignment_id = str(a.get("id") or f"{task_id}-{assignee.get('id')}")

            already = (state.get("processed",{}).get(assignment_id) == sig)
            if already and not cfg["score_all_on_start"]:
                continue

            jobs.append({
                "cfg": cfg, "task_id": task_id, "task_obj": task_obj,
                "item_id": item_id or 0, "item_meta": item_meta, "perq": perq, "overall_max": overall_max,
                "assignment": a, "attach_workers": cfg["attach_workers"]
            })

    ai_sem = threading.BoundedSemaphore(max(1, int(cfg["ai_parallel"])))

    logging.info(f"[EXEC] Running {len(jobs)} students with STUDENT_WORKERS={cfg['student_workers']} ATTACH_WORKERS={cfg['attach_workers']}")

    results=[]
    if jobs:
        def wrap(job):
            job["ai_sem"] = ai_sem
            try:
                return process_student(job)
            except Exception as e:
                return {"ok": False, "err": f"outer exception: {repr(e)}", "task_id": job.get("task_id")}

        with cf.ThreadPoolExecutor(max_workers=cfg["student_workers"]) as tp:
            futs = [tp.submit(wrap, j) for j in jobs]
            for fu in cf.as_completed(futs):
                try: results.append(fu.result())
                except Exception as e: results.append({"ok": False, "err": f"future exception: {repr(e)}"})

    # merge results into state; notify failures
    now = int(time.time())
    for r in results:
        if not isinstance(r, dict): continue
        if r.get("ok"):
            aid = r.get("assignment_id"); sig = r.get("sig")
            if aid and sig:
                state.setdefault("processed", {})[aid] = sig
            # record scored
            if r.get("score") is not None and task_ctx.get(r["task_id"],{}).get("item_id"):
                item_id = task_ctx[r["task_id"]]["item_id"]
                owner_id = r.get("receiver_id")
                if item_id and owner_id:
                    state.setdefault("scored", {}).setdefault(str(item_id), {})[str(owner_id)] = {"score": r["score"], "ts": now, "verified": bool(r.get("verified", False))}
        else:
            rec = {"task_id": r.get("task_id"), "assignment_id": r.get("assignment_id"), "receiver_id": r.get("receiver_id"), "reason": r.get("err"), "ts": now}
            state.setdefault("failed", []).append(rec)
            if cfg["tg_token"] and cfg["tg_chat"]:
                telegram_notify(cfg["tg_token"], cfg["tg_chat"], f"❌ 批改失敗 task={r.get('task_id')} assignment={r.get('assignment_id')} stu={r.get('receiver_id')}\n{r.get('err')}")

    # completion notifications
    for task_id, ctx in task_ctx.items():
        item_id = ctx.get("item_id")
        if not item_id: continue
        try:
            meta = api0.get_item_detail(item_id) or {}
            comp = (meta.get("completed_scores_counts") or {})
            actual = int(comp.get("actual") or 0); expected = int(comp.get("expected") or 0)
            if expected > 0 and actual >= expected:
                sent = state.get("reported_complete", {}).get(str(item_id))
                if not sent:
                    msg = f"✅ 作業完成：task {task_id} | item {item_id}  （{actual}/{expected}）"
                    telegram_notify(cfg["tg_token"], cfg["tg_chat"], msg)
                    state.setdefault("reported_complete", {})[str(item_id)] = now
        except Exception as e:
            logging.error(f"[COMPLETE] item {item_id} -> {repr(e)}", exc_info=True)

    save_state(cfg["state_path"], state)

if __name__ == "__main__":
    main()
PY
}

setup_venv() {
  echo "[4/10] Creating Python venv..."
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install -U pip
  "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt"
}

write_service_linux() {
  echo "[5/10] Writing systemd unit..."
  cat > /etc/systemd/system/$SERVICE <<EOF
[Unit]
Description=AGrader - Seiue auto-grader
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/python $APP_DIR/main.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable $SERVICE || true
}

write_launchd_macos() {
  echo "[5/10] Writing launchd plist..."
  mkdir -p "$(dirname "$LAUNCHD_PLIST")"
  cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>net.bdfz.agrader</string>
  <key>ProgramArguments</key>
  <array>
    <string>$VENV_DIR/bin/python</string>
    <string>$APP_DIR/main.py</string>
  </array>
  <key>WorkingDirectory</key><string>$APP_DIR</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PYTHONUNBUFFERED</key><string>1</string>
  </dict>
  <key>StandardOutPath</key><string>$APP_DIR/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$APP_DIR/launchd.err.log</string>
</dict>
</plist>
EOF
  launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
  launchctl load "$LAUNCHD_PLIST"
}

run_once() {
  echo "[6/10] Running once for smoke test..."
  "$VENV_DIR/bin/python" "$APP_DIR/main.py" || true
}

install_or_update() {
  local os=$(os_detect)
  if [ "$os" = "linux" ]; then
    install_pkgs_linux
  elif [ "$os" = "mac" ]; then
    install_pkgs_macos
  else
    echo "Unsupported OS"; exit 1
  fi

  write_project
  setup_venv

  if [ "$os" = "linux" ]; then
    write_service_linux
    echo "[7/10] Starting systemd service..."
    systemctl restart $SERVICE
    systemctl status $SERVICE --no-pager -l | sed -n '1,40p'
  else
    write_launchd_macos
    echo "[7/10] launchd loaded."
  fi

  echo "[8/10] Done. Logs:"
  if [ "$os" = "linux" ]; then
    journalctl -u $SERVICE -n 60 --no-pager || true
  else
    tail -n 60 "$APP_DIR/launchd.err.log" 2>/dev/null || true
  fi
}

install_or_update