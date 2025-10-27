#!/usr/bin/env bash
# taiwanebook.sh — Taiwan eBooks downloader (safe & fast)
# Input: BOOK_ID | book page URL (with/without /reader, any locale) | viewer URL
# Strategy: reader-first extraction → validated probe → download
# Safety: layered fallbacks (HTTP opts → http1.1 → http2 → relaxed guards)
# Speed: parallel downloads (--jobs), optional aria2 engine
# UX: resume, progress bar, English success message with absolute path

set -euo pipefail

# --------------------------- config ---------------------------------
BASE="https://taiwanebook.ncl.edu.tw"
UA_HEADER="User-Agent: curl-taiwan-ebooks-shell/2.1"

LOG_FILE="${LOG_FILE:-./taiwanebook_error.log}"
OUTDIR="."
SLEEP_BETWEEN="${SLEEP_BETWEEN:-0}"
MAX_PARTS="${MAX_PARTS:-40}"
QUIET=0

# Speed & safety knobs
JOBS="${JOBS:-1}"                       # parallel downloads when multiple files resolved
CURL_HTTP_OPTS="${CURL_HTTP_OPTS:-}"    # e.g., --http1.1 or --http2
ENGINE="${ENGINE:-auto}"                # auto|curl|aria2
FORCE_SAFE="${FORCE_SAFE:-1}"           # 1=enable layered fallbacks

# Modes for multi-part:
# auto (default): if F01 exists, download all contiguous parts; else single
# single        : force single file only (no Fxx)
# all           : download all parts found up to MAX_PARTS
MULTIPART_MODE="${MULTIPART_MODE:-auto}"

# --------------------------- utils ----------------------------------
timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

log_err() { printf "[%s] %s\n" "$(timestamp)" "$1" >>"$LOG_FILE"; }

trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

abspath() {
  local p="${1:?}"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$p" <<'PY'
import os,sys; print(os.path.realpath(sys.argv[1]))
PY
  elif command -v perl >/dev/null 2>&1; then
    perl -MCwd=realpath -e 'print realpath($ARGV[0])' "$p"
  else
    (cd "$(dirname "$p")" && printf "%s/%s\n" "$PWD" "$(basename "$p")")
  fi
}

human_size() {
  awk 'function human(x){ s="B KB MB GB TB PB"; split(s,a); for(i=1;x>=1024 && i<6;i++) x/=1024; return sprintf("%.2f %s", x, a[i]); } {print human($1)}'
}

url_decode() {
  local s="${1:-}"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$s" <<'PY' 2>/dev/null
import sys, urllib.parse
print(urllib.parse.unquote(sys.argv[1]))
PY
  elif command -v perl >/dev/null 2>&1; then
    perl -MURI::Escape -e 'print uri_unescape($ARGV[0])' "$s"
  else
    s="${s//+/ }"; printf '%b' "${s//%/\\x}"
  fi
}

