#!/usr/bin/env bash
# yue.k12media.cn 自動閱卷 demo — shell 版（加固版 / 可換題目）
# 原始轉寫：2025-11-11
# 本次加固：2026-01-19
# 依賴：bash, curl, jq, base64, mkdir, date, python3
# 建議：macOS 用 brew 裝 jq:  brew install jq
# ------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="yue-auto-mark-2026-01-19-hardened"
echo "[info] script version: $SCRIPT_VERSION"

############################################
# 0. CLI 參數（可選）
############################################
#
# 你可以：
#   ./yue-auto-mark.sh \
#      --paper-id 46736 --item-group-id 866723 \
#      --model gemini-2.5-flash \
#      --prompt-file ./prompt.txt \
#      --export-dir exports --tag yue_marking_20260119
#

PAPER_ID=""
ITEM_GROUP_ID=""
GEMINI_MODEL="gemini-3-flash"
PROMPT_FILE=""
EXPORT_DIR="exports"
EXPORT_TAG=""

while (($#)); do
  case "$1" in
    --paper-id)
      PAPER_ID="$2"; shift 2 ;;
    --item-group-id)
      ITEM_GROUP_ID="$2"; shift 2 ;;
    --model)
      GEMINI_MODEL="$2"; shift 2 ;;
    --prompt-file)
      PROMPT_FILE="$2"; shift 2 ;;
    --export-dir)
      EXPORT_DIR="$2"; shift 2 ;;
    --tag)
      EXPORT_TAG="$2"; shift 2 ;;
    -h|--help)
      cat <<'HELP'
Usage:
  ./yue-auto-mark.sh [options]

Options:
  --paper-id <id>        PaperID
  --item-group-id <id>   ItemGroupID
  --model <name>         Gemini model (default: gemini-2.5-flash)
  --prompt-file <path>   External prompt txt file (for next questions)
  --export-dir <dir>     Export directory (default: exports)
  --tag <tag>            Export tag prefix
HELP
      exit 0
      ;;
    *)
      echo "[fatal] unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

############################################
# 1. 基本配置
############################################

BASE="https://yue.k12media.cn/testmate/json"

# ✅ 建議：用環境變量覆蓋（避免把帳密寫進腳本）
USERNAME="${YUE_USERNAME:-}"  # export YUE_USERNAME='xxx'
PASSWORD="${YUE_PASSWORD:-}"  # export YUE_PASSWORD='xxx'
SITE_ID="${YUE_SITE_ID:-}"    # export YUE_SITE_ID='303'

# Paper / ItemGroup：可用 CLI 或環境變量覆蓋
: "${PAPER_ID:=${YUE_PAPER_ID:-}}"
: "${ITEM_GROUP_ID:=${YUE_ITEM_GROUP_ID:-}}"

if [[ -z "$PAPER_ID" || -z "$ITEM_GROUP_ID" ]]; then
  echo "[fatal] PAPER_ID / ITEM_GROUP_ID is required. Use --paper-id/--item-group-id or env YUE_PAPER_ID/YUE_ITEM_GROUP_ID" >&2
  exit 1
fi

# timeout
SITE_TIMEOUT="${YUE_SITE_TIMEOUT:-10}"
GEMINI_TIMEOUT="${YUE_GEMINI_TIMEOUT:-25}"
GEMINI_RETRY="${YUE_GEMINI_RETRY:-3}"

# 沒任務時等幾秒
IDLE_SLEEP="${YUE_IDLE_SLEEP:-3}"

# 統計
TOTAL_FETCHED=0     # 拿到的任務數（包含成功/失敗）
TOTAL_SCORED=0      # 成功送回去的數
TOTAL_FAILED=0      # 中途失敗、需要 cancel 的數

# 平台進度（從 Apply 的 JSON 裡拿）
PLATFORM_TOTAL=""        # PaperCount
PLATFORM_DONE=""         # MarkingCompleteCount[].D2
PLATFORM_ME_COUNT=""     # ScoreStatistics[].MarkingCount
PLATFORM_ME_AVG=""       # ScoreStatistics[].ScoreSum / MarkingCount

TOKEN=""

