#!/usr/bin/env bash
# ==============================================================================
# stream-backup.sh: Stream-encrypted backups (Local Backup, Upload, Restore)
#
# Three core features:
#   1. backup  <source_dir> <output_dir>   : Stream tar -> openssl -> local chunks
#   2. upload  <source_dir> <remote_name>  : Stream, encrypt & upload directly to S3
#   3. restore <backup_dir> <dest_dir>     : Decrypt chunks & extract to destination
#
# Options:
#   -v, --verbose, or VERBOSE=1            : Enable verbose debug logging
#
# Requirements: bash (3.2+), tar, openssl, gpg, pv, and s3cmd (or aws-cli).
# ==============================================================================
set -euo pipefail

# Check for -v or --verbose flags anywhere in arguments
VERBOSE="${VERBOSE:-0}"
filtered_args=()
for arg in "$@"; do
  if [[ "$arg" == "-v" || "$arg" == "--verbose" ]]; then
    VERBOSE=1
  else
    filtered_args+=("$arg")
  fi
done
if [[ ${#filtered_args[@]} -gt 0 ]]; then
  set -- "${filtered_args[@]}"
else
  set --
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -d "$SCRIPT_DIR/bin" ]] && export PATH="$SCRIPT_DIR/bin:$PATH"

BUCKET="${BUCKET:-}"                       # Remote S3 bucket name (required for upload)
PREFIX="${PREFIX:-backups}"                # Remote S3 prefix: s3://$BUCKET/$PREFIX/
RECIPIENT="${RECIPIENT:-i@valt.me}"        # GPG recipient key ID / email
CHUNK_SIZE="${CHUNK_SIZE:-2000m}"          # Split chunk size (e.g. 1m, 200m, 2000m)
CIPHER="${CIPHER:-aes-256-cbc}"            # OpenSSL symmetric cipher
S3_HOST="${S3_HOST:-}"                     # Custom S3 endpoint host
AWS_PROFILE="${AWS_PROFILE:-}"             # AWS profile for authentication
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"        # Concurrent upload workers
RAM_DISK_MB="${RAM_DISK_MB:-}"             # RAM disk size (auto-computed from formula if unset)

# --- 2. Logging & Error Helpers ---
log()   { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()   { printf "\033[1;31m[FAIL]\033[0m %s\n" "$*" >&2; exit 1; }
debug() { [[ "$VERBOSE" == "1" ]] && printf "\033[1;35m[DEBUG]\033[0m %s\n" "$*" || true; }

# Helper: Format raw bytes into human-readable string
format_bytes() {
  local b="$1"
  awk -v b="$b" 'BEGIN {
    if (b >= 1073741824) { printf "%.2f GiB (%d bytes)", b/1073741824, b }
    else if (b >= 1048576) { printf "%.2f MiB (%d bytes)", b/1048576, b }
    else if (b >= 1024) { printf "%.2f KiB (%d bytes)", b/1024, b }
    else { printf "%d bytes", b }
  }'
}

# Helper: Parse CHUNK_SIZE string into raw bytes
chunk_to_bytes() {
  local val="$1"
  local num="${val%[a-zA-Z]*}"
  local unit="${val#$num}"
  unit=$(echo "$unit" | tr '[:upper:]' '[:lower:]')
  case "$unit" in
    g) echo "$(( num * 1024 * 1024 * 1024 ))" ;;
    m) echo "$(( num * 1024 * 1024 ))" ;;
    k) echo "$(( num * 1024 ))" ;;
    *) echo "$num" ;;
  esac
}

# Helper: Compute RAM disk size = chunk_size * parallel_jobs * 1.05 (+ metadata overhead on macOS)
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
  local base_mb
  base_mb=$(awk -v c="$chunk_mb" -v j="$jobs" 'BEGIN { printf "%.0f\n", (c * j * 1.05) + 0.499 }')
  local total_mb="$base_mb"
  # On macOS, diskutil partitioning (GPT/EFI partition ~200MB + HFS+ metadata) requires extra sectors
  if [[ "$(uname -s)" == "Darwin" ]]; then
    total_mb=$(( total_mb + 280 ))
  fi
  [[ "$total_mb" -lt 32 ]] && total_mb=32
  echo "$total_mb"
}

