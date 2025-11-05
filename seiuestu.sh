#!/usr/bin/env bash
# seiuestu.sh - Seiue student/photo fetcher (shell edition, full features + retry)
# v2025-11-05-full+related-r1
#      seiuestu.sh <姓名|学号usin|学生id>
#    - 打印基本信息、家长
#    - 打印插件/徽章/处分
#    - 打印约谈/聊天
#    - 打印选科/方向（含最近活动）
#    - 打印成绩单汇总
#    - 下载头像并自动预览（除非 --no-preview）
#
# 依赖：curl, jq
#
set -euo pipefail

VERSION="v2025-11-05-full+related-r1"
API="https://api.seiue.com"
PASSPORT="https://passport.seiue.com"
AUTH_FILE="${HOME}/.seiue_auth.json"
DL_DIR="${HOME}/Downloads"

LOG_FILE="${SEIUE_LOG_FILE:-${HOME}/bin/seiuephoto.log}"
SUMMARY_FILE="${SEIUE_SUMMARY_FILE:-${HOME}/bin/seiuephoto_results.csv}"
STUDENT_MAP_FILE="${SEIUE_STUDENT_MAP_FILE:-${HOME}/bin/seiuephoto_students.json}"
NAME_MAP_FILE="${SEIUE_NAME_MAP_FILE:-${HOME}/bin/seiuephoto_names.json}"

mkdir -p "$(dirname "$LOG_FILE")" || true

echo "seiuephoto.sh $VERSION"

# 全局上下文（方便重试时直接改）
TOKEN=""
REFID=""
SCHOOL_ID="${SEIUE_SCHOOL_ID:-3}"
ROLE="${SEIUE_ROLE:-teacher}"
REFERER="${SEIUE_REFERER:-https://chalk-c3.seiue.com}"
SEMESTER_ID="${SEIUE_SEMESTER_ID:-61564}"
AUTO_PREVIEW=1   # 默认开预览

# ---------- 基础小工具 ----------
have() { command -v "$1" >/dev/null 2>&1; }

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "$ts $*" | tee -a "$LOG_FILE"
}

require_tools() {
  for t in curl jq; do
    if ! have "$t"; then
      echo "❌ need $t but not found. install first." >&2
      exit 2
    fi
  done
}

json_get() {
  local f="$1" j="$2"
  if [ -f "$f" ]; then
    jq -r "$j" "$f" 2>/dev/null || true
  else
    echo ""
  fi
}

ensure_json_file() {
  local f="$1"
  [ -f "$f" ] || echo "{}" >"$f"
}

append_summary_row() {
  # timestamp,file_id,signed_url,out_path,status,http_status,reflection_id
  local fid="$1" url="$2" out="$3" status="$4" code="$5" refid="$6"
  mkdir -p "$(dirname "$SUMMARY_FILE")"
  if [ ! -f "$SUMMARY_FILE" ]; then
    echo "timestamp,file_id,signed_url,out_path,status,http_status,reflection_id" >"$SUMMARY_FILE"
  fi
  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$fid" "$url" "$out" "$status" "$code" "$refid" >>"$SUMMARY_FILE"
}

# ---------- 预览 ----------
preview_file() {
  local f="$1"
  [ $AUTO_PREVIEW -eq 1 ] || return 0
  if have qlmanage; then
    qlmanage -p "$f" >/dev/null 2>&1 || true
  elif have open; then
    open "$f" >/dev/null 2>&1 || true
  fi
}

# ---------- 登录 & token ----------
decode_jwt_exp() {
  local jwt="$1"
  if have python3; then
    python3 - "$jwt" <<'PY'
import sys, json, base64
jwt = sys.argv[1]
try:
    body = jwt.split('.')[1]
    pad = '=' * ((4 - len(body) % 4) % 4)
    data = json.loads(base64.urlsafe_b64decode(body + pad).decode())
    print(data.get("exp",""))
except Exception:
    print("")
PY
  else
    echo ""
  fi
}

