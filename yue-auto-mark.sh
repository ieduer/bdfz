#!/usr/bin/env bash
# yue.k12media.cn 自動閱卷 demo — shell 版
# 轉寫日期：2025-11-11
# 依賴：bash, curl, jq, base64, mkdir, date
# 建議：macOS 用 brew 裝 jq:  brew install jq
# ------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="yue-auto-mark-2025-11-11"
echo "[info] script version: $SCRIPT_VERSION"

############################################
# 1. 基本配置
############################################

BASE="https://yue.k12media.cn/testmate/json"

USERNAME=""
PASSWORD=""
SITE_ID=""    

PAPER_ID=
ITEM_GROUP_ID=

# timeout
SITE_TIMEOUT=10
GEMINI_TIMEOUT=25
GEMINI_RETRY=3

# 沒任務時等幾秒
IDLE_SLEEP=3

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

# Gemini 部分（原封不動搬過來，少一個都不行）
GEMINI_MODEL="gemini-2.5-flash"
GEMINI_API_KEYS=(
  ""
)
GEMINI_KEY_INDEX=0

# 給 Gemini 的 prompt，原樣搬
read -r -d '' GEMINI_SCORING_PROMPT <<'EOF'
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

############################################
# 2. 小工具
############################################

log() {
  # 統一輸出
  echo "[$(date '+%H:%M:%S')] $*" >&1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[fatal] '$1' not found. Please install it (brew install $1)"; exit 1;
  }
}

# URL encode (純 bash 版)
urlencode() {
  local data
  data=$(python3 - <<'PYCODE'
import sys, urllib.parse
print(urllib.parse.quote(sys.stdin.read().rstrip(), safe=''))
PYCODE
)
  printf "%s" "$data"
}

