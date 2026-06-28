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

# Set up mock curl that returns valid NVD API 2.0 JSON responses
MOCK_BIN="$WORK_DIR/mock_bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
# New per-page contract (SPEC §V.28): body to -o, HTTP code to stdout (-w).
dest=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) dest="$2"; shift 2 ;;
        -D|-w|-H|-X|-d) shift 2 ;;
        --retry|--retry-delay|--max-time) shift 2 ;;
        -*) shift ;;
        *) shift ;;
    esac
done
echo '{"totalResults": 1, "resultsPerPage": 1, "startIndex": 0, "vulnerabilities": [{"cve": {"id": "CVE-2024-0001", "lastModified": "2024-01-01T00:00:00"}}]}' > "$dest"
printf '200'
MOCK
chmod +x "$MOCK_BIN/curl"

cat > "$MOCK_BIN/sleep" <<'MOCK'
#!/usr/bin/env bash
:
MOCK
chmod +x "$MOCK_BIN/sleep"

# Run download.sh with mock curl
(
    fix_mock_shebangs "$MOCK_BIN"
    export PATH="$MOCK_BIN:$PATH"
    export NVD_MIRROR_URL="http://mock.test/api"
    export NVD_RATE_DELAY=0
    cd "$WORK_DIR"
    bash "$SCRIPT_DIR/download.sh"
)
cd "$WORK_DIR"

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
