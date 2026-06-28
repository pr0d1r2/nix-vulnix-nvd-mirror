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
: > "$checksum_file"

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
            jq '.vulnerabilities // []' "$body" > "$dest_dir/page-${start_index}.json"
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
            jitter=$((RANDOM % (delay / 5 + 1)))   # ~+20% jitter
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
    local feed stage ckpt start_index total_results agg count

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
        printf 'lastIndex=%s\ntotalResults=%s\n' "$start_index" "$total_results" > "$ckpt"
        if [ "$start_index" -lt "$total_results" ]; then
            sleep "$rate_delay"
        fi
    done

    # Aggregate all pages, dedup by CVE id keeping newest lastModified (§V.31).
    agg=$(cat "$stage"/page-*.json 2>/dev/null \
        | jq -s 'add // [] | group_by(.cve.id) | map(max_by(.cve.lastModified))')
    count=$(printf '%s' "$agg" | jq 'length')

    # Completeness guard: deduped count must meet the reported total (§V.31).
    if [ "$total_results" -gt 0 ] && [ "$count" -lt "$total_results" ]; then
        return 1
    fi

    # Deterministic gzip (§V.41) into staging, validate, atomic move (§V.32).
    printf '%s' "$agg" | jq --argjson t "$count" \
        '{resultsPerPage: length, startIndex: 0, totalResults: $t, vulnerabilities: .}' \
        | gzip -n > "$stage/feed.json.gz"
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
            echo "$checksum  $(basename "$dest")" >> "$checksum_file"
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

for year in $(seq "$start_year" "$current_year"); do
    download_with_retry \
        "${nvd_api_url}?pubStartDate=${year}-01-01T00:00:00.000&pubEndDate=${year}-12-31T23:59:59.999" \
        "$outdir/nvdcve-2.0-${year}.json.gz"
done

mod_start=$(date -u -d "120 days ago" +%Y-%m-%dT00:00:00.000 2>/dev/null || date -u -v-120d +%Y-%m-%dT00:00:00.000)
mod_end=$(date -u +%Y-%m-%dT23:59:59.999)
download_with_retry \
    "${nvd_api_url}?lastModStartDate=${mod_start}&lastModEndDate=${mod_end}" \
    "$outdir/nvdcve-2.0-modified.json.gz"

echo "Verifying checksums..."
(cd "$outdir" && sha256sum -c sha256sums.txt)

echo "Mirror complete: $(find "$outdir" -maxdepth 1 -name '*.json.gz' | wc -l) feeds downloaded"
