#!/usr/bin/env bash
# AGrader - API-first auto-grading pipeline (installer/runner) - FULL INLINE EDITION
# Linux: apt/dnf/yum/apk + systemd; macOS: Homebrew + optional launchd
# v1.10.8-hotfix-fullinline-2025-11-02
#
# What this script does:
# 1) Installs prerequisites (Python3 + venv, curl, jq).
# 2) Creates /opt/agrader (or updates it) with a Python venv.
# 3) Writes ALL required project files (main.py, seiue_api.py, ai_providers.py, utilx.py, credentials.py).
# 4) Creates/updates .env and (re)prompts for MONITOR_TASK_IDS, RUN_MODE, FULL_SCORE_MODE, STOP_CRITERIA.
# 5) Installs/updates a systemd service on Linux (optional launchd on macOS).
# 6) Starts the service if RUN_MODE=watch, or runs once if RUN_MODE=oneshot.
#
# Your persistent config lives at: /opt/agrader/.env
#
# Notes:
# - No numeric fake IDs are used. Replace placeholders like <TASK_ID> after install.
# - .env is hot-reloaded by the app on every loop; edits take effect without restart in watch mode.

set -euo pipefail

# ---------- constants ----------
APP_DIR="/opt/agrader"
VENV_DIR="$APP_DIR/venv"
ENV_FILE="$APP_DIR/.env"
SERVICE="agrader.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE}"
LAUNCHD_PLIST="${HOME}/Library/LaunchAgents/net.bdfz.agrader.plist"
PY_MAIN="$APP_DIR/main.py"
PY_API="$APP_DIR/seiue_api.py"
PY_AI="$APP_DIR/ai_providers.py"
PY_UTIL="$APP_DIR/utilx.py"
PY_CRED="$APP_DIR/credentials.py"

# ---------- helpers ----------
have() { command -v "$1" >/dev/null 2>&1; }
os_detect() {
  case "$(uname -s)" in
    Darwin) echo "mac";;
    Linux)  echo "linux";;
    *)      echo "other";;
  esac
}
die() { echo "ERROR: $*" >&2; exit 1; }

ask() {
  # ask "Prompt" VAR [default]
  local prompt="$1"; local var="$2"; local def="${3:-}"; local ans=""
  if [ -n "${def}" ]; then
    read -r -p "$prompt [$def]: " ans || true
    ans="${ans:-$def}"
  else
    read -r -p "$prompt: " ans || true
  fi
  printf -v "$var" "%s" "$ans"
}
yn() {
  # yn "question?" VAR [default_y|default_n]
  local q="$1"; local var="$2"; local def="${3:-default_n}"; local ans=""
  local hint="[y/N]"; [ "$def" = "default_y" ] && hint="[Y/n]"
  read -r -p "$q $hint " ans || true
  ans="${ans:-$([ "$def" = "default_y" ] && echo y || echo n)}"
  case "$ans" in
    y|Y) printf -v "$var" "y" ;;
    n|N) printf -v "$var" "n" ;;
    *)   printf -v "$var" "n" ;;
  esac
}

ensure_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Re-executing with sudo to get root privileges..."
    exec sudo -E bash "$0" "$@"
  fi
}

install_pkgs_linux() {
  echo "Installing prerequisites on Linux..."
  if have apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends python3 python3-venv python3-pip curl jq ca-certificates
  elif have dnf; then
    dnf install -y python3 python3-pip python3-virtualenv curl jq ca-certificates
  elif have yum; then
    yum install -y python3 python3-pip python3-virtualenv curl jq ca-certificates || true
  elif have apk; then
    apk add --no-cache python3 py3-pip py3-virtualenv curl jq ca-certificates
  else
    die "Unsupported Linux package manager. Install python3, python3-venv, curl, jq manually."
  fi
}

install_pkgs_mac() {
  echo "Installing prerequisites on macOS..."
  if ! have brew; then
    die "Homebrew is required on macOS. Install from https://brew.sh and re-run."
  fi
  brew update
  brew install python@3.12 jq coreutils || true
  # Ensure 'python3' points to brewed python
  if ! python3 --version >/dev/null 2>&1; then
    brew link --overwrite python@3.12
  fi
}

ensure_dirs() {
  mkdir -p "$APP_DIR"
  chmod 755 "$APP_DIR"
}

ensure_venv() {
  if [ ! -x "$VENV_DIR/bin/python" ]; then
    echo "Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
  fi
  echo "Upgrading pip and installing Python deps..."
  "$VENV_DIR/bin/pip" install --upgrade pip
  "$VENV_DIR/bin/pip" install --no-cache-dir requests python-dotenv backoff tiktoken
}