# Gemini keys：
# 1) 優先讀 GEMINI_API_KEYS 環境變量（逗號分隔）
# 2) 否則用下面陣列
# 注意：環境變量名叫 GEMINI_API_KEYS（和腳本陣列同名）
GEMINI_API_KEYS_ARR=()
if [[ -n "${GEMINI_API_KEYS:-}" ]]; then
  # shellcheck disable=SC2206
  GEMINI_API_KEYS_ARR=( ${GEMINI_API_KEYS//,/ } )
else
  GEMINI_API_KEYS_ARR=(
    ""
  )
fi

if [[ ${#GEMINI_API_KEYS_ARR[@]} -eq 0 ]]; then
  echo "[fatal] No Gemini API keys. Set env GEMINI_API_KEYS='k1,k2' or fill array." >&2
  exit 1
fi

GEMINI_KEY_INDEX=0
KEY_COOLDOWN_SEC="${GEMINI_KEY_COOLDOWN_SEC:-120}"
ALL_KEYS_BUSY_SLEEP="${GEMINI_ALL_KEYS_BUSY_SLEEP:-15}"

# exports
mkdir -p "$EXPORT_DIR"
if [[ -z "$EXPORT_TAG" ]]; then
  EXPORT_TAG="yue_marking_$(date '+%Y%m%d_%H%M%S')"
fi
EXPORT_JSONL="$EXPORT_DIR/${EXPORT_TAG}_records.jsonl"
EXPORT_VALID_REPORTS="$EXPORT_DIR/${EXPORT_TAG}_valid_reports.txt"
EXPORT_INVALID_REPORTS="$EXPORT_DIR/${EXPORT_TAG}_invalid_reports.txt"

############################################
# 2. Prompt（默認：4 分題；下次換題請用 --prompt-file）
############################################

read -r -d '' DEFAULT_PROMPT <<'EOF'
你是一個語文閱卷老師，請你根據下面這套固定的參考答案與評分標準，對學生的作答進行打分，滿分 4 分。
請你一定要先識別圖片中的學生答案，再按四條依次判分，每一條都寫一句判語，最後給一段總評。

【參考答案與評分標準（固定內容）】

①塑造人物形象。吉米的父親看到蝙蝠就飛起刷子扔過去，說明父親身手矯健（1 分），最終吉米抓住蝙蝠，先關在籠子裡，但晚上的時候兩個人又把蝙蝠放生，刻畫出吉米的善良和對生命的尊重呵護。（1 分）

②烘托離別情緒。（1 分）離別在即，廚房裡的任何一件事物都能讓吉米想起之前的事情，一個洗碗刷，背後有父子兩人抓蝙蝠、放飛蝙蝠的溫馨往事。（1 分）可以想像，其他的東西也同樣有不同的故事，小說雖然不一一提及，但通過這一細節，可以給讀者充分的想像空間，可以想像這個廚房承載著吉米多少的回憶。（1 分）

【打分要點（要嚴格照這個來）】
1. 「父親形象」這一分（point_father）：
   - 必須說到這個具體細節：「父親看到蝙蝠就用刷子扔過去」「父親迅速處理蝙蝠」這類，才能給 1 分。
   - 只說「父親很好」「父親關心生活」「父親不拘小節」但沒扣到蝙蝠/刷子/抓蝙蝠這個細節，一律 0 分。
2. 「吉米形象」這一分（point_jimmy）：
   - 必須說到吉米（或寫成“我”的這個人物）善良 / 放生 / 尊重生命 / 把蝙蝠放回去 / 對生命有呵護，才能給 1 分。
   - 只說「回憶」「我對家不捨」這種不行，0 分。
   - 原文叫「吉米」，如果學生寫成「我」，你也要當成同一個人來判。
3. 「烘托離別情緒」這一分（point_farewell）：
   - 要把「離別在即」+「看到廚房裡的物件想起抓蝙蝠這件事」這兩部分說出來，才給 1 分。
   - 只說「表現了離別的傷感」沒有扣到這個物件細節，0 分。
4. 「細節作用」這一分（point_detail_function）：
   - 說到「這個廚房承載很多回憶」「這個細節帶出沒寫完的往事」「給讀者想像空間」這一類，給 1 分。
   - 沒說到上述作用，0 分。

【你要輸出的 JSON 結構（必須照這個）】：
{
  "student_answer": "...你從圖片裡識別出的學生原文...",
  "point_father": 0,
  "comment_father": "",
  "point_jimmy": 0,
  "comment_jimmy": "",
  "point_farewell": 0,
  "comment_farewell": "",
  "point_detail_function": 0,
  "comment_detail_function": "",
  "final_score": 0,
  "overall_comment": ""
}

請注意：
- 一定要輸出合法 JSON，不能有 ```json 這種標記，不能有多餘文字。
- 四個點的分數相加必須等於 final_score。
- 如果圖片沒有字，就當作空白卷，四項都 0，final_score 也 0，overall_comment 寫「未作答」即可。
EOF

GEMINI_SCORING_PROMPT="$DEFAULT_PROMPT"
if [[ -n "$PROMPT_FILE" ]]; then
  if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "[fatal] prompt file not found: $PROMPT_FILE" >&2
    exit 1
  fi
  GEMINI_SCORING_PROMPT="$(cat "$PROMPT_FILE")"
fi

############################################
# 3. 小工具
############################################

log() {
  echo "[$(date '+%H:%M:%S')] $*" >&1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[fatal] '$1' not found. Please install it (brew install $1)"; exit 1;
  }
}

urlencode() {
  python3 - <<'PYCODE'
import sys, urllib.parse
print(urllib.parse.quote(sys.stdin.read().rstrip(), safe=''))
PYCODE
}

mask_secret() {
  local s="$1"
  if [[ -z "$s" ]]; then
    echo ""
    return
  fi
  local n=${#s}
  if (( n <= 12 )); then
    echo "***"
    return
  fi
  echo "${s:0:6}***${s:n-6:6}"
}

ensure_image_dir() {
  mkdir -p images
}

now_epoch() {
  date +%s
}

# ✅ 為兼容 macOS 內建 bash 3.2，不用 assoc array，用平行陣列
KEYS_COOLDOWN_UNTIL=()

init_cooldowns() {
  KEYS_COOLDOWN_UNTIL=()
  for _ in "${GEMINI_API_KEYS_ARR[@]}"; do
    KEYS_COOLDOWN_UNTIL+=("0")
  done
}

set_key_cooldown() {
  local idx="$1"
  local until="$2"
  KEYS_COOLDOWN_UNTIL[$idx]="$until"
}

get_key_cooldown() {
  local idx="$1"
  echo "${KEYS_COOLDOWN_UNTIL[$idx]}"
}

pick_usable_key_index() {
  local now
  now=$(now_epoch)

  local total=${#GEMINI_API_KEYS_ARR[@]}
  for ((i=0; i<total; i++)); do
    local idx=$GEMINI_KEY_INDEX
    local cd
    cd=$(get_key_cooldown "$idx")
    if (( now >= cd )); then
      echo "$idx"
      return 0
    fi
    GEMINI_KEY_INDEX=$(( (GEMINI_KEY_INDEX + 1) % total ))
  done
  echo "-1"
}

get_next_key_by_index() {
  local idx="$1"
  echo "${GEMINI_API_KEYS_ARR[$idx]}"
  local total=${#GEMINI_API_KEYS_ARR[@]}
  GEMINI_KEY_INDEX=$(( (idx + 1) % total ))
}

############################################
# 4. 登錄 & 通用請求
############################################

login() {
  local url="$BASE/Login.ashx"
  log "login → $url"

  local resp
  resp=$(curl -sS --connect-timeout "$SITE_TIMEOUT" --max-time "$SITE_TIMEOUT" \
    -d "clientType=html5" \
    --data-urlencode "siteID=$SITE_ID" \
    --data-urlencode "username=$USERNAME" \
    --data-urlencode "password=$PASSWORD" \
    "$url")

  local ok
  ok=$(echo "$resp" | jq -r '.OperatorSuccess')
  if [[ "$ok" != "true" ]]; then
    echo "[fatal] login failed: $resp" >&2
    exit 1
  fi
  TOKEN=$(echo "$resp" | jq -r '.Token')
  log "login ok, token=$(mask_secret "$TOKEN")"
}

api_post() {
  local path="$1"; shift
  local url="$BASE/$path"
  local data=("token=$TOKEN")
  while (($#)); do
    data+=("$1")
    shift
  done

  local resp
  resp=$(curl -sS --connect-timeout "$SITE_TIMEOUT" --max-time "$SITE_TIMEOUT" \
    -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
    -H "Origin: https://yue.k12media.cn" \
    -H "Referer: https://yue.k12media.cn/testmate/index.html" \
    -d "${data[@]}" \
    "$url" || true)

  local login_err
  login_err=$(echo "$resp" | jq -r 'select(.OperatorSuccess == false) | .Describe' 2>/dev/null || echo "")
  if [[ "$login_err" == *"登录"* ]]; then
    log "api_post: token invalid, re-login..."
    login
    resp=$(curl -sS --connect-timeout "$SITE_TIMEOUT" --max-time "$SITE_TIMEOUT" \
      -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
      -H "Origin: https://yue.k12media.cn" \
      -H "Referer: https://yue.k12media.cn/testmate/index.html" \
      -d "token=$TOKEN" -d "${data[@]:1}" \
      "$url")
  fi

  printf "%s" "$resp"
}

############################################
# 5. 拿 paper_item_id & full_score
############################################

get_marking_item_group_info() {
  local resp
  resp=$(api_post "GetMarkingItemGroupInfo.ashx")

  local paper_item_id
  local full_score

  paper_item_id=$(echo "$resp" | jq --argjson pid "$PAPER_ID" --argjson gid "$ITEM_GROUP_ID" '
    .MarkingItemGroupInfos[]? | select(.PaperID == $pid)
    | .ItemGroups[]? | select(.ItemGroupID == $gid)
    | .Items[0].PaperItemID
  ' 2>/dev/null)

  full_score=$(echo "$resp" | jq --argjson pid "$PAPER_ID" --argjson gid "$ITEM_GROUP_ID" '
    .MarkingItemGroupInfos[]? | select(.PaperID == $pid)
    | .ItemGroups[]? | select(.ItemGroupID == $gid)
    | .Items[0].FullScore
  ' 2>/dev/null)

  if [[ -z "$paper_item_id" || "$paper_item_id" == "null" ]]; then
    echo "[fatal] ItemGroup not found in GetMarkingItemGroupInfo.ashx" >&2
    echo "$resp" >&2
    exit 1
  fi

  echo "$paper_item_id|$full_score"
}

############################################
# 6. 申請任務、取圖
############################################

apply_paper_marking_task() {
  local url="$BASE/ApplyPaperMarkingTask.ashx"
  log "apply task → $url"

  local resp
  resp=$(curl -sS --connect-timeout "$SITE_TIMEOUT" --max-time "$SITE_TIMEOUT" \
    -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
    -H "Origin: https://yue.k12media.cn" \
    -H "Referer: https://yue.k12media.cn/testmate/index.html" \
    -d "token=$TOKEN" \
    -d "paperID=$PAPER_ID" \
    -d "itemGroupID=$ITEM_GROUP_ID" \
    "$url")

  # 更新平台進度
  local task_block
  task_block=$(echo "$resp" | jq '.Task // empty')
  if [[ -n "$task_block" ]]; then
    local pt pd
    pt=$(echo "$task_block" | jq -r '.PaperCount // empty')
    pd=$(echo "$task_block" | jq -r '.MarkingCompleteCount[0].D2 // empty')
    local mc ss
    mc=$(echo "$task_block" | jq -r '.ScoreStatistics[0].MarkingCount // empty')
    ss=$(echo "$task_block" | jq -r '.ScoreStatistics[0].ScoreSum // empty')

    if [[ -n "$pt" && "$pt" != "null" ]]; then PLATFORM_TOTAL="$pt"; fi
    if [[ -n "$pd" && "$pd" != "null" ]]; then PLATFORM_DONE="$pd"; fi
    if [[ -n "$mc" && "$mc" != "null" ]]; then PLATFORM_ME_COUNT="$mc"; fi
    if [[ -n "$mc" && -n "$ss" && "$mc" != "null" && "$ss" != "null" && "$mc" != "0" ]]; then
      PLATFORM_ME_AVG=$(python3 - <<PY
mc = $mc
ss = $ss
print(round(ss/mc, 2))
PY
)
    fi
  fi

  local task_id
  task_id=$(echo "$resp" | jq -r '.PaperMarkingTaskID // .Task.PaperMarkingTaskID // empty')
  if [[ -z "$task_id" || "$task_id" == "null" ]]; then
    echo "NONE|$resp"
  else
    echo "$task_id|$resp"
  fi
}

fetch_answer_image() {
  local apply_json="$1"
  local img_file="$2"

  local img_buf_id
  img_buf_id=$(echo "$apply_json" | jq -r '.ImageBufferID // .ImageBufferId // .imageBufferID // .Task.ImageBufferID // .Task.ImageBufferId // .Task.imageBufferID // empty')
  if [[ -z "$img_buf_id" || "$img_buf_id" == "null" ]]; then
    echo "[fatal] apply resp has no ImageBufferID" >&2
    echo "$apply_json" >&2
    return 1
  fi

  local token_enc
  token_enc=$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("$TOKEN"))
PY
)

  local buf_enc
  buf_enc=$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("$img_buf_id"))
PY
)

  # ✅ terminal 不打印帶 token 的完整 URL
  log "download image → ImageBufferID=$img_buf_id"

  local img_url="https://yue.k12media.cn/testmate/json/GetImageFromBuffer.ashx?token=${token_enc}&ImageBufferID=${buf_enc}"

  curl -sS --connect-timeout "$SITE_TIMEOUT" --max-time "$SITE_TIMEOUT" \
    -H "Referer: https://yue.k12media.cn/testmate/index.html" \
    -o "$img_file" \
    "$img_url"

  local sz
  sz=$(wc -c < "$img_file" | tr -d ' ')
  if [[ -z "$sz" || "$sz" -lt 32 ]]; then
    echo "[fatal] downloaded image too small/empty: $sz bytes" >&2
    return 1
  fi

  echo "$img_buf_id"
}

############################################
# 7. Gemini OCR + 打分（加固：可換題 & key cooldown）
############################################

# 將 Gemini 返回的 text 解析/校驗成可用 JSON：
# - 去掉 ``` 包裹
# - 抽取第一個 {...} JSON
# - 正規化 point_* 為 0/1
# - final_score = sum(point_*)
normalize_gemini_text_to_json() {
  python3 - <<'PY'
import sys, json, re

def parse_any_json(text: str):
    t = (text or '').strip()
    try:
        return json.loads(t)
    except Exception:
        pass

    if t.startswith('```'):
        nl = t.find('\n')
        if nl != -1:
            inner = t[nl+1:].strip()
            if inner.endswith('```'):
                inner = inner[:-3].strip()
            try:
                return json.loads(inner)
            except Exception:
                pass

    m = re.search(r"\{.*\}", t, flags=re.S)
    if m:
        try:
            return json.loads(m.group(0))
        except Exception:
            return None
    return None

raw = sys.stdin.read()
obj = parse_any_json(raw)

if not isinstance(obj, dict):
    out = {
        "student_answer": raw.strip(),
        "final_score": 0,
        "overall_comment": "模型輸出非標準 JSON，已降級為 0 分，請人工核查。",
        "_validate_reason": "parse_failed"
    }
    print(json.dumps(out, ensure_ascii=False))
    sys.exit(0)

points_sum = 0
for k in list(obj.keys()):
    if isinstance(k, str) and k.startswith('point_'):
        v = obj.get(k)
        try:
            iv = int(str(v).strip())
            iv = 1 if iv != 0 else 0
        except Exception:
            iv = 0
        obj[k] = iv
        points_sum += iv

obj.setdefault('student_answer', '')
obj.setdefault('overall_comment', '本題已按 point_* 拆分評分，請對照批語修改。')

obj['final_score'] = int(points_sum)

if points_sum == 0 and not str(obj.get('student_answer', '')).strip():
    obj['overall_comment'] = obj.get('overall_comment') or '未作答'

obj['_validate_reason'] = 'ok'
print(json.dumps(obj, ensure_ascii=False))
PY
}

gemini_call() {
  local image_path="$1"

  local image_b64
  image_b64=$(base64 < "$image_path" | tr -d '\n')

  local total_keys=${#GEMINI_API_KEYS_ARR[@]}
  local last_err=""

  while true; do
    local idx
    idx=$(pick_usable_key_index)
    if [[ "$idx" == "-1" ]]; then
      log "[gemini] all keys in cooldown, sleep ${ALL_KEYS_BUSY_SLEEP}s ..."
      sleep "$ALL_KEYS_BUSY_SLEEP"
      continue
    fi

    local key
    key=$(get_next_key_by_index "$idx")

    local url="https://generativelanguage.googleapis.com/v1beta/models/$GEMINI_MODEL:generateContent?key=$key"

    local payload
    payload=$(jq -n --arg prompt "$GEMINI_SCORING_PROMPT" --arg img "$image_b64" '
      {
        contents: [
          {
            parts: [
              {text: $prompt},
              {inline_data: {mime_type: "image/png", data: $img}}
            ]
          }
        ]
      }
    ')

    for ((attempt=1; attempt<=GEMINI_RETRY; attempt++)); do
      log "gemini key=$(mask_secret "$key") idx=$((idx+1))/${total_keys} attempt ${attempt}/${GEMINI_RETRY} model=$GEMINI_MODEL"

      local resp_with_code
      resp_with_code=$(curl -sS --connect-timeout "$GEMINI_TIMEOUT" --max-time "$GEMINI_TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        -w "\n__HTTP_CODE__:%{http_code}" \
        "$url" 2>&1) || true

      local http_code
      http_code=$(echo "$resp_with_code" | tail -n 1 | sed 's/__HTTP_CODE__://')
      local resp
      resp=$(echo "$resp_with_code" | sed '$d')

      if [[ "$http_code" == "429" || "$http_code" == "503" ]]; then
        local until
        until=$(( $(now_epoch) + KEY_COOLDOWN_SEC ))
        set_key_cooldown "$idx" "$until"
        log "[gemini] http=$http_code → cooldown key idx=$idx for ${KEY_COOLDOWN_SEC}s"
        last_err="$resp"
        break
      fi

      local text
      text=$(echo "$resp" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null || true)
      if [[ -z "$text" ]]; then
        last_err="$resp"
        log "[gemini] empty text, retry ..."
        sleep 1
        continue
      fi

      echo "$text" | normalize_gemini_text_to_json
      return 0
    done

    # next key
    continue
  done

  echo "[fatal] gemini all keys failed: $last_err" >&2
  return 1
}

############################################
# 8. 提交 & 取消
############################################

submit_marking_result() {
  local task_id="$1"
  local paper_item_id="$2"
  local score="$3"

  local task_result_obj
  task_result_obj=$(jq -n \
    --argjson t "$task_id" \
    --argjson pi "$paper_item_id" \
    --arg s "$score" '
    {
      PaperMarkingTaskID: $t,
      InkTrace: [],
      ItemScores: [
        {
          PaperItemID: $pi,
          ItemScore: $s,
          PointScores: [],
          PanelScores: [],
          ErrorTypes: "",
          ErrorTypeSigns: []
        }
      ]
    }
  ')

  local encoded
  encoded=$(printf "%s" "$task_result_obj" | urlencode)

  local url="$BASE/SubmitMarkingTaskResult.ashx"
  log "submit → $url (score=$score)"

  local resp
  resp=$(curl -sS --connect-timeout "$SITE_TIMEOUT" --max-time "$SITE_TIMEOUT" \
    -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
    -H "Origin: https://yue.k12media.cn" \
    -H "Referer: https://yue.k12media.cn/testmate/index.html" \
    --data "token=$TOKEN&taskResult=$encoded" \
    "$url")

  printf "%s" "$resp"
}

cancel_task() {
  local task_id="$1"
  local deleted
  deleted=$(jq -n --argjson tid "$task_id" '[{TaskType:1, TaskID:$tid}]')
  local resp
  resp=$(api_post "CancelTask.ashx" "deletedTasks=$(printf "%s" "$deleted" | urlencode)")
  printf "%s" "$resp"
}

############################################
# 9. 導出 / 報告
############################################

append_jsonl() {
  local path="$1"
  local json_line="$2"
  printf "%s\n" "$json_line" >> "$path"
}

append_text() {
  local path="$1"
  local text="$2"
  printf "%s\n" "$text" >> "$path"
}

build_report_block() {
  local task_id="$1"
  local img_path="$2"
  local score="$3"
  local full_score="$4"
  local gemini_json="$5"

  local sa
  sa=$(echo "$gemini_json" | jq -r '.student_answer // ""')

  local lines=()
  lines+=("[report] ===== 一份批完 =====")
  lines+=("任務ID: $task_id")
  lines+=("圖片路徑: $img_path")
  lines+=("得分(送回網站): $score/$full_score")
  lines+=("學生答案OCR: $sa")

  local pts
  pts=$(echo "$gemini_json" | jq -r 'to_entries | map(select(.key|startswith("point_"))) | sort_by(.key) | .[] | .key')
  if [[ -n "$pts" ]]; then
    while read -r pk; do
      [[ -z "$pk" ]] && continue
      local ck
      ck="comment_${pk#point_}"
      local pv cv
      pv=$(echo "$gemini_json" | jq -r --arg k "$pk" '.[$k] // 0')
      cv=$(echo "$gemini_json" | jq -r --arg k "$ck" '.[$k] // ""')
      lines+=("${pk}(${pv}): ${cv}")
    done <<< "$pts"
  fi

  local oc
  oc=$(echo "$gemini_json" | jq -r '.overall_comment // ""')
  lines+=("總評: $oc")
  lines+=("[report] =====================")

  (IFS=$'\n'; echo "${lines[*]}")
}

############################################
# 10. 主流程
############################################

main() {
  require_cmd curl
  require_cmd jq
  require_cmd python3
  require_cmd base64

  if [[ -z "$USERNAME" || -z "$PASSWORD" || -z "$SITE_ID" ]]; then
    echo "[fatal] Missing USERNAME/PASSWORD/SITE_ID. Please export YUE_USERNAME / YUE_PASSWORD / YUE_SITE_ID." >&2
    exit 1
  fi

  log "[init] paper_id=$PAPER_ID item_group_id=$ITEM_GROUP_ID"
  log "[init] gemini_model=$GEMINI_MODEL export_tag=$EXPORT_TAG"
  log "[init] jsonl=$EXPORT_JSONL"

  init_cooldowns
  login

  local info
  info=$(get_marking_item_group_info)
  local paper_item_id="${info%%|*}"
  local full_score="${info##*|}"
  log "[init] paper_item_id=$paper_item_id full_score=$full_score"

  ensure_image_dir

  while true; do
    local applied
    applied=$(apply_paper_marking_task)
    local task_id="${applied%%|*}"
    local apply_json="${applied#*|}"

    if [[ "$task_id" == "NONE" ]]; then
      if [[ -n "$PLATFORM_TOTAL" ]]; then
        local msg="[loop] no task, sleep ${IDLE_SLEEP}s ... (platform ${PLATFORM_DONE}/${PLATFORM_TOTAL}"
        if [[ -n "$PLATFORM_ME_COUNT" ]]; then
          msg+=", me=$PLATFORM_ME_COUNT"
        fi
        if [[ -n "$PLATFORM_ME_AVG" ]]; then
          msg+=", avg=$PLATFORM_ME_AVG"
        fi
        msg+=")"
        log "$msg"
      else
        log "[loop] no task, sleep ${IDLE_SLEEP}s ... (done=$TOTAL_SCORED, failed=$TOTAL_FAILED)"
      fi
      sleep "$IDLE_SLEEP"
      continue
    fi

    TOTAL_FETCHED=$((TOTAL_FETCHED + 1))

    local img_path="images/${task_id}.png"
    local img_buf_id=""

    if ! img_buf_id=$(fetch_answer_image "$apply_json" "$img_path"); then
      log "[error] fetch image failed, cancel task $task_id"
      cancel_task "$task_id" >/dev/null 2>&1 || true
      TOTAL_FAILED=$((TOTAL_FAILED + 1))
      log "[progress] fetched=$TOTAL_FETCHED success=$TOTAL_SCORED failed=$TOTAL_FAILED"
      sleep "$IDLE_SLEEP"
      continue
    fi

    log "[image] saved to $img_path (ImageBufferID=$img_buf_id)"

    local gemini_json
    if ! gemini_json=$(gemini_call "$img_path"); then
      log "[error] gemini failed, cancel task $task_id"
      cancel_task "$task_id" >/dev/null 2>&1 || true
      TOTAL_FAILED=$((TOTAL_FAILED + 1))
      log "[progress] fetched=$TOTAL_FETCHED success=$TOTAL_SCORED failed=$TOTAL_FAILED"
      sleep "$IDLE_SLEEP"
      continue
    fi

    log "[result] gemini normalized JSON:"
    echo "$gemini_json" | jq .

    local score
    score=$(echo "$gemini_json" | jq -r '.final_score // 0')

    if ! [[ "$score" =~ ^[0-9]+$ ]]; then
      score=0
    fi
    if (( score < 0 )); then score=0; fi
    if (( score > full_score )); then score="$full_score"; fi

    local submit_resp
    submit_resp=$(submit_marking_result "$task_id" "$paper_item_id" "$score")
    TOTAL_SCORED=$((TOTAL_SCORED + 1))

    log "[submit] resp: $submit_resp"

    # record jsonl（每份一行）
    local record
    record=$(
     