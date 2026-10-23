#!/usr/bin/env bash
# ==============================================================================
# stream-backup.sh - Encrypted, deduplicated backups using restic
# ==============================================================================
set -euo pipefail

# Ensure standard user tool paths and terminal TTY are accessible
export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"
export GPG_TTY="${GPG_TTY:-$(tty 2>/dev/null || true)}"

if ! command -v restic >/dev/null 2>&1; then
  echo "[ERROR] restic is not installed. Run: brew install restic" >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# Configuration & S3 Credentials
# ------------------------------------------------------------------------------
BUCKET="${BUCKET:-}"
PREFIX="${PREFIX:-backups}"
S3_HOST="${S3_HOST:-s3.amazonaws.com}"
AWS_PROFILE="${AWS_PROFILE:-}"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"
PACK_SIZE_MB="${PACK_SIZE_MB:-128}"
RECIPIENT="${RECIPIENT:-i@valt.me}"
KEY_FILE="${KEY_FILE:-$HOME/.config/stream-backup/key.gpg}"

# Extract credentials from ~/.aws/credentials when AWS_PROFILE is set
if [[ -n "$AWS_PROFILE" && -f "$HOME/.aws/credentials" ]]; then
  get_cred() {
    awk -F'=' -v profile="[$AWS_PROFILE]" -v field="$1" '
      $0 == profile { in_profile = 1; next }
      /^\[/         { in_profile = 0 }
      in_profile && $0 ~ field {
        gsub(/[[:space:]]/, "", $2)
        print $2
      }
    ' "$HOME/.aws/credentials"
  }
  export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-$(get_cred aws_access_key_id)}"
  export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-$(get_cred aws_secret_access_key)}"
fi

# Automatically infer region for Scaleway endpoints (e.g., s3.fr-par.scw.cloud)
if [[ -z "${AWS_DEFAULT_REGION:-}" && "$S3_HOST" =~ \.([a-z0-9-]+)\.scw\.cloud ]]; then
  export AWS_DEFAULT_REGION="${BASH_REMATCH[1]}"
fi

# ------------------------------------------------------------------------------
# Encryption Key Management (via GPG)
# ------------------------------------------------------------------------------
# If no password is provided in environment, decrypt GPG key once into RESTIC_PASSWORD
if [[ -z "${RESTIC_PASSWORD:-}" && -z "${RESTIC_PASSWORD_FILE:-}" && -z "${RESTIC_PASSWORD_COMMAND:-}" ]]; then
  if [[ ! -f "$KEY_FILE" ]]; then
    echo "[INFO] Creating new GPG-encrypted key for $RECIPIENT at $KEY_FILE..."
    mkdir -p "$(dirname "$KEY_FILE")"
    head -c 32 /dev/urandom | gpg --batch --yes --trust-model always --encrypt -r "$RECIPIENT" -o "$KEY_FILE"
  fi
  RESTIC_PASSWORD="$(gpg --quiet --decrypt "$KEY_FILE")"
  export RESTIC_PASSWORD
