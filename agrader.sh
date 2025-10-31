#!/usr/bin/env bash
# AGrader - one-shot installer/runner/uninstaller (all-in-one)
# OS: Debian/Ubuntu (apt), RHEL/CentOS/Rocky/Alma (yum/dnf), Alpine (apk)
set -euo pipefail

APP_DIR="/opt/agrader"
VENV_DIR="$APP_DIR/venv"
ENV_FILE="$APP_DIR/.env"
SERVICE="agrader.service"

have() { command -v "$1" >/dev/null 2>&1; }
ask() { local p="$1" var="$2" def="${3:-}"; local ans;
  if [ -n "${def}" ]; then read -r -p "$p [$def]: " ans || true; ans="${ans:-$def}";
  else read -r -p "$p: " ans || true; fi
  printf -v "$var" "%s" "$ans"
}
ask_secret() { local p="$1" var="$2"; local ans; read -r -s -p "$p: " ans || true; echo; printf -v "$var" "%s" "$ans"; }

install_pkgs() {
  echo "[1/9] Installing system dependencies..."
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
    echo "Unsupported package manager. Please install: python3, venv, pip, curl, jq, tesseract(+eng+chi_sim), poppler-utils, ghostscript, coreutils."
    exit 1
  fi
}

ensure_env_patch() {
  # 修补旧 .env：修正 LOG_FORMAT、补 LOG_DATEFMT、PUT 优先的评分端点
  [ -f "$ENV_FILE" ] || return 0
  cp -f "$ENV_FILE" "$ENV_FILE.bak.$(date +%s)" || true

  # 如果 LOG_FORMAT 缺失，或包含裸 %Y/%m/%d/%H（典型错误），改为映射式
  if ! grep -q '^LOG_FORMAT=' "$ENV_FILE"; then
    echo 'LOG_FORMAT=%(asctime)s.%(msecs)03d %(levelname)s %(name)s - %(message)s' >> "$ENV_FILE"
  elif grep -Eiq '^LOG_FORMAT=.*(%Y|%m|%d|%H|%M|%S)' "$ENV_FILE"; then
    sed -i -E 's#^LOG_FORMAT=.*#LOG_FORMAT=%(asctime)s.%(msecs)03d %(levelname)s %(name)s - %(message)s#' "$ENV_FILE"
  fi

  # 如果 LOG_DATEFMT 缺失则补上
  grep -q '^LOG_DATEFMT=' "$ENV_FILE" || echo 'LOG_DATEFMT=%Y-%m-%d %H:%M:%S' >> "$ENV_FILE"

  # 给分端点：若未设置或没有 PUT，就设置为 PUT 优先
  if ! grep -q '^SEIUE_SCORE_ENDPOINTS=' "$ENV_FILE"; then
    echo 'SEIUE_SCORE_ENDPOINTS=PUT:/common/items/{item_id}/scores?type=item_score:array;PUT:/vnas/common/items/{item_id}/scores?type=item_score:array;POST:/vnas/common/items/{item_id}/scores?type=item_score:array;POST:/common/items/{item_id}/scores?type=item_score:array' >> "$ENV_FILE"
  elif ! grep -q '^SEIUE_SCORE_ENDPOINTS=.*PUT:' "$ENV_FILE"; then
    sed -i -E 's#^SEIUE_SCORE_ENDPOINTS=.*#SEIUE_SCORE_ENDPOINTS=PUT:/common/items/{item_id}/scores?type=item_score:array;PUT:/vnas/common/items/{item_id}/scores?type=item_score:array;POST:/vnas/common/items/{item_id}/scores?type=item_score:array;POST:/common/items/{item_id}/scores?type=item_score:array#' "$ENV_FILE"
  fi
}

