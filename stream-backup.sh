#!/usr/bin/env bash
# ==============================================================================
# stream-backup.sh: Stream-encrypted backups (Local Backup, Upload, Restore)
#
# Three core features:
#   1. backup  <source_dir> <output_dir>   : Stream tar -> openssl -> local chunks
#   2. upload  <source_dir> <remote_name>  : Stream, encrypt & upload directly to S3
#   3. restore <backup_dir> <dest_dir>     : Decrypt chunks & extract to destination
#
# Requirements: bash (4+), tar, openssl, gpg, pv, and s3cmd (or aws-cli).
# ==============================================================================
set -euo pipefail

# --- 1. Environment & Defaults ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -d "$SCRIPT_DIR/bin" ]] && export PATH="$SCRIPT_DIR/bin:$PATH"

BUCKET="${BUCKET:-}"                       # Remote S3 bucket name (required for upload)
PREFIX="${PREFIX:-backups}"                # Remote S3 prefix: s3://$BUCKET/$PREFIX/
RECIPIENT="${RECIPIENT:-i@valt.me}"        # GPG recipient key ID / email
CHUNK_SIZE="${CHUNK_SIZE:-200m}"          # Split chunk size (e.g. 1m, 500m, 2000m)
CIPHER="${CIPHER:-aes-256-cbc}"            # OpenSSL symmetric cipher
S3_HOST="${S3_HOST:-}"                     # Custom S3 endpoint host
AWS_PROFILE="${AWS_PROFILE:-}"             # AWS profile for authentication
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"        # Concurrent upload workers
RAM_DISK_MB="${RAM_DISK_MB:-}"             # RAM disk size (auto-computed from formula if unset)

# --- 2. Logging & Error Helpers ---
log()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[FAIL]\033[0m %s\n" "$*" >&2; exit 1; }

# Helper: Compute RAM disk size = chunk_size * parallel_jobs * 1.05
calc_ram_disk_mb() {
  local chunk="$1" jobs="$2"
  local num="${chunk%[a-zA-Z]*}"
  local unit="${chunk#$num}"
  unit=$(echo "$unit" | tr '[:upper:]' '[:lower:]')
  local chunk_mb="$num"
  case "$unit" in
    g) chunk_mb=$(( num * 1024 )) ;;
    k) chunk_mb=$(( (num + 1023) / 1024 )) ;;
    *) chunk_mb=$num ;;
  esac
  local total_mb
  total_mb=$(awk -v c="$chunk_mb" -v j="$jobs" 'BEGIN { printf "%.0f\n", (c * j * 1.05) + 0.499 }')
  [[ "$total_mb" -lt 16 ]] && total_mb=16
  echo "$total_mb"
}

# State for in-memory disk cleanup trap
RAM_DEV=""
RAM_PATH=""

cleanup_ram() {
  if [[ -n "$RAM_DEV" ]]; then
    diskutil eject "$RAM_DEV" >/dev/null 2>&1 || hdiutil detach "$RAM_DEV" >/dev/null 2>&1 || true
    log "In-memory RAM disk detached ($RAM_DEV)."
    RAM_DEV=""
  elif [[ -n "$RAM_PATH" && -d "$RAM_PATH" ]]; then
    rm -rf "$RAM_PATH"
    log "In-memory RAM directory cleaned ($RAM_PATH)."
    RAM_PATH=""
  fi
}
trap cleanup_ram EXIT ERR INT TERM

# --- 3. S3 Credential Resolution & Upload ---
init_s3_credentials() {
  [[ -z "$AWS_PROFILE" ]] && return 0
  if command -v aws >/dev/null 2>&1; then
    eval "$(aws configure export-credentials --profile "$AWS_PROFILE" --format env 2>/dev/null || true)"
  fi
  if [[ -z "${AWS_ACCESS_KEY_ID:-}" && -f "$HOME/.aws/credentials" ]]; then
    AWS_ACCESS_KEY_ID=$(awk -F '=[ \t]*' -v p="[$AWS_PROFILE]" '$0 ~ p {f=1; next} /^\[/ {f=0} f && $1 ~ /aws_access_key_id/ {print $2}' "$HOME/.aws/credentials")
    AWS_SECRET_ACCESS_KEY=$(awk -F '=[ \t]*' -v p="[$AWS_PROFILE]" '$0 ~ p {f=1; next} /^\[/ {f=0} f && $1 ~ /aws_secret_access_key/ {print $2}' "$HOME/.aws/credentials")
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  fi
}

