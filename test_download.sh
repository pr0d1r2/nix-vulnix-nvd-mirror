#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

passed=0
failed=0

pass() { echo "PASS: $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1" >&2; failed=$((failed + 1)); }

# Generated mock helpers use `#!/usr/bin/env bash`, but a hermetic Nix build
# sandbox has no /usr/bin/env. Rewrite each mock's shebang to the bash actually
# on PATH so the tests run both locally and under `nix flake check`.
fix_mock_shebangs() {
    local d="$1" f bash_path
    bash_path="$(command -v bash)"
    for f in "$d"/*; do
        [ -e "$f" ] || continue
        sed "1s|^#!/usr/bin/env bash\$|#!$bash_path|" "$f" > "$f.tmp" && mv "$f.tmp" "$f" && chmod +x "$f"
    done
}

current_year=$(date +%Y)
start_year=$((current_year - 5))

setup_mocks() {
    local mock_bin="$WORK_DIR/mock_bin"
    mkdir -p "$mock_bin"

    cat > "$mock_bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
# Faithful-ish NVD mock for the per-page fetch contract (SPEC §V.28-§V.32):
# download.sh calls `curl -sS -D <hdr> -o <body> -w '%{http_code}' ... <url>`,
# reads the body from -o, and the HTTP code from stdout (-w).
echo "$@" >> "${MOCK_CURL_STATE_DIR}/full_args.log"
dest=""
url=""
hdr=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) dest="$2"; shift 2 ;;
        -D) hdr="$2"; shift 2 ;;
        -w) shift 2 ;;
        -H) shift 2 ;;
        -X) shift 2 ;;
        -d) shift 2 ;;
        --retry|--retry-delay|--max-time) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done

echo "$url" >> "${MOCK_CURL_STATE_DIR}/urls.log"

# Notification path: download.sh's webhook POST has no -o.
if [[ -z "$dest" ]]; then
    echo "$url" >> "${MOCK_CURL_STATE_DIR}/notifications.log"
    exit 0
fi

# Prior-state seed (§V.37): pages_url serves a gzipped published feed.
if [[ "$url" == *mock.pages* || "$url" == *github.io* ]]; then
    if [[ "${MOCK_PAGES_EMPTY:-0}" == "1" ]]; then
        exit 22   # simulate 404 -> no prior state -> bootstrap
    fi
    if [[ "${MOCK_SEED_CVE:-0}" == "1" && "$url" == *2024* ]]; then
        # existing bucket already holds CVE-2024-00000 with an OLD lastModified
        echo '{"resultsPerPage":1,"startIndex":0,"totalResults":1,"vulnerabilities":[{"cve":{"id":"CVE-2024-00000","lastModified":"2020-01-01T00:00:00"}}]}' | gzip > "$dest"
        exit 0
    fi
    echo '{"resultsPerPage":0,"startIndex":0,"totalResults":0,"vulnerabilities":[]}' | gzip > "$dest"
    exit 0
fi

# Per-page-URL call counter (keyed by full url incl. startIndex).
url_key=$(echo "$url" | tr -c '[:alnum:]' '_')
count_file="${MOCK_CURL_STATE_DIR}/count_${url_key}"
count=1
if [[ -f "$count_file" ]]; then
    count=$(( $(cat "$count_file") + 1 ))
fi
echo "$count" > "$count_file"

[[ -n "$hdr" ]] && : > "$hdr"

mode="${MOCK_CURL_MODE:-success}"
fail_count="${MOCK_CURL_FAIL_COUNT:-0}"

# Page body: honor startIndex/resultsPerPage for pagination tests. A test sets
# MOCK_CURL_TOTAL to drive multi-page responses; default single empty page.
total="${MOCK_CURL_TOTAL:-0}"
per_page=$(echo "$url" | sed -n 's/.*resultsPerPage=\([0-9]*\).*/\1/p'); per_page="${per_page:-2000}"
start_index=$(echo "$url" | sed -n 's/.*startIndex=\([0-9]*\).*/\1/p'); start_index="${start_index:-0}"

ok_body() {
    local n=0 vulns="[]"
    if [[ "$total" -gt 0 ]]; then
        local remaining=$(( total - start_index ))
        [[ "$remaining" -gt "$per_page" ]] && remaining=$per_page
        [[ "$remaining" -lt 0 ]] && remaining=0
        n=$remaining
        # emit n distinct CVEs so dedup/count can be asserted
        vulns=$(awk -v s="$start_index" -v n="$n" 'BEGIN{printf "[";for(i=0;i<n;i++){printf "%s{\"cve\":{\"id\":\"CVE-2024-%05d\",\"lastModified\":\"2024-01-01T00:00:00\"}}",(i?",":""),s+i}printf "]"}')
    fi
    printf '{"totalResults": %s, "resultsPerPage": %s, "startIndex": %s, "vulnerabilities": %s}' \
        "$total" "$per_page" "$start_index" "$vulns" > "$dest"
}

case "$mode" in
    fail_always)
        printf '500'; exit 0 ;;
    fail_then_succeed)
        if [[ "$count" -le "$fail_count" ]]; then printf '500'; exit 0; fi
        ok_body; printf '200'; exit 0 ;;
    corrupt_then_valid)
        if [[ "$count" -le "$fail_count" ]]; then echo "corrupt not json" > "$dest"; printf '200'; exit 0; fi
        ok_body; printf '200'; exit 0 ;;
    ratelimit_then_succeed)
        if [[ "$count" -le "$fail_count" ]]; then
            [[ -n "$hdr" ]] && printf 'Retry-After: 1\r\n' > "$hdr"
            printf '429'; exit 0
        fi
        ok_body; printf '200'; exit 0 ;;
    upsert)
        # window re-reports CVE-2024-00000 with a NEWER lastModified + a new CVE
        printf '{"totalResults":2,"resultsPerPage":2,"startIndex":0,"vulnerabilities":[{"cve":{"id":"CVE-2024-00000","lastModified":"2024-06-01T00:00:00"}},{"cve":{"id":"CVE-2024-00001","lastModified":"2024-06-01T00:00:00"}}]}' > "$dest"
        printf '200'; exit 0 ;;
    *)
        ok_body; printf '200'; exit 0 ;;