write_project() {
  echo "[2/9] Collecting initial configuration..."
  mkdir -p "$APP_DIR" "$APP_DIR/work"

  if [ ! -f "$ENV_FILE" ]; then
    echo "Enter Seiue API credentials/headers (auto OR manual)."
    echo "— Auto mode: provide username/password to auto-login & refresh when needed."
    echo "— Manual mode: leave username/password empty and paste Bearer token & reflection_id."
    ask "Seiue API Base" SEIUE_BASE "https://api.seiue.com"

    # AUTO MODE (optional)
    ask "Seiue Username (leave empty to skip auto-login)" SEIUE_USERNAME ""
    if [ -n "$SEIUE_USERNAME" ]; then
      ask_secret "Seiue Password" SEIUE_PASSWORD
    else
      SEIUE_PASSWORD=""
    fi

    # MANUAL MODE (optional / fallback)
    ask "X-School-Id" SEIUE_SCHOOL_ID "3"
    ask "X-Role" SEIUE_ROLE "teacher"
    ask "X-Reflection-Id (manual; empty if auto-login)" SEIUE_REFLECTION_ID ""
    ask_secret "Bearer token (manual; empty if auto-login)" SEIUE_BEARER

    ask "Comma-separated Task IDs to monitor" MONITOR_TASK_IDS
    ask "Polling interval seconds" POLL_INTERVAL "10"

    echo
    echo "Choose AI provider:"
    echo "  1) gemini (Google Generative Language)"
    echo "  2) deepseek"
    ask "Select 1/2" AI_CHOICE "1"
    if [ "$AI_CHOICE" = "2" ]; then
      AI_PROVIDER="deepseek"
      ask_secret "DeepSeek API Key" DEEPSEEK_API_KEY
      ask "DeepSeek Model" DEEPSEEK_MODEL "deepseek-reasoner"
      GEMINI_API_KEY=""
      GEMINI_MODEL="gemini-2.5-pro"
    else
      AI_PROVIDER="gemini"
      ask_secret "Gemini API Key" GEMINI_API_KEY
      ask "Gemini Model" GEMINI_MODEL "gemini-2.5-pro"
      DEEPSEEK_API_KEY=""
      DEEPSEEK_MODEL="deepseek-reasoner"
    fi

    echo
    echo "Telegram (optional, ENTER to skip)"
    ask "Telegram Bot Token" TELEGRAM_BOT_TOKEN ""
    ask "Telegram Chat ID" TELEGRAM_CHAT_ID ""

    echo
    echo "Heavy PDF OCR fallback control:"
    ask "Enable PDF OCR fallback after pdftotext fails? (1/0)" ENABLE_PDF_OCR_FALLBACK "1"
    ask "Max PDF pages allowed for OCR fallback" MAX_PDF_OCR_PAGES "20"
    ask "Max seconds allowed for OCR fallback (timeout)" MAX_PDF_OCR_SECONDS "120"
    ask "Notify via Telegram when skipping heavy OCR? (1/0)" TELEGRAM_VERBOSE "1"
    ask "Keep downloaded work files for debugging? (1/0)" KEEP_WORK_FILES "0"

    echo
    echo "Logging options:"
    ask "LOG_LEVEL (DEBUG/INFO/WARN/ERROR)" LOG_LEVEL "INFO"
    ask "LOG_FILE path" LOG_FILE "$APP_DIR/agrader.log"
    # 固定给出正确的默认格式
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

# Confirmed review endpoint
SEIUE_REVIEW_POST_TEMPLATE=/chalk/task/v2/assignees/{receiver_id}/tasks/{task_id}/reviews

# Multiple fallback endpoints for score (METHOD:PATH[:BODY])
# 405/MethodNotAllowed 时自动换路径/方法；BODY=array|object（默认 array）
SEIUE_SCORE_ENDPOINTS=PUT:/common/items/{item_id}/scores?type=item_score:array;PUT:/vnas/common/items/{item_id}/scores?type=item_score:array;POST:/vnas/common/items/{item_id}/scores?type=item_score:array;POST:/common/items/{item_id}/scores?type=item_score:array

# ---- AI ----
AI_PROVIDER=${AI_PROVIDER}
GEMINI_API_KEY=${GEMINI_API_KEY}
GEMINI_MODEL=${GEMINI_MODEL}
DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY}
DEEPSEEK_MODEL=${DEEPSEEK_MODEL}

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

# ---- Scoring/Review strategy ----
SCORE_WRITE=1
REVIEW_ALL_EXISTING=1
SCORE_GIVE_ALL_ON_START=1

# ---- Paths/State ----
STATE_PATH=${APP_DIR}/state.json
WORKDIR=${APP_DIR}/work
EOF
    chmod 600 "$ENV_FILE"
  else
    echo "Reusing existing $ENV_FILE"
    ensure_env_patch
  fi

  echo "[3/9] Writing project files..."
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

  # ---- docs ----
  cat > "$APP_DIR/AGRADER_DEPLOY.md" <<'EOF'
# AGrader (Seiue auto-grading pipeline)

Flow: listen → fetch submission → fetch task → extract (DraftJS + attachments OCR) → AI grade (Gemini/DeepSeek) → clamp to max → write back review (+ score) → Telegram notify.

Auth:
- Auto mode (recommended): set SEIUE_USERNAME/SEIUE_PASSWORD only; the service logs in, stores bearer in memory, refreshes on 401/403.
- Manual mode: set SEIUE_BEARER (+ optional SEIUE_REFLECTION_ID). Auto-login is skipped.

Confirmed endpoints:
- POST review: /chalk/task/v2/assignees/{receiver_id}/tasks/{task_id}/reviews  (expect 201)
- GET assignments: /chalk/task/v2/tasks/{task_id}/assignments?expand=is_excellent,assignee,team,submission,review
- GET signed file URL: /chalk/netdisk/files/{file_id}/url  (302 Location)
- Score write: multiple fallbacks; see .env (SCORE_WRITE / SEIUE_SCORE_ENDPOINTS / legacy template)

Attachments to AI: Files are extracted to text (pdftotext/ocr) and MERGED into the prompt. The model names remain exactly as configured.

Logging:
- Use LOG_FORMAT (mapping style) + LOG_DATEFMT. Example:
  LOG_FORMAT="%(asctime)s.%(msecs)03d %(levelname)s %(name)s - %(message)s"
  LOG_DATEFMT="%Y-%m-%d %H:%M:%S"
EOF

  # ---- utilx.py ----
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
    for k in ["score_items", "questions", "problems", "rubric", "grading", "grading_items"]:
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
    import hashlib
    return hashlib.sha256(text.encode("utf-8", "ignore")).hexdigest()
PY

  # ---- credentials.py (auto-login) ----
  cat > "$APP_DIR/credentials.py" <<'PY'
import logging, requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

