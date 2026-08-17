#!/usr/bin/env bash
set -Eeuo pipefail

pages_url="${PAGES_URL:-https://pr0d1r2.github.io/nix-vulnix-nvd-mirror}"
current_year=$(date +%Y)
start_year=$((current_year - 5))
max_attempts=5
attempt_delay=30

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

feeds=()
for year in $(seq "$start_year" "$current_year"); do
  feeds+=("nvdcve-2.0-${year}.json.gz")
done
feeds+=("nvdcve-2.0-modified.json.gz")

check_feed() {
  local file="$1"
  local url="${pages_url}/${file}"
  local dest="$tmpdir/$file"

  if curl -fsSL --retry 3 --retry-delay 60 --max-time 300 -o "$dest" "$url" && gzip -t "$dest"; then
    echo "OK: $file"
    return 0
  fi
  rm -f "$dest"
  echo "FAIL: $file" >&2
  return 1
}

attempt=1
while [ "$attempt" -le "$max_attempts" ]; do
  all_ok=true
  for feed in "${feeds[@]}"; do
    if ! check_feed "$feed"; then
      all_ok=false
      break
    fi
  done

  if $all_ok; then
    echo "Health check passed: all ${#feeds[@]} feeds verified"
    exit 0
  fi

  if [ "$attempt" -eq "$max_attempts" ]; then
    echo "Health check failed after $max_attempts attempts" >&2
    exit 1
  fi

  echo "Attempt $attempt/$max_attempts failed, retrying in ${attempt_delay}s..." >&2
  sleep "$attempt_delay"
  attempt=$((attempt + 1))
done
