#!/usr/bin/env bash
set -Eeuo pipefail

workflow="$(cd "$(dirname "$0")" && pwd)/.github/workflows/mirror.yml"
ci_workflow="$(cd "$(dirname "$0")" && pwd)/.github/workflows/ci.yml"

assert_contains() {
  local description="$1" pattern="$2"
  if ! grep -Eq -- "$pattern" "$workflow"; then
    echo "FAIL: $description" >&2
    exit 1
  fi
  echo "PASS: $description"
}

assert_contains "mirror is gated by the reusable CI workflow" 'uses: \./\.github/workflows/ci\.yml'
if ! grep -Eq -- 'workflow_call:' "$ci_workflow"; then
  echo "FAIL: CI workflow is callable by mirror" >&2
  exit 1
fi
echo "PASS: CI workflow is callable by mirror"
assert_contains "mirror waits for checks" 'needs: check'
assert_contains "checkout fetches full history for lock commits" 'fetch-depth: 0'
assert_contains "feed hashes use Nix SRI format" 'nix hash file --sri --type sha256'
assert_contains "flat feed paths are pre-seeded" 'nix-store --add-fixed sha256'
assert_contains "the nvd-cache package is built" 'nix build -L \.#nvd-cache'
assert_contains "Cachix receives an auth token" 'authToken:.*CACHIX_AUTH_TOKEN'
assert_contains "the cache output is explicitly pushed" 'cachix push pr0d1r2'
assert_contains "cache retention is limited to seven days" 'cachix pin.*--keep-days 7'
assert_contains "Pages write permission is granted" 'pages: write'
assert_contains "Pages deployment has an OIDC token" 'id-token: write'
assert_contains "Pages deployment uses the GitHub Pages environment" 'environment: github-pages'
assert_contains "Pages artifact is uploaded" 'actions/upload-pages-artifact@'
assert_contains "Pages artifact is deployed" 'actions/deploy-pages@'

if grep -Eq 'peaceiris/actions-gh-pages|force_orphan|gh-pages' "$workflow"; then
  echo "FAIL: workflow must not publish a gh-pages branch" >&2
  exit 1
fi
echo "PASS: workflow has no gh-pages branch deployment"

# §B.27: main is protected (a PR is required), so the lock lands through a PR
# the workflow merges itself, and it lands AFTER the cache is published — a
# refused lock push must never again skip the build and the Cachix push.
if grep -Eq 'git push origin HEAD:main' "$workflow"; then
  echo "FAIL: the lock must not be pushed straight to protected main" >&2
  exit 1
fi
echo "PASS: the lock is not pushed straight to protected main"
assert_contains "the lock lands through a pull request" 'gh pr create'
assert_contains "the workflow merges its own lock pull request" 'gh pr merge'
assert_contains "the job may open pull requests" 'pull-requests: write'
lock_line="$(grep -n 'name: Publish feed lock' "$workflow" | cut -d: -f1)"
pin_line="$(grep -n 'cachix pin' "$workflow" | cut -d: -f1)"
if [ -z "$lock_line" ] || [ -z "$pin_line" ] || [ "$lock_line" -lt "$pin_line" ]; then
  echo "FAIL: the lock is published after the cache, so its failure cannot skip it" >&2
  exit 1
fi
echo "PASS: the lock is published after the cache"

echo "Workflow regression checks passed"