class AuthResult:
    def __init__(self, ok: bool, token: str = "", reflection_id: str = "", detail: str = ""):
        self.ok = ok
        self.token = token
        self.reflection_id = reflection_id
        self.detail = detail

def _session_with_retries() -> requests.Session:
    s = requests.Session()
    r = Retry(total=5, backoff_factor=1.5, status_forcelist=(429,500,502,503,504), allowed_methods=frozenset({"GET","POST"}))
    s.mount("https://", HTTPAdapter(max_retries=r))
    s.headers.update({
        "User-Agent": "AGrader/1.4 (+login)",
        "Accept": "application/json, text/plain, */*",
    })
    return s

def login(username: str, password: str) -> AuthResult:
    try:
        sess = _session_with_retries()
        login_url = "https://passport.seiue.com/login?school_id=3&type=account&from=null&redirect_url=null"
        auth_url  = "https://passport.seiue.com/authorize"

        login_form = {"email": username, "login": username, "username": username, "password": password}
        login_headers = {
            "Referer": login_url,
            "Origin": "https://passport.seiue.com",
            "Content-Type": "application/x-www-form-urlencoded",
        }
        lr = sess.post(login_url, headers=login_headers, data=login_form, timeout=30)
        if lr.status_code >= 400:
            logging.error(f"[AUTH] Login HTTP {lr.status_code}: {(lr.text or '')[:300]}")
        if "chalk" not in lr.url and "bindings" not in lr.url:
            logging.warning(f"[AUTH] Login redirect URL unexpected: {lr.url}")

        auth_form = {"client_id":"GpxvnjhVKt56qTmnPWH1sA","response_type":"token"}
        auth_headers = {
            "Referer": "https://chalk-c3.seiue.com/",
            "Origin": "https://chalk-c3.seiue.com",
            "Content-Type": "application/x-www-form-urlencoded",
        }
        ar = sess.post(auth_url, headers=auth_headers, data=auth_form, timeout=30)
        ar.raise_for_status()
        j = ar.json() or {}
        token = j.get("access_token","")
        reflection = j.get("active_reflection_id","")
        if token and reflection:
            logging.info("[AUTH] Acquired access_token and reflection_id.")
            return AuthResult(True, token, str(reflection))
        return AuthResult(False, detail=f"Missing token or reflection_id in response: keys={list(j.keys())}")
    except requests.RequestException as e:
        logging.error(f"[AUTH] Network error during auth: {e}", exc_info=True)
        return AuthResult(False, detail=str(e))
PY

  # ---- extractor.py ----
  cat > "$APP_DIR/extractor.py" <<'PY'
import os, subprocess, tempfile, mimetypes, traceback, shutil, logging
from typing import Tuple
from PIL import Image
import pytesseract

def _run(cmd: list, input_bytes: bytes=None, timeout=180) -> Tuple[int, bytes, bytes]:
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE if input_bytes else None,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, err = p.communicate(input=input_bytes, timeout=timeout)
    return p.returncode, out, err

def _pdf_pages(path: str) -> int:
    try:
        code, out, _ = _run(["pdfinfo", path], timeout=20)
        if code == 0:
            for line in out.decode("utf-8","ignore").splitlines():
                if line.lower().startswith("pages:"):
                    return int(line.split(":")[1].strip())
    except Exception:
        pass
    return -1

