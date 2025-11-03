#!/usr/bin/env bash
# AGrader - API-first auto-grading pipeline (installer/runner) - FULL INLINE EDITION
# Linux: apt/dnf/yum/apk + systemd; macOS: Homebrew + optional launchd
# v1.14.1-fullinline-2025-11-03
#
# 這版目的：在「班級 → 任務列表 (domain=group&domain_biz_id_in=...) → 選任務」的新流上
# 把你原來要的高級功能全塞回來：
# - AI 自動評分 (gemini / deepseek，JSON 修復)
# - 附件下載 + OCR + pdf/docx/pptx 解析
# - 404/422 智能重試 + item_id 重新解析 + TTL
# - state.json 裡同時記「task 對應的 item_id」和「每個學生最近一次批閱記錄」
# - 可以切回 FULL_SCORE_MODE=all
#
# 注意：這支腳本會往 /opt/agrader 寫：.env、main.py、seiue_api.py、ai_providers.py、extractor.py、utilx.py、prompt.txt
# 注意：仍然建 systemd 服務 agrader.service

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

ask() {
  local p="$1" var="$2" def="${3:-}"
  local ans
  if [ -n "${def}" ]; then
    read -r -p "$p [$def]: " ans || true
    ans="${ans:-$def}"
  else
    read -r -p "$p: " ans || true
  fi
  printf -v "$var" "%s" "$ans"
}

ask_secret() {
  local p="$1" var="$2"
  local ans
  read -r -s -p "$p: " ans || true
  echo
  printf -v "$var" "%s" "$ans"
}

