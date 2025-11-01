#!/usr/bin/env bash
# AGrader - API-first auto-grading pipeline (installer/runner)
# Linux: apt/yum/apk + systemd; macOS: Homebrew + optional launchd
set -euo pipefail

APP_DIR="/opt/agrader"
VENV_DIR="$APP_DIR/venv"
ENV_FILE="$APP_DIR/.env"
SERVICE="agrader.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE}"
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

  # Confirmed endpoints (只保留權威端點；清掉多餘回退)
  if grep -q '^SEIUE_SCORE_ENDPOINTS=' "$ENV_FILE"; then
    sed -i.bak -E 's#^SEIUE_SCORE_ENDPOINTS=.*#SEIUE_SCORE_ENDPOINTS=POST:/vnas/klass/items/{item_id}/scores/sync?async=true\&from_task=true:array#' "$ENV_FILE" || true
  else
    echo 'SEIUE_SCORE_ENDPOINTS=POST:/vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true:array' >> "$ENV_FILE"
  fi
  grep -q '^SEIUE_REVIEW_POST_TEMPLATE=' "$ENV_FILE" || \
    echo 'SEIUE_REVIEW_POST_TEMPLATE=/chalk/task/v2/assignees/{receiver_id}/tasks/{task_id}/reviews' >> "$ENV_FILE"
  grep -q '^SEIUE_VERIFY_SCORE_GET_TEMPLATE=' "$ENV_FILE" || \
    echo 'SEIUE_VERIFY_SCORE_GET_TEMPLATE=/vnas/common/items/{item_id}/scores?paginated=0&type=item_score' >> "$ENV_FILE"

  # Strategy toggles / concurrency / AI backoff（降到安全基線）
  grep -q '^DRY_RUN=' "$ENV_FILE" || echo 'DRY_RUN=0' >> "$ENV_FILE"
  grep -q '^VERIFY_AFTER_WRITE=' "$ENV_FILE" || echo 'VERIFY_AFTER_WRITE=1' >> "$ENV_FILE"
  grep -q '^RETRY_FAILED=' "$ENV_FILE" || echo 'RETRY_FAILED=1' >> "$ENV_FILE"
  if grep -q '^STUDENT_WORKERS=' "$ENV_FILE"; then
    sed -i.bak -E 's#^STUDENT_WORKERS=.*#STUDENT_WORKERS=1#' "$ENV_FILE" || true
  else
    echo 'STUDENT_WORKERS=1' >> "$ENV_FILE"
  fi
  if grep -q '^ATTACH_WORKERS=' "$ENV_FILE"; then
    sed -i.bak -E 's#^ATTACH_WORKERS=.*#ATTACH_WORKERS=3#' "$ENV_FILE" || true
  else
    echo 'ATTACH_WORKERS=3'  >> "$ENV_FILE"
  fi
  if grep -q '^AI_PARALLEL=' "$ENV_FILE"; then
    sed -i.bak -E 's#^AI_PARALLEL=.*#AI_PARALLEL=1#' "$ENV_FILE" || true
  else
    echo 'AI_PARALLEL=1'     >> "$ENV_FILE"
  fi
  grep -q '^AI_MAX_RETRIES=' "$ENV_FILE"  || echo 'AI_MAX_RETRIES=5'  >> "$ENV_FILE"
  grep -q '^AI_BACKOFF_BASE_SECONDS=' "$ENV_FILE" || echo 'AI_BACKOFF_BASE_SECONDS=2.5' >> "$ENV_FILE"
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
    ask "Select 1/2" AI_CHOICE "2"
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
    STUDENT_WORKERS="1"
    ATTACH_WORKERS="3"
    AI_PARALLEL="1"
    AI_MAX_RETRIES="5"
    AI_BACKOFF_BASE_SECONDS="2.5"
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
SEIUE_SCORE_ENDPOINTS=POST:/vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true:array
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
AI_FAILOVER=1

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
    s.headers.update({"User-Agent": "AGrader/1.8 (+login)","Accept": "application/json, text/plain, */*"})
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

  # ---- ai_providers.py：修正：空輸出不再修，JSON 修復改走對向供應商 ----
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
        if not text:
            return {"per_question": [], "overall": {"score": 0, "comment": "AI rate limited"}}
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
        # Repair 使用「對向供應商」，避免在同一供應商上再次撞 429
        prefer = "deepseek" if self.provider == "gemini" else "gemini"
        if prefer == "deepseek":
            key = os.getenv("DEEPSEEK_API_KEY",""); model = os.getenv("DEEPSEEK_MODEL","deepseek-reasoner")
            if not key: return bad_text or ""
            url = "https://api.deepseek.com/chat/completions"; headers={"Authorization": f"Bearer {key}"}
            sys_prompt = "You are a JSON fixer. Return ONLY the corrected JSON object. No code fences. No commentary."
            user = "The following is not valid JSON. Please fix it and return only the corrected JSON object.\n\n<<<\n"+(bad_text or "")+"\n>>>"
            body={"model": model,"messages":[{"role":"system","content":sys_prompt},{"role":"user","content": user}],"temperature":0.0}
            r = requests.post(url, headers=headers, json=body, timeout=120); r.raise_for_status()
            data = r.json()
            return data.get("choices",[{}])[0].get("message",{}).get("content","")
        else:
            key = os.getenv("GEMINI_API_KEY",""); model = os.getenv("GEMINI_MODEL","gemini-2.5-pro")
            if not key: return bad_text or ""
            url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={key}"
            instr = "The following is not valid JSON. Please fix it and return only the corrected JSON object."
            body = {"contents":[{"parts":[{"text": instr+"\n\n<<<\n"+(bad_text or "")+"\n>>>\n"}]}], "generationConfig":{"temperature":0.0}}
            r = requests.post(url, json=body, timeout=120); r.raise_for_status()
            data = r.json()
            return data["candidates"][0]["content"]["parts"][0]["text"]