write_env_if_missing() {
  if [ ! -f "$ENV_FILE" ]; then
    cat >"$ENV_FILE" <<'ENV'
# ========== AGrader .env ==========
# Core run behaviour
RUN_MODE=oneshot            # oneshot | watch
POLL_INTERVAL=10            # seconds for watch mode
STOP_CRITERIA=score_and_review  # score_and_review | score_only

# Tasks to grade (comma separated)
MONITOR_TASK_IDS=<TASK_ID>

# Grading mode
FULL_SCORE_MODE=off         # off=AI normal grading | all=force full marks
FULL_SCORE_COMMENT=記得看高考真題。

# SEIUE auth (prefer bearer; auto-login is best-effort)
SEIUE_BASE=https://api.seiue.com
SEIUE_SCHOOL_ID=3
SEIUE_ROLE=teacher
SEIUE_REFLECTION_ID=
SEIUE_BEARER=
SEIUE_USERNAME=
SEIUE_PASSWORD=

# AI provider (choose one)
AI_PROVIDER=deepseek        # deepseek | gemini | endpoint
DEEPSEEK_MODEL=deepseek-reasoner
DEEPSEEK_API_KEY=
# GEMINI_MODEL=gemini-2.5-pro
# GEMINI_API_KEY=
# Custom endpoint (POST JSON {"prompt": "..."} -> {"answer": "..."}), e.g. ai.bdfz.net
# AI_ENDPOINT=https://ai.bdfz.net/

# Safety nets
VERIFY_AFTER_WRITE=1
RETRY_ON_422_ONCE=1
MAX_SCORE_CACHE_TTL=600
LOG_LEVEL=INFO
LOG_FORMAT=%(asctime)s.%(msecs)03d %(levelname)s %(name)s - %(message)s
LOG_DATEFMT=%Y-%m-%d %H:%M:%S
# ==================================
ENV
    chmod 600 "$ENV_FILE"
  fi
}

prompt_core_vars() {
  echo
  echo "=== Configure core options ==="
  local cur_tasks cur_run cur_full cur_stop
  cur_tasks="$(grep -E '^MONITOR_TASK_IDS=' "$ENV_FILE" | sed -E 's/^MONITOR_TASK_IDS=//')"
  cur_run="$(grep -E '^RUN_MODE=' "$ENV_FILE" | sed -E 's/^RUN_MODE=//')"
  cur_full="$(grep -E '^FULL_SCORE_MODE=' "$ENV_FILE" | sed -E 's/^FULL_SCORE_MODE=//')"
  cur_stop="$(grep -E '^STOP_CRITERIA=' "$ENV_FILE" | sed -E 's/^STOP_CRITERIA=//')"

  ask "Task IDs (comma separated, e.g. <TASK_ID>,<TASK_ID>)" NEW_TASKS "${cur_tasks:-<TASK_ID>}"
  ask "Run mode (oneshot/watch)" NEW_RUN "${cur_run:-oneshot}"
  ask "Full score mode (off/all)" NEW_FULL "${cur_full:-off}"
  ask "Stop criteria (score_and_review/score_only)" NEW_STOP "${cur_stop:-score_and_review}"

  # in-place update (.env always contains these keys)
  tmp="$(mktemp)"; cp "$ENV_FILE" "$tmp"
  sed -E -e "s|^MONITOR_TASK_IDS=.*|MONITOR_TASK_IDS=${NEW_TASKS}|" \
         -e "s|^RUN_MODE=.*|RUN_MODE=${NEW_RUN}|" \
         -e "s|^FULL_SCORE_MODE=.*|FULL_SCORE_MODE=${NEW_FULL}|" \
         -e "s|^STOP_CRITERIA=.*|STOP_CRITERIA=${NEW_STOP}|" "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
}