s3_put() {
  local file="$1" dest="$2"
  init_s3_credentials
  if command -v aws >/dev/null 2>&1; then
    local aws_flags=()
    [[ -n "$AWS_PROFILE" ]] && aws_flags+=(--profile "$AWS_PROFILE")
    [[ -n "$S3_HOST" ]] && aws_flags+=(--endpoint-url "https://$S3_HOST")
    aws "${aws_flags[@]}" s3 cp "$file" "$dest"
  elif command -v s3cmd >/dev/null 2>&1; then
    local s3cmd_flags=(--no-check-md5 --config=/dev/null)
    [[ -n "${AWS_ACCESS_KEY_ID:-}" ]] && s3cmd_flags+=(--access_key="$AWS_ACCESS_KEY_ID")
    [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && s3cmd_flags+=(--secret_key="$AWS_SECRET_ACCESS_KEY")
    [[ -n "$S3_HOST" ]] && s3cmd_flags+=(--host="$S3_HOST" --host-bucket="%(bucket)s.$S3_HOST")
    s3cmd "${s3cmd_flags[@]}" put "$file" "$dest"
  else
    err "Neither 'aws' nor 's3cmd' CLI found."
  fi
}

# --- 4. Feature 1: Local Backup to a Folder ---
backup_local() {
  # Strict parameter validation
  [[ $# -ne 2 ]] && err "Usage: $0 backup <source_dir> <output_dir>"
  local src_dir="$1" out_dir="$2"
  [[ ! -d "$src_dir" ]] && err "Source directory does not exist: $src_dir"

  mkdir -p "$out_dir"
  local key_file="$out_dir/passwd.txt.gpg"
  local aes_key; aes_key=$(openssl rand -base64 32)
  printf "%s" "$aes_key" | gpg --batch --yes --trust-model always --recipient "$RECIPIENT" --encrypt > "$key_file" \
    || err "GPG encryption failed for recipient: $RECIPIENT"

  log "Measuring source size for progress meter..."
  local total_bytes; total_bytes=$(du -sb "$src_dir" 2>/dev/null | awk '{print $1}' || du -sk "$src_dir" | awk '{print $1 * 1024}')
  local pv_cmd=(cat)
  command -v pv >/dev/null 2>&1 && pv_cmd=(pv -s "$total_bytes" -N "Encrypting")

  log "Streaming archive ($src_dir) -> openssl ($CIPHER) -> chunks ($CHUNK_SIZE)..."
  tar -cf - -C "$(dirname "$src_dir")" "$(basename "$src_dir")" \
    | "${pv_cmd[@]}" \
    | openssl enc "-$CIPHER" -salt -pbkdf2 -iter 100000 -md sha512 -pass "pass:$aes_key" \
    | split -b "$CHUNK_SIZE" - "$out_dir/chunk_"

  log "Local backup complete: $out_dir/"
}

# --- 5. Feature 2: Remote Folder Upload ---
upload_remote() {
  # Strict parameter validation
  [[ -z "$BUCKET" ]] && err "BUCKET environment variable is required (e.g. BUCKET=my-bucket)"
  [[ $# -ne 2 ]] && err "Usage: $0 upload <source_dir> <remote_name>"
  local src_dir="$1" remote_name="$2"
  [[ ! -d "$src_dir" ]] && err "Source directory does not exist: $src_dir"

  local s3_dest="s3://${BUCKET}/${PREFIX}/${remote_name}"

  # Compute RAM disk size: chunk_size * parallel_jobs * 1.05
  local ram_mb="${RAM_DISK_MB:-$(calc_ram_disk_mb "$CHUNK_SIZE" "$PARALLEL_JOBS")}"
  log "Allocating ${ram_mb}MB in-memory RAM disk (formula: $CHUNK_SIZE * $PARALLEL_JOBS * 1.05)..."
  if [[ "$(uname -s)" == "Darwin" ]]; then
    local sectors=$(( ram_mb * 2048 ))
    local vol_name="StreamRAM_$$"
    RAM_DEV=$(hdiutil attach -nobrowse -nomount "ram://$sectors" | awk '{print $1}')
    diskutil erasevolume HFS+ "$vol_name" "$RAM_DEV" >/dev/null
    RAM_PATH="/Volumes/$vol_name"
  else
    RAM_PATH=$(mktemp -d /dev/shm/stream_ram_XXXXXX 2>/dev/null || mktemp -d /tmp/stream_ram_XXXXXX)
  fi

  log "Encrypting and chunking '$src_dir' directly into RAM ($RAM_PATH)..."
  backup_local "$src_dir" "$RAM_PATH"

  local key_file="$RAM_PATH/passwd.txt.gpg"
  local chunks=("$RAM_PATH"/chunk_*)
  local total_chunks=${#chunks[@]}

  log "Uploading key to $s3_dest/passwd.txt.gpg..."
  s3_put "$key_file" "$s3_dest/passwd.txt.gpg"

  log "Uploading $total_chunks chunks in parallel (concurrency: $PARALLEL_JOBS)..."
  local active=0 idx=0
  for chunk in "${chunks[@]}"; do
    (( ++idx ))
    (
      s3_put "$chunk" "$s3_dest/$(basename "$chunk")"
      log "  ✓ [${idx}/${total_chunks}] Uploaded $(basename "$chunk") ($(( idx * 100 / total_chunks ))%)"
    ) &
    (( ++active >= PARALLEL_JOBS )) && { wait -n 2>/dev/null || wait; (( --active )) || true; }
  done
  wait
  log "Upload complete: $s3_dest/"

  cleanup_ram
}

# --- 6. Feature 3: Restore from a Local Folder ---
restore_local() {
  # Strict parameter validation
  [[ $# -ne 2 ]] && err "Usage: $0 restore <backup_dir> <dest_dir>"
  local backup_dir="$1" dest_dir="$2"
  [[ ! -d "$backup_dir" ]] && err "Backup directory does not exist: $backup_dir"
  local key_file="$backup_dir/passwd.txt.gpg"
  [[ ! -f "$key_file" ]] && err "Missing key file: $key_file"

  mkdir -p "$dest_dir"
  local aes_key; aes_key=$(gpg --batch --yes --decrypt "$key_file") || err "GPG decryption failed"

  log "Decrypting chunks from '$backup_dir' into '$dest_dir'..."
  local pv_cmd=(cat)
  command -v pv >/dev/null 2>&1 && pv_cmd=(pv -N "Decrypting")
  cat "$backup_dir"/chunk_* \
    | "${pv_cmd[@]}" \
    | openssl enc -d "-$CIPHER" -salt -pbkdf2 -iter 100000 -md sha512 -pass "pass:$aes_key" \
    | tar -xf - -C "$dest_dir"

  log "Restore complete into '$dest_dir'."
}

# --- 7. CLI Dispatcher ---
case "${1:-}" in
  backup)  shift; backup_local "$@" ;;
  upload)  shift; upload_remote "$@" ;;
  restore) shift; restore_local "$@" ;;
  -h|--help|help|"")
    cat <<EOF
Usage:
  $0 backup  <source_dir> <output_dir>   # Stream, encrypt & split into local folder
  $0 upload  <source_dir> <remote_name>  # Stream, encrypt, split & upload to S3 (requires BUCKET)
  $0 restore <backup_dir> <dest_dir>     # Decrypt local chunks & unpack to destination

Environment Variables:
  BUCKET        Remote S3 bucket name (required for 'upload')
  PREFIX        Remote S3 prefix (default: 'backups')
  S3_HOST       Custom S3 endpoint host (e.g. 's3.fr-par.scw.cloud')
  AWS_PROFILE   AWS profile for credentials (e.g. 'scaleway')
  PARALLEL_JOBS Concurrent chunk upload workers (default: 4)
  CHUNK_SIZE    Chunk split size (default: '2000m')
  RECIPIENT     GPG recipient email / key ID (default: 'i@valt.me')
EOF
    ;;
  *) err "Unknown command '${1:-}'. Run '$0 --help' for usage." ;;
esac
