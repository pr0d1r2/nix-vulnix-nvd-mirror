#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

passed=0
failed=0

pass() { echo "PASS: $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1" >&2; failed=$((failed + 1)); }

current_year=$(date +%Y)
start_year=$((current_year - 5))

setup_mocks() {
    local mock_bin="$WORK_DIR/mock_bin"
    mkdir -p "$mock_bin"

    cat > "$mock_bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
dest=""
url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) dest="$2"; shift 2 ;;
        -H) shift 2 ;;
        --retry|--retry-delay|--max-time) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done

echo "$url" >> "${MOCK_CURL_STATE_DIR}/urls.log"

if [[ -z "$dest" ]]; then
    echo "$url" >> "${MOCK_CURL_STATE_DIR}/notifications.log"
    exit 0
fi

url_key=$(echo "$url" | tr -c '[:alnum:]' '_')
count_file="${MOCK_CURL_STATE_DIR}/count_${url_key}"
count=1
if [[ -f "$count_file" ]]; then
    count=$(( $(cat "$count_file") + 1 ))
fi
echo "$count" > "$count_file"

mode="${MOCK_CURL_MODE:-success}"
fail_count="${MOCK_CURL_FAIL_COUNT:-0}"

case "$mode" in
    fail_always)
        exit 1
        ;;
    fail_then_succeed)
        if [[ "$count" -le "$fail_count" ]]; then
            exit 1
        fi
        echo '{"totalResults": 0, "resultsPerPage": 0, "startIndex": 0, "vulnerabilities": []}' > "$dest"
        exit 0
        ;;
    corrupt_then_valid)
        if [[ "$count" -le "$fail_count" ]]; then
            echo "corrupt data not json" > "$dest"
            exit 0
        fi
        echo '{"totalResults": 0, "resultsPerPage": 0, "startIndex": 0, "vulnerabilities": []}' > "$dest"
        exit 0
        ;;
    *)
        echo '{"totalResults": 0, "resultsPerPage": 0, "startIndex": 0, "vulnerabilities": []}' > "$dest"
        exit 0
        ;;
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
        export PATH="$mock_bin:$PATH"
        export MOCK_CURL_STATE_DIR="$state_dir"
        export MOCK_CURL_MODE="${MOCK_CURL_MODE:-success}"
        export MOCK_CURL_FAIL_COUNT="${MOCK_CURL_FAIL_COUNT:-0}"
        export MOCK_SLEEP_LOG="$sleep_log"
        export NVD_MIRROR_URL="${NVD_MIRROR_URL:-http://mock.test/api}"
        export NVD_RATE_DELAY=0
        export NOTIFICATION_WEBHOOK_URL="${NOTIFICATION_WEBHOOK_URL:-}"
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

# ── Test 4: Retry on curl failure with exponential backoff ─────────────────

test_retry_backoff() {
    local test_dir="$WORK_DIR/test_retry_backoff"
    mkdir -p "$test_dir"

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

    if [[ "$first_delay" -eq 60 ]]; then
        pass "retry backoff: first delay is 60s"
    else
        fail "retry backoff: first delay expected 60, got $first_delay"
    fi

    if [[ "$second_delay" -eq 120 ]]; then
        pass "retry backoff: second delay is 120s"
    else
        fail "retry backoff: second delay expected 120, got $second_delay"
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

# ── Test 8: curl receives required resilience flags ────────────────────────

test_curl_flags() {
    local test_dir="$WORK_DIR/test_curl_flags"
    mkdir -p "$test_dir"

    local mock_bin="$WORK_DIR/mock_bin_flags"
    mkdir -p "$mock_bin"

    cat > "$mock_bin/curl" <<'FLAGCURL'
#!/usr/bin/env bash
echo "$@" >> "${MOCK_CURL_STATE_DIR}/full_args.log"
dest=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) dest="$2"; shift 2 ;;
        -H) shift 2 ;;
        --retry|--retry-delay|--max-time) shift 2 ;;
        -*) shift ;;
        *) shift ;;
    esac
done
echo '{"totalResults": 0, "resultsPerPage": 0, "startIndex": 0, "vulnerabilities": []}' > "$dest"
FLAGCURL
    chmod +x "$mock_bin/curl"

    cat > "$mock_bin/sleep" <<'SLEEPSTUB'
#!/usr/bin/env bash
:
SLEEPSTUB
    chmod +x "$mock_bin/sleep"

    local state_dir="$test_dir/state"
    local run_dir="$test_dir/run"
    mkdir -p "$state_dir" "$run_dir"

    (
        export PATH="$mock_bin:$PATH"
        export MOCK_CURL_STATE_DIR="$state_dir"
        export MOCK_SLEEP_LOG="$test_dir/sleep.log"
        export NVD_MIRROR_URL="http://mock.test/api"
        export NVD_RATE_DELAY=0
        cd "$run_dir"
        bash "$SCRIPT_DIR/download.sh"
    )

    local args_log="$state_dir/full_args.log"
    local first_call
    first_call=$(head -1 "$args_log")

    local all_ok=true
    if ! echo "$first_call" | grep -q -- '--retry 3'; then
        fail "curl flags: missing --retry 3"
        all_ok=false
    fi
    if ! echo "$first_call" | grep -q -- '--retry-delay 60'; then
        fail "curl flags: missing --retry-delay 60"
        all_ok=false
    fi
    if ! echo "$first_call" | grep -q -- '--max-time 300'; then
        fail "curl flags: missing --max-time 300"
        all_ok=false
    fi

    if $all_ok; then
        pass "curl flags: --retry 3 --retry-delay 60 --max-time 300 present"
    fi
}

