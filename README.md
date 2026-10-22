# stream-backup.sh: Stream-Encrypted Backups

A concise, single-file Bash shell script (~175 lines) with strict input validation, linear execution, and zero branching.

---

## 3 Core Features

1. **`backup <source_dir> <output_dir>`**: Stream archive, encrypt (AES-256-CBC), and split directly into a local folder.
2. **`upload <source_dir> <remote_name>`**: Stream archive, encrypt, split, and upload directly to remote S3 storage in parallel with live progress.
3. **`restore <backup_dir> <dest_dir>`**: Stream decrypt chunks on the fly and unpack directly into target directory.

---

## Requirements

Install standard CLI utilities:

```bash
# macOS (Homebrew)
brew install pv s3cmd
# (Optionally awscli: brew install awscli)

# Ubuntu / Debian
apt-get install -y pv s3cmd
```

---

## Usage

### 1. Create a Local Encrypted Backup

Streams `<source_dir>` directly through `tar | pv | openssl enc | split` into encrypted chunks in `<output_dir>`:

```bash
./stream-backup.sh backup ~/Desktop/screenshots ./my_local_backup
```

Produces:
```text
my_local_backup/
├── chunk_aa
├── chunk_ab
└── passwd.txt.gpg
```

---

### 2. Stream, Encrypt & Upload Directly to S3

Streams `<source_dir>`, encrypts it into chunks in temporary storage, and uploads `passwd.txt.gpg` and all chunks to `s3://$BUCKET/$PREFIX/<remote_name>/` using parallel workers. All temporary chunks are automatically wiped upon completion:

```bash
CHUNK_SIZE=1m \
AWS_PROFILE=scaleway \
BUCKET=googledrive \
S3_HOST=s3.fr-par.scw.cloud \
./stream-backup.sh upload ~/Desktop/screenshots screenshots_backup
```

---

### 3. Restore from a Local Backup Folder

Streams chunks on the fly through `cat | pv | openssl enc -d | tar -xf -`:

```bash
./stream-backup.sh restore ./my_local_backup ./restored_screenshots
```

---

## Environment Variables

| Variable | Description | Default |
| :--- | :--- | :--- |
| `BUCKET` | Remote S3 bucket name (required for `upload`) | `""` |
| `PREFIX` | Remote S3 prefix path (for `upload`) | `backups` |
| `S3_HOST` | Custom S3 endpoint host (e.g. `s3.fr-par.scw.cloud`) | `""` (AWS default) |
| `AWS_PROFILE` | AWS profile name for credentials | `""` |
| `PARALLEL_JOBS` | Concurrent chunk upload workers | `4` |
| `RAM_DISK_MB` | In-memory RAM disk size in MB (for `upload`) | Auto (`chunk_size * parallel_jobs * 1.05`) |
| `CHUNK_SIZE` | Chunk split size | `2000m` |
| `CIPHER` | OpenSSL cipher algorithm | `aes-256-cbc` |
| `RECIPIENT` | GPG recipient email / key ID | `i@valt.me` |
