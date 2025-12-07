#!/usr/bin/env bash
# quiz-submit.sh 
# 平台：macOS（Homebrew jq + curl）
# 版本：2025-12-06-01-SUBQUIZ-PUT-SIMPLE
#
# ✅ 本版目標
#  讓不該人做的事情自己解決。
# 用法：
#   ./quiz-submit.sh 2832
#   DRY_RUN=1 ./quiz-submit.sh 2832             # 只生成 payload，不提交
#   ENABLE_AI=0 ./quiz-submit.sh 2832            # 關 AI 走保守填答（judge=true/single=0）
#   FALSE_SECTIONS_CSV="6009,6013" ./quiz-submit.sh 2832   # 指定某些 sectionId 判 false

set -euo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="2025-12-06-01-SUBQUIZ-PUT-SIMPLE"
log() { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*"; }
die() { printf "[%s] ERROR: %s\n" "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
need_bin() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need_bin jq; need_bin curl
mkdir -p ./out

# -------------------------
# 基本配置
# -------------------------
BASE="https://quiz.pkuschool.edu.cn"
QUIZ_ID="${1:-${QUIZ_ID:-2831}}"

# Bearer（可用環境覆蓋 TOKEN）
TOKEN="${TOKEN:-}"
XVER="${XVER:-30400010}"

# AI 控制
ENABLE_AI="${ENABLE_AI:-1}"
FALSE_SECTIONS_CSV="${FALSE_SECTIONS_CSV:-}"

# Gemini
GEMINI_API_KEY="${GEMINI_API_KEY:-}"
GEMINI_MODEL="${GEMINI_MODEL:-gemini-2.5-flash}"
MAX_OUTPUT_TOKENS="${MAX_OUTPUT_TOKENS:-auto}"
ENABLE_WEB_SEARCH="${ENABLE_WEB_SEARCH:-0}"
RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-5}"
RETRY_BASE_DELAY="${RETRY_BASE_DELAY:-2}"

DRY_RUN="${DRY_RUN:-0}"

UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36'
CHUA='"Chromium";v="142", "Brave";v="142", "Not_A Brand";v="99"'

COOKIEJAR="./out/cookies-${QUIZ_ID}.txt"
: > "$COOKIEJAR"

# 通用頭（不含 Referer，因為後續要雙 Referer 逐一嘗試）
COMMON_H=(
  -H "Authorization: Bearer ${TOKEN}"
  -H "X-Client-Version: ${XVER}"
  -H 'X-Requested-With: XMLHttpRequest'
  -H "User-Agent: ${UA}"
  -H "Accept: application/json, text/plain, */*"
  -H "Origin: ${BASE}"
  -H 'sec-ch-ua-mobile: ?0'
  -H "sec-ch-ua: ${CHUA}"
  -H 'sec-ch-ua-platform: "macOS"'
  -H "Sec-GPC: 1"
  -H "Accept-Language: en-US,en;q=0.9"
  -H "Content-Type: application/json"
  -H "Host: quiz.pkuschool.edu.cn"
)

# -------------------------
# 輔助：模型輸出上限
# -------------------------
get_model_output_limit() {
  local meta
  meta="$(curl -sS "https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}?key=${GEMINI_API_KEY}" || true)"
  [[ -n "${meta}" ]] || return 1
  printf '%s' "$meta" | jq -r '(.outputTokenLimit // .output_token_limit // .outputTokensLimit // .output_tokens_limit // empty)'
}

to_bool() {
  local v="${1:-0}"
  if [[ "$v" == "true" || "$v" == "false" ]]; then printf "%s" "$v"; return; fi
  [[ "$v" =~ ^[0-9]+$ && "$v" -gt 0 ]] && printf "true" || printf "false"
}

# -------------------------
# 1) 預取 + 讀卷（同時接 Cookie）
# -------------------------
log "GET 试卷结构: ${QUIZ_ID}"
resp_json="$(curl -sS "${BASE}/api/quiz/${QUIZ_ID}" "${COMMON_H[@]}" -c "$COOKIEJAR" -b "$COOKIEJAR")"
echo "$resp_json" > "./out/get-${QUIZ_ID}.json"
code="$(jq -r '.code' "./out/get-${QUIZ_ID}.json" 2>/dev/null || echo "")"
[[ "$code" == "200" ]] || { jq . "./out/get-${QUIZ_ID}.json" || true; die "GET /api/quiz/${QUIZ_ID} 非 200（code=${code:-nil}）"; }
jq -e '.data.sections|type=="array"' "./out/get-${QUIZ_ID}.json" >/dev/null || die ".data.sections 不是陣列"