write_systemd_linux() {
  cat >"$SERVICE_PATH" <<EOF
[Unit]
Description=AGrader - API-first auto-grading service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
Environment=PYTHONUNBUFFERED=1
ExecStart=$VENV_DIR/bin/python $PY_MAIN
Restart=always
RestartSec=3
# Hardening (optional)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

write_launchd_mac() {
  mkdir -p "$(dirname "$LAUNCHD_PLIST")"
  cat >"$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key><string>net.bdfz.agrader</string>
    <key>ProgramArguments</key>
    <array>
      <string>$VENV_DIR/bin/python</string>
      <string>$PY_MAIN</string>
    </array>
    <key>WorkingDirectory</key><string>$APP_DIR</string>
    <key>StandardOutPath</key><string>$APP_DIR/agrader.out.log</string>
    <key>StandardErrorPath</key><string>$APP_DIR/agrader.err.log</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
  </dict>
</plist>
EOF
}

start_by_mode() {
  local mode
  mode="$(grep -E '^RUN_MODE=' "$ENV_FILE" | sed -E 's/^RUN_MODE=//')"
  case "$mode" in
    watch)
      if [ "$(os_detect)" = "linux" ]; then
        systemctl enable --now "$SERVICE"
        systemctl status "$SERVICE" --no-pager -l || true
      elif [ "$(os_detect)" = "mac" ]; then
        launchctl unload "$LAUNCHD_PLIST" >/dev/null 2>&1 || true
        launchctl load -w "$LAUNCHD_PLIST"
        echo "launchd loaded. Logs: tail -f $APP_DIR/agrader.err.log"
      else
        echo "Unknown OS; start the app manually: $VENV_DIR/bin/python $PY_MAIN"
      fi
      ;;
    *)
      echo "RUN_MODE=oneshot → running once..."
      "$VENV_DIR/bin/python" "$PY_MAIN" || true
      echo "Done."
      ;;
  esac
}