PY

  # ---- seiue_api.py：登入單例鎖 + 422 視為成功 + 刪回退噪音 ----
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
    s.headers.update({"Accept":"application/json, text/plain, */*","User-Agent":"AGrader/1.9"})
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
            # 可能其他執行緒已成功
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
        # 只使用權威端點；422(已存在) 視為成功
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

  cat > "$APP_DIR/main.py" <<'PY'
import os, json, time, logging, re, tempfile, threading, concurrent.futures as cf
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
        "interval": int(get("POLL_INTERVAL","10")),
        "workdir": get("WORKDIR","/opt/agrader/work"),
        "state_path": get("STATE_PATH","/opt/agrader/state.json"),
        "ocr_lang": get("OCR_LANG","chi_sim+eng"),
        "max_attach": int(get("MAX_ATTACHMENT_BYTES","25165824")),
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
    }

def load_state(path: str) -> Dict[str, Any]:
    try:
        with open(path,"r") as f: data = json.load(f)
        data.setdefault("processed", {}); data.setdefault("scored", {}); data.setdefault("failed", []); data.setdefault("reported_complete", {})
        return data
    except Exception:
        return {"processed": {}, "scored": {}, "failed": [], "reported_complete": {}}

def save_state(path: str, st: Dict[str, Any]):
    tmp = path + ".tmp"
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