save_auth() {
  local token="$1" refid="$2"
  mkdir -p "$(dirname "$AUTH_FILE")"
  jq -n --arg t "$token" --arg r "$refid" '{access_token:$t,reflection_id:$r}' >"$AUTH_FILE"
}

login_and_issue_token() {
  local username="${SEIUE_USERNAME:-}"
  local password="${SEIUE_PASSWORD:-}"
  if [ -z "$username" ] || [ -z "$password" ]; then
    echo "❌ SEIUE_USERNAME/SEIUE_PASSWORD not set" >&2
    return 1
  fi

  local login_url="${PASSPORT}/login?school_id=${SCHOOL_ID}"
  local auth_url="${PASSPORT}/authorize"

  log "[login] POST $login_url"
  curl -sS -c /tmp/seiue_cookies.txt -b /tmp/seiue_cookies.txt \
    -H "Origin: ${PASSPORT}" \
    -H "Referer: ${login_url}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "email=${username}" \
    --data-urlencode "password=${password}" \
    "$login_url" >/dev/null

  log "[authorize] POST $auth_url"
  local auth_resp
  auth_resp="$(curl -sS -c /tmp/seiue_cookies.txt -b /tmp/seiue_cookies.txt \
    -H "Origin: https://chalk-c3.seiue.com" \
    -H "Referer: https://chalk-c3.seiue.com/" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "client_id=GpxvnjhVKt56qTmnPWH1sA" \
    --data-urlencode "response_type=token" \
    "$auth_url")"

  local token refid
  token="$(jq -r '.access_token // ""' <<<"$auth_resp")"
  refid="$(jq -r '.active_reflection_id // ""' <<<"$auth_resp")"
  if [ -z "$token" ] || [ -z "$refid" ]; then
    echo "❌ authorize response missing token/reflection_id" >&2
    echo "$auth_resp" >>"$LOG_FILE"
    return 1
  fi
  save_auth "$token" "$refid"
  echo "$token|$refid"
}

ensure_token() {
  local direct="${SEIUE_API_TOKEN:-}"
  if [ -n "$direct" ]; then
    TOKEN="$direct"
    REFID="${SEIUE_REFLECTION_ID:-$(json_get "$AUTH_FILE" '.reflection_id')}"
    save_auth "$TOKEN" "$REFID"
    log "[env] using SEIUE_API_TOKEN"
    return 0
  fi

  local cached_t cached_r exp now
  cached_t="$(json_get "$AUTH_FILE" '.access_token')"
  cached_r="$(json_get "$AUTH_FILE" '.reflection_id')"
  if [ -n "$cached_t" ]; then
    exp="$(decode_jwt_exp "$cached_t")"
    now="$(date +%s)"
    if [ -n "$exp" ] && [ "$exp" -gt $((now+60)) ] && [ -n "$cached_r" ]; then
      TOKEN="$cached_t"
      REFID="$cached_r"
      log "[cache] use cached token"
      return 0
    fi
  fi

  local pair
  pair="$(login_and_issue_token)" || {
    echo "❌ login failed" >&2
    exit 3
  }
  TOKEN="${pair%%|*}"
  REFID="${pair##*|}"
}

# 通用 headers
get_common_headers_args() {
  printf '%s\n' \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "X-School-Id: ${SCHOOL_ID}" \
    -H "X-Role: ${ROLE}" \
    -H "X-Reflection-Id: ${REFID}" \
    -H "Accept: application/json, text/plain, */*" \
    -H "Origin: https://chalk-c3.seiue.com" \
    -H "Referer: https://chalk-c3.seiue.com/" \
    -H "User-Agent: seiuephoto.sh/${VERSION}"
}

# ----- 通用 GET，带 401/403 重试 -----
api_get_json() {
  local url="$1"
  local resp code body
  resp="$(curl -sS -w '\n%{http_code}' $(get_common_headers_args) "$url")"
  body="${resp%$'\n'*}"
  code="${resp##*$'\n'}"
  if [ "$code" = "401" ] || [ "$code" = "403" ]; then
    log "[api] $url -> $code, retry after re-auth"
    ensure_token
    resp="$(curl -sS -w '\n%{http_code}' $(get_common_headers_args) "$url")"
    body="${resp%$'\n'*}"
    code="${resp##*$'\n'}"
  fi
  if [ "$code" != "200" ]; then
    echo ""
    return 1
  fi
  echo "$body"
  return 0
}