def file_to_text(path: str, ocr_lang: str="chi_sim+eng", size_cap: int=25*1024*1024) -> str:
    if not os.path.exists(path):
        return "[[error: file not found]]"
    sz = os.path.getsize(path)
    if sz > size_cap:
        return f"[[skipped: file too large ({sz} bytes)]]"

    mt, _ = mimetypes.guess_type(path)
    ext = (os.path.splitext(path)[1] or "").lower()

    if ext == ".pdf" or (mt and mt.endswith("pdf")):
        try:
            code, out, err = _run(["pdftotext", "-layout", path, "-"], timeout=120)
            if code == 0 and out.strip():
                return out.decode("utf-8", "ignore")
        except Exception as e:
            logging.warning(f"[EXTRACT] pdftotext failed: {e}", exc_info=True)

        enable_fallback = os.getenv("ENABLE_PDF_OCR_FALLBACK","1") not in ("0", "false", "False")
        max_pages = int(os.getenv("MAX_PDF_OCR_PAGES","20"))
        max_seconds = int(os.getenv("MAX_PDF_OCR_SECONDS","120"))
        pages = _pdf_pages(path)
        if (not enable_fallback) or (pages > 0 and pages > max_pages):
            return f"[[skipped: pdf ocr fallback disabled or too large (pages={pages}, size={sz})]]"

        try:
            tmpdir = tempfile.mkdtemp(prefix="pdfocr_")
            prefix = os.path.join(tmpdir, "pg")
            code, _, err = _run(["pdftoppm", "-r", "200", path, prefix], timeout=max_seconds)
            text_acc = []
            if code == 0:
                for f in sorted(os.listdir(tmpdir)):
                    if f.startswith("pg") and (f.endswith(".ppm") or f.endswith(".png") or f.endswith(".jpg")):
                        img_path = os.path.join(tmpdir, f)
                        try:
                            img = Image.open(img_path)
                            part = pytesseract.image_to_string(img, lang=ocr_lang)
                            text_acc.append(part)
                        except Exception as e:
                            logging.error(f"[OCR] tesseract error on {f}: {e}", exc_info=True)
                            text_acc.append(f"[[error: tesseract {e} on {f}]]")
                merged = "\n".join(text_acc).strip()
                return merged or "[[error: ocr produced empty text]]"
            return f"[[error: pdftoppm failed code={code} msg={err.decode('utf-8','ignore')[:200]}]]"
        except Exception as e:
            logging.error(f"[EXTRACT] pdf ocr fallback exception: {e}", exc_info=True)
            return f"[[error: pdf ocr fallback exception: {repr(e)}]]"

    if ext in [".png", ".jpg", ".jpeg", ".bmp", ".tiff", ".webp"] or (mt and mt.startswith("image/")):
        try:
            img = Image.open(path)
            return pytesseract.image_to_string(img, lang=ocr_lang) or "[[error: image ocr empty]]"
        except Exception as e:
            logging.error(f"[EXTRACT] image ocr exception: {e}", exc_info=True)
            return f"[[error: image ocr exception: {repr(e)}]]"

    if ext == ".docx":
        try:
            import docx
            doc = docx.Document(path)
            return "\n".join(p.text for p in doc.paragraphs)
        except Exception as e:
            logging.error(f"[EXTRACT] docx extract exception: {e}", exc_info=True)
            return f"[[error: docx extract exception: {repr(e)}]]"

    if ext == ".pptx":
        try:
            from pptx import Presentation
            prs = Presentation(path)
            lines=[]
            for s in prs.slides:
                for shp in s.shapes:
                    if hasattr(shp, "text"):
                        lines.append(shp.text)
            return "\n".join(lines) or "[[error: pptx no text]]"
        except Exception as e:
            logging.error(f"[EXTRACT] pptx extract exception: {e}", exc_info=True)
            return f"[[error: pptx extract exception: {repr(e)}]]"

    try:
        with open(path, "rb") as f:
            b = f.read()
        return b.decode("utf-8", "ignore")
    except Exception as e:
        logging.error(f"[EXTRACT] unknown file read exception: {e}", exc_info=True)
        return f"[[error: unknown file read exception: {repr(e)}]]"
PY

  # ---- ai_providers.py ----
  cat > "$APP_DIR/ai_providers.py" <<'PY'
import os, time, json, requests, logging, random

def _backoff_loop():
    max_retries = int(os.getenv("AI_MAX_RETRIES","5"))
    base = float(os.getenv("AI_BACKOFF_BASE_SECONDS","1.5"))
    jitter = float(os.getenv("AI_JITTER_SECONDS","0.5"))
    for i in range(max_retries):
        yield i
        sleep = (base ** i) + random.uniform(0, jitter)
        time.sleep(sleep)

class AIClient:
    def __init__(self, provider: str, model: str, key: str):
        self.provider = provider
        self.model = model
        self.key = key

    def grade(self, prompt: str) -> dict:
        try:
            if self.provider == "gemini":
                return self._gemini(prompt)
            elif self.provider == "deepseek":
                return self._deepseek(prompt)
            else:
                raise ValueError("Unknown AI provider")
        except requests.RequestException as e:
            logging.error(f"[AI] network error: {e}", exc_info=True)
            return {"per_question": [], "overall": {"score": 0, "comment": f"AI网络错误: {e}"}}
        except Exception as e:
            logging.error(f"[AI] client error: {e}", exc_info=True)
            return {"per_question": [], "overall": {"score": 0, "comment": f"AI调用异常: {e}"}}

    def _gemini(self, prompt: str) -> dict:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{self.model}:generateContent?key={self.key}"
        body = {"contents": [{"parts":[{"text": prompt}]}], "generationConfig": {"temperature": 0.2}}
        for _ in _backoff_loop():
            r = requests.post(url, json=body, timeout=180)
            if r.status_code == 429:
                logging.warning("[AI] Gemini 429; backing off and retrying...")
                continue
            r.raise_for_status()
            data = r.json()
            txt = ""
            try:
                txt = data["candidates"][0]["content"]["parts"][0]["text"]
            except Exception:
                txt = json.dumps(data)[:4000]
            return self._force_json(txt)
        return {"per_question": [], "overall": {"score": 0, "comment": "AI 429 too many requests"}}

    def _deepseek(self, prompt: str) -> dict:
        url = "https://api.deepseek.com/chat/completions"
        headers = {"Authorization": f"Bearer {self.key}"}
        body = {
            "model": self.model,
            "messages": [{"role":"system","content":"You are a strict grader. Output ONLY valid JSON per schema."},
                         {"role":"user","content": prompt}],
            "temperature": 0.2
        }
        for _ in _backoff_loop():
            r = requests.post(url, headers=headers, json=body, timeout=180)
            if r.status_code == 429:
                logging.warning("[AI] DeepSeek 429; backing off and retrying...")
                continue
            r.raise_for_status()
            data = r.json()
            txt = data.get("choices",[{}])[0].get("message",{}).get("content","")
            return self._force_json(txt)
        return {"per_question": [], "overall": {"score": 0, "comment": "AI 429 too many requests"}}

    def _force_json(self, text: str) -> dict:
        text = (text or "").strip()
        if text.startswith("{"):
            try: return json.loads(text)
            except Exception: pass
        import re
        m = re.search(r"\{.*\}", text, re.S)
        if m:
            try: return json.loads(m.group(0))
            except Exception as e:
                logging.error(f"[AI] JSON parse error: {e}", exc_info=True)
        return {"per_question": [], "overall": {"score": 0, "comment": text[:200]}}
