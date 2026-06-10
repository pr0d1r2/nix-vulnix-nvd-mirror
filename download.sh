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
    rm -rf "$outdir"
}
trap cleanup_on_failure ERR

_fetch_api_feed() {
    local url="$1"
    local dest="$2"
    local start_index=0
    local total_results=-1
    local tmppage tmpjson page_url
    local -a curl_cmd
    tmppage=$(mktemp)
    tmpjson=$(mktemp)
    echo '[]' > "$tmpjson"

    while [ "$total_results" -eq -1 ] || [ "$start_index" -lt "$total_results" ]; do
        page_url="${url}&startIndex=${start_index}&resultsPerPage=${results_per_page}"

        curl_cmd=(curl -fsSL --retry 3 --retry-delay 60 --max-time 300)
        if [ -n "${NVD_API_KEY:-}" ]; then
            curl_cmd+=(-H "apiKey: $NVD_API_KEY")
        fi
        curl_cmd+=(-o "$tmppage" "$page_url")

        if ! "${curl_cmd[@]}"; then
            rm -f "$tmppage" "$tmpjson"
            return 1
        fi

        if [ "$total_results" -eq -1 ]; then
            if ! total_results=$(jq -r '.totalResults // 0' "$tmppage"); then
                rm -f "$tmppage" "$tmpjson"
                return 1
            fi
        fi

        if ! jq -s '.[0] + (.[1].vulnerabilities // [])' "$tmpjson" "$tmppage" > "${tmpjson}.new"; then
            rm -f "$tmppage" "$tmpjson" "${tmpjson}.new"
            return 1
        fi
        mv "${tmpjson}.new" "$tmpjson"

        start_index=$((start_index + results_per_page))

        if [ "$start_index" -lt "$total_results" ]; then
            sleep "$rate_delay"
        fi
    done

    local total_assembled
    if [ "$total_results" -eq -1 ]; then
        total_assembled=0
    else
        total_assembled=$total_results
    fi

    if ! jq -n --slurpfile vulns "$tmpjson" \
        --argjson total "$total_assembled" \
        '{resultsPerPage: ($vulns[0] | length), startIndex: 0, totalResults: $total, vulnerabilities: $vulns[0]}' \
        | gzip > "$dest"; then
        rm -f "$tmppage" "$tmpjson"
        return 1
    fi

    rm -f "$tmppage" "$tmpjson"
    return 0
}

download_with_retry() {
    local url="$1"
    local dest="$2"
    local attempt=1

    while [ "$attempt" -le "$max_retries" ]; do
        local exit_code=0
        _fetch_api_feed "$url" "$dest" || exit_code=$?

        if [ "$exit_code" -eq 0 ] && gzip -t "$dest" 2>/dev/null; then
            local checksum
            checksum=$(sha256sum "$dest" | cut -d' ' -f1)
            echo "$checksum  $(basename "$dest")" >> "$checksum_file"
            echo "OK: $(basename "$dest") (SHA256: $checksum)"
            return 0
        fi
        rm -f "$dest"
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