url_encode() {
  local s="${1:-}"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$s" <<'PY' 2>/dev/null
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
  elif command -v perl >/dev/null 2>&1; then
    perl -MURI::Escape -e 'print uri_escape($ARGV[0])' "$s"
  else
    # RFC3986-ish: encode everything not in unreserved set
    local i c; LC_ALL=C
    for (( i=0; i<${#s}; i++ )); do
      c="${s:i:1}"
      case "$c" in [a-zA-Z0-9.~_-]) printf '%s' "$c";; *) printf '%%%02X' "'$c";; esac
    done
  fi
}

viewer_url_for_path() {
  local file_path="$1"
  local enc; enc="$(url_encode "$file_path")"
  printf "%s/pdfjs/web/viewer.html?file=%s" "$BASE" "$enc"
}

sanitize_name() { sed -E 's#[/[:cntrl:]]#_#g' | tr -c '[:alnum:]._-+' '_'; }

stat_size() {
  local f="$1"
  if [[ -f "$f" ]]; then
    stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# --------------------------- probe ----------------------------------
probe_url_and_size() {
  local url="$1"
  local ref="${2:-${BASE}/}"
  # Check HTTP code first (byte-range probe)
  local code
  code="$(curl $CURL_HTTP_OPTS -sSIL -H "Referer: ${ref}" -H "$UA_HEADER" --range 0-0 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
  if [[ "$code" != "200" && "$code" != "206" ]]; then
    return 1
  fi
  # Fetch headers to parse size info
  local headers
  headers="$(curl $CURL_HTTP_OPTS -fsSLI -H "Referer: ${ref}" -H "$UA_HEADER" --range 0-0 "$url" 2>/dev/null || true)"
  if [[ -n "$headers" ]]; then
    local total
    total="$(printf "%s\n" "$headers" | awk -F'/' '/[Cc]ontent-[Rr]ange:/ {gsub("\r",""); print $2}' | tr -d '\r' | trim || true)"
    if [[ -n "$total" ]]; then printf "%s" "$total"; return 0; fi
    total="$(printf "%s\n" "$headers" | awk -F': ' 'tolower($1)=="content-length" {gsub("\r","",$2); print $2}' | trim || true)"
    if [[ -n "$total" ]]; then printf "%s" "$total"; return 0; fi
    printf ""; return 0
  fi
  return 1
}

extract_file_param() {
  local s="$1"
  local enc
  enc="$(printf '%s\n' "$s" | sed -n 's/.*[?&]file=\([^&#]*\).*/\1/p' | head -n1 || true)"
  if [[ -n "${enc:-}" ]]; then url_decode "$enc" | trim; return 0; fi
  enc="$(printf '%s\n' "$s" | grep -oE 'viewer\.html\?file=[^"&]+' | head -n1 | sed 's/.*file=//' || true)"
  if [[ -n "${enc:-}" ]]; then url_decode "$enc" | trim; return 0; fi
  return 1
}

# --- HTML path extractor using Python (robust) ---
extract_paths_from_html_python() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - <<'PY'
import sys, re, urllib.parse
html = sys.stdin.read()
urls = []
urls += re.findall(r'''(?:href|src)\s*=\s*['"]([^'"]*viewer\.html\?[^'"]*)['"]''', html, flags=re.IGNORECASE)
urls += re.findall(r'(viewer\.html\?[^"\'<>\s]+)', html, flags=re.IGNORECASE)
seen=set()
for u in urls:
    try:
        parts = urllib.parse.urlsplit(u)
        qs = urllib.parse.parse_qs(parts.query)
        vals = qs.get('file', [])
        if not vals:
            m = re.search(r'file=([^&#]+)', u)
            if m: vals = [m.group(1)]
        for v in vals:
            path = urllib.parse.unquote(v)
            if path.startswith('/ebkFiles/') and path not in seen:
                seen.add(path); print(path)
    except Exception:
        continue
PY
}

extract_all_file_paths_from_reader() {
  local page="$1"
  local html
  html="$(curl -fsSL -H "$UA_HEADER" "$page" 2>/dev/null || true)"
  [[ -z "$html" ]] && return 1

  local out_py
  out_py="$(printf '%s' "$html" | extract_paths_from_html_python 2>/dev/null || true)"
  if [[ -n "$out_py" ]]; then
    printf '%s\n' "$out_py" | awk '/^\/ebkFiles\//{ if(!seen[$0]++){ print $0 } }'
    return 0
  fi

  printf '%s\n' "$html" \
  | grep -oE 'viewer\.html\?file=[^"&]+' \
  | sed 's/.*file=//' \
  | while IFS= read -r enc; do url_decode "$enc" | trim; done \
  | awk '/^\/ebkFiles\//{ if(!seen[$0]++){ print $0 } }'
}

guess_pdf_paths_by_id() {
  local id="$1"
  echo "/ebkFiles/${id}/${id}.PDF"
  echo "/ebkFiles/${id}/${id}.pdf"
  local i
  for i in $(seq -w 1 "$MAX_PARTS"); do
    echo "/ebkFiles/${id}/${id}F${i}.PDF"
    echo "/ebkFiles/${id}/${id}f${i}.pdf"
  done
}