PY

  # ---- seiue_api.py (multi-endpoint PUT/POST fallback, unchanged逻辑) ----
  cat > "$APP_DIR/seiue_api.py" <<'PY'
import os, logging, requests
from typing import Dict, Any, List, Tuple
from credentials import login, AuthResult
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

def _session_with_retries() -> requests.Session:
    s = requests.Session()
    r = Retry(total=5, backoff_factor=1.5, status_forcelist=(429,500,502,503,504),
              allowed_methods=frozenset({"GET","POST","PUT"}))
    s.mount("https://", HTTPAdapter(max_retries=r))
    return s

class Seiue:
    def __init__(self, base: str, bearer: str, school_id: str, role: str, reflection_id: str,
                 username: str="", password: str=""):
        self.base = base.rstrip("/")
        self.username = username
        self.password = password
        self.school_id = str(school_id)
        self.role = role
        self.reflection_id = str(reflection_id) if reflection_id else ""
        self.bearer = bearer or ""
        self.session = _session_with_retries()
        self._init_headers()
        if not self.bearer and self.username and self.password:
            self._login_and_apply()

    def _init_headers(self):
        self.session.headers.update({
            "Accept": "application/json, text/plain, */*",
            "User-Agent": "AGrader/1.4",
        })
        if self.bearer:
            self.session.headers.update({"Authorization": f"Bearer {self.bearer}"})
        if self.school_id:
            self.session.headers.update({"X-School-Id": self.school_id, "x-school-id": self.school_id})
        if self.role:
            self.session.headers.update({"X-Role": self.role, "x-role": self.role})
        if self.reflection_id:
            self.session.headers.update({"X-Reflection-Id": self.reflection_id, "x-reflection-id": self.reflection_id})

    def _login_and_apply(self) -> bool:
        if not (self.username and self.password):
            return False
        logging.info("[AUTH] Attempting auto-login with username/password...")
        res: AuthResult = login(self.username, self.password)
        if res.ok:
            self.bearer = res.token
            if res.reflection_id:
                self.reflection_id = str(res.reflection_id)
            self._init_headers()
            logging.info("[AUTH] Auto-login successful; headers updated.")
            return True
        logging.error(f"[AUTH] Auto-login failed: {res.detail}")
        return False

    def _url(self, path: str) -> str:
        if path.startswith("http"): return path
        if not path.startswith("/"): path = "/" + path
        return self.base + path

    def _with_refresh(self, request_fn):
        r = request_fn()
        if getattr(r, "status_code", None) in (401,403):
            logging.warning("[AUTH] Got 401/403; trying to re-auth...")
            if self._login_and_apply():
                return request_fn()
        return r

    def get_assignments(self, task_id: int) -> List[Dict[str, Any]]:
        url = self._url(f"/chalk/task/v2/tasks/{task_id}/assignments?expand=is_excellent,assignee,team,submission,review")
        r = self._with_refresh(lambda: self.session.get(url, timeout=60))
        if r.status_code >= 400:
            logging.error(f"[API] get_assignments HTTP {r.status_code}: {(r.text or '')[:500]}")
        r.raise_for_status()
        return r.json()

    def get_task(self, task_id: int) -> Dict[str, Any]:
        url = self._url(f"/chalk/task/v2/tasks/{task_id}")
        r = self._with_refresh(lambda: self.session.get(url, timeout=60))
        if r.status_code >= 400:
            logging.error(f"[API] get_task HTTP {r.status_code}: {(r.text or '')[:500]}")
        r.raise_for_status()
        return r.json()

    def get_file_signed_url(self, file_id: str) -> str:
        url = self._url(f"/chalk/netdisk/files/{file_id}/url")
        r = self._with_refresh(lambda: self.session.get(url, allow_redirects=False, timeout=60))
        if r.status_code in (301,302) and "Location" in r.headers:
            return r.headers["Location"]
        try:
            j = r.json()
            if isinstance(j, dict) and j.get("url"): return j["url"]
        except Exception:
            pass
        if r.status_code >= 400:
            logging.error(f"[API] file url HTTP {r.status_code}: {(r.text or '')[:500]}")
        r.raise_for_status()
        return ""

    def download(self, url: str) -> bytes:
        r = self._with_refresh(lambda: self.session.get(url, timeout=120))
        if r.status_code >= 400:
            logging.error(f"[API] download HTTP {r.status_code}: {(r.text or '')[:200]}")
        r.raise_for_status()
        return r.content

    def post_review(self, receiver_id: int, task_id: int, content: str, result="approved") -> Dict[str, Any]:
        path = os.getenv("SEIUE_REVIEW_POST_TEMPLATE","/chalk/task/v2/assignees/{receiver_id}/tasks/{task_id}/reviews").format(
            receiver_id=receiver_id, task_id=task_id)
        url = self._url(path)
        body = {
            "result": result, "content": content, "reason": "",
            "attachments": [], "do_evaluation": False, "is_submission_changed": False
        }
        r = self._with_refresh(lambda: self.session.post(url, json=body, timeout=60))
        if r.status_code not in (200,201):
            logging.error(f"[API] post_review HTTP {r.status_code}: {(r.text or '')[:400]}")
            r.raise_for_status()
        return r.json()

    def post_item_score(self, item_id: int, owner_id: int, task_id: int, score: float) -> Tuple[int, str]:
        candidates = []
        def add(method, path, body="array"):
            candidates.append({"method": method, "path": path, "body": body})

        raw = (os.getenv("SEIUE_SCORE_ENDPOINTS","") or "").strip()
        if raw:
            for seg in raw.split(";"):
                seg = seg.strip()
                if not seg: continue
                parts = seg.split(":")
                if len(parts) < 2: continue
                method = parts[0].strip().upper()
                body   = "array"
                if len(parts) >= 3: body = parts[-1].strip().lower()
                path   = ":".join(parts[1:-1]) if len(parts) > 2 else parts[1]
                if method not in ("POST","PUT"): method = "POST"
                if body not in ("array","object"): body = "array"
                add(method, path.strip(), body)

        if not candidates:
            add("PUT",  "/common/items/{item_id}/scores?type=item_score", "array")
            add("PUT",  "/vnas/common/items/{item_id}/scores?type=item_score", "array")
            add("POST", "/vnas/common/items/{item_id}/scores?type=item_score", "array")
            add("POST", "/common/items/{item_id}/scores?type=item_score", "array")

        last_code, last_text = 0, ""
        for i, c in enumerate(candidates, 1):
            path = c["path"].format(item_id=item_id)
            url  = self._url(path)
            method = c["method"]
            if c["body"] == "array":
                body = [{
                    "owner_id": owner_id, "valid": True, "score": str(score),
                    "review": "", "attachments": [], "related_data": {"task_id": task_id},
                    "type": "item_score", "status": "published"
                }]
            else:
                body = {
                    "owner_id": owner_id, "valid": True, "score": str(score),
                    "review": "", "attachments": [], "related_data": {"task_id": task_id},
                    "type": "item_score", "status": "published"
                }

            logging.info(f"[API] score try#{i}: {method} {path} body={c['body']}")
            r = self._with_refresh(lambda: self.session.request(method, url, json=body, timeout=60))
            last_code, last_text = getattr(r, "status_code", 0), (r.text or "")[:400]

            if 200 <= last_code < 300 or last_code in (200,201,204):
                logging.info(f"[API] score success: {method} {path} -> {last_code}")
                return last_code, last_text

            logging.warning(f"[API] score failed: {method} {path} -> {last_code} :: {last_text}")

        return last_code, last_text