esac
MOCK_CURL
    chmod +x "$mock_bin/curl"

    cat > "$mock_bin/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
echo "$1" >> "${MOCK_SLEEP_LOG}"
MOCK_SLEEP
    chmod +x "$mock_bin/sleep"

    echo "$mock_bin"
}

run_download() {
    local test_dir="$1"
    local state_dir="$test_dir/state"
    local run_dir="$test_dir/run"
    local sleep_log="$test_dir/sleep.log"
    mkdir -p "$state_dir" "$run_dir"

    local mock_bin
    mock_bin=$(setup_mocks)

    (
        fix_mock_shebangs "$mock_bin"
        export PATH="$mock_bin:$PATH"
        export MOCK_CURL_STATE_DIR="$state_dir"
        export MOCK_CURL_MODE="${MOCK_CURL_MODE:-success}"
        export MOCK_CURL_FAIL_COUNT="${MOCK_CURL_FAIL_COUNT:-0}"
        export MOCK_SLEEP_LOG="$sleep_log"
        export NVD_MIRROR_URL="${NVD_MIRROR_URL:-http://mock.test/api}"
        export PAGES_URL="${PAGES_URL:-http://mock.pages}"
        export NVD_RATE_DELAY=0
        export NOTIFICATION_WEBHOOK_URL="${NOTIFICATION_WEBHOOK_URL:-}"
        export MOCK_PAGES_EMPTY="${MOCK_PAGES_EMPTY:-0}"
        export MOCK_SEED_CVE="${MOCK_SEED_CVE:-0}"
        export MOCK_CURL_TOTAL="${MOCK_CURL_TOTAL:-0}"
        export NVD_API_KEY="${NVD_API_KEY:-}"
        export NVD_RESULTS_PER_PAGE="${NVD_RESULTS_PER_PAGE:-2000}"
        cd "$run_dir"
        bash "$SCRIPT_DIR/download.sh"
    )
}

# ── Test 1: Year range — correct 6-year rolling window ─────────────────────