write_main_py() {
  cat >"$PY_MAIN" <<'PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AGrader v1.10.8-hotfix
- Restore NORMAL AI grading workflow (kept FULL mode).
- Enforce RUN_MODE=oneshot|watch and STOP_CRITERIA=score_and_review|score_only.
- Pre-verify scores, clamp to true max, retry once on 422 (parse max from message).
- Post review via Seiue.post_review(); treat 405 as ignorable "not supported".
"""

import os, sys, time, json, logging
from typing import Dict, Any, List, Tuple, Optional
from dotenv import load_dotenv
from utilx import draftjs_to_text, clamp, scan_question_maxima
from ai_providers import AIClient
from seiue_api import Seiue

def _as_bool(x, default=True):
    if x is None: return default
    s = str(x).strip().lower()
    return s not in ("0","false","no","off")

def setup_logging():
    lvl = os.getenv("LOG_LEVEL","INFO").upper()
    fmt = os.getenv("LOG_FORMAT","%(asctime)s.%(msecs)03d %(levelname)s %(name)s - %(message)s")
    datefmt = os.getenv("LOG_DATEFMT","%Y-%m-%d %H:%M:%S")
    logging.basicConfig(level=getattr(logging, lvl, logging.INFO), format=fmt, datefmt=datefmt)

def load_env_every_time():
    load_dotenv(override=True)  # hot-reload .env every pass

class MaxCache:
    def __init__(self, ttl_seconds: int = 600):
        self.ttl = ttl_seconds
        self.store: Dict[int, Tuple[float, float]] = {}

    def get(self, item_id: int) -> Optional[float]:
        now = time.time()
        v = self.store.get(item_id)
        if not v: return None
        mx, exp = v
        if now <= exp: return mx
        self.store.pop(item_id, None)
        return None

    def put(self, item_id: int, mx: float):
        self.store[item_id] = (mx, time.time() + self.ttl)

def build_prompt(template_path: str, task: Dict[str,Any], student_name: str, student_id: str,
                 max_score: float, per_q_schema: List[Dict[str,Any]], submission_text: str) -> str:
    try:
        with open(template_path, "r", encoding="utf-8") as f:
            tpl = f.read()
    except Exception:
        tpl = (
            "You are a strict Chinese language grader.\n\n"
            "Task: {task_title}\nStudent: {student_name} ({student_id})\n"
            "Max Score: {max_score}\nPer-Question Schema (JSON): {per_question_json}\n\n"
            "The student's submission text is below (UTF-8). Use rubric and constraints to grade.\n---\n{assignment_text}\n---\n\n"
            'Output ONLY a valid JSON object with this exact shape, nothing else:\n'
            '{"per_question":[{"id":"...","score":float,"comment":"..."}],"overall":{"score":float,"comment":"..."} }\n'
        )
    title = task.get("title") or task.get("name") or f"Task {task.get('id','')}"
    body = tpl.format(
        task_title=title,
        student_name=student_name,
        student_id=student_id,
        max_score=max_score,
        per_question_json=json.dumps(per_q_schema, ensure_ascii=False),
        assignment_text=submission_text or "",
    )
    return body

def extract_submission_text(assignment: Dict[str,Any]) -> str:
    sub = (assignment.get("submission") or {})
    if isinstance(sub, dict):
        content = sub.get("content") or sub.get("text") or ""
        txt = draftjs_to_text(content) if content else ""
        if txt.strip():
            return txt
    for key in ("text","content","body"):
        v = assignment.get(key)
        if isinstance(v, str) and v.strip():
            return v
    return ""

def pick_receiver_identity(assignment: Dict[str,Any]) -> Tuple[Optional[int], str]:
    assignee = assignment.get("assignee") or {}
    name = assignee.get("name") or assignee.get("username") or ""
    try:
        ref = assignee.get("reflection") or {}
        rid = int(ref.get("id") or 0) or None
    except Exception:
        rid = None
    if rid is None:
        try:
            rid = int(assignee.get("id") or 0) or None
        except Exception:
            rid = None
    return rid, name

def give_comment_and_score(api: Seiue, ai: Optional[AIClient], task_id: int, full_mode: bool,
                           full_comment: str, stop_criteria: str, max_cache: MaxCache) -> Dict[str,int]:
    stats = {"ok":0, "skip":0, "fail":0}
    task = api.get_task(task_id)
    assignments = api.get_assignments(task_id) or []
    item_ids = api.derive_item_ids(task, assignments)
    if not item_ids:
        logging.error("[TASK %s] cannot derive any item_id; abort.", task_id)
        return stats
    item_id = item_ids[0]

    mx = max_cache.get(item_id)
    if mx is None:
        mx = api.get_item_max_score(item_id) or 100.0
        max_cache.put(item_id, mx)

    perq_schema, overall_guess = scan_question_maxima(task)
    true_max = mx or overall_guess or 100.0

    for idx, a in enumerate(assignments, 1):
        rid, sname = pick_receiver_identity(a)
        if not rid:
            logging.warning("[TASK %s] #%d missing receiver_id -> skip one.", task_id, idx)
            stats["skip"] += 1
            continue

        existing = api.verify_existing_score(item_id, rid)
        if existing is not None:
            logging.info("[TASK %s] #%d rid=%s name=%s (already exists: %.2f)", task_id, idx, rid, sname, existing)
            stats["ok"] += 1
            continue

        review_text = ""
        desired = None

        if full_mode:
            desired = float(true_max)
            review_text = full_comment or "記得看高考真題。"
        else:
            submission_text = extract_submission_text(a)
            prompt = build_prompt(
                os.getenv("PROMPT_TEMPLATE_PATH", f"{os.getcwd()}/prompt.txt"),
                task, sname, str(rid), true_max, perq_schema, submission_text
            )
            try:
                assert ai is not None, "AI client is None in normal grading mode."
                jr = ai.grade(prompt)
                overall = (jr.get("overall") or {})
                desired = float(overall.get("score") or 0.0)
                review_text = str(overall.get("comment") or "").strip()
            except Exception as e:
                logging.error("[AI] parse/grade failed rid=%s: %s", rid, e, exc_info=True)
                desired = 0.0
                review_text = review_text or "（AI 評分失敗，暫記 0 分）"

        desired = clamp(float(desired), 0.0, float(true_max))

        review_ok = True
        if review_text:
            rok, rcode, rbody = api.post_review(rid, task_id, review_text)
            if not rok and rcode != 405:
                review_ok = False
                logging.warning("[REVIEW][TASK %s] rid=%s failed code=%s body=%s", task_id, rid, rcode, str(rbody)[:200])

        wrote = False
        ok, code, body = api.post_item_score(item_id, rid, desired, review_text)
        if not ok and code == 422 and _as_bool(os.getenv("RETRY_ON_422_ONCE","1"), True):
            mx2 = api.parse_max_from_422(str(body))
            if isinstance(mx2, float) and mx2 > 0:
                desired2 = clamp(desired, 0.0, mx2)
                ok, code, body = api.post_item_score(item_id, rid, desired2, review_text)
                if ok:
                    desired = desired2
                    wrote = True
        else:
            wrote = ok

        if wrote and _as_bool(os.getenv("VERIFY_AFTER_WRITE","1"), True):
            exist2 = api.verify_existing_score(item_id, rid)
            if exist2 is None:
                logging.info("[VERIFY][TASK %s] rid=%s verify-late (skip strict check)", task_id, rid)

        satisfied = False
        stop_criteria = (stop_criteria or "score_only").strip().lower()
        if stop_criteria == "score_and_review":
            satisfied = wrote and review_ok
        else:
            satisfied = wrote

        if satisfied:
            logging.info("[OK][TASK %s] #%d rid=%s name=%s score=%.2f", task_id, idx, rid, sname, desired)
            stats["ok"] += 1
        else:
            logging.warning("[FAIL][TASK %s] #%d rid=%s name=%s", task_id, idx, rid, sname)
            stats["fail"] += 1

    return stats

def run_once():
    api = Seiue(
        base=os.getenv("SEIUE_BASE","https://api.seiue.com"),
        bearer=os.getenv("SEIUE_BEARER",""),
        school_id=os.getenv("SEIUE_SCHOOL_ID","3"),
        role=os.getenv("SEIUE_ROLE","teacher"),
        reflection_id=os.getenv("SEIUE_REFLECTION_ID",""),
        username=os.getenv("SEIUE_USERNAME","") or None,
        password=os.getenv("SEIUE_PASSWORD","") or None,
    )
    ai: Optional[AIClient] = None
    if os.getenv("FULL_SCORE_MODE","off").strip().lower() != "all":
        prov = os.getenv("AI_PROVIDER","deepseek").strip().lower()
        model = os.getenv("DEEPSEEK_MODEL","deepseek-reasoner") if prov=="deepseek" else os.getenv("GEMINI_MODEL","gemini-2.5-pro")
        key = os.getenv("DEEPSEEK_API_KEY","") if prov=="deepseek" else os.getenv("GEMINI_API_KEY","")
        endpoint = os.getenv("AI_ENDPOINT","")
        ai = AIClient(prov, model, key, endpoint=endpoint)

    ids_raw = os.getenv("MONITOR_TASK_IDS","").strip().strip(",")
    if not ids_raw:
        logging.error("MONITOR_TASK_IDS missing.")
        return False
    task_ids = []
    for x in ids_raw.split(","):
        s = x.strip()
        if not s: continue
        try:
            task_ids.append(int(s))
        except ValueError:
            logging.warning("Skip non-numeric task id: %s", s)
    if not task_ids:
        logging.error("No valid task ids.")
        return False

    stop_criteria = os.getenv("STOP_CRITERIA","score_only").strip().lower()
    full_mode = (os.getenv("FULL_SCORE_MODE","off").strip().lower() == "all")
    full_comment = os.getenv("FULL_SCORE_COMMENT","記得看高考真題。")
    max_cache = MaxCache(ttl_seconds=int(os.getenv("MAX_SCORE_CACHE_TTL","600")))

    overall_ok = True
    for tid in task_ids:
        logging.info("[EXEC] Processing task_id=%s (FULL=%s, STOP=%s)", tid, full_mode, stop_criteria)
        stats = give_comment_and_score(api, ai, tid, full_mode, full_comment, stop_criteria, max_cache)
        logging.info("[SUMMARY][TASK %s] ok=%d skip=%d fail=%d", tid, stats["ok"], stats["skip"], stats["fail"])
        if stats["fail"] > 0:
            overall_ok = False
    return overall_ok

def main():
    load_env_every_time()
    setup_logging()

    run_mode = os.getenv("RUN_MODE","oneshot").strip().lower()
    poll = int(os.getenv("POLL_INTERVAL","10") or "10")

    if run_mode == "watch":
        while True:
            load_env_every_time()
            try:
                run_once()
            except Exception as e:
                logging.error("run_once exception: %s", e, exc_info=True)
            time.sleep(poll)
    else:
        ok = run_once()
        sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
PY
  chmod 644 "$PY_MAIN"
}

write_seiue_api_py() {
  cat >"$PY_API" <<'PY'
import os, logging, requests, threading, re
from typing import Dict, Any, List, Union, Optional, Tuple
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

def _flatten_find_item_ids(obj: Union[Dict[str,Any], List[Any]]) -> List[int]:
    found: List[int] = []
    def walk(x):
        if isinstance(x, dict):
            for k,v in x.items():
                lk = str(k).lower()
                if lk.endswith("item_id") or lk.endswith("klass_item_id"):
                    try:
                        iv = int(v)
                        if iv>0: found.append(iv)
                    except Exception:
                        pass
                walk(v)
        elif isinstance(x, list):
            for y in x: walk(y)
    walk(obj)
    out: List[int] = []
    seen = set()
    for i in found:
        if i not in seen:
            out.append(i); seen.add(i)
    return out

class Seiue:
    def __init__(self, base: str, bearer: str, school_id: str, role: str, reflection_id: str,
                 username: Optional[str]=None, password: Optional[str]=None):
        self.base = (base or "https://api.seiue.com").rstrip("/")
        self.username = username or ""
        self.password = password or ""
        self.school_id = str(school_id or "3")
        self.role = role or "teacher"
        self.reflection_id = str(reflection_id) if reflection_id else ""
        self.bearer = bearer or ""
        self.session = _session_with_retries()
        self._init_headers()
        if not self.bearer and self.username and self.password:
            self._login_and_apply()

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

    def _with_refresh(self, fn):
        r = fn()
        if getattr(r,"status_code",None) in (401,403):
            logging.warning("[AUTH] 401/403; re-auth...")
            if self._login_and_apply(): return fn()
        return r

    # --------- fetchers ---------
    def get_task(self, task_id: int):
        url = self._url(f"/chalk/task/v2/tasks/{task_id}")
        r = self._with_refresh(lambda: self.session.get(url, timeout=60))
        if r.status_code >= 400:
            logging.error(f"[API] get_task {r.status_code}: {(r.text or '')[:400]}")
            r.raise_for_status()
        return r.json()

    def get_tasks_bulk(self, task_ids: List[int]):
        if not task_ids: return {}
        ids = ",".join(str(i) for i in sorted(set(task_ids)))
        url = self._url(f"/chalk/task/v2/tasks?id_in={ids}&expand=group")
        r = self._with_refresh(lambda: self.session.get(url, timeout=60))
        if r.status_code >= 400:
            logging.error(f"[API] get_tasks_bulk {r.status_code}: {(r.text or '')[:400]}")
            r.raise_for_status()
        arr = r.json() or []
        out = {}
        for obj in arr:
            tid = int(obj.get("id") or 0)
            if tid: out[tid] = obj
        return out

    def get_assignments(self, task_id: int):
        url = self._url(f"/chalk/task/v2/tasks/{task_id}/assignments?expand=is_excellent,assignee,team,submission,review")
        r = self._with_refresh(lambda: self.session.get(url, timeout=60))
        if r.status_code >= 400:
            logging.error(f"[API] get_assignments {r.status_code}: {(r.text or '')[:400]}")
            r.raise_for_status()
        return r.json()

    def get_item_detail(self, item_id: int):
        url = self._url(f"/vnas/klass/items/{item_id}?expand=assessment%2Cassessment_stage%2Cstage%2Cscore_items%2Crules")
        r = self._with_refresh(lambda: self.session.get(url, timeout=30))
        if r.status_code >= 400:
            logging.error(f"[API] get_item_detail {r.status_code}: {(r.text or '')[:300]}")
            r.raise_for_status()
        return r.json()

    # --------- helpers ---------
    def derive_item_ids(self, task: Dict[str,Any], assignments: List[Dict[str,Any]]) -> List[int]:
        ids = []
        ids += _flatten_find_item_ids(task)
        for a in assignments:
            ids += _flatten_find_item_ids(a)
        out = []
        seen=set()
        for i in ids:
            if i not in seen and i>0:
                out.append(i); seen.add(i)
        return out

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
            rows = data if isinstance(data, list) else (data.get("data") or data.get("items") or [])
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

    # --------- writers ---------
    def post_review(self, receiver_id: int, task_id: int, text: str) -> Tuple[bool, int, str]:
        path_tmpl = os.getenv("SEIUE_REVIEW_POST_TEMPLATE","/chalk/task/v2/assignees/{receiver_id}/tasks/{task_id}/reviews")
        path = path_tmpl.format(receiver_id=receiver_id, task_id=task_id)
        url = self._url(path)
        try:
            r = self._with_refresh(lambda: self.session.post(
                url, json={"content": str(text or "")}, timeout=30
            ))
            code = getattr(r, "status_code", 0) or 0
            if code == 405:
                return False, 405, r.text or ""
            if code >= 400:
                return False, code, r.text or ""
            return True, code, r.text or ""
        except requests.RequestException as e:
            return False, -1, str(e)

    def post_item_score(self, item_id: int, owner_id: int, score: float, review: Optional[str]=None) -> Tuple[bool,int,str]:
        spec = os.getenv("SEIUE_SCORE_ENDPOINTS","POST:/vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true:array")
        try:
            method, rest = spec.split(":", 1)
            path, payload_style = rest.rsplit(":", 1)
        except ValueError:
            method, path, payload_style = "POST", "/vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true", "array"

        url = self._url(path.format(item_id=item_id))
        row = {"owner_id": int(owner_id), "score": float(score)}
        if review: row["review"] = str(review)
        body = [row] if payload_style.lower() != "object" else row

        try:
            r = self._with_refresh(lambda: self.session.request(method.upper(), url, json=body, timeout=30))
            code = getattr(r, "status_code", 0) or 0
            if code >= 400:
                return False, code, r.text or ""
            return True, code, r.text or ""
        except requests.RequestException as e:
            return False, -1, str(e)
PY
  chmod 644 "$PY_API"
}

write_ai_providers_py() {
  cat >"$PY_AI" <<'PY'
import os, json, re, requests, logging
from typing import Dict, Any, Optional
from utilx import repair_json

class AIClient:
    """
    Pluggable AI client.
    - provider = deepseek | gemini | endpoint
    - For provider=endpiont, set AI_ENDPOINT (POST JSON {"prompt": "..."} -> {"answer": "..."}).
    """
    def __init__(self, provider: str, model: str, api_key: str, endpoint: Optional[str]=None):
        self.provider = (provider or "deepseek").lower()
        self.model = model or "deepseek-reasoner"
        self.api_key = api_key or ""
        self.endpoint = endpoint or os.getenv("AI_ENDPOINT","").strip()

    def _call_deepseek(self, prompt: str) -> str:
        """
        DeepSeek provides OpenAI-compatible endpoints.
        We try /v1/chat/completions; if the provider uses /v1/responses, the server should map it.
        """
        url = os.getenv("DEEPSEEK_BASE","https://api.deepseek.com").rstrip("/") + "/v1/chat/completions"
        headers = {"Authorization": f"Bearer {self.api_key}", "Content-Type":"application/json"}
        body = {
            "model": self.model,
            "messages": [
                {"role":"system","content":"Output ONLY valid JSON per instructions."},
                {"role":"user","content":prompt}
            ],
            "temperature": 0.2
        }
        r = requests.post(url, headers=headers, json=body, timeout=120)
        r.raise_for_status()
        data = r.json()
        try:
            return data["choices"][0]["message"]["content"]
        except Exception:
            return json.dumps({"overall":{"score":0,"comment":"MODEL_PARSE_ERROR"},"per_question":[]}, ensure_ascii=False)

    def _call_gemini(self, prompt: str) -> str:
        base = os.getenv("GEMINI_BASE","https://generativelanguage.googleapis.com")
        url = f"{base.rstrip('/')}/v1beta/models/{self.model}:generateContent?key={self.api_key}"
        headers = {"Content-Type":"application/json"}
        body = {"contents":[{"parts":[{"text": prompt}]}], "generationConfig":{"temperature":0.2}}
        r = requests.post(url, headers=headers, json=body, timeout=120)
        r.raise_for_status()
        data = r.json()
        # Expect text at candidates[0].content.parts[0].text
        try:
            return data["candidates"][0]["content"]["parts"][0]["text"]
        except Exception:
            return json.dumps({"overall":{"score":0,"comment":"MODEL_PARSE_ERROR"},"per_question":[]}, ensure_ascii=False)

    def _call_endpoint(self, prompt: str) -> str:
        url = self.endpoint
        if not url:
            raise RuntimeError("AI_ENDPOINT is not set for provider=endpoint")
        headers = {"Content-Type":"application/json"}
        r = requests.post(url, headers=headers, json={"prompt": prompt}, timeout=120)
        r.raise_for_status()
        data = r.json()
        ans = data.get("answer") or ""
        return ans if isinstance(ans, str) else json.dumps(ans, ensure_ascii=False)

    def grade(self, prompt: str) -> Dict[str, Any]:
        if self.provider == "endpoint":
            raw = self._call_endpoint(prompt)
        elif self.provider == "gemini":
            raw = self._call_gemini(prompt)
        else:
            raw = self._call_deepseek(prompt)

        try:
            obj = repair_json(raw)
            if not isinstance(obj, dict):
                raise ValueError("JSON not an object")
            # normalize
            if "overall" not in obj: obj["overall"] = {"score":0,"comment":""}
            if "per_question" not in obj: obj["per_question"] = []
            # ensure score is a float
            try:
                obj["overall"]["score"] = float(obj["overall"].get("score",0.0))
            except Exception:
                obj["overall"]["score"] = 0.0
            obj["overall"]["comment"] = str(obj["overall"].get("comment",""))
            return obj
        except Exception as e:
            logging.error("AI JSON repair failed: %s", e, exc_info=True)
            return {"overall":{"score":0.0,"comment":"(AI output parse failed)"},"per_question":[]}
PY
  chmod 644 "$PY_AI"
}

write_utilx_py() {
  cat >"$PY_UTIL" <<'PY'
import json, re
from typing import Any, Dict, List, Tuple

def clamp(x: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, x))

def draftjs_to_text(content: Any) -> str:
    """
    Accepts either a DraftJS dict or JSON string; returns concatenated plain text.
    """
    try:
        if isinstance(content, str):
            try:
                content = json.loads(content)
            except Exception:
                return content
        blocks = (content or {}).get("blocks") or []
        lines = []
        for b in blocks:
            t = b.get("text","")
            if isinstance(t, str):
                lines.append(t)
        return "\n".join(lines).strip()
    except Exception:
        return ""

def scan_question_maxima(task: Dict[str,Any]) -> Tuple[List[Dict[str,Any]], float]:
    """
    Try to infer per-question schema and total max from task payload (best effort).
    Returns (schema, overall_guess). Schema example: [{"id":"Q1","max":10}, ...]
    """
    schema: List[Dict[str,Any]] = []
    total = 0.0
    # common locations
    cand_lists = []
    for key in ("assessment","rubric","score_items","scoring_items","rules"):
        v = task.get(key)
        if isinstance(v, list): cand_lists.append(v)
        elif isinstance(v, dict):
            for k2 in ("items","score_items","scoring_items","rules"):
                vv = v.get(k2)
                if isinstance(vv, list): cand_lists.append(vv)

    for arr in cand_lists:
        for i, it in enumerate(arr, 1):
            mid = it.get("id") or it.get("name") or f"Q{i}"
            mx = it.get("full") or it.get("max") or it.get("max_score") or it.get("full_score")
            try:
                mx = float(mx)
            except Exception:
                mx = 0.0
            if mx > 0:
                schema.append({"id": str(mid), "max": float(mx)})
                total += float(mx)

    overall_guess = total if total > 0 else 0.0
    return schema, overall_guess

def _extract_json_brace_region(s: str) -> str:
    """
    Extract the first plausible {...} region; naive brace match.
    """
    start = s.find("{")
    if start < 0:
        return s
    depth = 0
    for i in range(start, len(s)):
        c = s[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return s[start:i+1]
    return s[start:]

def repair_json(text: str) -> Any:
    """
    Try to coerce LLM text into JSON.
    - extracts first {...}
    - removes trailing commas
    - fixes common quote issues
    """
    if not isinstance(text, str):
        return text
    js = _extract_json_brace_region(text)
    # remove trailing commas before } or ]
    js = re.sub(r",(\s*[}\]])", r"\1", js)
    try:
        return json.loads(js)
    except Exception:
        # attempt to replace smart quotes
        js2 = js.replace("“","\"").replace("”","\"").replace("’","'").replace("‘","'")
        js2 = re.sub(r",(\s*[}\]])", r"\1", js2)
        return json.loads(js2)
PY
  chmod 644 "$PY_UTIL"
}

write_credentials_py() {
  cat >"$PY_CRED" <<'PY'
from dataclasses import dataclass
from typing import Optional
import requests, logging, json

@dataclass
class AuthResult:
    ok: bool
    token: str = ""
    reflection_id: Optional[str] = None
    detail: str = ""

def login(username: str, password: str) -> AuthResult:
    """
    Best-effort programmatic login.
    If your environment prefers static bearer tokens, leave SEIUE_BEARER in .env and skip user/pass.
    """
    try:
        s = requests.Session()
        s.headers.update({"Accept":"application/json, text/plain, */*","User-Agent":"AGrader/1.10"})
        # Try authorize endpoint (payload fields may vary across deployments)
        # We attempt two common shapes.
        candidates = [
            ("https://passport.seiue.com/authorize", {"account": username, "password": password}),
            ("https://passport.seiue.com/authorize", {"username": username, "password": password}),
        ]
        for url, payload in candidates:
            r = s.post(url, json=payload, timeout=30)
            if r.status_code >= 400:
                continue
            try:
                data = r.json()
            except Exception:
                continue
            token = data.get("access_token") or data.get("token") or ""
            reflection_id = data.get("active_reflection_id") or data.get("reflection_id") or None
            if token:
                return AuthResult(ok=True, token=token, reflection_id=reflection_id, detail="ok")
        return AuthResult(ok=False, detail="authorize failed")
    except Exception as e:
        logging.error("login exception: %s", e, exc_info=True)
        return AuthResult(ok=False, detail=str(e))
PY
  chmod 644 "$PY_CRED"
}

# ---------- main flow ----------
ensure_root

OS="$(os_detect)"
case "$OS" in
  linux) install_pkgs_linux ;;
  mac)   install_pkgs_mac ;;
  *)     die "Unsupported OS: $(uname -s)" ;;
esac

ensure_dirs
ensure_venv
write_env_if_missing

# Always (re)write code to ensure you get the fixed version
write_main_py
write_seiue_api_py
write_ai_providers_py
write_utilx_py
write_credentials_py

# Prompt core params on every run (fixes the “upgrade cannot change values” complaint)
prompt_core_vars

# Services
if [ "$OS" = "linux" ]; then
  write_systemd_linux
elif [ "$OS" = "mac" ]; then
  yn "Install launchd agent (keeps it running)?" DO_LAUNCHD default_n
  if [ "$DO_LAUNCHD" = "y" ]; then
    write_launchd_mac
  fi
fi

start_by_mode

echo
echo "=== DONE ==="
echo "App dir: $APP_DIR"
echo "Venv:    $VENV_DIR"
echo "Config:  $ENV_FILE (hot-reloaded)"
if [ "$OS" = "linux" ]; then
  echo "Service: $SERVICE_PATH  (journalctl -u $SERVICE -f)"
fi