get_next_gemini_key() {
  local idx=$GEMINI_KEY_INDEX
  local key="${GEMINI_API_KEYS[$idx]}"
  # shellcheck disable=SC2004
  GEMINI_KEY_INDEX=$(( (GEMINI_KEY_INDEX + 1) % ${#GEMINI_API_KEYS[@]} ))
  printf "%s" "$key"
}

ensure_image_dir() {
  mkdir -p images
}

############################################
# 3. 登錄 & 通用請求
############################################

login() {
  local url="$BASE/Login.ashx"
  log "login → $url"
  # 用 --data-urlencode 保證中文 OK
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
    echo "[fatal] login failed: $resp"
    exit 1
  fi
  TOKEN=$(echo "$resp" | jq -r '.Token')
  log "login ok, token=$TOKEN"
}

api_post() {
  # $1: path, $2...: extra data (key=value)
  local path="$1"; shift
  local url="$BASE/$path"
  local data=("token=$TOKEN")
  while (($#)); do
    data+=("$1")
    shift
  done
  # shellcheck disable=SC2068
  local resp
  resp=$(curl -sS --connect-timeout "$SITE_TIMEOUT" --max-time "$SITE_TIMEOUT" \
    -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
    -H "Origin: https://yue.k12media.cn" \
    -H "Referer: https://yue.k12media.cn/testmate/index.html" \
    -d "${data[@]}" \
    "$url" || true)

  # 登錄失效的情況：Describe 裡有 “登录”
  local login_err
  login_err=$(echo "$resp" | jq -r 'select(.OperatorSuccess == false) | .Describe' 2>/dev/null || echo "")
  if [[ "$login_err" == *"登录"* ]]; then
    log "api_post: token invalid, re-login..."
    login
    # 再打一次
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
# 4. 拿 paper_item_id & full_score
############################################

get_marking_item_group_info() {
  local resp
  resp=$(api_post "GetMarkingItemGroupInfo.ashx")
  # 尋找 PaperID == PAPER_ID 的那組
  local paper_item_id
  local full_score

  # 用 jq 走一遍
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
    echo "[fatal] ItemGroup not found in GetMarkingItemGroupInfo.ashx"
    echo "$resp"
    exit 1
  fi

  echo "$paper_item_id|$full_score"
}

############################################
# 5. 申請任務、取圖
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
    # 沒任務
    echo "NONE|$resp"
  else
    echo "$task_id|$resp"
  fi
}

fetch_answer_image() {
  # $1: apply_json
  local apply_json="$1"
  local img_buf_id

  img_buf_id=$(echo "$apply_json" | jq -r '.ImageBufferID // .ImageBufferId // .imageBufferID // .Task.ImageBufferID // .Task.ImageBufferId // .Task.imageBufferID // empty')
  if [[ -z "$img_buf_id" || "$img_buf_id" == "null" ]]; then
    echo "[fatal] apply resp has no ImageBufferID"
    echo "$apply_json"
    return 1
  fi

  local img_url="https://yue.k12media.cn/testmate/json/GetImageFromBuffer.ashx?token=$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("$TOKEN"))
PY
)&ImageBufferID=$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("$img_buf_id"))
PY
)"
  log "download image → $img_url"
  local img_file="$2"
  curl -sS --connect-timeout "$SITE_TIMEOUT" --max-time "$SITE_TIMEOUT" \
    -H "Referer: https://yue.k12media.cn/testmate/index.html" \
    -o "$img_file" \
    "$img_url"
  echo "$img_buf_id"
}

############################################
# 6. Gemini OCR + 打分
############################################

gemini_call() {
  # $1: image_path
  local image_path="$1"
  local image_b64
  image_b64=$(base64 < "$image_path" | tr -d '\n')

  local last_err=""
  local total_keys=${#GEMINI_API_KEYS[@]}

  for ((ki=0; ki<total_keys; ki++)); do
    local key
    key=$(get_next_gemini_key)
    local url="https://generativelanguage.googleapis.com/v1beta/models/$GEMINI_MODEL:generateContent?key=$key"
    # payload
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
      log "gemini key#$((ki+1))/$total_keys attempt $attempt/$GEMINI_RETRY ..."
      local resp
      resp=$(curl -sS --connect-timeout "$GEMINI_TIMEOUT" --max-time "$GEMINI_TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$url" 2>&1) || true

      # 嘗試取 text
      local text
      text=$(echo "$resp" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null || true)
      if [[ -n "$text" ]]; then
        # 嘗試把 text 當成 json
        if echo "$text" | jq -e . >/dev/null 2>&1; then
          # 校正 final_score
          local pf pj pfare pdet
          pf=$(echo "$text" | jq -r '.point_father // 0')
          pj=$(echo "$text" | jq -r '.point_jimmy // 0')
          pfare=$(echo "$text" | jq -r '.point_farewell // 0')
          pdet=$(echo "$text" | jq -r '.point_detail_function // 0')
          local fs=$((pf + pj + pfare + pdet))
          # 合成一個帶 final_score 的 json
          echo "$text" | jq --argjson fs "$fs" '.final_score = $fs'
          return 0
        else
          # 不是 json，用 fallback
          local guessed=0
          # 粗暴抓 0~4 分
          if [[ "$text" =~ ([0-4])[[:space:]]*分 ]]; then
            guessed="${BASH_REMATCH[1]}"
          fi
          jq -n --arg sa "$text" --argjson sc "$guessed" '{
            student_answer: $sa,
            point_father: 0,
            comment_father: "未能識別為父親抓蝙蝠的細節，按規則不得分。",
            point_jimmy: 0,
            comment_jimmy: "未能識別為吉米善良/放生/尊重生命，按規則不得分。",
            point_farewell: 0,
            comment_farewell: "未能把離別情緒與這個廚房細節關聯起來，按規則不得分。",
            point_detail_function: 0,
            comment_detail_function: "未具體說到“承載回憶/給想像空間”，按規則不得分。",
            final_score: $sc,
            overall_comment: "模型輸出非標準 JSON，已按文字估分。"
          }'
          return 0
        fi
      else
        last_err="$resp"
        log "gemini error / empty resp, try next attempt/key..."
      fi
    done
  done

  echo "[fatal] gemini all keys failed: $last_err" >&2
  return 1
}

############################################
# 7. 提交 & 取消
############################################

submit_marking_result() {
  # $1: task_id, $2: paper_item_id, $3: score
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
# 8. 主流程
############################################

main() {
  require_cmd curl
  require_cmd jq
  require_cmd python3
  require_cmd base64

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
    local img_buf_id
    img_buf_id=$(fetch_answer_image "$apply_json" "$img_path")
    log "[image] saved to $img_path (ImageBufferID=$img_buf_id)"

    # Gemini
    local gemini_json
    if ! gemini_json=$(gemini_call "$img_path"); then
      log "[error] gemini failed, cancel task $task_id"
      cancel_task "$task_id" >/dev/null 2>&1 || true
      TOTAL_FAILED=$((TOTAL_FAILED + 1))
      log "[progress] fetched=$TOTAL_FETCHED success=$TOTAL_SCORED failed=$TOTAL_FAILED"
      sleep "$IDLE_SLEEP"
      continue
    fi
    log "[result] gemini parsed JSON:"
    echo "$gemini_json" | jq .

    # 拿分
    local score
    score=$(echo "$gemini_json" | jq -r '.final_score // 0')
    if (( score < 0 )); then score=0; fi
    if (( score > full_score )); then score="$full_score"; fi

    # 提交
    local submit_resp
    submit_resp=$(submit_marking_result "$task_id" "$paper_item_id" "$score")
    log "[submit] resp: $submit_resp"
    TOTAL_SCORED=$((TOTAL_SCORED + 1))

    # 任務完成報告
    log "[report] ===== 一份批完 ====="
    log "任務ID: $task_id"
    log "圖片路徑: $img_path"
    log "得分(送回網站): $score/$full_score"
    log "學生答案OCR: $(echo "$gemini_json" | jq -r '.student_answer')"
    log "父親形象($(echo "$gemini_json" | jq -r '.point_father')): $(echo "$gemini_json" | jq -r '.comment_father')"
    log "吉米形象($(echo "$gemini_json" | jq -r '.point_jimmy')): $(echo "$gemini_json" | jq -r '.comment_jimmy')"
    log "離別情緒($(echo "$gemini_json" | jq -r '.point_farewell')): $(echo "$gemini_json" | jq -r '.comment_farewell')"
    log "細節作用($(echo "$gemini_json" | jq -r '.point_detail_function')): $(echo "$gemini_json" | jq -r '.comment_detail_function')"
    log "總評: $(echo "$gemini_json" | jq -r '.overall_comment')"

    if [[ -n "$PLATFORM_TOTAL" ]]; then
      local msg="平台進度: 已閱 ${PLATFORM_DONE}/${PLATFORM_TOTAL}"
      if [[ -n "$PLATFORM_DONE" && -n "$PLATFORM_TOTAL" && "$PLATFORM_TOTAL" != "0" ]]; then
        local pct
        pct=$(python3 - <<PY
done = ${PLATFORM_DONE:-0}
tot = ${PLATFORM_TOTAL:-1}
print(round(done/tot*100, 2))
PY
)
        msg+=" (${pct}%)"
      fi
      if [[ -n "$PLATFORM_ME_COUNT" ]]; then
        msg+=", 我自己：$PLATFORM_ME_COUNT 份"
      fi
      if [[ -n "$PLATFORM_ME_AVG" ]]; then
        msg+=", 均分 $PLATFORM_ME_AVG"
      fi
      log "$msg"
    fi

    log "當前進度: 已成功 $TOTAL_SCORED 份，失敗 $TOTAL_FAILED 份，總共申請 $TOTAL_FETCHED 份"
    log "[report] ====================="

  done
}

main "$@"