def main():
    setup_logging()
    cfg = load_env()
    state = load_state(cfg["state_path"])

    # 實例化 AI（允許 failover）
    def make_ai(provider):
        if provider == "gemini":
            return AIClient("gemini", cfg["gemini_model"], cfg["gemini_key"])
        else:
            return AIClient("deepseek", cfg["deepseek_model"], cfg["deepseek_key"])
    ai = make_ai(cfg["ai_provider"])
    ai_alt = make_ai("deepseek" if cfg["ai_provider"]=="gemini" else "gemini") if cfg["ai_failover"] else None

    # API client
    api = Seiue(cfg["base"], cfg["bearer"], cfg["school_id"], cfg["role"], cfg["reflection_id"], cfg["username"], cfg["password"])

    if not cfg["task_ids"]:
        logging.info("No MONITOR_TASK_IDS provided; exiting.")
        return

    logging.info(f"[EXEC] Monitoring tasks={cfg['task_ids']} with STUDENT_WORKERS={cfg['student_workers']} ATTACH_WORKERS={cfg['attach_workers']} AI_PARALLEL={cfg['ai_parallel']}")

    # 批量取 task 元資料
    task_map = api.get_tasks_bulk(cfg["task_ids"])
    if not task_map:
        logging.warning("get_tasks_bulk returned empty; will fallback to single fetch per task.")
        task_map = {tid: api.get_task(tid) for tid in cfg["task_ids"]}

    # 主循環（單次跑一輪即可；若做 daemon，外層 systemd 負責重啟/定時）
    for task_id in cfg["task_ids"]:
        try:
            task = task_map.get(task_id) or api.get_task(task_id)
            item_id = (task.get("custom_fields") or {}).get("item_id") or task.get("item_id")
            if not item_id:
                logging.warning(f"[TASK {task_id}] no item_id; skip.")
                continue

            item_meta = api.get_item_detail(int(item_id)) or {}
            # 權威滿分與路徑
            try:
                full_score = float(item_meta.get("full_score") or 100)
            except Exception:
                full_score = 100.0

            perq, overall_max_guess = scan_question_maxima(task)
            overall_max = full_score if full_score else overall_max_guess

            assigns = api.get_assignments(task_id) or []
            # 學生並發處理（保守）
            sem = threading.Semaphore(cfg["ai_parallel"])

            def handle_one(a):
                with sem:
                    assignee = (a.get("assignee") or {})
                    assignee_id = int(assignee.get("id") or 0)
                    stu_name = assignee.get("name","")
                    sub = a.get("submission") or {}
                    sub_text = extract_submission_text(sub)

                    # 附件抽取（串列小量，ATTACH_WORKERS 控制）
                    attach_texts=[]
                    atts = sub.get("attachments") or []
                    if atts:
                        def one_attach(fid):
                            try:
                                url = api.get_file_signed_url(str(fid))
                                import tempfile, os
                                blob = api.download(url)
                                fd, p = tempfile.mkstemp(prefix="attach_", suffix=os.path.splitext(url.split("?")[0])[1])
                                with os.fdopen(fd,"wb") as f: f.write(blob)
                                txt = file_to_text(p, cfg["ocr_lang"], cfg["max_attach"])
                                try:
                                    if os.getenv("KEEP_WORK_FILES","0") in ("0","false","False"): os.remove(p)
                                except Exception: pass
                                return txt
                            except Exception as e:
                                logging.error(f"[ATTACH] {fid} {e}", exc_info=True); return f"[[error: attach {fid}]]"
                        with cf.ThreadPoolExecutor(max_workers=cfg["attach_workers"]) as tp:
                            futures=[tp.submit(one_attach, (x.get('id') or x)) for x in atts]
                            for fut in cf.as_completed(futures):
                                attach_texts.append(fut.result() or "")

                    # 構建 Prompt 並評分
                    prompt = build_prompt(task, item_meta, {"id": assignee_id, "name": stu_name}, sub_text, attach_texts, perq, overall_max)
                    try:
                        result = ai.grade(prompt)
                        if cfg["ai_failover"] and not result.get("per_question") and (result.get("overall",{}).get("score",0) == 0) and ai_alt:
                            logging.warning("[AI] primary returned empty/0; trying failover provider...")
                            result = ai_alt.grade(prompt)
                    except Exception as e:
                        logging.error(f"[AI] grade error: {e}", exc_info=True)
                        result = {"per_question": [], "overall": {"score": 0, "comment": "AI exception"}}

                    try:
                        overall_score = float(result.get("overall",{}).get("score",0) or 0.0)
                    except Exception:
                        overall_score = 0.0
                    overall_score = clamp(overall_score, 0.0, overall_max or 100.0)

                    # 寫入：review + score
                    if os.getenv("SCORE_WRITE","1") not in ("0","false","False"):
                        try:
                            api.post_review(assignee_id, task_id, result.get("overall",{}).get("comment",""))
                        except Exception as e:
                            logging.error(f"[REVIEW] {assignee_id} {e}", exc_info=True)
                        try:
                            ok = api.post_item_score(int(item_id), assignee_id, task_id, overall_score)
                            if not ok:
                                logging.warning(f"[SCORE] not ok for owner={assignee_id}")
                        except Exception as e:
                            logging.error(f"[SCORE] {assignee_id} {e}", exc_info=True)

            for a in assigns:
                try:
                    handle_one(a)
                except Exception as e:
                    logging.error(f"[STUDENT] handle error: {e}", exc_info=True)

        except Exception as e:
            logging.error(f"[TASK {task_id}] fatal: {e}", exc_info=True)

