#!/usr/bin/env bash
# taiwanebook.sh — Taiwan eBooks downloader (GitHub-ready .sh)
# Features:
# - Input: book ID (preferred), book page URL (with/without /reader, any locale), or viewer URL
# - Auto resolve single or multi-part PDFs (F01..Fn) by probing
# - Shows file size, progress, download speed, total time; supports resume (-C -)
# - Detailed error log with timestamps
# - Auto-install alias `twb` into ~/.zshrc on first run (safe + idempotent)
# - Batch via stdin or multiple args
# macOS-friendly; depends on: bash, curl; optional: python3/perl for URL decode / abspath

set -euo pipefail

# --------------------------- config ---------------------------------
BASE="https://taiwanebook.ncl.edu.tw"
REF_HEADER="Referer: ${BASE}/"
UA_HEADER="User-Agent: curl-taiwan-ebooks-shell/2.0"

LOG_FILE="${LOG_FILE:-./taiwanebook_error.log}"
OUTDIR="."
SLEEP_BETWEEN="${SLEEP_BETWEEN:-0}"
MAX_PARTS="${MAX_PARTS:-40}"          # upper bound when scanning F01..Fn
QUIET=0

# Modes for multi-part:
# auto (default): if F01 exists, download all contiguous parts; else download single
# single        : force single file only (no Fxx scanning)
# all           : force download all parts found up to MAX_PARTS
MULTIPART_MODE="${MULTIPART_MODE:-auto}"

# --------------------------- utils ----------------------------------
timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

log_err() {
  local msg="$1"
  printf "[%s] %s\n" "$(timestamp)" "$msg" >>"$LOG_FILE"
}