test_year_range() {
    local test_dir="$WORK_DIR/test_year_range"
    mkdir -p "$test_dir"

    run_download "$test_dir"

    local run_dir="$test_dir/run"
    local expected_files=0
    for year in $(seq "$start_year" "$current_year"); do
        if [[ -f "$run_dir/public/nvdcve-2.0-${year}.json.gz" ]]; then
            expected_files=$((expected_files + 1))
        else
            fail "year range: missing nvdcve-2.0-${year}.json.gz"
            return
        fi
    done

    if [[ -f "$run_dir/public/nvdcve-2.0-modified.json.gz" ]]; then
        expected_files=$((expected_files + 1))
    else
        fail "year range: missing nvdcve-2.0-modified.json.gz"
        return
    fi

    local expected_count=$((current_year - start_year + 1 + 1))
    if [[ "$expected_files" -eq "$expected_count" ]]; then
        pass "year range: $expected_count feeds for ${start_year}-${current_year} + modified"
    else
        fail "year range: expected $expected_count files, got $expected_files"
    fi
}

# ── Test 2: No extra years outside the rolling window ──────────────────────

test_no_extra_years() {
    local test_dir="$WORK_DIR/test_no_extra_years"
    mkdir -p "$test_dir"

    run_download "$test_dir"

    local run_dir="$test_dir/run"
    local file_count
    file_count=$(find "$run_dir/public" -maxdepth 1 -name 'nvdcve-2.0-*.json.gz' | wc -l)
    local expected_count=$((current_year - start_year + 1 + 1))

    if [[ "$file_count" -eq "$expected_count" ]]; then
        pass "no extra years: exactly $expected_count feed files"
    else
        fail "no extra years: expected $expected_count, got $file_count"
    fi
}

# ── Test 3: NVD_MIRROR_URL override is used in curl calls ─────────────────

test_mirror_url_override() {
    local test_dir="$WORK_DIR/test_mirror_url"
    mkdir -p "$test_dir"

    NVD_MIRROR_URL="http://custom.mirror/nvd" run_download "$test_dir"

    local state_dir="$test_dir/state"
    if grep -q "^http://custom.mirror/nvd?" "$state_dir/urls.log"; then
        pass "mirror URL override: curl called with custom URL"
    else
        fail "mirror URL override: custom URL not found in curl calls"
    fi
}

# ── Test 4: Per-page retry uses exponential backoff + jitter (§V.28) ────────

test_retry_backoff() {
    local test_dir="$WORK_DIR/test_retry_backoff"
    mkdir -p "$test_dir"

    # Two transient page failures, then success: per-page backoff is
    # page_base_delay(5), then 10 + up to ~20% jitter (§V.28).
    MOCK_CURL_MODE="fail_then_succeed" MOCK_CURL_FAIL_COUNT=2 \
        run_download "$test_dir"

    local sleep_log="$test_dir/sleep.log"
    if [[ ! -f "$sleep_log" ]]; then
        fail "retry backoff: no sleep calls recorded"
        return
    fi

    local first_delay second_delay
    first_delay=$(sed -n '1p' "$sleep_log")
    second_delay=$(sed -n '2p' "$sleep_log")

    if [[ "$first_delay" -ge 5 && "$first_delay" -le 6 ]]; then
        pass "retry backoff: first per-page delay is ~5s (base + jitter)"
    else
        fail "retry backoff: first delay expected 5-6, got $first_delay"
    fi

    if [[ "$second_delay" -ge 10 && "$second_delay" -le 12 ]]; then
        pass "retry backoff: second per-page delay is ~10s (exp + jitter)"
    else
        fail "retry backoff: second delay expected 10-12, got $second_delay"
    fi
}

# ── Test 5: Retry succeeds after transient failure ─────────────────────────

test_retry_succeeds() {
    local test_dir="$WORK_DIR/test_retry_succeeds"
    mkdir -p "$test_dir"

    MOCK_CURL_MODE="fail_then_succeed" MOCK_CURL_FAIL_COUNT=1 \
        run_download "$test_dir"

    local run_dir="$test_dir/run"
    local file_count
    file_count=$(find "$run_dir/public" -maxdepth 1 -name '*.json.gz' | wc -l)
    local expected=$((current_year - start_year + 1 + 1))

    if [[ "$file_count" -eq "$expected" ]]; then
        pass "retry succeeds: all $expected feeds downloaded after transient failure"
    else
        fail "retry succeeds: expected $expected files, got $file_count"
    fi
}

# ── Test 6: Max retries exhausted → failure + cleanup ──────────────────────

test_max_retries_cleanup() {
    local test_dir="$WORK_DIR/test_max_retries"
    mkdir -p "$test_dir"

    local exit_code=0
    MOCK_CURL_MODE="fail_always" run_download "$test_dir" 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        pass "max retries: script exits with non-zero status"
    else
        fail "max retries: script should have exited with non-zero status"
    fi

    local run_dir="$test_dir/run"
    if [[ ! -d "$run_dir/public" ]]; then
        pass "max retries: public/ removed by ERR trap"
    else
        fail "max retries: public/ should have been removed by cleanup"
    fi
}

