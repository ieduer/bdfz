#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="treehole-export-2025-12-14-v1"

log() { echo "[treehole_export] $*"; }

usage() {
  cat <<'USAGE'
Usage:
  bash treehole_export.sh [--db /path/to/treehole.db] [--out /path/to/output_dir]

Defaults:
  --db  auto-detect from /opt/treehole-app/.env (TREEHOLE_DB_PATH), fallback /srv/treehole/treehole.db
  --out /root/treehole-export-<UTC_TIMESTAMP>

Outputs:
  - treehole.db.backup
  - treehole.dump.sql
  - treehole.posts.csv
  - treehole.stats.txt
  - treehole.sha256.txt
  - /root/treehole-export-<UTC_TIMESTAMP>.tar.gz

USAGE
}

require_cmd() {
  local c="$1"
  if ! command -v "$c" >/dev/null 2>&1; then
    log "ERROR: command not found: $c"
    exit 1
  fi
}

read_db_path_from_env() {
  local env_file="/opt/treehole-app/.env"
  if [[ ! -f "$env_file" ]]; then
    return 1
  fi

  # Accept formats:
  # TREEHOLE_DB_PATH="/srv/treehole/treehole.db"
  # TREEHOLE_DB_PATH=/srv/treehole/treehole.db
  local line
  line="$(grep -E '^[[:space:]]*TREEHOLE_DB_PATH=' "$env_file" | tail -n 1 || true)"
  if [[ -z "$line" ]]; then
    return 1
  fi

  # Strip prefix and surrounding quotes
  local val="${line#*=}"
  val="${val%\"}"
  val="${val#\"}"
  val="${val%\'}"
  val="${val#\'}"

  if [[ -z "$val" ]]; then
    return 1
  fi

  echo "$val"
  return 0
}

DB_PATH=""
OUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)
      DB_PATH="${2:-}"
      shift 2
      ;;
    --out)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log "ERROR: unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

log "version: ${SCRIPT_VERSION}"

require_cmd date
require_cmd tar
require_cmd sha256sum
require_cmd sqlite3

if [[ -z "${DB_PATH}" ]]; then
  if DB_PATH="$(read_db_path_from_env)"; then
    log "Detected DB from /opt/treehole-app/.env: ${DB_PATH}"
  else
    DB_PATH="/srv/treehole/treehole.db"
    log "DB not found in /opt/treehole-app/.env, fallback: ${DB_PATH}"
  fi
fi

if [[ ! -f "${DB_PATH}" ]]; then
  log "ERROR: DB file not found: ${DB_PATH}"
  log "Hint: pass --db /actual/path/to/treehole.db"
  exit 1
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="/root/treehole-export-${TS}"
fi

mkdir -p "${OUT_DIR}"
chmod 700 "${OUT_DIR}"

log "DB: ${DB_PATH}"
log "OUT_DIR: ${OUT_DIR}"

log "1) Consistent backup (.backup)..."
sqlite3 "${DB_PATH}" ".backup '${OUT_DIR}/treehole.db.backup'"

log "2) SQL dump (.dump)..."
sqlite3 "${DB_PATH}" ".output '${OUT_DIR}/treehole.dump.sql'"
sqlite3 "${DB_PATH}" ".dump"
sqlite3 "${DB_PATH}" ".output stdout"

log "3) Export posts to CSV..."
sqlite3 "${DB_PATH}" -header -csv \
  "SELECT id, tag, created_at, content, ip_hash FROM posts ORDER BY id ASC;" \
  > "${OUT_DIR}/treehole.posts.csv"

log "4) Basic stats..."
{
  echo "db_path=${DB_PATH}"
  echo "export_utc=${TS}"
  echo
  echo "[posts_count]"
  sqlite3 "${DB_PATH}" "SELECT COUNT(*) AS posts_count FROM posts;"
  echo
  echo "[range_created_at]"
  sqlite3 "${DB_PATH}" "SELECT MIN(created_at) AS min_created_at, MAX(created_at) AS max_created_at FROM posts;"
  echo
  echo "[schema]"
  sqlite3 "${DB_PATH}" ".schema posts"
} > "${OUT_DIR}/treehole.stats.txt"

log "5) SHA256..."
(
  cd "${OUT_DIR}"
  sha256sum treehole.db.backup treehole.dump.sql treehole.posts.csv treehole.stats.txt > treehole.sha256.txt
)

ARCHIVE="/root/treehole-export-${TS}.tar.gz"
log "6) Pack to: ${ARCHIVE}"
tar -C "$(dirname "${OUT_DIR}")" -czf "${ARCHIVE}" "$(basename "${OUT_DIR}")"

log "DONE."
log "Files:"
ls -lah "${OUT_DIR}" "${ARCHIVE}"

log "If SSH is down, you can temporarily serve /root over HTTP to download the tar.gz:"
log "  cd /root && python3 -m http.server 8080 --bind 0.0.0.0"