# State for in-memory disk cleanup trap
RAM_DEV=""
RAM_PATH=""
PRODUCER_PID=""
UPLOAD_PIDS=" "

pause_producer() {
  local pid="$1"
  if [[ -n "$pid" ]]; then
    pkill -STOP -P "$pid" 2>/dev/null || true
    kill -STOP "$pid" 2>/dev/null || true
  fi
  pkill -STOP -f "split .*$RAM_PATH/chunk_" 2>/dev/null || true
  if [[ -d /proc ]]; then
    for f in /proc/[0-9]*/stat; do
      awk -v p="$pid" '$4 == p {print $1}' "$f" 2>/dev/null | xargs kill -STOP 2>/dev/null || true
    done
  fi
}

resume_producer() {
  local pid="$1"
  if [[ -n "$pid" ]]; then
    kill -CONT "$pid" 2>/dev/null || true
    pkill -CONT -P "$pid" 2>/dev/null || true
  fi
  pkill -CONT -f "split .*$RAM_PATH/chunk_" 2>/dev/null || true
  if [[ -d /proc ]]; then
    for f in /proc/[0-9]*/stat; do
      awk -v p="$pid" '$4 == p {print $1}' "$f" 2>/dev/null | xargs kill -CONT 2>/dev/null || true
    done
  fi
}

terminate_producer() {
  local pid="$1"
  pkill -TERM -f "split .*$RAM_PATH/chunk_" 2>/dev/null || true
  pkill -KILL -f "split .*$RAM_PATH/chunk_" 2>/dev/null || true
  if [[ -n "$pid" ]]; then
    pkill -TERM -P "$pid" 2>/dev/null || true
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  fi
  if [[ -d /proc ]]; then
    for f in /proc/[0-9]*/stat; do
      awk -v p="$pid" '$4 == p {print $1}' "$f" 2>/dev/null | xargs kill -TERM 2>/dev/null || true
      awk -v p="$pid" '$4 == p {print $1}' "$f" 2>/dev/null | xargs kill -KILL 2>/dev/null || true
    done
  fi
}

cleanup_ram() {
  # Terminate all upload workers and their children immediately
  if [[ -n "$UPLOAD_PIDS" ]]; then
    for p in $UPLOAD_PIDS; do
      pkill -TERM -P "$p" 2>/dev/null || true
      pkill -KILL -P "$p" 2>/dev/null || true
      kill -TERM "$p" 2>/dev/null || true
      kill -KILL "$p" 2>/dev/null || true
      wait "$p" 2>/dev/null || true
    done
    UPLOAD_PIDS=""
  fi

  # Terminate producer pipeline
  if [[ -n "$PRODUCER_PID" ]]; then
    terminate_producer "$PRODUCER_PID"
    PRODUCER_PID=""
  fi

  # Eject/unmount RAM disk
  if [[ -n "$RAM_DEV" ]]; then
    debug "Unmounting and ejecting RAM disk device $RAM_DEV..."
    diskutil eject "$RAM_DEV" >/dev/null 2>&1 \
      || diskutil unmountDisk force "$RAM_DEV" >/dev/null 2>&1 \
      || hdiutil detach -force "$RAM_DEV" >/dev/null 2>&1 \
      || true
    log "In-memory RAM disk detached ($RAM_DEV)."
    RAM_DEV=""
  elif [[ -n "$RAM_PATH" && -d "$RAM_PATH" ]]; then
    debug "Removing in-memory RAM directory $RAM_PATH..."
    rm -rf "$RAM_PATH"
    log "In-memory RAM directory cleaned ($RAM_PATH)."
    RAM_PATH=""
  fi
}

on_interrupt() {
  printf "\n\033[1;33m[WARN]\033[0m Interrupted by user (Ctrl+C). Halting all operations...\n" >&2
  trap - EXIT ERR INT TERM
  exec 2>/dev/null
  cleanup_ram
  exit 130
}

trap cleanup_ram EXIT ERR
trap on_interrupt INT TERM

