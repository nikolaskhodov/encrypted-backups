# stream-backup.sh - Lean Restic Backup Wrapper

A lean Bash wrapper (~90 lines, 2 screens tall) around **`restic`** with zero external transport dependencies (no `aws` CLI, no `s3cmd`, no `tar`, no `split`, no RAM disk).

---

## Requirements

```bash
# macOS (Homebrew)
brew install restic gnupg
```

---

## Commands

```bash
# Local backup
./stream-backup.sh backup ~/Desktop/screenshots ./my_local_backup

# Remote backup directly to S3
AWS_PROFILE=scaleway \
BUCKET=googledrive \
S3_HOST=s3.fr-par.scw.cloud \
./stream-backup.sh upload ~/UE/ ue-test

# Restore from local repo or remote S3
./stream-backup.sh restore ./my_local_backup ./restored_screenshots
# or from S3:
AWS_PROFILE=scaleway BUCKET=googledrive S3_HOST=s3.fr-par.scw.cloud \
./stream-backup.sh restore ue-test ./restored_ue

# List snapshots
./stream-backup.sh snapshots ./my_local_backup

# Verify repository integrity
./stream-backup.sh check ./my_local_backup
```

---

## Configuration (Environment Variables)

### S3 & Remote Storage
| Variable | Description | Default |
| :--- | :--- | :--- |
| `BUCKET` | S3 bucket name (required for `upload`) | `""` |
| `PREFIX` | S3 prefix path | `backups` |
| `S3_HOST` | S3 endpoint host (e.g. `s3.fr-par.scw.cloud`) | `s3.amazonaws.com` |
| `AWS_PROFILE` | AWS profile in `~/.aws/credentials` | `""` |
| `AWS_ACCESS_KEY_ID` | AWS / S3 access key ID (overrides profile) | Auto from profile |
| `AWS_SECRET_ACCESS_KEY` | AWS / S3 secret access key (overrides profile) | Auto from profile |
| `AWS_DEFAULT_REGION` | AWS / S3 region (auto-inferred from `S3_HOST`) | Auto |
| `PARALLEL_JOBS` | Concurrent S3 connections (`-o s3.connections`) | `4` |
| `PACK_SIZE_MB` | Target restic pack size in MiB (`4`–`128`) | `128` |

### Encryption & Key Management
| Variable | Description | Default |
| :--- | :--- | :--- |
| `RECIPIENT` | GPG recipient email / key ID for key encryption | `i@valt.me` |
| `KEY_FILE` | Path to GPG-encrypted key file | `~/.config/stream-backup/key.gpg` |
| `RESTIC_PASSWORD` | Direct repository password override | `""` |
| `RESTIC_PASSWORD_FILE` | Path to plaintext password file override | `""` |
| `RESTIC_PASSWORD_COMMAND` | Custom command returning repository password override | `""` |
