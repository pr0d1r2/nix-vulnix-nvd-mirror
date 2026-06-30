#!/usr/bin/env bash
# One-shot fixer: the existing public/ year buckets are good, but the modified
# feed is oversized (NVD mass-modify -> >100MB, git-push rejected). Replace ONLY
# the modified feed with a small recent window, then publish public/ as-is.
#
#   ./republish.sh            # MODIFIED_DAYS=2 by default
#   MODIFIED_DAYS=5 ./republish.sh
set -Eeuo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
repo_url="${REPO_URL:-git@github.com:pr0d1r2/nix-vulnix-nvd-mirror.git}"
nvd="${NVD_MIRROR_URL:-https://services.nvd.nist.gov/rest/json/cves/2.0}"
days="${MODIFIED_DAYS:-2}"

if [ ! -d public ] || ! ls public/nvdcve-2.0-[0-9][0-9][0-9][0-9].json.gz >/dev/null 2>&1; then
    echo "no year buckets in public/ — run ./publish.sh first" >&2
    exit 1
fi

# Key: env -> Keychain (Touch ID).
keychain_service="${NVD_KEYCHAIN_SERVICE:-nvd-api-key}"
if [ -z "${NVD_API_KEY:-}" ] && command -v security >/dev/null 2>&1; then
    NVD_API_KEY="$(security find-generic-password -a "$USER" -s "$keychain_service" -w 2>/dev/null || true)"
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# --- 1. fetch a SMALL modified window (last $days days), paginated ---
s="$(date -u -v-"${days}"d +%Y-%m-%dT00:00:00.000 2>/dev/null || date -u -d "$days days ago" +%Y-%m-%dT00:00:00.000)"
e="$(date -u +%Y-%m-%dT23:59:59.999)"
url="${nvd}?lastModStartDate=${s}&lastModEndDate=${e}"
echo ">> fetching modified window: last ${days} days ..."
echo '[]' > "$tmp/agg.json"
si=0; total=-1
while [ "$total" -eq -1 ] || [ "$si" -lt "$total" ]; do
    curl -sS --retry 3 --retry-delay 30 --max-time 120 \
        ${NVD_API_KEY:+-H "apiKey: $NVD_API_KEY"} \
        -o "$tmp/page.json" "${url}&startIndex=${si}&resultsPerPage=2000"
    jq -e . "$tmp/page.json" >/dev/null || { echo "bad NVD response" >&2; exit 1; }
    [ "$total" -eq -1 ] && total="$(jq -r '.totalResults // 0' "$tmp/page.json")"
    jq -s '.[0] + (.[1].vulnerabilities // [])' "$tmp/agg.json" "$tmp/page.json" > "$tmp/agg2.json"
    mv "$tmp/agg2.json" "$tmp/agg.json"
    echo "   $((si < total ? si + 2000 : total))/${total}"
    si=$((si + 2000))
    [ "$si" -lt "$total" ] && sleep 1
done
jq '{resultsPerPage: length, startIndex: 0, totalResults: length, vulnerabilities: .}' \
    "$tmp/agg.json" | gzip -n > public/nvdcve-2.0-modified.json.gz
echo "   modified: $(jq 'length' "$tmp/agg.json") CVEs, $(du -h public/nvdcve-2.0-modified.json.gz | cut -f1)"

# --- 2. size guard: nothing over GitHub's 100MB git limit ---
big="$(find public -name '*.json.gz' -size +95M)"
[ -z "$big" ] || { echo "still oversized (won't push): $big" >&2; exit 1; }

# --- 3. regenerate checksums over the published feeds ---
( cd public && : > sha256sums.txt
  for f in nvdcve-2.0-*.json.gz; do
      echo "$(sha256sum "$f" | cut -d' ' -f1)  $f" >> sha256sums.txt
  done )

# --- 4. publish public/ -> gh-pages (orphan force-push) ---
echo ">> publishing public/ -> gh-pages ..."
pub="$(mktemp -d)"
cp -R public/. "$pub/"
( cd "$pub"
  touch .nojekyll
  git init -q && git checkout -q -b gh-pages && git add -A
  git -c user.email=mirror@local -c user.name="nvd-mirror" \
      commit -qm "feeds $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git push -qf "$repo_url" gh-pages )
rm -rf "$pub"
echo ">> done. Pages will reflect the new feeds shortly."