# --- 3. S3 Credential Resolution & Upload ---
init_s3_credentials() {
  [[ -z "$AWS_PROFILE" ]] && return 0
  debug "Resolving credentials for AWS_PROFILE='$AWS_PROFILE'..."
  if command -v aws >/dev/null 2>&1; then
    eval "$(aws configure export-credentials --profile "$AWS_PROFILE" --format env 2>/dev/null || true)"
    debug "Credentials resolved via aws-cli."
  fi
  if [[ -z "${AWS_ACCESS_KEY_ID:-}" && -f "$HOME/.aws/credentials" ]]; then
    debug "Parsing credentials from $HOME/.aws/credentials..."
    AWS_ACCESS_KEY_ID=$(awk -F '=[ \t]*' -v p="[$AWS_PROFILE]" '$0 ~ p {f=1; next} /^\[/ {f=0} f && $1 ~ /aws_access_key_id/ {print $2}' "$HOME/.aws/credentials")
    AWS_SECRET_ACCESS_KEY=$(awk -F '=[ \t]*' -v p="[$AWS_PROFILE]" '$0 ~ p {f=1; next} /^\[/ {f=0} f && $1 ~ /aws_secret_access_key/ {print $2}' "$HOME/.aws/credentials")
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    debug "Credentials loaded: AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:0:4}****"
  fi
}