fi

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------
get_repository_url() {
  local target="$1"
  local mode="${2:-auto}"  # "local", "remote", or "auto"

  if [[ "$mode" == "local" || ( "$mode" != "remote" && ( "$target" == /* || "$target" == ./* || -z "$BUCKET" ) ) ]]; then
    if [[ "$target" == /* ]]; then
      echo "$target"
    else
      echo "$PWD/$target"
    fi
  else
    local host="$S3_HOST"
    [[ "$host" =~ ^https?:// ]] || host="https://$host"
    echo "s3:${host}/${BUCKET}/${PREFIX}/${target#s3://}"
  fi
}

ensure_repository_ready() {
  local repo_url="$1"

  # Initialize repository if config does not exist, otherwise unlock any stale locks
  if ! restic -r "$repo_url" cat config >/dev/null 2>&1; then
    echo "[INFO] Initializing new restic repository at $repo_url..."
    restic -r "$repo_url" init
  else
    restic -r "$repo_url" unlock >/dev/null 2>&1 || true
  fi
}

RESTIC_OPTIONS=(
  -o "s3.connections=${PARALLEL_JOBS}"
  --pack-size "${PACK_SIZE_MB}"
)

# ------------------------------------------------------------------------------
# Commands
# ------------------------------------------------------------------------------
do_backup() {
  local raw_source="$1"
  local target="$2"
  local mode="$3"  # "local" or "remote"

  local clean_source="${raw_source%/}"
  local source_dir
  local source_name
  source_dir="$(cd "$(dirname "$clean_source")" && pwd)"
  source_name="$(basename "$clean_source")"

  local repo_url
  repo_url="$(get_repository_url "$target" "$mode")"

  ensure_repository_ready "$repo_url"

  echo "[INFO] Backing up: $source_dir/$source_name"
  echo "[INFO] Target:     $repo_url"

  (
    cd "$source_dir"
    restic -r "$repo_url" "${RESTIC_OPTIONS[@]}" backup "$source_name"
  )
}

do_restore() {
  local target="$1"
  local dest_dir="$2"
  local snapshot_id="${3:-latest}"

  local repo_url
  repo_url="$(get_repository_url "$target" "auto")"

  mkdir -p "$dest_dir"
  local abs_dest
  abs_dest="$(cd "$dest_dir" && pwd)"

  echo "[INFO] Restoring snapshot '$snapshot_id' to $abs_dest..."
  restic -r "$repo_url" restore "$snapshot_id" --target "$abs_dest"
}

show_help() {
  cat <<EOF
Usage: $0 <command> [arguments...]

Commands:
  backup    <source_dir> <local_repo>           Back up locally to an encrypted restic repo
  upload    <source_dir> <remote_name>          Back up directly to remote S3
  restore   <repo_or_remote> <dest> [snapshot]  Restore files (default: latest snapshot)
  snapshots <repo_or_remote>                    List all snapshots in repository
  check     <repo_or_remote>                    Verify cryptographic and data integrity

Environment Variables:
  S3 & Remote Storage:
    BUCKET                  S3 bucket name (required for upload)
    PREFIX                  S3 prefix path (default: backups)
    S3_HOST                 S3 endpoint host (e.g. s3.fr-par.scw.cloud, default: s3.amazonaws.com)
    AWS_PROFILE             AWS profile in ~/.aws/credentials (e.g. scaleway)
    AWS_ACCESS_KEY_ID       AWS / S3 access key ID (overrides profile lookup)
    AWS_SECRET_ACCESS_KEY   AWS / S3 secret access key (overrides profile lookup)
    AWS_DEFAULT_REGION      AWS / S3 region (auto-inferred from S3_HOST if matching .<region>.scw.cloud)
    PARALLEL_JOBS           Number of concurrent S3 connections (default: 4)
    PACK_SIZE_MB            Target restic pack size in MiB [4..128] (default: 128)

  Encryption & Key Management:
    RECIPIENT               GPG recipient for repository key encryption (default: i@valt.me)
    KEY_FILE                Path to GPG-encrypted key file (default: ~/.config/stream-backup/key.gpg)
    RESTIC_PASSWORD         Direct repository password override
    RESTIC_PASSWORD_FILE    Path to plaintext password file override
    RESTIC_PASSWORD_COMMAND Custom command returning repository password override
EOF
}

# ------------------------------------------------------------------------------
# CLI Dispatcher
# ------------------------------------------------------------------------------
case "${1:-}" in
  -h|--help|help)
    show_help
    exit 0
    ;;

  backup)
    [[ $# -ge 3 ]] || { echo "Usage: $0 backup <source_dir> <local_repo>" >&2; exit 1; }
    do_backup "$2" "$3" "local"
    ;;

  upload)
    [[ $# -ge 3 ]] || { echo "Usage: $0 upload <source_dir> <remote_name>" >&2; exit 1; }
    do_backup "$2" "$3" "remote"
    ;;

  restore)
    [[ $# -ge 3 ]] || { echo "Usage: $0 restore <repo_or_remote> <dest_dir> [snapshot_id]" >&2; exit 1; }
    do_restore "$2" "$3" "${4:-latest}"
    ;;

  snapshots)
    [[ $# -ge 2 ]] || { echo "Usage: $0 snapshots <repo_or_remote>" >&2; exit 1; }
    restic -r "$(get_repository_url "$2")" snapshots
    ;;

  check)
    [[ $# -ge 2 ]] || { echo "Usage: $0 check <repo_or_remote>" >&2; exit 1; }
    restic -r "$(get_repository_url "$2")" check --read-data
    ;;

  *)
    show_help >&2
    exit 1
    ;;
esac
