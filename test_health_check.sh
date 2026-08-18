#!/usr/bin/env bash
# Test cases intentionally run commands in subshells with temporary
# environment overrides; those assignments do not leak by design.
# shellcheck disable=SC2030,SC2031
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

setup_mock_curl() {
    local mode="$1"
    local mock_bin="$WORK_DIR/mock_bin_${mode}_$$"
    mkdir -p "$mock_bin"

    case "$mode" in
        success)
            cat > "$mock_bin/curl" <<'MOCK'
#!/usr/bin/env bash
dest=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) dest="$2"; shift 2 ;;
        --retry|--retry-delay|--max-time) shift 2 ;;
        -*) shift ;;
        *) shift ;;
    esac
done
echo '{"CVE_Items": []}' | gzip > "$dest"
exit 0
MOCK
            ;;
        fail)
            cat > "$mock_bin/curl" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
            ;;
        corrupt)
            cat > "$mock_bin/curl" <<'MOCK'
#!/usr/bin/env bash
dest=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) dest="$2"; shift 2 ;;
        --retry|--retry-delay|--max-time) shift 2 ;;
        -*) shift ;;
        *) shift ;;
    esac
done
echo "not valid gzip data" > "$dest"
exit 0
MOCK
            ;;
    esac
    chmod +x "$mock_bin/curl"

    cat > "$mock_bin/sleep" <<'MOCK'
#!/usr/bin/env bash
:
MOCK
    chmod +x "$mock_bin/sleep"

    echo "$mock_bin"
}

# ── Test 1: Health check passes with valid feeds ─────────────────────────

test_health_check_passes() {
    local mock_bin
    mock_bin=$(setup_mock_curl success)

    local exit_code=0
    (
        fix_mock_shebangs "$mock_bin"
        export PATH="$mock_bin:$PATH"
        export PAGES_URL="http://mock.test"
        bash "$SCRIPT_DIR/health_check.sh"
    ) > /dev/null || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        pass "health check passes with valid feeds"
    else
        fail "health check should pass with valid feeds (exit=$exit_code)"
    fi
}

# ── Test 2: Health check fails when endpoint is unreachable ──────────────

test_health_check_fails_unreachable() {
    local mock_bin
    mock_bin=$(setup_mock_curl fail)

    local exit_code=0
    (
        fix_mock_shebangs "$mock_bin"
        export PATH="$mock_bin:$PATH"
        export PAGES_URL="http://mock.test"
        bash "$SCRIPT_DIR/health_check.sh"
    ) > /dev/null 2>&1 || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        pass "health check fails when endpoint unreachable"
    else
        fail "health check should fail when endpoint unreachable"
    fi
}

# ── Test 3: Health check fails with corrupt gzip ─────────────────────────

test_health_check_fails_corrupt() {
    local mock_bin
    mock_bin=$(setup_mock_curl corrupt)

    local exit_code=0
    (
        fix_mock_shebangs "$mock_bin"
        export PATH="$mock_bin:$PATH"
        export PAGES_URL="http://mock.test"
        bash "$SCRIPT_DIR/health_check.sh"
    ) > /dev/null 2>&1 || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        pass "health check fails with corrupt gzip files"
    else
        fail "health check should fail with corrupt gzip files"
    fi
}

# ── Test 4: Health check verifies correct number of feeds ────────────────

test_health_check_feed_count() {
    local mock_bin="$WORK_DIR/mock_bin_count"
    mkdir -p "$mock_bin"

    cat > "$mock_bin/curl" <<'MOCK'
#!/usr/bin/env bash
dest=""
url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) dest="$2"; shift 2 ;;
        --retry|--retry-delay|--max-time) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
echo "$url" >> "${MOCK_LOG}"
echo '{"CVE_Items": []}' | gzip > "$dest"
exit 0
MOCK
    chmod +x "$mock_bin/curl"

    cat > "$mock_bin/sleep" <<'MOCK'
#!/usr/bin/env bash
:
MOCK
    chmod +x "$mock_bin/sleep"

    local log_file="$WORK_DIR/count_urls.log"

    (
        fix_mock_shebangs "$mock_bin"
        export PATH="$mock_bin:$PATH"
        export PAGES_URL="http://mock.test"
        export MOCK_LOG="$log_file"
        bash "$SCRIPT_DIR/health_check.sh"
    ) > /dev/null

    local url_count
    url_count=$(wc -l < "$log_file")
    local expected=$((current_year - start_year + 1 + 1))

    if [ "$url_count" -eq "$expected" ]; then
        pass "health check verifies $expected feeds (6 years + modified)"
    else
        fail "health check expected $expected URLs, got $url_count"
    fi
}

# ── Test 5: PAGES_URL override is used ───────────────────────────────────

test_pages_url_override() {
    local mock_bin="$WORK_DIR/mock_bin_url"
    mkdir -p "$mock_bin"

    cat > "$mock_bin/curl" <<'MOCK'
#!/usr/bin/env bash
dest=""
url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) dest="$2"; shift 2 ;;
        --retry|--retry-delay|--max-time) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
echo "$url" >> "${MOCK_LOG}"
echo '{"CVE_Items": []}' | gzip > "$dest"
exit 0
MOCK
    chmod +x "$mock_bin/curl"

    cat > "$mock_bin/sleep" <<'MOCK'
#!/usr/bin/env bash
:
MOCK
    chmod +x "$mock_bin/sleep"

    local log_file="$WORK_DIR/url_override.log"

    (
        fix_mock_shebangs "$mock_bin"
        export PATH="$mock_bin:$PATH"
        export PAGES_URL="http://custom.pages.test/mirror"
        export MOCK_LOG="$log_file"
        bash "$SCRIPT_DIR/health_check.sh"
    ) > /dev/null

    if grep -q "^http://custom.pages.test/mirror/" "$log_file"; then
        pass "PAGES_URL override is used in curl calls"
    else
        fail "PAGES_URL override not found in curl calls"
    fi
}

# ── Run all tests ────────────────────────────────────────────────────────

echo "=== test_health_check.sh ==="
echo ""

test_health_check_passes
test_health_check_fails_unreachable
test_health_check_fails_corrupt
test_health_check_feed_count
test_pages_url_override

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