s3_put() {
  local file="$1" dest="$2" log_file="${3:-}"
  init_s3_credentials
  if command -v aws >/dev/null 2>&1; then
    local aws_cmd=(aws)
    [[ -n "$AWS_PROFILE" ]] && aws_cmd+=(--profile "$AWS_PROFILE")
    [[ -n "$S3_HOST" ]] && aws_cmd+=(--endpoint-url "https://$S3_HOST")
    if [[ -n "$log_file" ]]; then
      aws_cmd+=(s3 cp "$file" "$dest")
      debug "Executing: ${aws_cmd[*]} (tracking progress -> $log_file)"
      if [[ "$(uname -s)" == "Darwin" ]] && command -v script >/dev/null 2>&1; then
        script -q "$log_file" "${aws_cmd[@]}"
      else
        "${aws_cmd[@]}" > "$log_file" 2>&1
      fi
    else
      aws_cmd+=(s3 cp --no-progress "$file" "$dest")
      debug "Executing: ${aws_cmd[*]}"
      "${aws_cmd[@]}"
    fi
  elif command -v s3cmd >/dev/null 2>&1; then
    local s3cmd_flags=(--no-check-md5 --config=/dev/null)
    [[ -n "${AWS_ACCESS_KEY_ID:-}" ]] && s3cmd_flags+=(--access_key="$AWS_ACCESS_KEY_ID")
    [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && s3cmd_flags+=(--secret_key="$AWS_SECRET_ACCESS_KEY")
    [[ -n "$S3_HOST" ]] && s3cmd_flags+=(--host="$S3_HOST" --host-bucket="%(bucket)s.$S3_HOST")
    if [[ -n "$log_file" ]]; then
      s3cmd_flags+=(--progress)
      debug "Executing: s3cmd ${s3cmd_flags[*]} put $file $dest (tracking progress -> $log_file)"
      s3cmd "${s3cmd_flags[@]}" put "$file" "$dest" > "$log_file" 2>&1
    else
      s3cmd_flags+=(--no-progress)
      debug "Executing: s3cmd ${s3cmd_flags[*]} put $file $dest"
      s3cmd "${s3cmd_flags[@]}" put "$file" "$dest"
    fi
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
  log "Total size to backup ($src_dir): $(format_bytes "$total_bytes")"
  debug "Exact bytes: $total_bytes"

  local pv_cmd=(cat)
  command -v pv >/dev/null 2>&1 && pv_cmd=(pv -s "$total_bytes" -N "Encrypting")

  log "Streaming archive ($src_dir) -> openssl ($CIPHER) -> chunks ($CHUNK_SIZE)..."
  tar -cf - -C "$(dirname "$src_dir")" "$(basename "$src_dir")" \
    | "${pv_cmd[@]}" \
    | openssl enc "-$CIPHER" -salt -pbkdf2 -iter 100000 -md sha512 -pass "pass:$aes_key" \
    | split -b "$CHUNK_SIZE" - "$out_dir/chunk_"

  log "Local backup complete: $out_dir/"
}

# --- 5. Feature 2: Remote Folder Upload (Live Streaming Throttle) ---
upload_remote() {
  # Strict parameter validation
  [[ -z "$BUCKET" ]] && err "BUCKET environment variable is required (e.g. BUCKET=my-bucket)"
  [[ $# -ne 2 ]] && err "Usage: $0 upload <source_dir> <remote_name>"
  local src_dir="$1" remote_name="$2"
  [[ ! -d "$src_dir" ]] && err "Source directory does not exist: $src_dir"

  local s3_dest="s3://${BUCKET}/${PREFIX}/${remote_name}"
  local chunk_bytes; chunk_bytes=$(chunk_to_bytes "$CHUNK_SIZE")
  debug "Chunk size: $CHUNK_SIZE ($chunk_bytes bytes)"

  # Measure and output total size to be backed up
  log "Measuring source size..."
  local total_bytes; total_bytes=$(du -sb "$src_dir" 2>/dev/null | awk '{print $1}' || du -sk "$src_dir" | awk '{print $1 * 1024}')
  log "Total size to backup ($src_dir): $(format_bytes "$total_bytes")"
  debug "Source size in bytes: $total_bytes"

  # Allocate In-Memory RAM Disk
  local ram_mb="${RAM_DISK_MB:-$(calc_ram_disk_mb "$CHUNK_SIZE" "$PARALLEL_JOBS")}"
  log "Allocating ${ram_mb}MB in-memory RAM disk (formula: $CHUNK_SIZE * $PARALLEL_JOBS * 1.05)..."
  if [[ "$(uname -s)" == "Darwin" ]]; then
    local sectors=$(( ram_mb * 2048 ))
    local vol_name="StreamRAM_$$"
    debug "Running: hdiutil attach -nobrowse -nomount ram://$sectors"
    RAM_DEV=$(hdiutil attach -nobrowse -nomount "ram://$sectors" | awk '{print $1}')
    debug "Allocated device: $RAM_DEV. Formatting volume $vol_name..."
    # Format with MBR to prevent macOS from creating a 200MB EFI system partition; fallback to erasevolume
    if ! diskutil partitionDisk "$RAM_DEV" 1 MBR HFS+ "$vol_name" 100% >/dev/null 2>&1; then
      diskutil erasevolume HFS+ "$vol_name" "$RAM_DEV" >/dev/null
    fi
    RAM_PATH="/Volumes/$vol_name"
    diskutil disableJournal "$RAM_PATH" >/dev/null 2>&1 || true
  else
    RAM_PATH=$(mktemp -d /dev/shm/stream_ram_XXXXXX 2>/dev/null || mktemp -d /tmp/stream_ram_XXXXXX)
  fi
  debug "RAM disk mounted at: $RAM_PATH"

  # Step A: Encrypt AES key to RAM disk
  local key_file="$RAM_PATH/passwd.txt.gpg"
  local aes_key; aes_key=$(openssl rand -base64 32)
  printf "%s" "$aes_key" | gpg --batch --yes --trust-model always --recipient "$RECIPIENT" --encrypt > "$key_file" \
    || err "GPG encryption failed for recipient: $RECIPIENT"

  log "Uploading key to $s3_dest/passwd.txt.gpg..."
  s3_put "$key_file" "$s3_dest/passwd.txt.gpg"
  rm -f "$key_file"

  # Step B: Launch producer pipeline in background into RAM disk
  local est_chunks=$(( (total_bytes + chunk_bytes - 1) / chunk_bytes ))
  [[ $est_chunks -lt 1 ]] && est_chunks=1

  log "Starting streaming pipeline -> RAM chunks ($CHUNK_SIZE) -> S3 ($PARALLEL_JOBS concurrent workers)..."
  (
    tar -cf - -C "$(dirname "$src_dir")" "$(basename "$src_dir")" \
      | openssl enc "-$CIPHER" -salt -pbkdf2 -iter 100000 -md sha512 -pass "pass:$aes_key" \
      | split -b "$CHUNK_SIZE" - "$RAM_PATH/chunk_"
  ) &
  local producer_pid=$!
  PRODUCER_PID="$producer_pid"
  debug "Producer pipeline started (PID: $producer_pid)"

  # Step C: Live consumer loop with in-place per-worker progress & Streamer status
  local STREAMER_LABEL="${STREAMER_LABEL:-Streamer}"
  local upload_pids=" "
  local active_uploads=0
  local uploaded_idx=0
  local paused=false
  local in_progress=" "
  local available_slots=""
  for (( i=1; i<=PARALLEL_JOBS; i++ )); do
    available_slots="$available_slots $i"
  done
  local pid_slot_map=""

  allocate_slot() {
    assigned_slot=""
    local new_slots=""
    for s in $available_slots; do
      if [[ -z "$assigned_slot" ]]; then
        assigned_slot="$s"
      else
        new_slots="$new_slots $s"
      fi
    done
    available_slots="$new_slots"
  }

  release_slot() {
    local s="$1"
    local exists=false
    for existing in $available_slots; do
      [[ "$existing" == "$s" ]] && exists=true
    done
    if [[ "$exists" == false ]]; then
      available_slots="$available_slots $s"
    fi
  }

  # Initialize in-place display slots: 1 Streamer row + PARALLEL_JOBS Worker rows
  echo "Streaming & encrypting archive -> RAM chunks..." > "$RAM_PATH/.streamer_status"
  [[ -t 1 ]] && printf "\033[1;35m[%s]\033[0m Streaming & encrypting archive -> RAM chunks...\n" "$STREAMER_LABEL"
  for (( i=1; i<=PARALLEL_JOBS; i++ )); do
    echo "Idle" > "$RAM_PATH/.worker_status_$i"
    [[ -t 1 ]] && printf "\033[1;36m[Worker %d]\033[0m Idle\n" "$i"
  done

  render_workers() {
    if [[ -t 1 ]]; then
      local total_lines=$(( PARALLEL_JOBS + 1 ))
      printf "\033[%dA" "$total_lines"
      local s_st="Idle"
      [[ -f "$RAM_PATH/.streamer_status" ]] && s_st=$(cat "$RAM_PATH/.streamer_status" 2>/dev/null || echo "Idle")
      printf "\r\033[2K\033[1;35m[%s]\033[0m %s\n" "$STREAMER_LABEL" "$s_st"
      for (( i=1; i<=PARALLEL_JOBS; i++ )); do
        local st="Idle"
        [[ -f "$RAM_PATH/.worker_status_$i" ]] && st=$(cat "$RAM_PATH/.worker_status_$i" 2>/dev/null || echo "Idle")
        printf "\r\033[2K\033[1;36m[Worker %d]\033[0m %s\n" "$i" "$st"
      done
    fi
  }

  local max_ram_bytes=$(( chunk_bytes * PARALLEL_JOBS ))
  local producer_reaped=false

  while kill -0 "$producer_pid" 2>/dev/null || [[ $(find "$RAM_PATH" -name "chunk_*" 2>/dev/null | wc -l) -gt 0 ]] || [[ $active_uploads -gt 0 ]]; do
    render_workers

    # Check if producer finished or failed
    if [[ "$producer_reaped" == false ]] && ! kill -0 "$producer_pid" 2>/dev/null; then
      producer_reaped=true
      if wait "$producer_pid" 2>/dev/null; then
        echo "✓ Complete (all data streamed to RAM)" > "$RAM_PATH/.streamer_status"
      else
        local prod_rc=$?
        if [[ $prod_rc -ne 0 && $prod_rc -ne 130 ]]; then
          echo "✗ Failed with code $prod_rc" > "$RAM_PATH/.streamer_status"
          render_workers
          err "Streaming pipeline (tar/openssl/split) failed with exit code $prod_rc."
        fi
      fi
    fi

    # Prune finished upload workers, track oldest PID, and reclaim worker slots
    local alive_pids=" "
    local oldest_pid=""
    active_uploads=0
    for p in $upload_pids; do
      if kill -0 "$p" 2>/dev/null; then
        alive_pids="${alive_pids}$p "
        (( ++active_uploads ))
        [[ -z "$oldest_pid" ]] && oldest_pid="$p"
      else
        # Worker $p finished! Reclaim its slot for future chunks
        for entry in $pid_slot_map; do
          if [[ "$entry" == "$p:"* ]]; then
            local freed_slot="${entry#$p:}"
            release_slot "$freed_slot"
          fi
        done
      fi
    done
    upload_pids="$alive_pids"
    UPLOAD_PIDS="$alive_pids"

    # Scan RAM disk chunks: measure total bytes and dispatch completed chunks
    local bytes_in_ram=0
    local completed_in_ram=0
    for f in "$RAM_PATH"/chunk_*; do
      [[ -f "$f" ]] || continue
      local sz; sz=$(wc -c < "$f" 2>/dev/null | tr -d " " || echo 0)
      (( bytes_in_ram += sz ))
      local is_complete=false
      if [[ "$sz" -ge "$chunk_bytes" ]] || ! kill -0 "$producer_pid" 2>/dev/null; then
        is_complete=true
        (( ++completed_in_ram ))
      fi

      local cname; cname=$(basename "$f")
      [[ "$in_progress" == *" $cname "* ]] && continue

      if [[ "$is_complete" == true && $active_uploads -lt $PARALLEL_JOBS ]]; then
        # Allocate next free worker slot
        allocate_slot
        local w="$assigned_slot"

        in_progress="${in_progress}${cname} "
        (( ++active_uploads ))
        (( ++uploaded_idx ))
        local cur_idx="$uploaded_idx"
        debug "Dispatching [Worker $w] for $cname ($cur_idx/$est_chunks)..."
        (
          local start_sec; start_sec=$(date +%s)
          local w_log="$RAM_PATH/.worker_log_$w"
          rm -f "$w_log"
          echo "Started: $cname ($cur_idx/$est_chunks, $(format_bytes "$sz"))..." > "$RAM_PATH/.worker_status_$w"
          [[ ! -t 1 ]] && log "[Worker $w] Started: $cname ($cur_idx/$est_chunks, $(format_bytes "$sz"))..."

          # Periodic in-place update every 1 second
          (
            local elapsed=0
            while true; do
              sleep 1
              (( ++elapsed )) || true
              local progress_info=""
              if [[ -f "$w_log" ]]; then
                local last_line
                last_line=$(tr '\r' '\n' < "$w_log" 2>/dev/null | grep "Completed" | tail -n 1 2>/dev/null || true)
                if [[ -n "$last_line" ]]; then
                  local parsed
                  parsed=$(echo "$last_line" | sed -E "s/.*Completed ([0-9.]+ [A-Za-z]+)\/([0-9.]+ [A-Za-z]+) \(([^)]+)\).*/\1 \/ \2 (\3)/" 2>/dev/null || true)
                  [[ -n "$parsed" && "$parsed" != "$last_line" ]] && progress_info="$parsed"
                fi
                if [[ -z "$progress_info" ]]; then
                  last_line=$(tr '\r' '\n' < "$w_log" 2>/dev/null | grep "%" | tail -n 1 2>/dev/null || true)
                  if [[ -n "$last_line" ]]; then
                    local parsed
                    parsed=$(echo "$last_line" | awk '{for(i=1;i<=NF;i++){if($i ~ /%$/){pct=$i}; if($i ~ /B\/s$/){spd=$(i-1)" "$i}}} END {if(pct && spd) print pct", "spd; else if(pct) print pct}' 2>/dev/null || true)
                    [[ -n "$parsed" ]] && progress_info="$parsed"
                  fi
                fi
              fi

              if [[ -n "$progress_info" ]]; then
                echo "Uploading: $cname ($cur_idx/$est_chunks) [$progress_info, ${elapsed}s]" > "$RAM_PATH/.worker_status_$w"
              else
                echo "Uploading: $cname ($cur_idx/$est_chunks) [${elapsed}s elapsed]..." > "$RAM_PATH/.worker_status_$w"
              fi
            done
          ) &
          local rep_pid=$!
          trap 'kill -9 "$rep_pid" 2>/dev/null || true; rm -f "$w_log"' EXIT INT TERM

          local put_rc=0
          s3_put "$f" "$s3_dest/$cname" "$w_log" >/dev/null 2>&1 || put_rc=$?

          kill -9 "$rep_pid" 2>/dev/null || true
          wait "$rep_pid" 2>/dev/null || true
          rm -f "$w_log"

          local end_sec; end_sec=$(date +%s)
          local dur=$(( end_sec - start_sec ))
          [[ $dur -lt 1 ]] && dur=1
          local speed_str; speed_str="$(format_bytes "$(( sz / dur ))")/s"

          if [[ $put_rc -eq 0 ]]; then
            rm -f "$f"
            echo "✓ Completed: $cname ($cur_idx/$est_chunks) in ${dur}s (${speed_str})" > "$RAM_PATH/.worker_status_$w"
            [[ ! -t 1 ]] && log "[Worker $w] ✓ Completed: $cname ($cur_idx/$est_chunks) in ${dur}s (${speed_str})"
          else
            echo "✗ Failed: $cname ($cur_idx/$est_chunks)" > "$RAM_PATH/.worker_status_$w"
            err "[Worker $w] ✗ Upload failed: $cname"
          fi
        ) &
        local worker_pid=$!
        upload_pids="${upload_pids}$worker_pid "
        UPLOAD_PIDS="${UPLOAD_PIDS}$worker_pid "
        pid_slot_map="$pid_slot_map $worker_pid:$w"
        [[ -z "$oldest_pid" ]] && oldest_pid="$worker_pid"
      fi
    done

    # Flow control: Pause or resume streamer based on total bytes in RAM and worker saturation
    local should_pause=false
    if [[ $active_uploads -ge $PARALLEL_JOBS || $completed_in_ram -ge $PARALLEL_JOBS || "$bytes_in_ram" -ge "$max_ram_bytes" ]]; then
      should_pause=true
    fi

    if [[ "$producer_reaped" == false ]]; then
      if [[ "$should_pause" == true && "$paused" == false ]]; then
        debug "RAM capacity or worker saturation reached (${bytes_in_ram}B in RAM, ${completed_in_ram} completed, ${active_uploads}/${PARALLEL_JOBS} active). Pausing streamer (PID: $producer_pid)..."
        pause_producer "$producer_pid"
        paused=true
        echo "Paused (RAM capacity reached, waiting for upload slots)..." > "$RAM_PATH/.streamer_status"
      elif [[ "$should_pause" == false && "$paused" == true ]]; then
        debug "RAM capacity freed (${bytes_in_ram}B in RAM, ${completed_in_ram} completed, ${active_uploads}/${PARALLEL_JOBS} active). Resuming streamer (PID: $producer_pid)..."
        resume_producer "$producer_pid"
        paused=false
        echo "Streaming & encrypting archive -> RAM chunks..." > "$RAM_PATH/.streamer_status"
      fi
    fi

    sleep 0.05
  done

  render_workers
  if [[ "$producer_reaped" == false ]]; then
    wait "$producer_pid" 2>/dev/null
    local prod_rc=$?
    if [[ $prod_rc -ne 0 && $prod_rc -ne 130 ]]; then
      err "Streaming pipeline (tar/openssl/split) failed with exit code $prod_rc. Check disk space."
    fi
  fi

  for p in $upload_pids; do
    wait "$p" 2>/dev/null || true
  done
  render_workers
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

Options:
  -v, --verbose                          # Enable verbose debug logs (or VERBOSE=1)

Environment Variables:
  BUCKET        Remote S3 bucket name (required for 'upload')
  PREFIX        Remote S3 prefix (default: 'backups')
  S3_HOST       Custom S3 endpoint host (e.g. 's3.fr-par.scw.cloud')
  AWS_PROFILE   AWS profile for credentials (e.g. 'scaleway')
  PARALLEL_JOBS Concurrent chunk upload workers (default: 4)
  CHUNK_SIZE    Chunk split size (default: '2000m')
  RECIPIENT     GPG recipient email / key ID (default: 'i@valt.me')
  VERBOSE       Set to 1 to enable debug logs
EOF
    ;;
  *) err "Unknown command '${1:-}'. Run '$0 --help' for usage." ;;
esac