# ----- 通用 HEAD，带重试 -----
api_head_location() {
  local url="$1"
  local resp code
  resp="$(curl -sS -I -w '\n%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "X-School-Id: ${SCHOOL_ID}" \
    -H "X-Role: ${ROLE}" \
    -H "X-Reflection-Id: ${REFID}" \
    "$url")"
  code="${resp##*$'\n'}"
  if [ "$code" = "401" ] || [ "$code" = "403" ]; then
    ensure_token
    resp="$(curl -sS -I -w '\n%{http_code}' \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "X-School-Id: ${SCHOOL_ID}" \
      -H "X-Role: ${ROLE}" \
      -H "X-Reflection-Id: ${REFID}" \
      "$url")"
    code="${resp##*$'\n'}"
  fi
  # 输出Location到stdout，把code写到全局?
  echo "$resp" | awk '/^Location:/ {sub(/\r$/,"",$2); print $2}'
  return 0
}

# ---------- fileId 相关 ----------
is_valid_fid() {
  local s="$1"
  [[ ${#s} -eq 32 && "$s" =~ ^[0-9a-f]+$ ]]
}

download_file() {
  local url="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  curl -sS -H "Referer: ${REFERER}" -o "$out" "$url"
  log "[download] $out"
  preview_file "$out"
}

process_fid() {
  local fid="$1" want_hd="$2"
  local processor=""
  [ "$want_hd" -eq 1 ] && processor="image/resize,w_2048/quality,q_90"
  local url="${API}/chalk/netdisk/files/${fid}.jpg/url"
  [ -n "$processor" ] && url="${url}?processor=${processor}"
  local loc
  loc="$(api_head_location "$url")"
  if [ -z "$loc" ]; then
    echo "❌ no signed url for $fid" >&2
    append_summary_row "$fid" "" "" "FAILED" 0 "$REFID"
    return 1
  fi
  mkdir -p "$DL_DIR"
  local out="${DL_DIR}/${fid}.jpg"
  download_file "$loc" "$out"
  append_summary_row "$fid" "$loc" "$out" "OK" 302 "$REFID"
  echo "Saved to: $out"
}

# ---------- 本地缓存 ----------
get_student_id_from_usin_cache() {
  local usin="$1"
  ensure_json_file "$STUDENT_MAP_FILE"
  jq -r --arg u "$usin" '.[$u] // ""' "$STUDENT_MAP_FILE"
}

set_student_id_to_usin_cache() {
  local usin="$1" sid="$2"
  ensure_json_file "$STUDENT_MAP_FILE"
  jq --arg u "$usin" --arg s "$sid" '.[$u]=$s' "$STUDENT_MAP_FILE" >"${STUDENT_MAP_FILE}.tmp" && mv "${STUDENT_MAP_FILE}.tmp" "$STUDENT_MAP_FILE"
}

get_student_id_from_name_cache() {
  local name="$1"
  ensure_json_file "$NAME_MAP_FILE"
  local key
  key="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  jq -r --arg k "$key" '.[$k] // ""' "$NAME_MAP_FILE"
}

set_student_id_to_name_cache() {
  local name="$1" sid="$2"
  ensure_json_file "$NAME_MAP_FILE"
  local key
  key="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  jq --arg k "$key" --arg s "$sid" '.[$k]=$s' "$NAME_MAP_FILE" >"${NAME_MAP_FILE}.tmp" && mv "${NAME_MAP_FILE}.tmp" "$NAME_MAP_FILE"
}

# ---------- 学生相关 ----------
fetch_student_detail_by_id() {
  local sid="$1"
  api_get_json "${API}/chalk/reflection/students/${sid}/rid/${REFID}?expand=guardians,grade,user"
}

search_student_by_name() {
  local name="$1"
  local biz_types="function,school_plugin,backend_school_plugin,student,teacher,notification,todo,class,backend_class,adminclass,backend_adminclass,group,moral_assessment,message"
  local enc="$name"
  if have python3; then
    enc="$(python3 - <<'PY'
import urllib.parse,sys
print(urllib.parse.quote(sys.argv[1]))
PY
"$name")"
  fi
  api_get_json "${API}/chalk/search/items?biz_type_in=${biz_types}&keyword=${enc}&semester_id=${SEMESTER_ID}"
}

resolve_student() {
  local ident="$1"
  # number first
  if [[ "$ident" =~ ^[0-9]+$ ]]; then
    local cached
    cached="$(get_student_id_from_usin_cache "$ident")"
    if [ -n "$cached" ]; then
      fetch_student_detail_by_id "$cached" && return 0
    fi
    # try as id
    local d
    d="$(fetch_student_detail_by_id "$ident" || true)"
    if [ -n "$d" ]; then
      echo "$d"
      return 0
    fi
    # try as usin
    local lst
    lst="$(api_get_json "${API}/chalk/reflection/students?usin=${ident}&paginated=0" || true)"
    if [ -n "$lst" ]; then
      local sid
      sid="$(echo "$lst" | jq -r '.[0].id // ""')"
      if [ -n "$sid" ]; then
        fetch_student_detail_by_id "$sid"
        return 0
      fi
    fi
  fi

  # name cache
  local cached_name
  cached_name="$(get_student_id_from_name_cache "$ident")"
  if [ -n "$cached_name" ]; then
    fetch_student_detail_by_id "$cached_name" && return 0
  fi

  # remote search
  local result
  result="$(search_student_by_name "$ident" || true)"
  if [ -n "$result" ]; then
    local sid
    sid="$(echo "$result" | jq -r 'map(select(.biz_type=="student" and .biz_id)) | .[0].biz_id // ""')"
    if [ -n "$sid" ]; then
      fetch_student_detail_by_id "$sid"
      return 0
    fi
  fi

  echo ""
}

download_student_photo() {
  local photo_key="$1"
  mkdir -p "$DL_DIR"
  # url
  if [[ "$photo_key" == http* ]]; then
    local fname
    fname="$(basename "${photo_key%%\?*}")"
    [ -z "$fname" ] && fname="student.jpg"
    local out="${DL_DIR}/${fname}"
    curl -sS -H "Referer: ${REFERER}" -o "$out" "$photo_key"
    echo "📷 saved photo: $out"
    preview_file "$out"
    return 0
  fi
  local key="${photo_key%.jpg}"
  key="${key%.jpeg}"
  if [[ ${#key} -eq 32 && "$key" =~ ^[0-9a-f]+$ ]]; then
    local url="${API}/chalk/netdisk/files/${key}.jpg/url?processor=image/resize,w_2048/quality,q_90"
    local loc
    loc="$(api_head_location "$url")"
    if [ -n "$loc" ]; then
      local out="${DL_DIR}/${key}.jpg"
      download_file "$loc" "$out"
      echo "📷 saved photo: $out"
      return 0
    fi
  fi
  echo "ℹ️ student has photo/avatar but cannot download common paths."
}

fetch_related_cert_plugins() { api_get_json "${API}/sgms/certification/reflections/$1/cert-school-plugins"; }
fetch_related_cert_records() { api_get_json "${API}/sgms/certification/reflections/$1/cert-reflections?expand=certification&owner_id=$1&paginated=0&policy=profile_related&sort=-passed_at"; }
fetch_related_chats() { api_get_json "${API}/chalk/chat/students/$1/chats?expand=owner&per_page=10&sort=-start_time&type=chat"; }
fetch_direction_answers() { api_get_json "${API}/scms/direction/owners/$1/answers"; }
fetch_direction_result() { api_get_json "${API}/scms/direction/owner/$1/direction-result?expand=is_guardian_confirmed%2Cconfirmed_guardians%2Cconfirmed_guardian_ids%2Csubjects_str%2Csetting%2Cowner"; }
fetch_direction_activities() { api_get_json "${API}/scms/direction/direction-results/$1/activities?event_action=direction_result.subject_changed&per_page=3"; }
fetch_transcript() { api_get_json "${API}/vnas/klass/owners/$1/transcript"; }

print_student_info() {
  local student="$1"
  echo "================= 学生基本信息 ================="
  echo "$student" | jq -r '
    def show($k): if .[$k] != null then ($k|tostring) + ": " + (.[$k]|tostring) else empty end;
    [
      show("id"),
      show("name"),
      show("pinyin"),
      show("gender"),
      show("usin"),
      show("account"),
      (if .grade != null then "grade: " + (.grade.name // .grade.label // (.grade|tostring)) else empty end),
      show("entered_on"),
      show("graduation_time"),
      show("phone"),
      show("email")
    ] | .[]'
  if [ "$(echo "$student" | jq '.guardians | length')" -gt 0 ]; then
    echo "--- 家长 ---"
    echo "$student" | jq -r '.guardians[] | "- \(.name)  phone:\(.phone)  role:\(.guardian_role_id)"'
  fi
}

print_related_info() {
  local sid="$1"
  local cp="$2"
  local cr="$3"
  local ch="$4"
  local da="$5"
  local dr="$6"
  local dact="$7"
  local tr="$8"

  echo
  echo "================= 插件 / 徽章 / 处分 ================="
  if [ -n "$cp" ] && [ "$(echo "$cp" | jq 'length')" -gt 0 ]; then
    echo "$cp" | jq -r '.[] | "- \(.label) (plugin_id=\(.plugin_id))"'
  else
    echo "(无插件记录)"
  fi

  if [ -n "$cr" ] && [ "$(echo "$cr" | jq 'length')" -gt 0 ]; then
    echo "--- 已获得的认证/徽章 ---"
    echo "$cr" | jq -r '.[] | "· \(.certification.name)  状态:\(.status)  时间:\(.passed_at)"'
  fi

  echo
  echo "================= 约谈 / 聊天 ================="
  if [ -n "$ch" ] && [ "$(echo "$ch" | jq 'length')" -gt 0 ]; then
    echo "$ch" | jq -r '.[] | "- \(.start_time) \(.title // .metadata.chat_instance_name // "「无标题」") by \(.owner.name // "unknown")"'
  else
    echo "(无近期约谈/聊天)"
  fi

  echo
  echo "================= 选科 / 方向 ================="
  if [ -n "$dr" ] && [ "$(echo "$dr" | jq 'type=="object"')" = "true" ]; then
    echo "$dr" | jq -r '
      "方向: \((.setting.name // .setting_id // "未设置"))  科目: \((.subjects_str // (if (.subjects|length)>0 then (.subjects|map(.name)|join(",")) else "" end)) )  家长确认: \((if .is_guardian_confirmed==true then "是" else "否" end))"
    '
  else
    echo "(无方向/选科结果)"
  fi

  if [ -n "$da" ] && [ "$(echo "$da" | jq 'length')" -gt 0 ]; then
    echo "$da" | jq -r '.[0] | "填报表单: \(.form_template.name // "N/A")  完成时间: \(.completed_at // "")"'
  fi

  if [ -n "$dact" ] && [ "$(echo "$dact" | jq 'length')" -gt 0 ]; then
    echo "--- 选科最近变更 ---"
    echo "$dact" | jq -r '.[] | "  - \(.operated_at) \(.summary)"'
  fi

  echo
  echo "================= 成绩 / 学分汇总 ================="
  if [ -n "$tr" ] && [ "$(echo "$tr" | jq 'type=="object"')" = "true" ]; then
    echo "$tr" | jq -r '
      to_entries
      | map(select(.key=="avg_score" or .key=="academic_avg_score" or .key=="grade_point_avg" or .key=="total_gained_credit" or .key=="total_credit" or .key=="failed_class_num"))
      | .[]
      | "\(.key): \(.value)"
    '
  else
    echo "(无成绩单数据)"
  fi
}

usage() {
  cat <<'EOF'
Usage:
  # fileId 模式
  seiuephoto.sh <fileId32> [more_fids...] [--hd] [--no-preview] [-f file.txt]

  # 学生模式
  seiuephoto.sh <student_name_or_usin_or_id>

Options:
  --hd          download HD image (fileId mode)
  --no-preview  disable macOS quicklook/open
  -f FILE       read fileIds from FILE (one per line)
  --help        show this help
EOF
}

# ---------- main ----------
require_tools
ensure_token
if [ -n "${SEIUE_REFLECTION_ID:-}" ]; then
  REFID="$SEIUE_REFLECTION_ID"
  log "[env] override reflection_id -> $REFID"
fi

main() {
  if [ $# -eq 0 ] || [[ "$1" == "--help" ]]; then
    usage
    exit 0
  fi

  local want_hd=0
  local list_file=""
  local args=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --hd) want_hd=1 ;;
      --no-preview) AUTO_PREVIEW=0 ;;
      -f) list_file="$2"; shift ;;
      *) args+=("$1") ;;
    esac
    shift
  done

  # 判断是否有 fid
  local candidate_fids=()
  local has_fid=0

  for a in "${args[@]}"; do
    if is_valid_fid "$a"; then
      has_fid=1
      candidate_fids+=("$a")
    fi
  done

  if [ -n "$list_file" ]; then
    has_fid=1
    while IFS= read -r line; do
      line="${line//[$'\t\r\n ']/}"
      [ -z "$line" ] && continue
      if is_valid_fid "$line"; then
        candidate_fids+=("$line")
      fi
    done <"$list_file"
  fi

  if [ $has_fid -eq 1 ]; then
    mkdir -p "$DL_DIR"
    local ok=0 total=0
    for fid in "${candidate_fids[@]}"; do
      total=$((total+1))
      if process_fid "$fid" "$want_hd"; then
        ok=$((ok+1))
      fi
    done
    log "done $ok/$total, csv=$SUMMARY_FILE"
    [ $ok -eq $total ] && exit 0 || exit 1
  fi

  # 学生模式
  local ident="${args[0]}"
  log "=== student mode: $ident ==="
  local student
  student="$(resolve_student "$ident")"
  if [ -z "$student" ]; then
    echo "❌ no student found for: $ident" >&2
    exit 5
  fi

  local sid usin name
  sid="$(echo "$student" | jq -r '.id|tostring')"
  usin="$(echo "$student" | jq -r '.usin // empty')"
  name="$(echo "$student" | jq -r '.name // empty')"
  [ -n "$usin" ] && set_student_id_to_usin_cache "$usin" "$sid"
  [ -n "$name" ] && set_student_id_to_name_cache "$name" "$sid"

  print_student_info "$student"

  local cert_plugins cert_records chats d_answers d_result d_acts transcript
  cert_plugins="$(fetch_related_cert_plugins "$sid" || echo "")"
  cert_records="$(fetch_related_cert_records "$sid" || echo "")"
  chats="$(fetch_related_chats "$sid" || echo "")"
  d_answers="$(fetch_direction_answers "$sid" || echo "")"
  d_result="$(fetch_direction_result "$sid" || echo "")"
  local drid=""
  drid="$(echo "$d_result" | jq -r '.id // ""' 2>/dev/null || echo "")"
  if [ -n "$drid" ]; then
    d_acts="$(fetch_direction_activities "$drid" || echo "")"
  else
    d_acts="[]"
  fi
  transcript="$(fetch_transcript "$sid" || echo "")"

  print_related_info "$sid" "$cert_plugins" "$cert_records" "$chats" "$d_answers" "$d_result" "$d_acts" "$transcript"

  local photo_key
  photo_key="$(echo "$student" | jq -r '.photo // .avatar // empty')"
  if [ -n "$photo_key" ]; then
    download_student_photo "$photo_key"
  else
    echo "ℹ️ student has no photo/avatar field."
  fi
}

main "$@"