PY

  # ---- main.py ----
  cat > "$APP_DIR/main.py" <<'PY'
import os, json, time, logging
from typing import Dict, Any, List
from dotenv import load_dotenv
from utilx import draftjs_to_text, scan_question_maxima, clamp, stable_hash
from extractor import file_to_text
from ai_providers import AIClient
from seiue_api import Seiue
import requests

def setup_logging():
    level = os.getenv("LOG_LEVEL","INFO").upper()
    level_map = {"DEBUG": logging.DEBUG, "INFO": logging.INFO, "WARN": logging.WARN, "WARNING": logging.WARN, "ERROR": logging.ERROR}
    log_level = level_map.get(level, logging.INFO)
    log_file = os.getenv("LOG_FILE","/opt/agrader/agrader.log")
    fmt = os.getenv("LOG_FORMAT", "%(asctime)s.%(msecs)03d %(levelname)s %(name)s - %(message)s")
    datefmt = os.getenv("LOG_DATEFMT", "%Y-%m-%d %H:%M:%S")
    logging.basicConfig(level=log_level, format=fmt, datefmt=datefmt)
    try:
        fh = logging.FileHandler(log_file, encoding="utf-8", mode="a")
        fh.setLevel(log_level)
        fh.setFormatter(logging.Formatter(fmt, datefmt=datefmt))
        logging.getLogger().addHandler(fh)
    except Exception:
        logging.warning(f"Cannot open LOG_FILE={log_file} for writing.")
    if log_level == logging.DEBUG:
        logging.getLogger("urllib3").setLevel(logging.INFO)

def load_env():
    load_dotenv(os.getenv("ENV_PATH",".env"))
    env = os.environ
    get = lambda k,d="": env.get(k,d)
    def as_bool(x: str, default=True):
        if x is None or x == "": return default
        return x not in ("0","false","False","no","NO")
    cfg = {
        "base": get("SEIUE_BASE","https://api.seiue.com"),
        "username": get("SEIUE_USERNAME",""),
        "password": get("SEIUE_PASSWORD",""),
        "bearer": get("SEIUE_BEARER",""),
        "school_id": get("SEIUE_SCHOOL_ID","3"),
        "role": get("SEIUE_ROLE","teacher"),
        "reflection_id": get("SEIUE_REFLECTION_ID",""),
        "task_ids": [int(x.strip()) for x in get("MONITOR_TASK_IDS","").split(",") if x.strip()],
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
        "tg_token": get("TELEGRAM_BOT_TOKEN",""),
        "tg_chat": get("TELEGRAM_CHAT_ID",""),
        "tg_verbose": as_bool(get("TELEGRAM_VERBOSE","1")),
        "score_write": as_bool(get("SCORE_WRITE","1")),
        "review_all_existing": as_bool(get("REVIEW_ALL_EXISTING","1")),
        "score_all_on_start": as_bool(get("SCORE_GIVE_ALL_ON_START","1")),
    }
    return cfg