set_env_kv() {
  local key="$1"; shift
  local val="$*"
  [ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found"; return 1; }
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
  elif have apk; then
    apk add --no-cache \
      python3 py3-pip py3-venv curl unzip jq ca-certificates coreutils \
      tesseract-ocr poppler-utils ghostscript libxml2 libxslt \
      tesseract-ocr-data-eng tesseract-ocr-data-chi_sim || true
  else
    echo "Unsupported Linux package manager. Please install deps manually."
    exit 1
  fi
}

install_pkgs_macos() {
  echo "[1/12] Installing system dependencies (macOS/Homebrew)..."
  if ! have brew; then
    echo "Homebrew not found. Please install Homebrew first."
    exit 1
  fi
  brew update
  brew install jq tesseract poppler ghostscript python@3.12 coreutils || true
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

  grep -q '^SEIUE_SCORE_ENDPOINTS=' "$ENV_FILE" || \
    echo 'SEIUE_SCORE_ENDPOINTS=POST:/vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true:array' >> "$ENV_FILE"
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
  grep -q '^ENABLE_PDF_OCR_FALLBACK=' "$ENV_FILE" || echo 'ENABLE_PDF_OCR_FALLBACK=1'  >> "$ENV_FILE"
  grep -q '^MAX_PDF_OCR_PAGES='       "$ENV_FILE" || echo 'MAX_PDF_OCR_PAGES=20'       >> "$ENV_FILE"
  grep -q '^MAX_PDF_OCR_SECONDS='     "$ENV_FILE" || echo 'MAX_PDF_OCR_SECONDS=120'    >> "$ENV_FILE"
  grep -q '^KEEP_WORK_FILES='         "$ENV_FILE" || echo 'KEEP_WORK_FILES=0'          >> "$ENV_FILE"

  grep -q '^MAX_SCORE_CACHE_TTL='     "$ENV_FILE" || echo 'MAX_SCORE_CACHE_TTL=600'    >> "$ENV_FILE"
  grep -q '^SCORE_CLAMP_ON_MAX='      "$ENV_FILE" || echo 'SCORE_CLAMP_ON_MAX=1'       >> "$ENV_FILE"

  grep -q '^AI_KEY_STRATEGY='         "$ENV_FILE" || echo 'AI_KEY_STRATEGY=roundrobin' >> "$ENV_FILE"
  grep -q '^GEMINI_API_KEYS='         "$ENV_FILE" || echo 'GEMINI_API_KEYS='           >> "$ENV_FILE"
  grep -q '^DEEPSEEK_API_KEYS='       "$ENV_FILE" || echo 'DEEPSEEK_API_KEYS='         >> "$ENV_FILE"

  grep -q '^RUN_MODE='        "$ENV_FILE" || echo 'RUN_MODE=watch' >> "$ENV_FILE"
  grep -q '^STOP_CRITERIA='   "$ENV_FILE" || echo 'STOP_CRITERIA=score_and_review' >> "$ENV_FILE"

  grep -q '^ITEM_ID_REFRESH_ON=' "$ENV_FILE" || echo 'ITEM_ID_REFRESH_ON=score_404,score_422,verify_miss,ttl' >> "$ENV_FILE"
  grep -q '^ITEM_ID_CACHE_TTL='  "$ENV_FILE" || echo 'ITEM_ID_CACHE_TTL=900' >> "$ENV_FILE"

  grep -q '^WORKDIR=' "$ENV_FILE" || echo "WORKDIR=${APP_DIR}/work" >> "$ENV_FILE"
  grep -q '^STATE_PATH=' "$ENV_FILE" || echo "STATE_PATH=${APP_DIR}/state.json" >> "$ENV_FILE"
}

# ====== 這裡是你這次要的關鍵：基於報文的班級/任務拉取 ======

seiue_login_and_fill_bearer() {
  [ -n "${SEIUE_BEARER:-}" ] && return 0
  [ -z "${SEIUE_USERNAME:-}" ] && return 0
  [ -z "${SEIUE_PASSWORD:-}" ] && return 0

  local login_url="https://passport.seiue.com/login?school_id=${SEIUE_SCHOOL_ID:-3}&type=account&from=null&redirect_url=null"
  local auth_url="https://passport.seiue.com/authorize"

  curl -sS -c /tmp/agrader-cookie.txt \
    -X POST "$login_url" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data "email=${SEIUE_USERNAME}&login=${SEIUE_USERNAME}&username=${SEIUE_USERNAME}&password=${SEIUE_PASSWORD}" >/dev/null

  local token_json
  token_json=$(curl -sS -b /tmp/agrader-cookie.txt \
    -X POST "$auth_url" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data "client_id=GpxvnjhVKt56qTmnPWH1sA&response_type=token")

  local token refl
  token=$(printf '%s\n' "$token_json" | jq -r '.access_token // empty')
  refl=$(printf '%s\n' "$token_json" | jq -r '.active_reflection_id // empty')

  if [ -n "$token" ]; then
    SEIUE_BEARER="$token"
    set_env_kv "SEIUE_BEARER" "$token"
  fi
  if [ -n "$refl" ]; then
    SEIUE_REFLECTION_ID="$refl"
    set_env_kv "SEIUE_REFLECTION_ID" "$refl"
  fi
}

seiue_api_get() {
  local path="$1"
  curl -sS \
    -H "Authorization: Bearer ${SEIUE_BEARER}" \
    -H "X-School-Id: ${SEIUE_SCHOOL_ID}" \
    -H "X-Role: ${SEIUE_ROLE}" \
    "${SEIUE_BASE%/}${path}"
}

fetch_groups_and_select() {
  seiue_login_and_fill_bearer
  echo "Fetching groups..."
  local raw
  raw=$(seiue_api_get "/chalk/group/groups?paginated=0") || raw="[]"

  # 如果回來的是 HttpException，就不要硬當成列表，直接讓後面走「手動輸入 task id」
  if printf '%s' "$raw" | jq -e 'type=="object" and ((.name? // "") | test("HttpException"))' >/dev/null 2>&1; then
    echo "API returned HttpException when listing groups, will fallback to manual task id input."
    return 1
  fi

  # 正規化成一個純 array
  local j
  j=$(printf '%s' "$raw" | jq -c 'if type=="array" then . elif type=="object" and .data then .data elif type=="object" then [.] else [] end') || j="[]"

  local count
  count=$(printf '%s' "$j" | jq 'length')
  if [ "$count" -eq 0 ]; then
    echo "No groups found from API (got non-array)."
    return 1
  fi

  echo "Available groups:"
  local i name gid
  for i in $(seq 0 $((count-1))); do
    name=$(printf '%s' "$j" | jq -r ".[$i].name // .[$i].title // \"(no-name-$i)\"")
    gid=$(printf '%s' "$j" | jq -r ".[$i].id // .[$i]._id // \"\"")
    echo "  $((i+1))) $name (id=$gid)"
  done
  local sel
  read -r -p "Select group [1-${count}]: " sel
  sel=${sel:-1}
  sel=$((sel-1))
  SELECTED_GROUP_ID=$(printf '%s' "$j" | jq -r ".[$sel].id // .[$sel]._id // \"\"")
  SELECTED_GROUP_NAME=$(printf '%s' "$j" | jq -r ".[$sel].name // .[$sel].title // \"\"")
  echo "→ Selected group: ${SELECTED_GROUP_NAME} (id=${SELECTED_GROUP_ID})"
}

fetch_tasks_for_group_and_select() {
  [ -z "${SELECTED_GROUP_ID:-}" ] && { echo "No group selected."; return 1; }
  echo "Fetching tasks for group ${SELECTED_GROUP_ID}..."
  local tj
  tj=$(seiue_api_get "/chalk/task/v2/tasks?domain=group&domain_biz_id_in=${SELECTED_GROUP_ID}&paginated=0&expand=group,assignments,custom_fields") || tj="[]"
  # 也做一次正規化，防止這裡也不是純 array
  tj=$(printf '%s' "$tj" | jq -c 'if type=="array" then . elif type=="object" and .data then .data elif type=="object" then [.] else [] end') || tj="[]"
  local tcount
  tcount=$(printf '%s' "$tj" | jq 'length')
  if [ "$tcount" -eq 0 ]; then
    echo "No tasks for this group."
    return 1
  fi
  echo "Tasks under this group:"
  local i tname tid itemid
  for i in $(seq 0 $((tcount-1))); do
    tname=$(printf '%s' "$tj" | jq -r ".[$i].title // .[$i].name // \"(no-title-$i)\"")
    tid=$(printf '%s' "$tj" | jq -r ".[$i].id")
    itemid=$(printf '%s' "$tj" | jq -r ".[$i].custom_fields.item_id // \"-\"")
    echo "  $((i+1))) $tname (task_id=$tid, item_id=$itemid)"
  done
  local tsel
  read -r -p "Select task to monitor [1-${tcount}]: " tsel
  tsel=${tsel:-1}
  tsel=$((tsel-1))
  local chosen_id
  chosen_id=$(printf '%s' "$tj" | jq -r ".[$tsel].id")
  set_env_kv "MONITOR_TASK_IDS" "$chosen_id"
  MONITOR_TASK_IDS_PROMPT="$chosen_id"
  echo "→ MONITOR_TASK_IDS=${chosen_id}"
}

prompt_task_ids() {
  echo "[3/12] Configure Task IDs..."
  if [ -f "$ENV_FILE" ]; then
    SEIUE_BASE="$(grep -E '^SEIUE_BASE=' "$ENV_FILE" | cut -d= -f2- || echo "https://api.seiue.com")"
    SEIUE_SCHOOL_ID="$(grep -E '^SEIUE_SCHOOL_ID=' "$ENV_FILE" | cut -d= -f2- || echo "3")"
    SEIUE_ROLE="$(grep -E '^SEIUE_ROLE=' "$ENV_FILE" | cut -d= -f2- || echo "teacher")"
    SEIUE_BEARER="$(grep -E '^SEIUE_BEARER=' "$ENV_FILE" | cut -d= -f2- || echo "")"
    SEIUE_USERNAME="$(grep -E '^SEIUE_USERNAME=' "$ENV_FILE" | cut -d= -f2- || echo "")"
    SEIUE_PASSWORD="$(grep -E '^SEIUE_PASSWORD=' "$ENV_FILE" | cut -d= -f2- || echo "")"
  fi
  # 先試 API 路
  if fetch_groups_and_select && fetch_tasks_for_group_and_select; then
    return
  fi
  # 不行再讓你手打
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
  echo "  2) AI + normal grading workflow (下載附件 → OCR → 打分 → 回寫)"
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
你是一名嚴格的語文老師，要根據題目和學生提交內容給出細緻的分數與評語。

【任務題目】
{task_title}

【學生】
{student_name} (ID: {student_id})

【最高分值】
{max_score}

【題目分項（如果有就按這個打分，沒有就由你自行拆分）】
{per_question_json}

【學生提交的文字內容】
{assignment_text}

【學生提交的附件轉文字】
{attachments_text}

請你只輸出 JSON，格式必須完全符合下面這個 schema，不能帶註釋，不能帶多餘字段，不能帶 markdown：

{"per_question":[{"id":"小題1","score":分數(數字),"comment":"這題評語"}],"overall":{"score":總分(數字),"comment":"總評語"}}
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
            try:
                mx = float(mx)
            except Exception:
                mx = 0.0
            perq.append({"id": qid, "max": mx})
        overall_max = sum(q["max"] for q in perq)
    else:
        cm = task.get("custom_fields", {})
        maybe_max = cm.get("max_score") or cm.get("full") or task.get("max_score")
        if maybe_max:
            try:
                overall_max = float(maybe_max)
            except Exception:
                pass
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
        self.ok = ok
        self.token = token
        self.reflection_id = reflection_id
        self.detail = detail

def _session_with_retries() -> requests.Session:
    s = requests.Session()
    r = Retry(total=5, backoff_factor=1.5, status_forcelist=(429,500,502,503,504), allowed_methods=frozenset({"GET","POST"}))
    s.mount("https://", HTTPAdapter(max_retries=r))
    s.headers.update({"User-Agent": "AGrader/1.14 (+login)","Accept": "application/json, text/plain, */*"})
    return s

def login(username: str, password: str) -> AuthResult:
    try:
        sess = _session_with_retries()
        login_url = "https://passport.seiue.com/login?school_id=3&type=account&from=null&redirect_url=null"
        auth_url  = "https://passport.seiue.com/authorize"
        login_form = {"email": username, "login": username, "username": username, "password": password}
        sess.post(login_url, headers={"Referer": login_url,"Origin": "https://passport.seiue.com","Content-Type": "application/x-www-form-urlencoded"}, data=login_form, timeout=30)
        auth_form = {"client_id":"GpxvnjhVKt56qTmnPWH1sA","response_type":"token"}
        ar = sess.post(auth_url, headers={"Referer": "https://chalk-c3.seiue.com/","Origin": "https://chalk-c3.seiue.com","Content-Type": "application/x-www-form-urlencoded"}, data=auth_form, timeout=30)
        ar.raise_for_status()
        j = ar.json() or {}
        token = j.get("access_token",""); reflection = j.get("active_reflection_id","")
        if token and reflection:
            return AuthResult(True, token, str(reflection))
        return AuthResult(False, detail=f"Missing token/reflection_id keys={list(j.keys())}")
    except requests.RequestException as e:
        logging.error(f"[AUTH] {e}", exc_info=True)
        return AuthResult(False, detail=str(e))
PY

  # extractor.py
  cat > "$APP_DIR/extractor.py" <<'PY'
import os, subprocess, mimetypes, logging, shutil
from typing import Tuple
from PIL import Image
import pytesseract

def _run(cmd: list, input_bytes: bytes=None, timeout=180) -> Tuple[int, bytes, bytes]:
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE if input_bytes else None, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
        code, out, _ = _run(["pdftotext", "-layout", path, "-"], timeout=120)
        if code == 0 and out.strip():
          return out.decode("utf-8","ignore")
      except Exception as e:
        logging.warning(f"[EXTRACT] pdftotext failed: {e}", exc_info=True)
      enable_fallback = os.getenv("ENABLE_PDF_OCR_FALLBACK","1") not in ("0","false","False")
      max_pages = int(os.getenv("MAX_PDF_OCR_PAGES","20"))
      pages = _pdf_pages(path)
      if (not enable_fallback) or (pages > 0 and pages > max_pages):
        return f"[[skipped: pdf ocr fallback disabled or too large (pages={pages}, size={sz})]]"
      import tempfile
      tmpdir = tempfile.mkdtemp(prefix="pdfocr_"); prefix = os.path.join(tmpdir, "pg")
      code, _, err = _run(["pdftoppm", "-r", "200", path, prefix], timeout=int(os.getenv("MAX_PDF_OCR_SECONDS","120")))
      if code != 0:
        return f"[[error: pdftoppm {err.decode('utf-8','ignore')[:200]}]]"
      texts=[]
      for f in sorted(os.listdir(tmpdir)):
        if f.startswith("pg"):
          fp = os.path.join(tmpdir,f)
          try:
            texts.append(pytesseract.image_to_string(Image.open(fp), lang=ocr_lang))
          except Exception as e:
            logging.error(f"[OCR] {e}", exc_info=True)
            texts.append(f"[[error: tesseract {e}]]")
      if os.getenv("KEEP_WORK_FILES","0") in ("0","false","False"):
        shutil.rmtree(tmpdir, ignore_errors=True)
      return ("\n".join(texts).strip() or "[[error: ocr empty]]")

    if ext in [".png",".jpg",".jpeg",".bmp",".tiff",".webp"] or (mt and mt.startswith("image/")):
      try:
        return pytesseract.image_to_string(Image.open(path), lang=ocr_lang) or "[[error: image ocr empty]]"
      except Exception as e:
        logging.error(f"[EXTRACT] {e}", exc_info=True)
        return f"[[error: image ocr exception: {repr(e)}]]"

    if ext == ".docx":
      try:
        import docx
        return "\n".join(p.text for p in docx.Document(path).paragraphs)
      except Exception as e:
        logging.error(f"[EXTRACT] {e}", exc_info=True)
        return f"[[error: docx extract exception: {repr(e)}]]"

    if ext == ".pptx":
      try:
        from pptx import Presentation
        lines=[]
        prs=Presentation(path)
        for s in prs.slides:
          for shp in s.shapes:
            if hasattr(shp,"text"):
              lines.append(shp.text)
        return "\n".join(lines) or "[[error: pptx no text]]"
      except Exception as e:
        logging.error(f"[EXTRACT] {e}", exc_info=True)
        return f"[[error: pptx extract exception: {repr(e)}]]"

    try:
      with open(path,"rb") as f:
        return f.read().decode("utf-8","ignore")
    except Exception as e:
      logging.error(f"[EXTRACT] {e}", exc_info=True)
      return f"[[error: unknown file read exception: {repr(e)}]]"
PY

  # ai_providers.py
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
                        logging.warning("[AI] Gemini %s; switch key #%d/%d", r.status_code, idx+1, len(self.keys))
                        continue
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
                    logging.warning("[AI] Gemini exception (%s); switch key #%d/%d", code, idx+1, len(self.keys))
                    continue
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
                        logging.warning("[AI] DeepSeek %s; switch key #%d/%d", r.status_code, idx+1, len(self.keys))
                        continue
                    r.raise_for_status()
                    data = r.json()
                    logging.info("[AI][USE] provider=deepseek model=%s key_index=%d/%d", self.model, idx+1, len(self.keys))
                    self._advance_rr(idx)
                    return data.get("choices",[{}])[0].get("message",{}).get("content","")
                except requests.RequestException as e:
                    code = getattr(e.response,'status_code',type(e).__name__)
                    logging.warning("[AI] DeepSeek exception (%s); switch key #%d/%d", code, idx+1, len(self.keys))
                    continue
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
                        if r.status_code == 429 or (500 <= r.status_code < 600):
                            continue
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
                        if r.status_code == 429 or (500 <= r.status_code < 600):
                            continue
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

  # seiue_api.py
  cat > "$APP_DIR/seiue_api.py" <<'PY'
import os, logging, requests, threading, re, time
from typing import Dict, Any, List, Union, Optional
from credentials import login, AuthResult
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
import pathlib

_login_lock = threading.Lock()

def _session_with_retries() -> requests.Session:
    s = requests.Session()
    r = Retry(total=5, backoff_factor=1.5, status_forcelist=(429,500,502,503,504), allowed_methods=frozenset({"GET","POST","PUT"}))
    s.mount("https://", HTTPAdapter(max_retries=r))
    s.headers.update({"Accept":"application/json, text/plain, */*","User-Agent":"AGrader/1.14"})
    return s

def _flatten_find_item_ids(obj: Union[Dict[str,Any], List[Any]]) -> List[int]:
    found: List[int] = []
    def walk(x):
        if isinstance(x, dict):
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
                        iv = int(v)
                        if iv>0: found.append(iv)
                    except Exception:
                        pass
                walk(v)
        elif isinstance(x, list):
            for y in x: walk(y)
    walk(obj)
    out=[]; seen=set()
    for i in found:
        if i not in seen:
            out.append(i); seen.add(i)
    return out

class Seiue:
    def __init__(self, base: str, bearer: str, school_id: str, role: str, reflection_id: str, username: str="", password: str=""):
        self.base = (base or "https://api.seiue.com").rstrip("/")
        self.username = username
        self.password = password
        self.school_id = str(school_id or "3")
        self.role = role or "teacher"
        self.reflection_id = str(reflection_id) if reflection_id else ""
        self.bearer = bearer or ""
        self.session = _session_with_retries()
        self._init_headers()
        if not self.bearer and self.username and self.password:
            self._login_and_apply()

    def _init_headers(self):
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
        with _login_lock:
            if self.bearer:
                self._init_headers()
                return True
            logging.info("[AUTH] Auto-login...")
            res: AuthResult = login(self.username, self.password)
            if res.ok:
                self.bearer = res.token
                if res.reflection_id:
                    self.reflection_id = str(res.reflection_id)
                self._init_headers()
                logging.info("[AUTH] OK")
                return True
            logging.error(f"[AUTH] Failed: {res.detail}")
            return False

    def _url(self, path: str) -> str:
        if path.startswith("http"):
            return path
        if not path.startswith("/"):
            path = "/" + path
        return self.base + path

    def _with_refresh(self, request_fn):
        r = request_fn()
        if getattr(r,"status_code",None) in (401,403):
            if self._login_and_apply():
                return request_fn()
        return r

    def get_task(self, task_id: int):
      url = self._url(f"/chalk/task/v2/tasks/{task_id}")
      r = self._with_refresh(lambda: self.session.get(url, timeout=60))
      if r.status_code >= 400:
        logging.error(f"[API] get_task {r.status_code}: {(r.text or '')[:500]}")
        r.raise_for_status()
      return r.json()

    def get_tasks_bulk(self, task_ids: List[int]):
        if not task_ids:
            return {}
        ids = ",".join(str(i) for i in sorted(set(task_ids)))
        url = self._url(f"/chalk/task/v2/tasks?id_in={ids}&expand=group,custom_fields")
        r = self._with_refresh(lambda: self.session.get(url, timeout=60))
        if r.status_code >= 400:
            logging.error(f"[API] get_tasks_bulk {r.status_code}: {(r.text or '')[:500]}")
            r.raise_for_status()
        arr = r.json() or []
        out = {}
        # 也防一手 {"data":[...]}
        if isinstance(arr, dict) and "data" in arr:
            arr = arr["data"]
        for obj in arr:
            tid = int(obj.get("id", 0) or 0)
            if tid:
                out[tid] = obj
        return out

    def get_assignments(self, task_id: int):
        url = self._url(f"/chalk/task/v2/tasks/{task_id}/assignments?expand=is_excellent,assignee,team,submission,review")
        r = self._with_refresh(lambda: self.session.get(url, timeout=60))
        if r.status_code >= 400:
            logging.error(f"[API] get_assignments {r.status_code}: {(r.text or '')[:500]}")
            r.raise_for_status()
        data = r.json()
        if isinstance(data, dict) and "data" in data:
            return data["data"]
        return data

    def get_assignment_detail(self, task_id: int, assignment_id: int):
        url = self._url(f"/chalk/task/v2/tasks/{task_id}/assignments/{assignment_id}?expand=submission,assignee,review")
        r = self._with_refresh(lambda: self.session.get(url, timeout=30))
        if r.status_code >= 400:
            return None
        return r.json()

    def get_item_detail(self, item_id: int):
        url = self._url(f"/vnas/klass/items/{item_id}?expand=related_data%2Cassessment%2Cassessment_stage%2Cstage")
        r = self._with_refresh(lambda: self.session.get(url, timeout=30))
        if r.status_code >= 400:
            logging.error(f"[API] get_item_detail {r.status_code}: {(r.text or '')[:300]}")
            r.raise_for_status()
        return r.json()

    def get_item_max_score(self, item_id: int) -> Optional[float]:
        try:
            d = self.get_item_detail(item_id) or {}
            for k in ("full_score","max_score","score_upper","full","max"):
                v = d.get(k)
                if v is not None:
                    try:
                        return float(v)
                    except Exception:
                        pass
            for arrk in ("score_items","scoring_items","rules"):
                arr = d.get(arrk)
                if isinstance(arr, list) and arr:
                    tot = 0.0
                    for it in arr:
                        mx = it.get("full") or it.get("max") or it.get("max_score")
                        try:
                            tot += float(mx or 0)
                        except Exception:
                            pass
                    if tot > 0:
                        return tot
            asses = d.get("assessment") or {}
            for k in ("total_item_score","full_score","max_score"):
                v = asses.get(k)
                if v is not None:
                    try:
                        return float(v)
                    except Exception:
                        pass
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
        if not text:
            return None
        m = re.search(r"满分\s*([0-9]+(?:\.[0-9]+)?)", text)
        if m:
            try:
                return float(m.group(1))
            except Exception:
                pass
        m2 = re.search(r"(?:max(?:imum)?|<=)\s*([0-9]+(?:\.[0-9]+)?)", text, re.I)
        if m2:
            try:
                return float(m2.group(1))
            except Exception:
                pass
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
                return True
            return int(tid) == int(task_id)
        except Exception:
            return False

    def resolve_item_id_candidates(self, task_id:int) -> List[int]:
        cands: List[int] = []
        try:
            t = self.get_task(task_id)
            cands += _flatten_find_item_ids(t)
        except Exception:
            pass
        try:
            assigns = self.get_assignments(task_id)
            cands += _flatten_find_item_ids(assigns)
        except Exception:
            pass
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
                    if iid <= 0:
                        continue
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
        out=[]; seen=set()
        for i in cands:
            if i not in seen:
                out.append(i); seen.add(i)
        return out

    def resolve_item_id(self, task_id: int) -> int:
        cands = self.resolve_item_id_candidates(task_id)
        if not cands:
            logging.error("[ITEM] Unable to resolve item_id for task %s", task_id)
            return 0
        for iid in cands:
            if self.is_item_valid_for_task(iid, task_id):
                logging.info("[ITEM] task %s -> item %s (validated)", task_id, iid)
                return iid
        iid = cands[0]
        logging.info("[ITEM] task %s -> item %s (first candidate)", task_id, iid)
        return iid

    def score_student(self, item_id: int, owner_id: int, score: float, comment: str=""):
        tmpl = os.getenv("SEIUE_SCORE_ENDPOINTS","POST:/vnas/klass/items/{item_id}/scores/sync?async=true&from_task=true:array")
        method, path, _schema = tmpl.split(":", 2)
        path = path.format(item_id=item_id)
        url = self._url(path)
        payload = {
            "owner_id": owner_id,
            "score": score,
            "comment": comment or "",
        }
        r = self._with_refresh(lambda: self.session.request(method, url, json=payload, timeout=30))
        if r.status_code >= 400:
            return False, r
        return True, r

    def post_review(self, receiver_id:int, task_id:int, content:str):
        tmpl = os.getenv("SEIUE_REVIEW_POST_TEMPLATE","/chalk/task/v2/assignees/{receiver_id}/tasks/{task_id}/reviews")
        path = tmpl.format(receiver_id=receiver_id, task_id=task_id)
        url = self._url(path)
        payload = {"content": content}
        r = self._with_refresh(lambda: self.session.post(url, json=payload, timeout=30))
        if r.status_code >= 400:
            logging.error("[API] post_review %s: %s", r.status_code, (r.text or "")[:200])
            return False
        return True

    def download_attachment(self, url: str, task_id: int, owner_id: int, filename: str, workdir: str) -> Optional[str]:
        try:
            pathlib.Path(workdir).mkdir(parents=True, exist_ok=True)
            if not url.startswith("http"):
                url = self._url(url)
            r = self._with_refresh(lambda: self.session.get(url, stream=True, timeout=120))
            if r.status_code >= 400:
                logging.error("[ATTACH] download fail %s: %s", r.status_code, (r.text or "")[:100])
                return None
            safe_fn = f"t{task_id}_o{owner_id}_{filename}".replace("/", "_").replace("..", "_")
            full_path = os.path.join(workdir, safe_fn)
            with open(full_path, "wb") as f:
                for chunk in r.iter_content(chunk_size=8192):
                    if chunk:
                        f.write(chunk)
            return full_path
        except Exception as e:
            logging.error("[ATTACH] exception: %s", e, exc_info=True)
            return None
PY

  # main.py —— 這裡直接寫一個不砍功能的版
  cat > "$APP_DIR/main.py" <<'PY'
import os, json, time, logging, traceback
from dotenv import load_dotenv
from seiue_api import Seiue
from utilx import clamp, scan_question_maxima, draftjs_to_text, stable_hash
from extractor import file_to_text
from ai_providers import AIClient

APP_DIR = "/opt/agrader"
ENV_PATH = os.path.join(APP_DIR, ".env")
if os.path.exists(ENV_PATH):
    load_dotenv(ENV_PATH)

STATE_PATH = os.getenv("STATE_PATH", os.path.join(APP_DIR, "state.json"))
LOG_LEVEL = os.getenv("LOG_LEVEL","INFO").upper()
LOG_FILE = os.getenv("LOG_FILE", os.path.join(APP_DIR, "agrader.log"))
RUN_MODE = os.getenv("RUN_MODE","watch")
STOP_CRITERIA = os.getenv("STOP_CRITERIA","score_and_review")
WORKDIR = os.getenv("WORKDIR", os.path.join(APP_DIR, "work"))

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format=os.getenv("LOG_FORMAT","%(asctime)s.%(msecs)03d %(levelname)s %(name)s - %(message)s"),
    datefmt=os.getenv("LOG_DATEFMT","%Y-%m-%d %H:%M:%S"),
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler()]
)

