#!/usr/bin/env bash
set -euo pipefail

mirror="${NVD_MIRROR_URL:-https://nvd.nist.gov/feeds/json/cve/2.0}"
outdir="public"
current_year=$(date +%Y)
start_year=$((current_year - 5))
max_retries=3
base_delay=60

mkdir -p "$outdir"

cleanup_on_failure() {
    echo "Download failed; removing partial output directory" >&2
    rm -rf "$outdir"
}
trap cleanup_on_failure ERR

download_with_retry() {
    local url="$1"
    local dest="$2"
    local attempt=1

    while [ "$attempt" -le "$max_retries" ]; do
        if curl -fsSL --retry 3 --retry-delay 60 --max-time 300 -o "$dest" "$url" && gzip -t "$dest"; then
            echo "OK: $(basename "$dest")"
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
        "$mirror/nvdcve-2.0-${year}.json.gz" \
        "$outdir/nvdcve-2.0-${year}.json.gz"
done

download_with_retry \
    "$mirror/nvdcve-2.0-modified.json.gz" \
    "$outdir/nvdcve-2.0-modified.json.gz"

echo "Mirror complete: $(find "$outdir" -maxdepth 1 -name '*.json.gz' | wc -l) feeds downloaded"