def load_state(path: str) -> Dict[str, Any]:
    try:
        with open(path, "r") as f: return json.load(f)
    except Exception: return {"processed": {}, "scored": {}}

def save_state(path: str, st: Dict[str, Any]):
    tmp = path + ".tmp"
    with open(tmp, "w") as f: json.dump(st, f)
    os.replace(tmp, path)

def telegram_notify(token: str, chat: str, text: str):
    if not token or not chat: return
    try:
        requests.post(f"https://api.telegram.org/bot{token}/sendMessage",
                      json={"chat_id": chat, "text": text, "parse_mode": "HTML", "disable_web_page_preview": True},
                      timeout=20)
    except Exception as e:
        logging.error(f"[TG] send error: {e}", exc_info=True)

def build_prompt(task: Dict[str,Any], stu: Dict[str,Any], sub_text: str, attach_texts: List[str], perq, overall_max) -> str:
    task_title = task.get("title","(untitled)")
    task_content_raw = task.get("content","")
    task_content = task_content_raw
    try:
        if task_content_raw and task_content_raw.strip().startswith("{"):
            task_content = draftjs_to_text(task_content_raw)
    except Exception:
        pass
    lines = []
    lines.append("You are a strict Chinese-language grader. Return ONLY JSON per the schema.")
    lines.append("")
    lines.append("== TASK =="); lines.append(f"Title: {task_title}"); lines.append(f"Instruction:\n{task_content}")
    lines.append(""); lines.append("== STUDENT =="); lines.append(f"Name: {stu.get('name','')}, ID: {stu.get('id','')}")
    lines.append(""); lines.append("== STUDENT SUBMISSION (TEXT) =="); lines.append(sub_text[:20000]); lines.append("")
    if attach_texts:
        lines.append("== ATTACHMENTS (TEXT MERGED) ==")
        for i, t in enumerate(attach_texts,1):
            lines.append(f"[Attachment #{i} | len={len(t)}]\n{t[:20000]}")
            lines.append("")
    lines.append("== SCORING CONSTRAINTS ==")
    if perq:
        lines.append("Per-question maxima:")
        for q in perq: lines.append(f"- {q['id']}: max {q['max']}")
        lines.append(f"Overall max = {overall_max}")
    else:
        lines.append(f"No per-question rubric found; overall max = {overall_max}")
    lines.append("""
== OUTPUT JSON SCHEMA ==
{
  "per_question": [{"id":"<qid>","score": <0..max>,"comment":"<=100 chars"}],
  "overall": {"score": <0..overall_max>, "comment":"<=200 chars"}
}
Rules: Never exceed maxima; use integers where natural; comments concise in Chinese; do not include any extra keys.
""")
    return "\n".join(lines)

def extract_submission_text(sub: Dict[str,Any]) -> str:
    t = sub.get("content_text","") or sub.get("content","")
    try:
        if isinstance(t, str) and t.strip().startswith("{"):
            return draftjs_to_text(t)
        if isinstance(t, str):
            return t
    except Exception:
        pass
    return ""