def load_state():
    if not os.path.exists(STATE_PATH):
        return {"task_items": {}, "graded": {}}
    try:
        with open(STATE_PATH,"r",encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {"task_items": {}, "graded": {}}

def save_state(st):
    tmp = STATE_PATH + ".tmp"
    with open(tmp,"w",encoding="utf-8") as f:
        json.dump(st,f,ensure_ascii=False,indent=2)
    os.replace(tmp, STATE_PATH)

def build_ai_client():
    provider = os.getenv("AI_PROVIDER","deepseek")
    if provider == "gemini":
        model = os.getenv("GEMINI_MODEL","gemini-2.5-pro")
        key = os.getenv("GEMINI_API_KEY","")
    else:
        provider = "deepseek"
        model = os.getenv("DEEPSEEK_MODEL","deepseek-reasoner")
        key = os.getenv("DEEPSEEK_API_KEY","")
    return AIClient(provider, model, key)

def build_prompt(task_obj, assignee_name, assignee_id, submission_text, attachments_text):
    perq, ovmax = scan_question_maxima(task_obj or {})
    tmpl_path = os.getenv("PROMPT_TEMPLATE_PATH", os.path.join(APP_DIR, "prompt.txt"))
    try:
        with open(tmpl_path, "r", encoding="utf-8") as f:
            tmpl = f.read()
    except Exception:
        tmpl = ("你是嚴格老師，請輸出 JSON。\n"
                "題目: {task_title}\n學生: {student_name}\n內容:\n{assignment_text}\n附件:\n{attachments_text}\n"
                '{"per_question":[],"overall":{"score":0,"comment":""}}')
    return tmpl.format(
        task_title=(task_obj.get("title") or task_obj.get("name") or f"Task {task_obj.get('id')}"),
        student_name=assignee_name or "?",
        student_id=assignee_id or "?",
        max_score=ovmax or task_obj.get("custom_fields",{}).get("max_score") or task_obj.get("max_score") or 40,
        per_question_json=json.dumps(perq, ensure_ascii=False),
        assignment_text=submission_text or "",
        attachments_text=attachments_text or "",
    ), ovmax

def extract_submission_text(submission) -> str:
    if not submission:
        return ""
    body = submission.get("body") or submission.get("content") or ""
    blocks = submission.get("content_json") or submission.get("contentJson") or None
    if blocks:
        return draftjs_to_text(blocks)
    return body

def flatten_attachments(submission) -> list:
    atts = submission.get("attachments") if submission else None
    if isinstance(atts, list):
        return atts
    return []

def get_env_flag(name: str, default=True):
    v = os.getenv(name, "1" if default else "0")
    return v not in ("0","false","False")

def main_once():
    base = os.getenv("SEIUE_BASE","https://api.seiue.com")
    bearer = os.getenv("SEIUE_BEARER","")
    school = os.getenv("SEIUE_SCHOOL_ID","3")
    role = os.getenv("SEIUE_ROLE","teacher")
    refl = os.getenv("SEIUE_REFLECTION_ID","")
    username = os.getenv("SEIUE_USERNAME","")
    password = os.getenv("SEIUE_PASSWORD","")

    client = Seiue(base, bearer, school, role, refl, username, password)
    ai_client = build_ai_client()
    st = load_state()

    raw_ids = os.getenv("MONITOR_TASK_IDS","").strip()
    if not raw_ids:
        logging.error("MONITOR_TASK_IDS empty, nothing to do.")
        return True
    task_ids = [int(x) for x in raw_ids.split(",") if x.strip().isdigit()]
    if not task_ids:
        logging.error("No valid task_ids in MONITOR_TASK_IDS.")
        return True

    item_refresh_on = (os.getenv("ITEM_ID_REFRESH_ON","score_404,score_422,verify_miss,ttl") or "").split(",")
    item_cache_ttl = int(os.getenv("ITEM_ID_CACHE_TTL","900"))
    full_mode = os.getenv("FULL_SCORE_MODE","off") == "all"
    full_comment = os.getenv("FULL_SCORE_COMMENT","記得看高考真題。")
    verify_after = get_env_flag("VERIFY_AFTER_WRITE", True)
    reverify_before = get_env_flag("REVERIFY_BEFORE_WRITE", True)
    retry_on_422 = get_env_flag("RETRY_ON_422_ONCE", True)
    score_clamp_on_max = get_env_flag("SCORE_CLAMP_ON_MAX", True)
    stop_criteria = os.getenv("STOP_CRITERIA","score_and_review")

    all_tasks_done = True

    for task_id in task_ids:
        # item_id with TTL cache
        now = time.time()
        task_items = st.setdefault("task_items", {})
        tentry = task_items.get(str(task_id)) or {}
        cached_item_id = tentry.get("item_id") or 0
        cached_at = tentry.get("cached_at") or 0
        need_refresh = False
        if not cached_item_id:
            need_refresh = True
        elif (now - cached_at) > item_cache_ttl:
            need_refresh = True
        if need_refresh:
            item_id = client.resolve_item_id(task_id)
            if item_id:
                task_items[str(task_id)] = {"item_id": item_id, "cached_at": now}
                save_state(st)
            else:
                logging.error("[TASK %s] Cannot resolve item_id, skip task", task_id)
                all_tasks_done = False
                continue
        else:
            item_id = cached_item_id

        try:
            task_obj = client.get_task(task_id)
        except Exception as e:
            logging.error("[TASK %s] get_task failed: %s", task_id, e)
            all_tasks_done = False
            continue

        try:
            assignments = client.get_assignments(task_id) or []
        except Exception as e:
            logging.error("[TASK %s] get_assignments failed: %s", task_id, e)
            all_tasks_done = False
            continue

        # try to get max score from item
        max_score = client.get_item_max_score(item_id) or task_obj.get("custom_fields",{}).get("max_score") or task_obj.get("max_score") or 40
        try:
            max_score = float(max_score)
        except Exception:
            max_score = 40.0

        graded = st.setdefault("graded", {})
        task_gr = graded.setdefault(str(task_id), {})

        done_cnt = 0
        total_cnt = len(assignments)
        for ass in assignments:
            rid = ass.get("id") or ass.get("_id")
            if not rid:
                continue
            assignee = ass.get("assignee") or {}
            owner_id = assignee.get("id") or assignee.get("_id")
            assignee_name = assignee.get("name") or assignee.get("realname") or assignee.get("username") or "學生"
            submission = ass.get("submission") or {}
            # skip if already recorded and stop_criteria says so
            # we still verify existing score in Seiue to avoid double write
            existing_key = str(owner_id)
            # re-verify before write
            existing_score_remote = None
            if reverify_before and owner_id:
                existing_score_remote = client.verify_existing_score(item_id, owner_id)
                if existing_score_remote is not None:
                    # record and skip
                    task_gr[existing_key] = {"score": existing_score_remote, "ts": time.time()}
                    logging.info("[FULL][OK*existing][TASK %s] rid=%s name=%s (already exists: %.2f)", task_id, rid, assignee_name, existing_score_remote)
                    done_cnt += 1
                    continue

            if full_mode:
                score_to_write = max_score
                comment_to_write = full_comment
            else:
                # normal AI flow
                submission_text = extract_submission_text(submission)
                # attachments
                attachments_texts = []
                for att in flatten_attachments(submission):
                    url = att.get("url") or att.get("path") or att.get("download_url")
                    fname = att.get("name") or att.get("filename") or "attach"
                    if not url:
                        continue
                    dl = client.download_attachment(url, task_id, owner_id or 0, fname, WORKDIR)
                    if dl:
                        attachments_texts.append(file_to_text(dl))
                merged_attachments = "\n---\n".join(attachments_texts)
                prompt, ovmax = build_prompt(task_obj, assignee_name, owner_id, submission_text, merged_attachments)
                ai_res = ai_client.grade(prompt)
                overall = ai_res.get("overall") or {}
                ai_score = overall.get("score") or 0
                ai_comment = overall.get("comment") or ""
                try:
                    ai_score = float(ai_score)
                except Exception:
                    ai_score = 0.0
                if score_clamp_on_max:
                    ai_score = clamp(ai_score, 0.0, float(max_score))
                score_to_write = ai_score
                comment_to_write = ai_comment or "已閱。"

            ok, resp = client.score_student(item_id, owner_id, score_to_write, comment_to_write)
            if not ok:
                status = resp.status_code
                body = (resp.text or "")[:300]
                logging.error("[TASK %s] score_student fail %s: %s", task_id, status, body)
                # item mismatch -> refresh and retry once
                if client._err_implies_item_mismatch(status, body) and "score_404" in item_refresh_on or "score_422" in item_refresh_on:
                    logging.warning("[TASK %s] item mismatch, refreshing item_id and retry...", task_id)
                    new_item_id = client.resolve_item_id(task_id)
                    if new_item_id and new_item_id != item_id:
                        st["task_items"][str(task_id)] = {"item_id": new_item_id, "cached_at": time.time()}
                        save_state(st)
                        ok2, resp2 = client.score_student(new_item_id, owner_id, score_to_write, comment_to_write)
                        if ok2:
                            item_id = new_item_id
                            ok = True
                            resp = resp2
                        else:
                            logging.error("[TASK %s] retry after item refresh still failed: %s", task_id, (resp2.text or "")[:200])
                if not ok and status == 422 and retry_on_422:
                    # maybe max score
                    mx = client.parse_max_from_422(body)
                    if mx:
                        score_to_write = mx
                        ok3, resp3 = client.score_student(item_id, owner_id, score_to_write, comment_to_write)
                        if ok3:
                            ok = True
                            resp = resp3
                if not ok:
                    all_tasks_done = False
                    continue

            # review (always)
            client.post_review(owner_id, task_id, comment_to_write)
            task_gr[existing_key] = {"score": score_to_write, "ts": time.time()}
            save_state(st)

            # verify after write
            if verify_after and owner_id:
                ver = client.verify_existing_score(item_id, owner_id)
                if ver is None:
                    logging.warning("[TASK %s] wrote score but verify missed (owner_id=%s)", task_id, owner_id)
                    if "verify_miss" in item_refresh_on:
                        st["task_items"][str(task_id)] = {"item_id": client.resolve_item_id(task_id), "cached_at": time.time()}
                        save_state(st)
                else:
                    logging.info("[API] Review posted for rid=%s task=%s", rid, task_id)
                    logging.info("[FULL][DONE][TASK %s] %s/%s rid=%s name=%s score=%.2f status=ok",
                                 task_id, done_cnt+1, total_cnt, rid, assignee_name, score_to_write)

            done_cnt += 1

        # finish this task
        logging.info("[SUMMARY][TASK %s] ✅ Task %s processed: %s / %s", task_id, task_id, done_cnt, total_cnt)
        if done_cnt < total_cnt:
            all_tasks_done = False

    return all_tasks_done

def main():
    poll = int(os.getenv("POLL_INTERVAL","10"))
    if RUN_MODE == "oneshot":
        main_once()
        return
    while True:
        try:
            all_done = main_once()
        except Exception as e:
            logging.error("[LOOP] exception: %s", e, exc_info=True)
            all_done = False
        if all_done and STOP_CRITERIA in ("score","review","score_and_review"):
            logging.info("[EXEC] All tasks complete. Shutting down.")
            break
        time.sleep(poll)

if __name__ == "__main__":
    main()
PY

}