if __name__ == "__main__":
    main()
PY
}

create_venv() {
  echo "[4/10] Creating venv and installing requirements..."
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip >/dev/null
  "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt" >/dev/null
}

write_service_linux() {
  echo "[5/10] Writing systemd service (Linux)..."
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=AGrader - Seiue auto-grader
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=ENV_PATH=$ENV_FILE
ExecStart=$VENV_DIR/bin/python $APP_DIR/main.py
Restart=always
RestartSec=20s
StartLimitIntervalSec=300
StartLimitBurst=3
WorkingDirectory=$APP_DIR
# 日誌交給 journalctl；檔案路徑由 LOG_FILE 控制
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

write_launchd_macos() {
  echo "[5/10] Writing launchd plist (macOS)..."
  mkdir -p "$(dirname "$LAUNCHD_PLIST")"
  cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>net.bdfz.agrader</string>
  <key>ProgramArguments</key>
  <array>
    <string>$VENV_DIR/bin/python</string>
    <string>$APP_DIR/main.py</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>ENV_PATH</key><string>$ENV_FILE</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>WorkingDirectory</key><string>$APP_DIR</string>
  <key>StandardOutPath</key><string>$APP_DIR/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$APP_DIR/launchd.err.log</string>
</dict>
</plist>
EOF
}

stop_existing() {
  echo "[6/10] Stopping existing service if running..."
  if [ "$(os_detect)" = "linux" ] && systemctl is-active --quiet "$SERVICE"; then
    systemctl stop "$SERVICE" || true
  fi
  if [ "$(os_detect)" = "mac" ] && launchctl list | grep -q "net.bdfz.agrader"; then
    launchctl unload "$LAUNCHD_PLIST" || true
  fi
}

start_service() {
  echo "[7/10] Enabling and starting..."
  if [ "$(os_detect)" = "linux" ]; then
    systemctl enable "$SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE"
    sleep 1
    systemctl status --no-pager "$SERVICE" || true
  elif [ "$(os_detect)" = "mac" ]; then
    launchctl load -w "$LAUNCHD_PLIST"
    sleep 1
    launchctl list | grep net.bdfz.agrader || true
  fi
}

post_notes() {
  echo "[8/10] Done. Logs:"
  if [ "$(os_detect)" = "linux" ]; then
    journalctl -u "$SERVICE" -n 50 --no-pager || true
    echo
    echo "Tail: journalctl -u $SERVICE -f"
  else
    echo "Tail: tail -f $APP_DIR/launchd.err.log $APP_DIR/launchd.out.log"
  fi
  echo "[9/10] Edit config: sudo nano $ENV_FILE"
  echo "[10/10] Re-run: sudo systemctl restart $SERVICE   (macOS: launchctl unload/load)"
}

main() {
  case "$(os_detect)" in
    linux) install_pkgs_linux;;
    mac)   install_pkgs_macos;;
    *) echo "Unsupported OS"; exit 1;;
  esac
  stop_existing
  write_project
  create_venv
  if [ "$(os_detect)" = "linux" ]; then
    write_service_linux
  else
    write_launchd_macos
  fi
  start_service
  post_notes
}

main "$@"