def run_once(cfg, api: Seiue, state: Dict[str,Any], ai_client: AIClient):
    processed_all = state.setdefault("processed", {})
    scored_all = state.setdefault("scored", {})  # per task: {receiver_id: true}

    os.makedirs(cfg["workdir"], exist_ok=True)

    for task_id in cfg["task_ids"]:
        try:
            assigns = api.get_assignments(task_id)
        except Exception as e:
            logging.error(f"[RUN] get_assignments({task_id}) failed: {e}", exc_info=True)
            continue

        task_obj = None
        for a in assigns:
            if "task" in a: task_obj = a["task"]; break
        if not task_obj:
            try: task_obj = api.get_task(task_id)
            except Exception:
                task_obj = {"id": task_id, "title":"(unknown)"}

        perq, overall_max = scan_question_maxima(task_obj)
        item_id = int(task_obj.get("custom_fields",{}).get("item_id", 0)) if isinstance(task_obj.get("custom_fields"), dict) else 0

        tmap = processed_all.setdefault(str(task_id), {})
        smap = scored_all.setdefault(str(task_id), {})

        for a in assigns:
            assignee = a.get("assignee") or {}
            receiver_id = int(assignee.get("id") or 0)
            if not receiver_id: continue
            sub = a.get("submission")
            if not sub: continue

            sub_id = str(sub.get("id") or "")
            updated = sub.get("updated_at") or sub.get("created_at") or ""
            sig = stable_hash((sub.get("content_text") or sub.get("content") or "") + "|" + (updated or ""))
            already = (tmap.get(sub_id) == sig)

            has_review = bool(a.get("review"))
            needs_review = (not has_review) and cfg["review_all_existing"]
            needs_score_on_start = cfg["score_all_on_start"] and (str(receiver_id) not in smap)

            should_process = (not already) or needs_review or needs_score_on_start
            if not should_process:
                continue

            sub_text = extract_submission_text(sub)
            attach_texts = []
            for att in (sub.get("attachments") or []):
                fid = att.get("id") or att.get("file_id") or att.get("oss_key") or ""
                if not fid: continue
                tmp_path = None
                try:
                    url = api.get_file_signed_url(str(fid))
                    blob = api.download(url)
                    import os as _os, tempfile as _tmp
                    ext = _os.path.splitext(url.split("?")[0])[1]
                    fp = _tmp.NamedTemporaryFile(delete=False, dir=cfg["workdir"], suffix=ext or ".bin")
                    tmp_path = fp.name
                    fp.write(blob); fp.close()
                    txt = file_to_text(tmp_path, ocr_lang=cfg["ocr_lang"], size_cap=cfg["max_attach"])
                    logging.info(f"[ATTACH] fid={fid} bytes={len(blob)} -> text_len={len(txt)} head={txt[:60].replace(chr(10),' ')}")
                    attach_texts.append(txt)
                except Exception as e:
                    msg = f"[[error: attachment {fid} download/extract failed: {repr(e)}]]"
                    logging.error(f"[ATTACH] {msg}", exc_info=True)
                    attach_texts.append(msg)
                finally:
                    if tmp_path and os.getenv("KEEP_WORK_FILES","0") not in ("1","true","True"):
                        try: _os.remove(tmp_path)
                        except Exception: pass

            prompt = build_prompt(task_obj, assignee, sub_text, attach_texts, perq, overall_max)
            logging.info(f"[AI] prompt_len={len(prompt)} task={task_obj.get('title','')} receiver_id={receiver_id}")
            try:
                result = ai_client.grade(prompt)
            except Exception as e:
                logging.error(f"[AI] call failed: {e}", exc_info=True)
                result = {"per_question": [], "overall": {"score": 0, "comment": f"AI调用失败: {repr(e)}"}}

            if result.get("per_question") and perq:
                maxima = {str(q["id"]): float(q["max"]) for q in perq}
                clamped = []; total = 0.0
                for row in result["per_question"]:
                    qid = str(row.get("id")); s = float(row.get("score", 0)); mx = float(maxima.get(qid, 0))
                    s2 = clamp(s, 0, mx); total += s2
                    clamped.append({"id": qid, "score": s2, "comment": (row.get("comment") or "")[:100]})
                result["per_question"] = clamped
                result["overall"] = result.get("overall", {})
                result["overall"]["score"] = clamp(float(result["overall"].get("score", total)), 0, sum(maxima.values()))
            else:
                sc = clamp(float(result.get("overall",{}).get("score", 0)), 0, float(overall_max))
                result["per_question"] = []
                result["overall"] = {"score": sc, "comment": (result.get("overall",{}).get("comment") or "")[:200]}

            # 评语
            if needs_review:
                lines = []
                lines.append(f"【自动评阅】{task_obj.get('title','')}")
                if result.get("per_question"):
                    lines.append("分项：")
                    for row in result["per_question"]:
                        lines.append(f"- {row['id']}: {row['score']}分（{row.get('comment','')[:50]}）")
                lines.append(f"总评：{result['overall'].get('comment','')}")
                content = "\n".join(lines)[:950]
                try:
                    api.post_review(receiver_id, task_id, content, result="approved")
                except Exception as e:
                    logging.error(f"[REVIEW] post_review failed: {e}", exc_info=True)

            # 给分
            if cfg["score_write"] and item_id and receiver_id:
                try:
                    code, txt = api.post_item_score(item_id=item_id, owner_id=receiver_id, task_id=task_id, score=float(result["overall"]["score"]))
                    logging.info(f"[SCORE] write result: HTTP {code} body={txt[:200]}")
                    if 200 <= int(code) < 300:
                        smap[str(receiver_id)] = True
                except Exception as e:
                    logging.error(f"[SCORE] write failed: {e}", exc_info=True)

            # 标记处理
            tmap[sub_id] = sig

    save_state(cfg["state_path"], state)

def main():
    setup_logging()
    cfg = load_env()
    api = Seiue(cfg["base"], cfg["bearer"], cfg["school_id"], cfg["role"], cfg["reflection_id"], cfg["username"], cfg["password"])
    ai_key = cfg["gemini_key"] if cfg["ai_provider"] == "gemini" else cfg["deepseek_key"]
    ai_model = cfg["gemini_model"] if cfg["ai_provider"] == "gemini" else cfg["deepseek_model"]
    ai_client = AIClient(cfg["ai_provider"], ai_model, ai_key)
    st = load_state(cfg["state_path"])
    run_once(cfg, api, st, ai_client)

if __name__ == "__main__":
    main()
PY

  echo "[4/9] Creating virtualenv & installing requirements..."
  python3 -m venv "$VENV_DIR" 2>/dev/null || python -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip
  "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt"

  echo "[5/9] Creating systemd service (if missing)..."
  if [ ! -f "/etc/systemd/system/$SERVICE" ]; then
    cat > "/etc/systemd/system/$SERVICE" <<EOF
[Unit]
Description=AGrader service
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
Environment=ENV_PATH=$ENV_FILE
ExecStart=$VENV_DIR/bin/python $APP_DIR/main.py
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE"
  else
    systemctl daemon-reload
  fi

  echo "[6/9] Restarting service..."
  systemctl restart "$SERVICE" || systemctl start "$SERVICE"

  echo "[7/9] Tail last 50 lines:"
  journalctl -u "$SERVICE" -n 50 --no-pager || true

  echo "[8/9] Done."
}

# main
install_pkgs
write_project
echo "[9/9] Complete."