# 抓 Cookie 內可能的 CSRF 名稱
extract_csrf() {
  awk 'BEGIN{FS="\t"} $0!~/^#/ && ($6=="XSRF-TOKEN"||$6=="csrfToken"||$6=="_csrf"||$6=="csrf"){print $7; found=1} END{if(!found)exit 1}' "$COOKIEJAR" 2>/dev/null || true
}
CSRF_VAL="$(extract_csrf || true)"
EXTRA_CSRF=()
if [[ -n "${CSRF_VAL:-}" ]]; then
  EXTRA_CSRF=(-H "X-XSRF-TOKEN: ${CSRF_VAL}" -H "x-xsrf-token: ${CSRF_VAL}")
  log "偵測到 CSRF Cookie，將附帶 X-XSRF-TOKEN / x-xsrf-token"
fi

# -------------------------
# 2) 準備題目給 AI（僅提取最少上下文）
# -------------------------
questions_json_path="./out/questions-${QUIZ_ID}.json"
jq '
  .data as $d
  | {
      quizId: $d.id,
      sectionCount: ($d.sections | length),
      questions: (
        $d.sections
        | to_entries
        | map({
            sectionId: .value.id,
            sectionIndex: .key,
            questions:
              ( .value.questions
                | to_entries
                | map({
                    questionId: (.value.id // .value.qid // .value.questionId // .key),
                    questionIndex: .key,
                    type: .value.type,
                    description:
                      ( if (.value.description|type=="object" and .value.description.type=="markdown")
                        then (.value.description.content // "")
                        else (.value.description // "")
                        end ),
                    options:
                      ( if .value.type=="single" then
                          ( (.value.options // [])
                            | map( if (type=="object" and .type=="markdown")
                                   then (.content // "")
                                   else tostring end ) )
                        else null end )
                  })
              )
          })
      )
    }
' "./out/get-${QUIZ_ID}.json" > "$questions_json_path"
total_q="$(jq '[.questions[].questions[]] | length' "$questions_json_path")"
judge_q="$(jq '[.questions[].questions[] | select(.type=="judge")] | length' "$questions_json_path")"
single_q="$(jq '[.questions[].questions[] | select(.type=="single")] | length' "$questions_json_path")"
log "統計：total=${total_q}, judge=${judge_q}, single=${single_q}"

# -------------------------
# 3) AI 生成答案（Gemini 或保守填答）
# -------------------------
ai_answers_path="./out/ai-answers-${QUIZ_ID}.json"

if [[ "${ENABLE_AI}" == "1" ]]; then
  if [[ "${MAX_OUTPUT_TOKENS}" == "auto" ]]; then
    if model_limit="$(get_model_output_limit 2>/dev/null)"; then
      MAX_OUTPUT_TOKENS="$(
        jq -n --argjson a "${model_limit:-0}" --argjson b 16384 '$a|if .==0 then $b else (if .>$b then $b else . end) end'
      )"
    else
      MAX_OUTPUT_TOKENS="8192"
    fi
  fi
  log "呼叫 Gemini (${GEMINI_MODEL}, maxOutputTokens=${MAX_OUTPUT_TOKENS}, web_search=${ENABLE_WEB_SEARCH})"

  ai_prompt=$(
    cat <<'P'
You will receive a quiz in Chinese with two question types:
- "judge": True/False.
- "single": Single choice with options.

Return JSON ONLY as:
{ "answers": [ { "sectionId": <number>, "questionIndex": <number>, "questionId": <number|string|nullable>, "type": "judge"|"single", "answer": true|false|number /* 0-based index for single */ } ] }

Rules:
- Fill EVERY question.
- For "single", return a 0-based option index and ensure it is within range.
- No explanations, no extra keys.
- If questionId is unknown, set it to null.
P
  )

  build_ai_request() {
    if [[ "${ENABLE_WEB_SEARCH}" == "1" ]]; then
      jq -n --arg prompt "$ai_prompt" --slurpfile q "$questions_json_path" --argjson maxOut "$MAX_OUTPUT_TOKENS" '
        {
          contents: [{role:"user",parts:[{text:$prompt},{text:("Questions JSON:\n"+($q[0]|tojson))}]}],
          generationConfig: {temperature:0, maxOutputTokens:$maxOut},
          tools: [ {google_search:{}} ]
        }'
    else
      jq -n --arg prompt "$ai_prompt" --slurpfile q "$questions_json_path" --argjson maxOut "$MAX_OUTPUT_TOKENS" '
        {
          contents: [{role:"user",parts:[{text:$prompt},{text:("Questions JSON:\n"+($q[0]|tojson))}]}],
          generationConfig: {
            temperature: 0,
            maxOutputTokens: $maxOut,
            responseMimeType: "application/json",
            responseSchema: {
              type:"object",
              properties:{
                answers:{
                  type:"array",
                  items:{
                    type:"object",
                    properties:{
                      sectionId:{},
                      questionIndex:{},
                      questionId:{},
                      type:{type:"string",enum:["judge","single"]},
                      answer:{oneOf:[{type:"boolean"},{type:"number"}]}
                    },
                    required:["sectionId","questionIndex","type","answer"]
                  }
                }
              },
              required:["answers"]
            }
          }
        }'
    fi
  }
  request_json_path="./out/gemini-request-${QUIZ_ID}.json"
  build_ai_request > "$request_json_path"

  call_gemini() {
    curl -sS -X POST \
      "https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${GEMINI_API_KEY}" \
      -H "Content-Type: application/json" \
      --data-binary @"${request_json_path}"
  }

  attempt=1; ai_resp=""
  while :; do
    ai_resp="$(call_gemini || true)"
    echo "$ai_resp" > "./out/gemini-raw-${QUIZ_ID}.json"
    err_code="$(printf '%s' "$ai_resp" | jq -r 'try .error.code // empty')"
    err_status="$(printf '%s' "$ai_resp" | jq -r 'try .error.status // empty')"
    finish_reason="$(printf '%s' "$ai_resp" | jq -r 'try .candidates[0].finishReason // empty')"

    if [[ -n "$err_code" && "$err_code" != "null" ]]; then
      if [[ "$err_code" == "429" || "$err_code" == "503" ]]; then
        (( attempt >= RETRY_ATTEMPTS )) && break
        sleep_time=$(( RETRY_BASE_DELAY * attempt ))
        log "Gemini error $err_code/$err_status, backoff ${sleep_time}s ..."
        sleep "$sleep_time"; attempt=$((attempt+1)); continue
      else
        break
      fi
    fi

    if [[ "$finish_reason" == "MAX_TOKENS" ]]; then
      if [[ "$MAX_OUTPUT_TOKENS" =~ ^[0-9]+$ ]]; then
        new_max=$(( MAX_OUTPUT_TOKENS * 2 ))
        if model_limit="$(get_model_output_limit 2>/dev/null)"; then
          (( new_max > model_limit )) && new_max="$model_limit"
        fi
        (( new_max > 16384 )) && new_max=16384
        MAX_OUTPUT_TOKENS="$new_max"
      else
        MAX_OUTPUT_TOKENS="8192"
      fi
      build_ai_request > "$request_json_path"
      (( attempt >= RETRY_ATTEMPTS )) && break
      attempt=$((attempt+1)); continue
    fi
    break
  done

  ai_text="$(printf '%s' "$ai_resp" | jq -r 'try .candidates[0].content.parts[0].text // empty')"
  [[ -n "$ai_text" && "$ai_text" != "null" ]] || { printf '%s\n' "$ai_resp" | jq . >&2; die "Gemini 無候選輸出"; }

  ai_text_clean="$(printf '%s' "$ai_text" | sed -E '1s/^```(json)?[[:space:]]*//; $s/[[:space:]]*```$//')"
  echo "$ai_text_clean" | jq . >/dev/null 2>&1 || { echo "$ai_text_clean" >&2; die "Gemini 輸出不是合法 JSON"; }

  printf '%s' "$ai_text_clean" | jq '.answers' > "$ai_answers_path"
  answered_count="$(jq 'length' "$ai_answers_path")"
  log "AI 回答題數：${answered_count} / ${total_q}"
else
  log "ENABLE_AI=0：使用保守填答（judge=true, single=0；對 FALSE_SECTIONS_CSV 置 false）"
  jq --arg csv "$FALSE_SECTIONS_CSV" '
    [ ($csv|split(",")|map(select(length>0))|map(tonumber)) ] as $falseS
    | {
        answers: (
          .questions
          | map(. as $sec |
              $sec.questions
              | map({
                sectionId: $sec.sectionId,
                questionIndex: .questionIndex,
                questionId: (.questionId // null),
                type: .type,
                answer:
                  ( if .type=="single" then 0
                    else ( if ($falseS[0]|index($sec.sectionId)) then false else true end )
                    end )
              })
            )
          | add
        )
      }
  ' "$questions_json_path" > "./out/ai-answers-fallback-${QUIZ_ID}.json"
  cp "./out/ai-answers-fallback-${QUIZ_ID}.json" "$ai_answers_path"
fi

# -------------------------
# 4) 覆蓋寫回 userAnswer（保留原 data；補齊 time/duration/finished=false）
# -------------------------
payload_path="./out/payload-${QUIZ_ID}.json"
now_ts="$(date +%s)"
jq --slurpfile A "$ai_answers_path" --argjson now "$now_ts" '
  .data as $d
  | $d
  | .time = ( .time // $now )
  | .duration = ( .duration // 0 )
  | .sections |= (
      to_entries
      | map(
          . as $se
          | .value
          | .questions |= (
              to_entries
              | map(
                  . as $qe
                  | (
                      [ $A[0][]
                        | select(
                            (.sectionId == $se.value.id) and (.questionIndex == $qe.key)
                            or ((.questionId != null) and (.questionId == ($qe.value.id // $qe.value.qid // $qe.value.questionId)))
                          )
                      ] | .[0]
                    ) as $ans
                  | .value
                  | .userAnswer = (
                      if .type == "judge" then
                        if ($ans != null and ($ans.answer|type)=="boolean")
                          then $ans.answer
                          elif ($ans != null and ($ans.answer|type)=="number")
                          then ( ($ans.answer|floor) != 0 )
                          else (.userAnswer // false)
                        end
                      elif .type == "single" then
                        if ($ans != null and ($ans.answer|type)=="number")
                          then ($ans.answer|floor)
                          elif ($ans != null and ($ans.answer|type)=="boolean")
                          then (if $ans.answer then 1 else 0 end)
                          else (.userAnswer // 0)
                        end
                      else .userAnswer
                      end
                    )
                )
              | map(.)
            )
        )
    )
  | .finished = false
' "./out/get-${QUIZ_ID}.json" > "$payload_path"
jq '.sections | map({id, qCount:(.questions|length)})' "$payload_path" > "./out/payload-sections-${QUIZ_ID}.json" || true
log "已生成載荷：$payload_path"

[[ "$DRY_RUN" == "1" ]] && { log "DRY_RUN=1：不提交。"; exit 0; }

# -------------------------
# 5) 兩步提交（PUT /api/quiz/{id}/save?finish=...，雙 Referer）
# -------------------------
REFERERS=(
  "${BASE}/analysis/${QUIZ_ID}"
  "${BASE}/quiz?id=${QUIZ_ID}"
)

send_one() {
  local url="$1" referer="$2" tag="$3"
  local hdr="./out/last-hdr-${tag}-${QUIZ_ID}.txt"
  local out="./out/last-resp-${tag}-${QUIZ_ID}.json"
  local http_code
  http_code="$(curl -sS -X PUT "$url" \
              "${COMMON_H[@]}" "${EXTRA_CSRF[@]}" \
              -H "Referer: ${referer}" \
              --data-binary @"${payload_path}" \
              -D "$hdr" -o "$out" -w "%{http_code}" \
              -c "$COOKIEJAR" -b "$COOKIEJAR" || true)"
  local api_code; api_code="$(jq -r 'try .code // empty' "$out" 2>/dev/null || true)"
  local api_msg;  api_msg="$(jq -r 'try .message // .msg // .error // empty' "$out" 2>/dev/null || true)"
  echo "$http_code" > "./out/last-http-${tag}-${QUIZ_ID}.txt"
  cp "$payload_path" "./out/last-body-${tag}-${QUIZ_ID}.json"
  if [[ "$api_code" == "200" ]]; then
    log "✔ 成功：${tag} (HTTP ${http_code}, api.code=${api_code})"
    return 0
  fi
  log "✘ 失敗：${tag} (HTTP ${http_code}, api.code=${api_code:-nil}, message=${api_msg:-nil}, referer=${referer})"
  return 1
}

try_submit_finish() {
  local finish_lit; finish_lit="$(to_bool "$1")"
  local url="${BASE}/api/quiz/${QUIZ_ID}/save?finish=${finish_lit}"

  for ref in "${REFERERS[@]}"; do
    local tag="f${finish_lit}-PUT-r$(( ${#ref} % 97 ))"
    if send_one "$url" "$ref" "$tag"; then
      return 0
    fi
  done
  return 1
}

log "提交 save(false)（PUT, finish=false） ..."
if ! try_submit_finish false; then
  die "save(false) 所有變體均返回非 200（請對比 ./out/last-* 與前端成功包）"
fi

log "提交 save(true)（PUT, finish=true） ..."
if ! try_submit_finish true; then
  die "save(true) 所有變體均返回非 200（請對比 ./out/last-* 與前端成功包）"
fi

# -------------------------
# 6) 校驗
# -------------------------
log "校驗結果（GET /api/quiz/${QUIZ_ID}）"
curl -sS "${BASE}/api/quiz/${QUIZ_ID}" "${COMMON_H[@]}" -b "$COOKIEJAR" \
| jq '{code,data: {id: .data.id, finished: .data.finished, duration: .data.duration, correct: .data.correct}}'

log "完成。script=${SCRIPT_VERSION}  trace: ./out/last-*.{txt,json} / ./out/payload-${QUIZ_ID}.json / $COOKIEJAR"