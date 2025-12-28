#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./add-proxies.sh [--dry-run] [--no-backup] [--after N] [--file /path/to/file]

DRY_RUN=0
MAKE_BACKUP=1
INSERT_AFTER=2
TARGET_FILE="/etc/environment"

while (( "$#" )); do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --no-backup) MAKE_BACKUP=0; shift ;;
    --after) INSERT_AFTER="$2"; shift 2 ;;
    --file) TARGET_FILE="$2"; shift 2 ;;
    -h|--help) sed -n '1,200p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

PROXY_BLOCK=$'ALL_PROXY="socks5h://cloudn8n.qzz.io:1090"\nHTTP_PROXY="socks5h://cloudn8n.qzz.io:1090"\nHTTPS_PROXY="socks5h://cloudn8n.qzz.io:1090"\nFTP_PROXY="socks5h://cloudn8n.qzz.io:1090"\nRSYNC_PROXY="socks5h://cloudn8n.qzz.io:1090"\nno_proxy="localhost,127.0.0.1"'

# If target doesn't exist, use empty content
if [[ -e "$TARGET_FILE" ]]; then
  ORIG_PERMS=$(stat -c '%a' "$TARGET_FILE" 2>/dev/null || stat -f '%Lp' "$TARGET_FILE" 2>/dev/null || echo "")
fi

# Backup if requested and file exists
if [[ $MAKE_BACKUP -eq 1 && -e "$TARGET_FILE" ]]; then
  TS=$(date +%Y%m%d%H%M%S)
  BACKUP_PATH="${TARGET_FILE}.${TS}.bak"
  echo "Creating backup: $BACKUP_PATH"
  if [[ -w "$TARGET_FILE" ]]; then
    cp -- "$TARGET_FILE" "$BACKUP_PATH"
  else
    sudo cp -- "$TARGET_FILE" "$BACKUP_PATH"
  fi
fi

# Create a cleaned temp file that removes existing proxy lines (if file exists)
CLEANED="$(mktemp)"
if [[ -e "$TARGET_FILE" ]]; then
  # remove lines that begin exactly with these variable names (case sensitive)
  grep -v -E '^(ALL_PROXY|HTTP_PROXY|HTTPS_PROXY|FTP_PROXY|RSYNC_PROXY|no_proxy)=' "$TARGET_FILE" > "$CLEANED" || true
else
  # ensure an empty file
  : > "$CLEANED"
fi

# Build final file with insertion after INSERT_AFTER line (append if fewer lines)
FINAL="$(mktemp)"
TOTAL_LINES=$(wc -l < "$CLEANED" || echo 0)
if (( TOTAL_LINES < INSERT_AFTER )); then
  # copy entire cleaned file then block
  cat "$CLEANED" > "$FINAL"
  printf '%s\n' "$PROXY_BLOCK" >> "$FINAL"
else
  head -n "$INSERT_AFTER" "$CLEANED" > "$FINAL"
  printf '%s\n' "$PROXY_BLOCK" >> "$FINAL"
  tail -n +"$((INSERT_AFTER + 1))" "$CLEANED" >> "$FINAL"
fi

# Dry run prints diff and exits
if [[ $DRY_RUN -eq 1 ]]; then
  echo "=== Proposed final content ==="
  cat "$FINAL"
  echo
  echo "=== Unified diff (orig -> final) ==="
  if [[ -e "$TARGET_FILE" && -x "$(command -v diff)" ]]; then
    diff -u "$TARGET_FILE" "$FINAL" || true
  fi
  rm -f "$CLEANED" "$FINAL"
  exit 0
fi

# Move final into place (use sudo if necessary)
echo "Writing changes to $TARGET_FILE"
if [[ ! -e "$TARGET_FILE" || -w "$TARGET_FILE" ]]; then
  mv "$FINAL" "$TARGET_FILE"
else
  sudo mv "$FINAL" "$TARGET_FILE"
fi

rm -f "$CLEANED"
echo "Done."
if [[ -n "${BACKUP_PATH:-}" ]]; then
  echo "Backup saved to: $BACKUP_PATH"
fi
echo "You may need to re-login or 'source /etc/environment' for changes to take effect."


