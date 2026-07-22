#!/usr/bin/env bash
set -Eeuo pipefail

nvd_api_url="${NVD_MIRROR_URL:-https://services.nvd.nist.gov/rest/json/cves/2.0}"
outdir="public"
current_year=$(date +%Y)
start_year=$((current_year - 5))
max_retries=3
base_delay=60
results_per_page="${NVD_RESULTS_PER_PAGE:-2000}"
rate_delay="${NVD_RATE_DELAY:-6}"
notification_webhook_url="${NOTIFICATION_WEBHOOK_URL:-}"
# Per-page resilience + continuation (SPEC §V.28-§V.32).
max_page_retries="${MAX_PAGE_RETRIES:-6}"
page_base_delay="${PAGE_BASE_DELAY:-5}"
page_max_delay="${PAGE_MAX_DELAY:-300}"
# Checkpoint staging lives OUTSIDE the deployed public/ (§V.30, §V.32).
staging_dir="${STAGING_DIR:-${TMPDIR:-/tmp}/nvd-part}"
# Incremental mirror (§V.2, §V.35-§V.39).
# window_days = NVD's hard cap / bootstrap chunk size (§V.36). daily_window_days
# = the daily lastMod lookback (§V.35): small enough to stay fast + bounded,
# large enough to self-heal multi-day outages.
window_days="${WINDOW_DAYS:-120}"
daily_window_days="${DAILY_WINDOW_DAYS:-7}"
# The published modified feed is a SMALL recent slice (decoupled from the wider
# merge window) so it never approaches GitHub's 100MB/file git limit even when
# NVD mass-modifies. The full window still merges into the year buckets.
modified_days="${MODIFIED_DAYS:-2}"
pages_url="${PAGES_URL:-https://pr0d1r2.github.io/nix-vulnix-nvd-mirror}"
is_bootstrap=0

# Portable UTC date helpers (GNU date -d, BSD date -v fallback).
day_start() {
  date -u -d "$1 days ago" +%Y-%m-%dT00:00:00.000 2>/dev/null ||
    date -u -v-"$1"d +%Y-%m-%dT00:00:00.000
}
day_end() {
  date -u -d "$1 days ago" +%Y-%m-%dT23:59:59.999 2>/dev/null ||
    date -u -v-"$1"d +%Y-%m-%dT23:59:59.999
}
now_end() { date -u +%Y-%m-%dT23:59:59.999; }

send_failure_notification() {
  if [ -z "$notification_webhook_url" ]; then
    return 0
  fi
  curl -fsSL --max-time 30 -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"text\":\"NVD mirror download failed at $(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
    "$notification_webhook_url" >/dev/null 2>&1 || true
}

mkdir -p "$outdir"
checksum_file="$outdir/sha256sums.txt"
: >"$checksum_file"

cleanup_on_failure() {
  echo "Download failed; removing partial output directory" >&2
  send_failure_notification
  rm -rf "$outdir" "$staging_dir"
}
trap cleanup_on_failure ERR

