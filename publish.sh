#!/usr/bin/env bash
# Build the NVD mirror locally (on an un-throttled / residential IP) and publish
# the resulting public/ bundle to the gh-pages branch — bypassing GitHub Actions
# runner-IP throttling entirely.
#
#   NVD_API_KEY=<uuid> ./publish.sh
#
# The download is fast with an API key on a residential IP; the publish is a
# force-push of public/ to gh-pages (orphan, matching the workflow's
# force_orphan, SPEC §V.7).
set -Eeuo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_url="${REPO_URL:-git@github.com:pr0d1r2/nix-vulnix-nvd-mirror.git}"

# With a key NVD allows 50 req/30s; pace faster than the 6s anon default.
export NVD_RATE_DELAY="${NVD_RATE_DELAY:-2}"

# Resolve the API key (env -> Keychain -> first-run onboarding). The key never
# lands in shell history, env, or argv; reading it from the Keychain triggers
# the access prompt (accepts Touch ID).
keychain_service="${NVD_KEYCHAIN_SERVICE:-nvd-api-key}"

# 2. macOS Keychain (read prompts / Touch ID).
if [ -z "${NVD_API_KEY:-}" ] && command -v security >/dev/null 2>&1; then
    NVD_API_KEY="$(security find-generic-password -a "$USER" -s "$keychain_service" -w 2>/dev/null || true)"
fi

# 3. First run: not found anywhere AND interactive -> prompt once, store, reuse.
if [ -z "${NVD_API_KEY:-}" ] && command -v security >/dev/null 2>&1 && [ -t 0 ]; then
    echo "NVD API key not found (env or Keychain '$keychain_service')." >&2
    echo "Get one free at https://nvd.nist.gov/developers/request-an-api-key" >&2
    NVD_API_KEY=""
    read -rs -p "Paste NVD API key to store in Keychain (blank = skip, run anon): " NVD_API_KEY || true
    echo >&2
    if [ -n "$NVD_API_KEY" ]; then
        security add-generic-password -a "$USER" -s "$keychain_service" -U -w "$NVD_API_KEY"
        echo "stored in Keychain as '$keychain_service' (Touch-ID gated on future runs)." >&2
    fi
fi

export NVD_API_KEY="${NVD_API_KEY:-}"

if [ -z "$NVD_API_KEY" ]; then
    echo "warning: no NVD_API_KEY — anonymous NVD limits apply (slow)." >&2
fi

echo ">> building feeds into public/ ..."
( cd "$here" && bash download.sh )

# Size guard: GitHub rejects any file >100MB on git push (gh-pages). Fail fast
# with a clear message instead of a doomed push. (Oversized modified feed ->
# `./republish.sh` regenerates it small while keeping the year buckets.)
big="$(find public -name '*.json.gz' -size +95M)"
if [ -n "$big" ]; then
    echo "error: feed(s) over 95MB exceed GitHub's 100MB git limit:" >&2
    echo "$big" >&2
    echo "shrink the window (DAILY_WINDOW_DAYS) or run ./republish.sh" >&2
    exit 1
fi

echo ">> publishing public/ -> gh-pages ..."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -R "$here/public/." "$tmp/"
(
    cd "$tmp"
    touch .nojekyll                      # serve .json.gz verbatim (no Jekyll)
    git init -q
    git checkout -q -b gh-pages
    git add -A
    git -c user.email=mirror@local -c user.name="nvd-mirror" \
        commit -qm "feeds $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    git push -qf "$repo_url" gh-pages
)

echo ">> done. GitHub Pages will reflect the new feeds within a few minutes."