# ── Test 7: Invalid JSON response triggers retry ──────────────────────────

test_corrupt_gzip_retry() {
    local test_dir="$WORK_DIR/test_corrupt_gzip"
    mkdir -p "$test_dir"

    MOCK_CURL_MODE="corrupt_then_valid" MOCK_CURL_FAIL_COUNT=1 \
        run_download "$test_dir"

    local run_dir="$test_dir/run"
    local all_valid=true
    for f in "$run_dir"/public/*.json.gz; do
        if ! gzip -t "$f" 2>/dev/null; then
            fail "corrupt gzip retry: $(basename "$f") is not valid gzip"
            all_valid=false
        fi
    done

    if $all_valid; then
        pass "corrupt gzip retry: all feeds are valid gzip after retry"
    fi

    local sleep_log="$test_dir/sleep.log"
    if [[ -f "$sleep_log" ]] && [[ -s "$sleep_log" ]]; then
        pass "corrupt gzip retry: retries occurred (sleep was called)"
    else
        fail "corrupt gzip retry: expected retries but no sleep calls"
    fi
}

# ── Test 8: NVD page fetch carries the resilience flags (§V.4) ─────────────

test_curl_flags() {
    local test_dir="$WORK_DIR/test_curl_flags"
    mkdir -p "$test_dir"

    run_download "$test_dir"

    # Check the NVD window page fetch (url has lastModStartDate), not the seed.
    local nvd_call
    nvd_call=$(grep -- 'lastModStartDate' "$test_dir/state/full_args.log" | head -1)

    local all_ok=true
    local flag
    for flag in '--retry 3' '--retry-delay 60' '--max-time 300'; do
        if ! echo "$nvd_call" | grep -q -- "$flag"; then
            fail "curl flags: missing $flag"
            all_ok=false
        fi
    done

    if $all_ok; then
        pass "curl flags: --retry 3 --retry-delay 60 --max-time 300 present"
    fi
}

# ── Test 9: pagination aggregates all pages into the id-year bucket ─────────

test_api_pagination() {
    local test_dir="$WORK_DIR/test_pagination"
    mkdir -p "$test_dir"

    # Window of 2 CVE-2024-* across 2 pages (1/page) -> both land in 2024 bucket.
    MOCK_CURL_TOTAL=2 NVD_RESULTS_PER_PAGE=1 run_download "$test_dir"

    local bucket="$test_dir/run/public/nvdcve-2.0-2024.json.gz"
    local n
    n=$(gzip -dc "$bucket" | jq '.vulnerabilities | length')
    if [[ "$n" -eq 2 ]]; then
        pass "API pagination: 2 CVEs aggregated across pages into the 2024 bucket"
    else
        fail "API pagination: expected 2 in 2024 bucket, got $n"
    fi
}

# ── Test 10: NVD_API_KEY is sent as request header ─────────────────────────

test_api_key_header() {
    local test_dir="$WORK_DIR/test_api_key"
    mkdir -p "$test_dir"

    NVD_API_KEY="test-key-abc123" run_download "$test_dir"

    if grep -q 'apiKey: test-key-abc123' "$test_dir/state/full_args.log"; then
        pass "API key header: apiKey header sent with curl"
    else
        fail "API key header: expected apiKey header in curl args"
    fi
}

# ── Test 11: Notification webhook called on download failure ──────────────

test_notification_on_failure() {
    local test_dir="$WORK_DIR/test_notification_failure"
    mkdir -p "$test_dir"

    local exit_code=0
    MOCK_CURL_MODE="fail_always" NOTIFICATION_WEBHOOK_URL="http://hooks.test/notify" \
        run_download "$test_dir" 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        pass "notification on failure: script exits with non-zero status"
    else
        fail "notification on failure: script should have failed"
    fi

    local state_dir="$test_dir/state"
    if [[ -f "$state_dir/notifications.log" ]] && grep -q "http://hooks.test/notify" "$state_dir/notifications.log"; then
        pass "notification on failure: webhook called on download failure"
    else
        fail "notification on failure: webhook not called"
    fi
}

# ── Test 12: No notification when webhook URL is not set ─────────────────

test_no_notification_without_webhook() {
    local test_dir="$WORK_DIR/test_no_notification"
    mkdir -p "$test_dir"

    local exit_code=0
    MOCK_CURL_MODE="fail_always" \
        run_download "$test_dir" 2>/dev/null || exit_code=$?

    local state_dir="$test_dir/state"
    if [[ ! -f "$state_dir/notifications.log" ]]; then
        pass "no notification without webhook: no webhook call when URL not set"
    else
        fail "no notification without webhook: unexpected webhook call"
    fi
}

# ── Test 13: HTTP 429 honors Retry-After (§V.29) ───────────────────────────

test_retry_after() {
    local test_dir="$WORK_DIR/test_retry_after"
    mkdir -p "$test_dir"

    # First page call -> 429 with `Retry-After: 1`, then success.
    MOCK_CURL_MODE="ratelimit_then_succeed" MOCK_CURL_FAIL_COUNT=1 \
        run_download "$test_dir"

    local sleep_log="$test_dir/sleep.log"
    if [[ -f "$sleep_log" ]] && grep -qx '1' "$sleep_log"; then
        pass "Retry-After: 429 response slept the server-specified 1s"
    else
        fail "Retry-After: expected a 1s sleep from Retry-After header"
    fi
}

# ── Test 14: feeds are deterministic with gzip -n (§V.41) ──────────────────

test_gzip_determinism() {
    local a="$WORK_DIR/test_det_a" b="$WORK_DIR/test_det_b"
    mkdir -p "$a" "$b"
    run_download "$a"
    run_download "$b"

    local fa="$a/run/public/nvdcve-2.0-${start_year}.json.gz"
    local fb="$b/run/public/nvdcve-2.0-${start_year}.json.gz"
    local ha hb
    ha=$(sha256sum "$fa" | cut -d' ' -f1)
    hb=$(sha256sum "$fb" | cut -d' ' -f1)

    if [[ "$ha" == "$hb" ]]; then
        pass "gzip -n: identical content yields byte-identical feed (sha256 match)"
    else
        fail "gzip -n: feed bytes differ between runs ($ha vs $hb)"
    fi
}

# ── Test 15: per-page staging lives OUTSIDE public/ (§V.30, §V.32) ──────────

test_staging_outside_public() {
    local test_dir="$WORK_DIR/test_staging"
    mkdir -p "$test_dir"
    run_download "$test_dir"

    local run_dir="$test_dir/run"
    local stray
    stray=$(find "$run_dir/public" -name '*.json' -o -name 'checkpoint' -o -name '.part' 2>/dev/null)
    if [[ -z "$stray" ]]; then
        pass "staging: no page chunks/checkpoint left under public/"
    else
        fail "staging: found staging artifacts under public/: $stray"
    fi
}

# ── Test 16: no NVD query exceeds 120 days (§V.36 — §B.5 regression guard) ──

test_window_max_120_days() {
    local test_dir="$WORK_DIR/test_window120"
    mkdir -p "$test_dir"
    run_download "$test_dir"

    local urls="$test_dir/state/urls.log"
    local bad=0 line s e sd ed days
    while IFS= read -r line; do
        s=$(echo "$line" | sed -n 's/.*\(lastMod\|pub\)StartDate=\([^&]*\).*/\2/p')
        e=$(echo "$line" | sed -n 's/.*\(lastMod\|pub\)EndDate=\([^&]*\).*/\2/p')
        [ -n "$s" ] && [ -n "$e" ] || continue
        sd=$(date -u -d "${s%%T*}" +%s 2>/dev/null || date -u -j -f "%Y-%m-%d" "${s%%T*}" +%s)
        ed=$(date -u -d "${e%%T*}" +%s 2>/dev/null || date -u -j -f "%Y-%m-%d" "${e%%T*}" +%s)
        days=$(( (ed - sd) / 86400 ))
        [ "$days" -gt 120 ] && bad=$((bad + 1))
    done < "$urls"

    if [ "$bad" -eq 0 ]; then
        pass "120-day limit: every NVD query window is <= 120 days (§V.36)"
    else
        fail "120-day limit: $bad NVD queries exceed 120 days"
    fi
}