resolve_token() {
  local token="$1"
  local file_path="" id="" size="" url=""

  # 1) Direct viewer URL
  if [[ "$token" == *"/pdfjs/web/viewer.html"* ]]; then
    file_path="$(extract_file_param "$token" || true)"
  fi

  # 2) Book page URL
  if [[ -z "${file_path:-}" && "$token" == *"/book/"* ]]; then
    file_path="$(extract_file_param "$(curl -fsSL -H "$UA_HEADER" "$token" 2>/dev/null || true)" || true)"
    if [[ -z "${file_path:-}" ]]; then
      local id_from; id_from="$(printf '%s' "$token" | sed -n 's#.*/book/\([^/?#]*\).*#\1#p' | trim || true)"
      if [[ -n "$id_from" ]]; then
        file_path="$(extract_file_param "$(curl -fsSL -H "$UA_HEADER" "${BASE}/en/book/${id_from}/reader" 2>/dev/null || true)" || true)"
        [[ -z "${file_path:-}" ]] && file_path="$(extract_file_param "$(curl -fsSL -H "$UA_HEADER" "${BASE}/zh-tw/book/${id_from}/reader" 2>/dev/null || true)" || true)"
        id="$id_from"
      fi
    fi
    if [[ -z "${file_path:-}" && -n "${id:-$id_from}" ]]; then
      local list
      list="$(extract_all_file_paths_from_reader "${BASE}/en/book/${id}/reader" || true)"
      [[ -z "$list" ]] && list="$(extract_all_file_paths_from_reader "${BASE}/zh-tw/book/${id}/reader" || true)"
      if [[ -n "$list" ]]; then
        while IFS= read -r p; do
          url="${BASE%/}${p}"; local ref_each; ref_each="$(viewer_url_for_path "$p")"
          size="$(probe_url_and_size "$url" "$ref_each" || true)"
          printf "%s\t%s\t%s\n" "$url" "${size:-}" "$ref_each"
        done <<<"$list"
        return 0
      fi
    fi
  fi

  # 3) Pure ID
  if [[ -z "${file_path:-}" && -z "${id:-}" && "$token" =~ ^[A-Z0-9-]+$ ]]; then
    id="$token"
  fi

  # 4) If we have file_path
  if [[ -n "${file_path:-}" ]]; then
    url="${BASE%/}${file_path}"
    local ref; ref="$(viewer_url_for_path "$file_path")"
    size="$(probe_url_and_size "$url" "$ref" || true)"
    if [[ $? -eq 0 ]]; then printf "%s\t%s\t%s\n" "$url" "${size:-}" "$ref"; return 0; else log_err "Probe failed: $url"; fi
  fi

  # 5) ID strategy
  if [[ -n "${id:-}" ]]; then
    # Reader-first by ID
    local list_by_id
    list_by_id="$(extract_all_file_paths_from_reader "${BASE}/en/book/${id}/reader" | sed '/^$/d' || true)"
    [[ -z "$list_by_id" ]] && list_by_id="$(extract_all_file_paths_from_reader "${BASE}/zh-tw/book/${id}/reader" | sed '/^$/d' || true)"
    if [[ -n "$list_by_id" ]]; then
      while IFS= read -r p; do
        url="${BASE%/}${p}"; local ref_each; ref_each="$(viewer_url_for_path "$p")"
        size="$(probe_url_and_size "$url" "$ref_each" || true)"
        printf "%s\t%s\t%s\n" "$url" "${size:-}" "$ref_each"
      done <<<"$list_by_id"
      return 0
    fi

    local first_single="/ebkFiles/${id}/${id}.PDF"
    local s
    case "$MULTIPART_MODE" in
      single)
        url="${BASE%/}${first_single}"
        local ref_single; ref_single="$(viewer_url_for_path "$first_single")"
        s="$(probe_url_and_size "$url" "$ref_single" || true)"
        if [[ $? -eq 0 ]]; then printf "%s\t%s\t%s\n" "$url" "$s" "$ref_single"; return 0; fi
        ;;
      all|auto)
        local parts=() i part_path part_url part_ref part_size
        for i in $(seq -w 1 "$MAX_PARTS"); do
          part_path="/ebkFiles/${id}/${id}F${i}.PDF"
          part_url="${BASE%/}${part_path}"
          part_ref="$(viewer_url_for_path "$part_path")"
          part_size="$(probe_url_and_size "$part_url" "$part_ref" || true)"
          if [[ $? -eq 0 ]]; then parts+=("$part_url"$'\t'"$part_size"$'\t'"$part_ref"); else [[ ${#parts[@]} -gt 0 ]] && break; fi
        done
        if [[ ${#parts[@]} -eq 0 ]]; then
          # try lowercase part names
          for i in $(seq -w 1 "$MAX_PARTS"); do
            part_path="/ebkFiles/${id}/${id}f${i}.pdf"
            part_url="${BASE%/}${part_path}"
            part_ref="$(viewer_url_for_path "$part_path")"
            part_size="$(probe_url_and_size "$part_url" "$part_ref" || true)"
            if [[ $? -eq 0 ]]; then parts+=("$part_url"$'\t'"$part_size"$'\t'"$part_ref"); else [[ ${#parts[@]} -gt 0 ]] && break; fi
          done
        fi
        if [[ "$MULTIPART_MODE" == "all" && ${#parts[@]} -gt 0 ]]; then printf "%s\n" "${parts[@]}"; return 0; fi
        if [[ "$MULTIPART_MODE" == "auto" ]]; then
          if [[ ${#parts[@]} -gt 0 ]]; then printf "%s\n" "${parts[@]}"; return 0; fi
          url="${BASE%/}${first_single}"; local ref_auto; ref_auto="$(viewer_url_for_path "$first_single")"
          s="$(probe_url_and_size "$url" "$ref_auto" || true)"
          if [[ $? -eq 0 ]]; then printf "%s\t%s\t%s\n" "$url" "$s" "$ref_auto"; return 0; fi
        fi
        ;;
    esac
  fi

  return 1
}

usage() {
  cat <<'EOF'
Usage:
  taiwanebook.sh [options] <BOOK_ID|URL> [more...]
  cat list.txt | taiwanebook.sh [options] -

Preferred input is the BOOK ID (e.g., NCL-9900010967). You may also pass:
  • Book page URL (any locale, with/without /reader)
  • PDF.js viewer URL (contains ?file=/ebkFiles/...)

Options:
  --outdir DIR         Save files under DIR (default: .)
  --sleep N            Sleep N seconds between downloads (default: 0)
  --mode auto|single|all
                       Multi-part strategy (default: auto)
  --jobs N             Download up to N files in parallel when multiple files are resolved (default: 1)
  --http1.1|--http2    Force HTTP version for curl (work around server quirks / speed)
  --engine curl|aria2  Choose download engine (default: auto; auto uses aria2 if available for large files)
  --safe|--no-safe     Enable/disable layered fallbacks (default: --safe)
  --quiet              Less chatter
  -h, --help           Show help

Examples:
  twb NCL-9900010967
  twb --jobs 3 NCL-9900010967
  twb --http1.1 NCL-9900010967
  twb --engine aria2 NCL-9900010967

Env:
  LOG_FILE=./taiwanebook_error.log
  MAX_PARTS=40  MULTIPART_MODE=auto  SLEEP_BETWEEN=0
  JOBS=1  CURL_HTTP_OPTS=""  ENGINE=auto  FORCE_SAFE=1
EOF
}

# ------------------------ arg parsing --------------------------------
INPUTS=()
while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --outdir) OUTDIR="${2:?}"; shift 2 ;;
    --sleep) SLEEP_BETWEEN="${2:?}"; shift 2 ;;
    --mode) MULTIPART_MODE="${2:?}"; shift 2 ;;
    --jobs) JOBS="${2:?}"; shift 2 ;;
    --http1.1) CURL_HTTP_OPTS="--http1.1"; shift ;;
    --http2) CURL_HTTP_OPTS="--http2"; shift ;;
    --engine) ENGINE="${2:?}"; shift 2 ;;
    --safe) FORCE_SAFE=1; shift ;;
    --no-safe) FORCE_SAFE=0; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -) while IFS= read -r line; do [[ -n "$line" ]] && INPUTS+=("$line"); done; shift ;;
    *) INPUTS+=("$1"); shift ;;
  esac
done

if [[ ${#INPUTS[@]} -eq 0 ]]; then usage; exit 1; fi
mkdir -p "$OUTDIR"

# -------------------------- alias install ----------------------------
ensure_alias() {
  local marker="# >>> taiwanebook.sh alias (managed)"
  local self_abs; self_abs="$(abspath "$0")"
  local rc_file=""
  if [[ "$SHELL" == *"/zsh" ]] && [[ -f "$HOME/.zshrc" ]]; then
    rc_file="$HOME/.zshrc"
  elif [[ "$SHELL" == *"/bash" ]] && [[ -f "$HOME/.bashrc" ]]; then
    rc_file="$HOME/.bashrc"
  elif [[ -f "$HOME/.zshrc" ]]; then
    rc_file="$HOME/.zshrc"
  elif [[ -f "$HOME/.bashrc" ]]; then
    rc_file="$HOME/.bashrc"
  else
    rc_file="$HOME/.zshrc"
  fi
  if ! grep -qs "alias twb=" "$rc_file"; then
    {
      echo "$marker"
      echo "alias twb='${self_abs}'"
      echo "# <<< taiwanebook.sh alias"
    } >>"$rc_file" || true
    if [[ $QUIET -eq 0 ]]; then
      echo "Installed alias: twb  (added to $rc_file). Reload with: source '$rc_file'"
      echo "Quick start:"
      echo "  • Single book:    twb NCL-9900010967"
      echo "  • Faster multi:   twb --jobs 3 NCL-9900010967"
      echo "  • Force HTTP/1.1: twb --http1.1 NCL-9900010967"
      echo "  • Help:           twb --help"
    fi
  fi
}
ensure_alias || true

# --------------------- aria2 engine (optional) -----------------------
aria2_download_one_url() {
  local url="$1" size_bytes="${2:-}" ref="${3:-${BASE}/}" out="$4" fname="$5"
  command -v aria2c >/dev/null 2>&1 || return 1
  local start="$(date +%s)"
  aria2c -c -x 8 -s 8 -k 1M \
    --header="Referer: ${ref}" \
    --header="$UA_HEADER" \
    --out "$fname" --dir "${OUTDIR%/}" \
    "$url"
  local rc=$?
  if [[ $rc -ne 0 ]]; then return $rc; fi
  local now="$(date +%s)"
  local elapsed=$(( now - start )); [[ $elapsed -le 0 ]] && elapsed=1
  local sz="$(stat_size "$out")"
  local after_human="$(printf "%s\n" "$sz" | human_size)"
  local spd_human
  spd_human="$(awk -v b="$sz" -v t="$elapsed" 'BEGIN{ s=b/t; u="B/s KB/s MB/s GB/s"; split(u,a); i=1; while(s>=1024 && i<4){s/=1024;i++} printf("%.2f %s", s, a[i]) }')"
  local out_abs; out_abs="$(abspath "$out")"
  if [[ $QUIET -eq 0 ]]; then
    echo "  ✓ Download completed successfully (aria2): $fname"
    echo "    Path: $out_abs | Size: ${after_human} | Avg speed: ${spd_human} | Time: ${elapsed}s"
  fi
  return 0
}

# ------------------------ download routine ---------------------------
download_one_url() {
  local url_raw="$1"
  local url; url="$(printf '%s' "$url_raw" | sed -e 's/[[:space:]]*$//')"
  local size_bytes="${2:-}"  # may be empty
  local ref="${3:-${BASE}/}"
  local fname out existing before_human after_human

  fname="$(basename "$url" | trim | sanitize_name)"
  while [[ "$fname" == *_ ]]; do fname="${fname%_}"; done
  out="${OUTDIR%/}/$fname"

  if [[ -n "$size_bytes" && "$size_bytes" != "0" ]]; then
    before_human="$(printf "%s\n" "$size_bytes" | human_size)"
    [[ $QUIET -eq 0 ]] && echo "• Target: $fname  | Size: ${before_human}  | URL: $url"
  else
    [[ $QUIET -eq 0 ]] && echo "• Target: $fname  | URL: $url"
  fi

  existing="$(stat_size "$out")"
  if [[ "$existing" -gt 0 ]]; then
    [[ $QUIET -eq 0 ]] && echo "  Resuming from: $(printf "%s\n" "$existing" | human_size)"
  fi

  # Engine decision (aria2 first if allowed & large)
  local use_aria2=0
  if [[ "$ENGINE" != "curl" ]] && command -v aria2c >/dev/null 2>&1; then
    if [[ "$ENGINE" == "aria2" ]]; then use_aria2=1
    elif [[ "$ENGINE" == "auto" && -n "${size_bytes:-}" && "$size_bytes" -ge 20971520 ]]; then use_aria2=1
    fi
  fi
  if [[ $use_aria2 -eq 1 ]]; then
    if aria2_download_one_url "$url" "${size_bytes:-}" "$ref" "$out" "$fname"; then return 0; else [[ $QUIET -eq 0 ]] && echo "  ! aria2 failed, falling back to curl: $fname"; fi
  fi

  # Layered curl attempts (safe baseline)
  local metrics rc line http sz spd ttot
  set +e

  # A) user http opts (may be empty)
  if [[ -t 2 ]]; then
    metrics="$(curl $CURL_HTTP_OPTS -fL -C - --retry 3 --retry-all-errors \
         --connect-timeout 15 --speed-time 30 --speed-limit 1024 \
         -H "Referer: ${ref}" -H "$UA_HEADER" \
         --progress-bar \
         --write-out 'http=%{http_code} size=%{size_download} speed=%{speed_download} time=%{time_total}\n' \
         -o "$out" "$url" 2>/dev/tty)"; rc=$?
  else
    metrics="$(curl $CURL_HTTP_OPTS -fL -C - --retry 3 --retry-all-errors \
         --connect-timeout 15 --speed-time 30 --speed-limit 1024 \
         -H "Referer: ${ref}" -H "$UA_HEADER" \
         --progress-bar \
         --write-out 'http=%{http_code} size=%{size_download} speed=%{speed_download} time=%{time_total}\n' \
         -o "$out" "$url" 2>&2)"; rc=$?
  fi

  if [[ $rc -ne 0 && $FORCE_SAFE -eq 1 ]]; then
    # B) force http/1.1
    if [[ -t 2 ]]; then
      metrics="$(curl --http1.1 -fL -C - --retry 3 --retry-all-errors \
           --connect-timeout 20 --speed-time 45 --speed-limit 1024 \
           -H "Referer: ${ref}" -H "$UA_HEADER" \
           --progress-bar \
           --write-out 'http=%{http_code} size=%{size_download} speed=%{speed_download} time=%{time_total}\n' \
           -o "$out" "$url" 2>/dev/tty)"; rc=$?
    else
      metrics="$(curl --http1.1 -fL -C - --retry 3 --retry-all-errors \
           --connect-timeout 20 --speed-time 45 --speed-limit 1024 \
           -H "Referer: ${ref}" -H "$UA_HEADER" \
           --progress-bar \
           --write-out 'http=%{http_code} size=%{size_download} speed=%{speed_download} time=%{time_total}\n' \
           -o "$out" "$url" 2>&2)"; rc=$?
    fi
  fi

  if [[ $rc -ne 0 && $FORCE_SAFE -eq 1 ]]; then
    # C) force http/2
    if [[ -t 2 ]]; then
      metrics="$(curl --http2 -fL -C - --retry 3 --retry-all-errors \
           --connect-timeout 20 --speed-time 45 --speed-limit 1024 \
           -H "Referer: ${ref}" -H "$UA_HEADER" \
           --progress-bar \
           --write-out 'http=%{http_code} size=%{size_download} speed=%{speed_download} time=%{time_total}\n' \
           -o "$out" "$url" 2>/dev/tty)"; rc=$?
    else
      metrics="$(curl --http2 -fL -C - --retry 3 --retry-all-errors \
           --connect-timeout 20 --speed-time 45 --speed-limit 1024 \
           -H "Referer: ${ref}" -H "$UA_HEADER" \
           --progress-bar \
           --write-out 'http=%{http_code} size=%{size_download} speed=%{speed_download} time=%{time_total}\n' \
           -o "$out" "$url" 2>&2)"; rc=$?
    fi
  fi

  if [[ $rc -ne 0 && $FORCE_SAFE -eq 1 ]]; then
    # D) last chance: relax low-speed guards & extend retries
    if [[ -t 2 ]]; then
      metrics="$(curl $CURL_HTTP_OPTS -L -C - --retry 5 --retry-all-errors \
           --connect-timeout 30 \
           -H "Referer: ${ref}" -H "$UA_HEADER" \
           --progress-bar \
           --write-out 'http=%{http_code} size=%{size_download} speed=%{speed_download} time=%{time_total}\n' \
           -o "$out" "$url" 2>/dev/tty)"; rc=$?
    else
      metrics="$(curl $CURL_HTTP_OPTS -L -C - --retry 5 --retry-all-errors \
           --connect-timeout 30 \
           -H "Referer: ${ref}" -H "$UA_HEADER" \
           --progress-bar \
           --write-out 'http=%{http_code} size=%{size_download} speed=%{speed_download} time=%{time_total}\n' \
           -o "$out" "$url" 2>&2)"; rc=$?
    fi
  fi
  set -e

  # parse metrics & report
  local http sz spd ttot
  http="$(sed -n 's/.*http=\([0-9][0-9][0-9]\).*/\1/p' <<<"$metrics")"
  sz="$(sed -n 's/.*size=\([0-9.][0-9]*\).*/\1/p' <<<"$metrics")"
  spd="$(sed -n 's/.*speed=\([0-9.][0-9]*\).*/\1/p' <<<"$metrics")"
  ttot="$(sed -n 's/.*time=\([0-9.][0-9]*\).*/\1/p' <<<"$metrics")"

  if [[ "${http:-}" != "200" && "${http:-}" != "206" ]]; then
    [[ $QUIET -eq 0 ]] && echo "  ✗ HTTP ${http:-?}. See $LOG_FILE"
    log_err "HTTP ${http:-?} url=$url out=$out"
    return 1
  fi

  after_human="$(printf "%s\n" "${sz:-0}" | human_size)"
  local spd_human
  spd_human="$(printf "%s\n" "${spd:-0}" | awk '{x=$1; s="B/s KB/s MB/s GB/s"; split(s,a); i=1; while(x>=1024 && i<4){x/=1024;i++} printf("%.2f %s", x, a[i])}')"
  local out_abs; out_abs="$(abspath "$out")"
  if [[ $QUIET -eq 0 ]]; then
    echo "  ✓ Download completed successfully: $fname"
    echo "    Path: $out_abs | Size: ${after_human} | Avg speed: ${spd_human} | Time: ${ttot}s"
  fi
  return 0
}

process_token() {
  local token="$1"
  [[ $QUIET -eq 0 ]] && echo "Resolving: $token"
  local lines; lines="$(resolve_token "$token" || true)"
  if [[ -z "$lines" ]]; then
    echo "✗ Unable to resolve: $token"
    log_err "Resolve failed for: $token"
    return 1
  fi

  # each line: URL<TAB>SIZE<TAB>REFERER
  local _has_bg=0
  while IFS=$'\t' read -r url size ref; do
    if (( JOBS > 1 )); then
      while (( $(jobs -r | wc -l | tr -d ' ') >= JOBS )); do sleep 0.1; done
      download_one_url "$url" "${size:-}" "${ref:-}" &
      _has_bg=1
      sleep "$SLEEP_BETWEEN"
    else
      download_one_url "$url" "${size:-}" "${ref:-}"
      sleep "$SLEEP_BETWEEN"
    fi
  done <<<"$lines"
  if (( _has_bg )); then wait; fi
}

# ------------------------------ run ---------------------------------
for item in "${INPUTS[@]}"; do
  process_token "$item" || true
done