# Fetch one page with per-page exponential backoff + jitter (§V.28) and
# Retry-After handling on 429/503 (§V.29). On success writes the page's
# vulnerabilities[] to "$dest_dir/page-<start_index>.json" and leaves the raw
# body at "$dest_dir/.body" (so the caller can read totalResults). Returns
# non-zero only after exhausting max_page_retries.
_fetch_page() {
  local url="$1"
  local start_index="$2"
  local dest_dir="$3"
  local page_url="${url}&startIndex=${start_index}&resultsPerPage=${results_per_page}"
  local hdr="$dest_dir/.hdr"
  local body="$dest_dir/.body"
  local attempt=1
  local -a curl_cmd
  local http_code delay jitter retry_after

  while [ "$attempt" -le "$max_page_retries" ]; do
    curl_cmd=(curl -sS -D "$hdr" -o "$body" -w '%{http_code}'
      --retry 3 --retry-delay 60 --max-time 300)
    if [ -n "${NVD_API_KEY:-}" ]; then
      curl_cmd+=(-H "apiKey: $NVD_API_KEY")
    fi
    curl_cmd+=("$page_url")

    http_code=$("${curl_cmd[@]}" 2>/dev/null || echo "000")

    if [ "$http_code" = "200" ] && jq -e . "$body" >/dev/null 2>&1; then
      jq '.vulnerabilities // []' "$body" >"$dest_dir/page-${start_index}.json"
      return 0
    fi

    if [ "$attempt" -eq "$max_page_retries" ]; then
      return 1
    fi

    # Honor server back-pressure (§V.29): on 429/503, sleep Retry-After.
    retry_after=""
    if [ "$http_code" = "429" ] || [ "$http_code" = "503" ]; then
      retry_after=$(grep -i '^Retry-After:' "$hdr" 2>/dev/null | tr -d '\r' | awk '{print $2}' | head -1)
    fi
    if [ -n "$retry_after" ]; then
      sleep "$retry_after"
    else
      delay=$((page_base_delay * (2 ** (attempt - 1))))
      [ "$delay" -gt "$page_max_delay" ] && delay=$page_max_delay
      jitter=$((RANDOM % (delay / 5 + 1))) # ~+20% jitter
      sleep "$((delay + jitter))"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

# Drive pagination for one feed via a checkpoint dir OUTSIDE public/ (§V.30):
# resume from lastIndex, aggregate + dedup by CVE id (§V.31), completeness
# guard, deterministic gzip -n (§V.41), atomic move (§V.32).
_fetch_api_feed() {
  local url="$1"
  local dest="$2"
  local feed stage ckpt start_index total_results count

  feed=$(basename "$dest" .json.gz)
  stage="${staging_dir}/${feed}"
  mkdir -p "$stage"
  ckpt="$stage/checkpoint"

  start_index=0
  total_results=-1
  if [ -f "$ckpt" ]; then
    start_index=$(sed -n 's/^lastIndex=//p' "$ckpt")
    total_results=$(sed -n 's/^totalResults=//p' "$ckpt")
    [ -n "$start_index" ] || start_index=0
    [ -n "$total_results" ] || total_results=-1
  fi

  while [ "$total_results" -eq -1 ] || [ "$start_index" -lt "$total_results" ]; do
    if ! _fetch_page "$url" "$start_index" "$stage"; then
      return 1
    fi
    if [ "$total_results" -eq -1 ]; then
      total_results=$(jq -r '.totalResults // 0' "$stage/.body")
    fi
    start_index=$((start_index + results_per_page))
    printf 'lastIndex=%s\ntotalResults=%s\n' "$start_index" "$total_results" >"$ckpt"
    if [ "$start_index" -lt "$total_results" ]; then
      sleep "$rate_delay"
    fi
  done

  # Aggregate all pages, dedup by CVE id keeping newest lastModified (§V.31).
  # §V.50 — a window can be 100k+ CVEs (~100MB); never capture it into a shell
  # variable (bash segfaults). Stream pages -> file, process jq from files.
  cat "$stage"/page-*.json 2>/dev/null |
    jq -s 'add // [] | group_by(.cve.id) | map(max_by(.cve.lastModified))' \
      >"$stage/agg.json"
  count=$(jq 'length' "$stage/agg.json")

  # Completeness guard: deduped count must meet the reported total (§V.31).
  if [ "$total_results" -gt 0 ] && [ "$count" -lt "$total_results" ]; then
    return 1
  fi

  # Deterministic gzip (§V.41) into staging, validate, atomic move (§V.32).
  jq '{resultsPerPage: length, startIndex: 0, totalResults: length, vulnerabilities: .}' \
    "$stage/agg.json" | gzip -n >"$stage/feed.json.gz"
  if ! gzip -t "$stage/feed.json.gz" 2>/dev/null; then
    return 1
  fi
  mv "$stage/feed.json.gz" "$dest"
  rm -rf "$stage"
  return 0
}

download_with_retry() {
  local url="$1"
  local dest="$2"
  local attempt=1
  local exit_code checksum delay

  while [ "$attempt" -le "$max_retries" ]; do
    exit_code=0
    # _fetch_api_feed resumes from its checkpoint (§V.30), so a feed-level
    # retry continues rather than restarting; staging is NOT deleted here.
    _fetch_api_feed "$url" "$dest" || exit_code=$?

    if [ "$exit_code" -eq 0 ] && gzip -t "$dest" 2>/dev/null; then
      checksum=$(sha256sum "$dest" | cut -d' ' -f1)
      echo "$checksum  $(basename "$dest")" >>"$checksum_file"
      echo "OK: $(basename "$dest") (SHA256: $checksum)"
      return 0
    fi
    if [ "$attempt" -eq "$max_retries" ]; then
      echo "FAIL: $url after $max_retries attempts" >&2
      return 1
    fi
    delay=$((base_delay * (2 ** (attempt - 1))))
    echo "Retry $(basename "$dest") in ${delay}s..." >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

# Seed public/ from the previously-published mirror (§V.37): the accumulated
# timeline. Empty/unreachable prior state ⇒ bootstrap.
seed_prior_state() {
  local year feed found=0
  for year in $(seq "$start_year" "$current_year"); do
    feed="nvdcve-2.0-${year}.json.gz"
    if curl -fsSL --retry 3 --retry-delay 10 --max-time 120 \
      -o "$outdir/$feed" "$pages_url/$feed" 2>/dev/null &&
      gzip -t "$outdir/$feed" 2>/dev/null; then
      found=$((found + 1))
    else
      rm -f "$outdir/$feed"
    fi
  done
  if [ "$found" -eq 0 ]; then
    is_bootstrap=1
  fi
}

# Upsert a fetched window's CVEs into per-id-year buckets (§V.38): bucket =
# the YYYY in the CVE id; newest lastModified wins. Rewrites the modified feed,
# emits empty feeds for in-window years with no CVEs (§V.5), prunes out-of-window
# buckets, and in December pre-publishes an empty next-year feed.
merge_window() {
  local window_gz="$1"
  local year bucket f y
  # §V.50 — file/stream-based merge: feed payloads (25k+ CVEs, ~100MB) must
  # never pass through a shell variable or `jq --argjson` (argv overflow ->
  # crash). jq reads from files (--slurpfile) so memory/argv stay bounded.
  local d="$staging_dir/merge"
  rm -rf "$d"
  mkdir -p "$d"
  gzip -dc "$window_gz" | jq '.vulnerabilities // []' >"$d/win.json"

  # modified feed = the recent slice of the window (last modified_days), NOT
  # the whole merge window (§V.38) — keeps it small while the full window is
  # still upserted into the year buckets below.
  local mod_cutoff
  mod_cutoff="$(day_start "$modified_days")"
  jq --arg c "$mod_cutoff" \
    '[ .[] | select(.cve.lastModified >= $c) ]
        | {resultsPerPage: length, startIndex: 0, totalResults: length, vulnerabilities: .}' \
    "$d/win.json" | gzip -n >"$outdir/nvdcve-2.0-modified.json.gz"

  for year in $(seq "$start_year" "$current_year"); do
    bucket="$outdir/nvdcve-2.0-${year}.json.gz"
    if [ -f "$bucket" ]; then
      gzip -dc "$bucket" | jq '.vulnerabilities // []' >"$d/existing.json"
    else
      echo '[]' >"$d/existing.json"
    fi
    jq --arg y "CVE-${year}-" '[.[] | select(.cve.id | startswith($y))]' \
      "$d/win.json" >"$d/winyear.json"
    # Upsert by CVE id, newest lastModified wins (§V.38), all from files.
    jq -n --slurpfile a "$d/existing.json" --slurpfile b "$d/winyear.json" \
      '($a[0] + $b[0]) | group_by(.cve.id) | map(max_by(.cve.lastModified))
            | {resultsPerPage: length, startIndex: 0, totalResults: length, vulnerabilities: .}' |
      gzip -n >"$d/bucket.gz"
    mv "$d/bucket.gz" "$bucket"
  done
  rm -rf "$d"

  # Prune buckets whose id-year is outside the rolling window (§V.38).
  for f in "$outdir"/nvdcve-2.0-[0-9][0-9][0-9][0-9].json.gz; do
    [ -e "$f" ] || continue
    y=$(basename "$f" | sed -n 's/^nvdcve-2.0-\([0-9]\{4\}\)\.json\.gz$/\1/p')
    [ -n "$y" ] || continue
    if [ "$y" -lt "$start_year" ] || [ "$y" -gt "$current_year" ]; then
      rm -f "$f"
    fi
  done

  # December: pre-publish an empty next-year feed to survive the UTC rollover.
  if [ "$(date -u +%m)" = "12" ]; then
    local nyf="$outdir/nvdcve-2.0-$((current_year + 1)).json.gz"
    [ -f "$nyf" ] || echo '[]' |
      jq '{resultsPerPage:0,startIndex:0,totalResults:0,vulnerabilities:[]}' |
      gzip -n >"$nyf"
  fi
}

# One-time backfill via sequential ≤120-day pubStart/End windows (§V.39).
bootstrap() {
  local start_epoch now_epoch span off s e win_gz
  start_epoch=$(date -u -d "${start_year}-01-01 UTC" +%s 2>/dev/null ||
    date -u -j -f "%Y-%m-%d %H:%M:%S" "${start_year}-01-01 00:00:00" +%s)
  now_epoch=$(date -u +%s)
  span=$(((now_epoch - start_epoch) / 86400 + 1))

  off=0
  while [ "$off" -lt "$span" ]; do
    s=$(day_start $((off + window_days - 1)))
    e=$(day_end "$off")
    win_gz="$staging_dir/bootstrap-window.json.gz"
    rm -f "$win_gz"
    download_with_retry \
      "${nvd_api_url}?pubStartDate=${s}&pubEndDate=${e}" "$win_gz"
    merge_window "$win_gz"
    rm -f "$win_gz"
    off=$((off + window_days))
  done
}

mkdir -p "$staging_dir"

seed_prior_state

if [ "$is_bootstrap" -eq 1 ]; then
  echo "No prior state found; bootstrapping full history..."
  bootstrap
fi

# Daily incremental: a single small lastMod window (§V.35), then upsert.
win_gz="$staging_dir/window.json.gz"
rm -f "$win_gz"
download_with_retry \
  "${nvd_api_url}?lastModStartDate=$(day_start $((daily_window_days - 1)))&lastModEndDate=$(now_end)" \
  "$win_gz"
merge_window "$win_gz"
rm -f "$win_gz"

# Checksums over the published feeds (rebuild; window temps are not included).
: >"$checksum_file"
for f in "$outdir"/nvdcve-2.0-*.json.gz; do
  [ -e "$f" ] || continue
  echo "$(sha256sum "$f" | cut -d' ' -f1)  $(basename "$f")" >>"$checksum_file"
done

echo "Verifying checksums..."
(cd "$outdir" && sha256sum -c sha256sums.txt)

echo "Mirror complete: $(find "$outdir" -maxdepth 1 -name '*.json.gz' | wc -l) feeds"