create_venv_and_install() {
  echo "[6/12] Creating venv and installing requirements..."
  mkdir -p "$APP_DIR"
  if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
  fi
  # shellcheck disable=SC1091
  . "$VENV_DIR/bin/activate"
  pip install --upgrade pip >/dev/null 2>&1 || true
  pip install -r "$APP_DIR/requirements.txt"
}

write_systemd() {
  if [ "$(os_detect)" != "linux" ]; then
    return
  fi
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=AGrader - Seiue auto-grader
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
Environment=PYTHONUNBUFFERED=1
ExecStart=${VENV_DIR}/bin/python ${PY_MAIN}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

write_launchd() {
  if [ "$(os_detect)" != "mac" ]; then
    return
  fi
  mkdir -p "$(dirname "$LAUNCHD_PLIST")"
  cat > "$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>net.bdfz.agrader</string>
  <key>ProgramArguments</key>
  <array>
    <string>${VENV_DIR}/bin/python</string>
    <string>${PY_MAIN}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>WorkingDirectory</key><string>${APP_DIR}</string>
  <key>StandardOutPath</key><string>${APP_DIR}/agrader.log</string>
  <key>StandardErrorPath</key><string>${APP_DIR}/agrader.log</string>
</dict>
</plist>
EOF
  launchctl load -w "$LAUNCHD_PLIST" || true
}

stop_previous() {
  echo "[PRE] Stopping any previous AGrader processes/services..."
  if [ "$(os_detect)" = "linux" ]; then
    systemctl stop "$SERVICE" 2>/dev/null || true
  else
    launchctl stop net.bdfz.agrader 2>/dev/null || true
  fi
}

start_service() {
  if [ "$(os_detect)" = "linux" ]; then
    echo "[8/12] Stopping existing service if running..."
    systemctl stop "$SERVICE" 2>/dev/null || true
    echo "[9/12] Enabling and starting..."
    systemctl enable "$SERVICE" >/dev/null 2>&1 || true
    systemctl start "$SERVICE"
  else
    echo "[8/12] (macOS) service already loaded."
  fi
}

tail_logs() {
  if [ "$(os_detect)" = "linux" ]; then
    echo "[10/12] Logs (last 20):"
    journalctl -u "$SERVICE" -n 20 --no-pager || true
    echo "Tail: journalctl -u $SERVICE -f"
  else
    echo "[10/12] Tail logs at ${APP_DIR}/agrader.log"
  fi
  echo "[11/12] Edit config: sudo nano ${ENV_FILE}"
  if [ "$(os_detect)" = "linux" ]; then
    echo "[12/12] Restart: sudo systemctl restart ${SERVICE}"
  else
    echo "[12/12] Restart: launchctl stop net.bdfz.agrader && launchctl start net.bdfz.agrader"
  fi
}

main_install() {
  if [ "$(os_detect)" = "linux" ]; then
    install_pkgs_linux
  elif [ "$(os_detect)" = "mac" ]; then
    install_pkgs_macos
  fi

  if [ -f "$ENV_FILE" ]; then
    echo "[2/12] Collecting initial configuration..."
    echo "Reusing existing $ENV_FILE"
  else
    echo "[2/12] Collecting initial configuration..."
    mkdir -p "$APP_DIR"
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    write_project 1
  fi

  stop_previous
  prompt_task_ids
  prompt_mode
  write_project 0
  create_venv_and_install
  write_systemd
  write_launchd
  start_service
  tail_logs
}

main_install