trim() {
  # trim leading/trailing whitespace from stdin
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

abspath() {
  # portable absolute path for the running script or file
  local p="${1:?}"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$p" <<'PY'
import os,sys; print(os.path.realpath(sys.argv[1]))
PY
  elif command -v perl >/dev/null 2>&1; then
    perl -MCwd=realpath -e 'print realpath($ARGV[0])' "$p"
  else
    # best-effort
    (cd "$(dirname "$p")" && printf "%s/%s\n" "$PWD" "$(basename "$p")")
  fi
}

human_size() {
  # bytes -> human string
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

sanitize_name() { sed -E 's#[/[:cntrl:]]#_#g' | tr -c '[:alnum:]._-+' '_'; }

stat_size() {
  # size of existing file (or 0 if missing)
  local f="$1"
  if [[ -f "$f" ]]; then
    # macOS stat
    stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# Returns 0 if URL exists; echoes size (bytes) to stdout if determinable, else empty
probe_url_and_size() {
  local url="$1"
  # Try byte-range first to get Content-Range total size
  local headers
  headers="$(curl -fsSLI -H "$REF_HEADER" -H "$UA_HEADER" --range 0-0 "$url" 2>/dev/null || true)"
  if [[ -n "$headers" ]]; then
    # Content-Range: bytes 0-0/123456
    local total
    total="$(printf "%s\n" "$headers" | awk -F'/' '/[Cc]ontent-[Rr]ange:/ {gsub("\r",""); print $2}' | tr -d '\r' | trim || true)"
    if [[ -n "$total" ]]; then
      printf "%s" "$total"
      return 0
    fi
    # Content-Length fallback
    total="$(printf "%s\n" "$headers" | awk -F': ' 'tolower($1)=="content-length" {gsub("\r","",$2); print $2}' | trim || true)"
    if [[ -n "$total" ]]; then
      printf "%s" "$total"
      return 0
    fi
    printf ""  # exists but unknown size
    return 0
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

extract_from_reader_or_book_page() {
  # Given a page URL (with/without /reader, any locale), fetch and try to extract /ebkFiles/.. path
  local page="$1"
  local html
  html="$(curl -fsSL -H "$UA_HEADER" "$page" 2>/dev/null || true)"
  if [[ -z "$html" ]]; then return 1; fi
  extract_file_param "$html" || return 1
}

guess_pdf_paths_by_id() {
  local id="$1"
  echo "/ebkFiles/${id}/${id}.PDF"
  local i
  for i in $(seq -w 1 "$MAX_PARTS"); do
    echo "/ebkFiles/${id}/${id}F${i}.PDF"
  done
}

resolve_token() {
  # Output one or more absolute URLs to download (based on MULTIPART_MODE)
  local token="$1"
  local file_path="" id="" urls=() size="" url=""

  # 1) Direct viewer URL -> file_path
  if [[ "$token" == *"/pdfjs/web/viewer.html"* ]]; then
    file_path="$(extract_file_param "$token" || true)"
  fi

  # 2) Book page (any locale, with/without /reader)
  if [[ -z "${file_path:-}" && "$token" == *"/book/"* ]]; then
    # try current page
    file_path="$(extract_from_reader_or_book_page "$token" || true)"
    # if not found, try its /reader variant
    if [[ -z "${file_path:-}" ]]; then
      local id_from
      id_from="$(printf '%s' "$token" | sed -n 's#.*/book/\([^/?#]*\).*#\1#p' | trim || true)"
      if [[ -n "$id_from" ]]; then
        file_path="$(extract_from_reader_or_book_page "${BASE}/en/book/${id_from}/reader" || true)"
        [[ -z "${file_path:-}" ]] && file_path="$(extract_from_reader_or_book_page "${BASE}/zh-tw/book/${id_from}/reader" || true)"
        id="$id_from"
      fi
    fi
  fi

  # 3) Pure ID
  if [[ -z "${file_path:-}" && -z "${id:-}" && "$token" =~ ^[A-Z0-9-]+$ ]]; then
    id="$token"
  fi

  # If we have a concrete file_path, validate and return it
  if [[ -n "${file_path:-}" ]]; then
    url="${BASE%/}${file_path}"
    size="$(probe_url_and_size "$url" || true)"
    if [[ $? -eq 0 ]]; then
      printf "%s\t%s\n" "$url" "${size:-}"
      return 0
    else
      log_err "Probe failed (viewer file path) for: $url"
    fi
  fi

  # If we have an ID, apply multi-part strategy
  if [[ -n "${id:-}" ]]; then
    local found_any=0
    local first_single="/ebkFiles/${id}/${id}.PDF"
    local s

    case "$MULTIPART_MODE" in
      single)
        url="${BASE%/}${first_single}"
        s="$(probe_url_and_size "$url" || true)"
        if [[ $? -eq 0 ]]; then echo -e "${url}\t${s}"; return 0; fi
        ;;
      all|auto)
        # Try F01.. first to detect multi-part
        local parts=() i part_url part_size
        for i in $(seq -w 1 "$MAX_PARTS"); do
          part_url="${BASE%/}/ebkFiles/${id}/${id}F${i}.PDF"
          part_size="$(probe_url_and_size "$part_url" || true)"
          if [[ $? -eq 0 ]]; then
            parts+=("${part_url}\t${part_size}")
            found_any=1
          else
            # Stop at first miss if we already found at least F01
            [[ ${#parts[@]} -gt 0 ]] && break
          fi
        done
        if [[ "$MULTIPART_MODE" == "all" && ${#parts[@]} -gt 0 ]]; then
          printf "%s\n" "${parts[@]}"
          return 0
        fi
        if [[ "$MULTIPART_MODE" == "auto" ]]; then
          if [[ ${#parts[@]} -gt 0 ]]; then
            printf "%s\n" "${parts[@]}"; return 0
          fi
          # fallback to single file
          url="${BASE%/}${first_single}"
          s="$(probe_url_and_size "$url" || true)"
          if [[ $? -eq 0 ]]; then echo -e "${url}\t${s}"; return 0; fi
        fi
        ;;
      *)
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
  --quiet              Less chatter
  -h, --help           Show help
Env:
  LOG_FILE=./taiwanebook_error.log
  MAX_PARTS=40  MULTIPART_MODE=auto  SLEEP_BETWEEN=0
EOF
}

# ------------------------ arg parsing --------------------------------
INPUTS=()
while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --outdir) OUTDIR="${2:?}"; shift 2 ;;
    --sleep) SLEEP_BETWEEN="${2:?}"; shift 2 ;;
    --mode) MULTIPART_MODE="${2:?}"; shift 2 ;;
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
  local zrc="$HOME/.zshrc"
  local marker="# >>> taiwanebook.sh alias (managed)"
  if grep -qs "alias twb=" "$zrc"; then
    return 0
  fi
  local self_abs; self_abs="$(abspath "$0")"
  {
    echo "$marker"
    echo "alias twb='$self_abs'"
    echo "# <<< taiwanebook.sh alias"
  } >>"$zrc" || true
  if [[ $QUIET -eq 0 ]]; then
    echo "Installed alias: twb  (added to $zrc). Reload with: source ~/.zshrc"
  fi
}
ensure_alias || true

# ------------------------ download routine ---------------------------
download_one_url() {
  local url="$1"
  local size_bytes="${2:-}" # may be empty
  local fname out existing before_human after_human

  fname="$(basename "$url" | sanitize_name)"
  out="${OUTDIR%/}/$fname"

  # pre-flight
  if [[ -n "$size_bytes" ]]; then
    before_human="$(printf "%s\n" "$size_bytes" | human_size)"
    [[ $QUIET -eq 0 ]] && echo "• Target: $fname  | Size: ${before_human}  | URL: $url"
  else
    [[ $QUIET -eq 0 ]] && echo "• Target: $fname  | URL: $url"
  fi

  local already=0
  existing="$(stat_size "$out")"
  if [[ "$existing" -gt 0 ]]; then
    already=1
    [[ $QUIET -eq 0 ]] && echo "  Resuming from: $(printf "%s\n" "$existing" | human_size)"
  fi

  # download with progress bar and write-out metrics
  local tmp_out; tmp_out="$(mktemp)"
  set +e
  curl -fL -C - --retry 3 --retry-all-errors \
       -H "$REF_HEADER" -H "$UA_HEADER" \
       --progress-bar \
       --write-out 'http=%{http_code} size=%{size_download} speed=%{speed_download} time=%{time_total}\n' \
       -o "$out" "$url" 2>/dev/null | tee "$tmp_out" >/dev/null
  local rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    [[ $QUIET -eq 0 ]] && echo "  ✗ Download failed (code $rc). See $LOG_FILE"
    log_err "Download error rc=$rc url=$url out=$out"
    return $rc
  fi

  # parse metrics (last line)
  local line; line="$(tail -n1 "$tmp_out" 2>/dev/null || true)"
  rm -f "$tmp_out" || true

  local http sz spd ttot
  http="$(sed -n 's/.*http=\([0-9][0-9][0-9]\).*/\1/p' <<<"$line")"
  sz="$(sed -n 's/.*size=\([0-9.][0-9]*\).*/\1/p' <<<"$line")"
  spd="$(sed -n 's/.*speed=\([0-9.][0-9]*\).*/\1/p' <<<"$line")"
  ttot="$(sed -n 's/.*time=\([0-9.][0-9]*\).*/\1/p' <<<"$line")"

  if [[ "$http" != "200" && "$http" != "206" ]]; then
    [[ $QUIET -eq 0 ]] && echo "  ✗ HTTP $http. See $LOG_FILE"
    log_err "HTTP $http url=$url out=$out"
    return 1
  fi

  after_human="$(printf "%s\n" "${sz:-0}" | human_size)"
  # Convert speed (bytes/sec) to human
  local spd_human
  spd_human="$(printf "%s\n" "${spd:-0}" | awk '{x=$1; s="B/s KB/s MB/s GB/s"; split(s,a); i=1; while(x>=1024 && i<4){x/=1024;i++} printf("%.2f %s", x, a[i])}')"

  [[ $QUIET -eq 0 ]] && echo "  ✓ Saved: $out  | Downloaded: ${after_human}  | Avg speed: ${spd_human}  | Time: ${ttot}s"
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

  # each line: URL<TAB>SIZE
  while IFS=$'\t' read -r url size; do
    # empty size means unknown; still attempt download
    download_one_url "$url" "${size:-}"
    sleep "$SLEEP_BETWEEN"
  done <<<"$lines"
}

# ------------------------------ run ---------------------------------
for item in "${INPUTS[@]}"; do
  process_token "$item" || true
done