# ── Test 17: merge upserts by CVE id, newest lastModified wins (§V.38) ──────

test_upsert_newer_wins() {
    local test_dir="$WORK_DIR/test_upsert"
    mkdir -p "$test_dir"

    # seed has CVE-2024-00000 @ 2020; window re-reports it @ 2024-06 + a new CVE.
    MOCK_SEED_CVE=1 MOCK_CURL_MODE=upsert run_download "$test_dir"

    local bucket="$test_dir/run/public/nvdcve-2.0-2024.json.gz"
    local n lm
    n=$(gzip -dc "$bucket" | jq '.vulnerabilities | length')
    lm=$(gzip -dc "$bucket" | jq -r '.vulnerabilities[] | select(.cve.id=="CVE-2024-00000") | .cve.lastModified')

    if [[ "$n" -eq 2 && "$lm" == "2024-06-01T00:00:00" ]]; then
        pass "upsert: newer lastModified wins, new CVE inserted (2 entries in 2024)"
    else
        fail "upsert: expected 2 entries + newer lastModified, got n=$n lm=$lm"
    fi
}

# ── Test 18: in-window year with no CVEs is an empty-but-valid feed (§V.5) ──

test_empty_year_feed() {
    local test_dir="$WORK_DIR/test_empty_year"
    mkdir -p "$test_dir"
    run_download "$test_dir"

    local f="$test_dir/run/public/nvdcve-2.0-${start_year}.json.gz"
    if [ -f "$f" ] && gzip -t "$f" 2>/dev/null \
        && [ "$(gzip -dc "$f" | jq '.totalResults')" -eq 0 ]; then
        pass "empty-year: ${start_year} with no CVEs is an empty-but-valid feed"
    else
        fail "empty-year: expected empty valid feed for ${start_year}"
    fi
}

