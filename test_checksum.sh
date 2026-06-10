#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

passed=0
failed=0

pass() { echo "PASS: $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1" >&2; failed=$((failed + 1)); }

# Create valid .json.gz feed files to serve via file://
FEED_DIR="$WORK_DIR/feeds"
mkdir -p "$FEED_DIR"

current_year=$(date +%Y)
start_year=$((current_year - 5))

for year in $(seq "$start_year" "$current_year"); do
    echo "{\"CVE_Items\": [], \"year\": $year}" | gzip > "$FEED_DIR/nvdcve-2.0-${year}.json.gz"
done
echo '{"CVE_Items": [], "feed": "modified"}' | gzip > "$FEED_DIR/nvdcve-2.0-modified.json.gz"

# Run download.sh with file:// mirror
export NVD_MIRROR_URL="file://$FEED_DIR"
cd "$WORK_DIR"
bash "$SCRIPT_DIR/download.sh"

# T1: sha256sums.txt is generated
if [ -f "public/sha256sums.txt" ]; then
    pass "sha256sums.txt exists"
else
    fail "sha256sums.txt not generated"
fi

# T2: sha256sums.txt has one entry per feed file
expected_count=$((current_year - start_year + 2))
actual_count=$(wc -l < "public/sha256sums.txt")
if [ "$actual_count" -eq "$expected_count" ]; then
    pass "sha256sums.txt has $expected_count entries"
else
    fail "expected $expected_count entries, got $actual_count"
fi

# T3: every .json.gz file has a corresponding checksum entry
all_present=true
for f in public/*.json.gz; do
    name=$(basename "$f")
    if ! grep -q "  $name\$" "public/sha256sums.txt"; then
        fail "missing checksum for $name"
        all_present=false
    fi
done
if $all_present; then
    pass "all feed files have checksum entries"
fi

# T4: checksums are valid 64-char hex strings (SHA256)
bad_hash=false
while IFS= read -r line; do
    hash=${line%%  *}
    if ! [[ "$hash" =~ ^[0-9a-f]{64}$ ]]; then
        fail "invalid SHA256 hash: $hash"
        bad_hash=true
    fi
done < "public/sha256sums.txt"
if ! $bad_hash; then
    pass "all hashes are valid SHA256 (64 hex chars)"
fi

# T5: sha256sum -c verifies all checksums
if (cd public && sha256sum -c sha256sums.txt > /dev/null 2>&1); then
    pass "sha256sum -c verifies all checksums"
else
    fail "sha256sum -c verification failed"
fi

# T6: checksums match independently computed values
mismatch=false
for f in public/*.json.gz; do
    name=$(basename "$f")
    expected=$(sha256sum "$f" | cut -d' ' -f1)
    recorded=$(grep "  $name\$" "public/sha256sums.txt" | cut -d' ' -f1)
    if [ "$expected" != "$recorded" ]; then
        fail "checksum mismatch for $name: expected=$expected recorded=$recorded"
        mismatch=true
    fi
done
if ! $mismatch; then
    pass "all checksums match independently computed values"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