# ── Test 9: API pagination fetches all pages ───────────────────────────────

test_api_pagination() {
    local test_dir="$WORK_DIR/test_pagination"
    mkdir -p "$test_dir"

    local mock_bin="$WORK_DIR/mock_bin_pagination"
    mkdir -p "$mock_bin"

    cat > "$mock_bin/curl" <<'PAGECURL'
#!/usr/bin/env bash
dest=""
url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) dest="$2"; shift 2 ;;
        -H) shift 2 ;;
        --retry|--retry-delay|--max-time) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done

echo "$url" >> "${MOCK_CURL_STATE_DIR}/urls.log"

start_index=0
if [[ "$url" =~ startIndex=([0-9]+) ]]; then
    start_index="${BASH_REMATCH[1]}"
fi

if [ "$start_index" -eq 0 ]; then
    echo '{"totalResults": 2, "resultsPerPage": 1, "startIndex": 0, "vulnerabilities": [{"cve": {"id": "CVE-0001"}}]}' > "$dest"
else
    echo '{"totalResults": 2, "resultsPerPage": 1, "startIndex": 1, "vulnerabilities": [{"cve": {"id": "CVE-0002"}}]}' > "$dest"
fi
PAGECURL
    chmod +x "$mock_bin/curl"

    cat > "$mock_bin/sleep" <<'SLEEPSTUB'
#!/usr/bin/env bash
:
SLEEPSTUB
    chmod +x "$mock_bin/sleep"

    local state_dir="$test_dir/state"
    local run_dir="$test_dir/run"
    mkdir -p "$state_dir" "$run_dir"

    (
        export PATH="$mock_bin:$PATH"
        export MOCK_CURL_STATE_DIR="$state_dir"
        export NVD_MIRROR_URL="http://mock.test/api"
        export NVD_RESULTS_PER_PAGE=1
        export NVD_RATE_DELAY=0
        cd "$run_dir"
        bash "$SCRIPT_DIR/download.sh"
    )

    local url_count
    url_count=$(wc -l < "$state_dir/urls.log")
    local expected_feeds=$((current_year - start_year + 1 + 1))
    local expected_calls=$((expected_feeds * 2))

    if [[ "$url_count" -eq "$expected_calls" ]]; then
        pass "API pagination: $expected_calls API calls for $expected_feeds feeds (2 pages each)"
    else
        fail "API pagination: expected $expected_calls API calls, got $url_count"
    fi

    local first_feed="$run_dir/public/nvdcve-2.0-${start_year}.json.gz"
    local vuln_count
    vuln_count=$(zcat "$first_feed" | jq '.vulnerabilities | length')
    if [[ "$vuln_count" -eq 2 ]]; then
        pass "API pagination: all vulnerabilities aggregated across pages"
    else
        fail "API pagination: expected 2 vulnerabilities, got $vuln_count"
    fi
}

# ── Test 10: NVD_API_KEY is sent as request header ─────────────────────────

test_api_key_header() {
    local test_dir="$WORK_DIR/test_api_key"
    mkdir -p "$test_dir"

    local mock_bin="$WORK_DIR/mock_bin_apikey"
    mkdir -p "$mock_bin"

    cat > "$mock_bin/curl" <<'KEYCURL'
#!/usr/bin/env bash
echo "$@" >> "${MOCK_CURL_STATE_DIR}/full_args.log"
dest=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) dest="$2"; shift 2 ;;
        -H) shift 2 ;;
        --retry|--retry-delay|--max-time) shift 2 ;;
        -*) shift ;;
        *) shift ;;
    esac
done
echo '{"totalResults": 0, "resultsPerPage": 0, "startIndex": 0, "vulnerabilities": []}' > "$dest"
KEYCURL
    chmod +x "$mock_bin/curl"

    cat > "$mock_bin/sleep" <<'SLEEPSTUB'
#!/usr/bin/env bash
:
SLEEPSTUB
    chmod +x "$mock_bin/sleep"

    local state_dir="$test_dir/state"
    local run_dir="$test_dir/run"
    mkdir -p "$state_dir" "$run_dir"

    (
        export PATH="$mock_bin:$PATH"
        export MOCK_CURL_STATE_DIR="$state_dir"
        export NVD_MIRROR_URL="http://mock.test/api"
        export NVD_API_KEY="test-key-abc123"
        export NVD_RATE_DELAY=0
        cd "$run_dir"
        bash "$SCRIPT_DIR/download.sh"
    )

    local args_log="$state_dir/full_args.log"
    if grep -q 'apiKey: test-key-abc123' "$args_log"; then
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

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