# ── Test 19: out-of-window id-year buckets are pruned (§V.38) ───────────────

test_prune_out_of_window() {
    local test_dir="$WORK_DIR/test_prune"
    mkdir -p "$test_dir/run/public"
    echo '{"resultsPerPage":0,"startIndex":0,"totalResults":0,"vulnerabilities":[]}' \
        | gzip > "$test_dir/run/public/nvdcve-2.0-2019.json.gz"

    run_download "$test_dir"

    if [ ! -f "$test_dir/run/public/nvdcve-2.0-2019.json.gz" ]; then
        pass "prune: out-of-window id-year bucket (2019) removed"
    else
        fail "prune: 2019 bucket should have been pruned"
    fi
}

# ── Test 20: empty prior state triggers bootstrap backfill (§V.39) ─────────

test_bootstrap_when_empty() {
    local test_dir="$WORK_DIR/test_bootstrap"
    mkdir -p "$test_dir"

    MOCK_PAGES_EMPTY=1 run_download "$test_dir"

    local pub_calls feeds
    pub_calls=$(grep -c 'pubStartDate' "$test_dir/state/urls.log")
    feeds=$(find "$test_dir/run/public" -name 'nvdcve-2.0-*.json.gz' | wc -l)
    if [ "$pub_calls" -ge 2 ] && [ "$feeds" -ge 7 ]; then
        pass "bootstrap: empty prior state -> sequential pub-window backfill ($pub_calls windows)"
    else
        fail "bootstrap: expected >=2 pub windows + >=7 feeds, got pub=$pub_calls feeds=$feeds"
    fi
}

# ── Test 21: modified feed mirrors the fetched window (§V.38) ──────────────

test_modified_is_window() {
    local test_dir="$WORK_DIR/test_modified"
    mkdir -p "$test_dir"
    MOCK_CURL_TOTAL=3 run_download "$test_dir"

    local n
    n=$(gzip -dc "$test_dir/run/public/nvdcve-2.0-modified.json.gz" | jq '.totalResults')
    if [[ "$n" -eq 3 ]]; then
        pass "modified feed: reflects the 3-CVE window"
    else
        fail "modified feed: expected 3, got $n"
    fi
}

# ── Run all tests ──────────────────────────────────────────────────────────

echo "=== test_download.sh ==="
echo ""

test_year_range
test_no_extra_years
test_mirror_url_override
test_retry_backoff
test_retry_succeeds
test_max_retries_cleanup
test_corrupt_gzip_retry
test_curl_flags
test_api_pagination
test_api_key_header
test_notification_on_failure
test_no_notification_without_webhook
test_retry_after
test_gzip_determinism
test_staging_outside_public
test_window_max_120_days
test_upsert_newer_wins
test_empty_year_feed
test_prune_out_of_window
test_bootstrap_when_empty
test_modified_is_window

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
