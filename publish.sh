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

# Resolve the API key: explicit env wins; otherwise pull from the macOS Keychain
# (the access prompt accepts Touch ID, and the key never lands in shell history,
# env, or argv). Store it once with:
#   read -rs -p 'NVD API key: ' k && \
#     security add-generic-password -a "$USER" -s nvd-api-key -U -w "$k" && unset k
keychain_service="${NVD_KEYCHAIN_SERVICE:-nvd-api-key}"
if [ -z "${NVD_API_KEY:-}" ] && command -v security >/dev/null 2>&1; then
    NVD_API_KEY="$(security find-generic-password -a "$USER" -s "$keychain_service" -w 2>/dev/null || true)"
    export NVD_API_KEY
fi

if [ -z "${NVD_API_KEY:-}" ]; then
    echo "warning: NVD_API_KEY not set (env or Keychain '$keychain_service') — anonymous NVD limits apply (slow)." >&2
fi

echo ">> building feeds into public/ ..."
( cd "$here" && bash download.sh )

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
