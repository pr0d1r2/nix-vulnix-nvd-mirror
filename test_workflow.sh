#!/usr/bin/env bash
set -Eeuo pipefail

workflow="$(cd "$(dirname "$0")" && pwd)/.github/workflows/mirror.yml"

assert_contains() {
  local description="$1" pattern="$2"
  if ! grep -Eq -- "$pattern" "$workflow"; then
    echo "FAIL: $description" >&2
    exit 1
  fi
  echo "PASS: $description"
}

assert_contains "mirror is gated by the reusable CI workflow" 'uses: \./\.github/workflows/ci\.yml'
assert_contains "mirror waits for checks" 'needs: check'
assert_contains "checkout fetches full history for lock commits" 'fetch-depth: 0'
assert_contains "feed hashes use Nix SRI format" 'nix hash file --sri --type sha256'
assert_contains "flat feed paths are pre-seeded" 'nix-store --add-fixed sha256'
assert_contains "the nvd-cache package is built" 'nix build -L \.#nvd-cache'
assert_contains "Cachix receives an auth token" 'authToken:.*CACHIX_AUTH_TOKEN'
assert_contains "the cache output is explicitly pushed" 'cachix push pr0d1r2'
assert_contains "cache retention is limited to seven days" 'cachix pin.*--keep-days 7'

echo "Workflow regression checks passed"
