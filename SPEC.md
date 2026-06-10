# SPEC — nix-vulnix-nvd-mirror

## §D — Description

A GitHub Pages mirror of NVD (National Vulnerability Database) JSON feeds for use with [vulnix](https://github.com/nix-community/vulnix), the Nix/NixOS vulnerability scanner. A daily GitHub Actions workflow downloads NVD 2.0 CVE feeds (covering the last 6 years plus the "modified" feed) and deploys them to GitHub Pages via force-push, providing a reliable, self-hosted mirror that avoids NVD rate limits and downtime. Target users are NixOS administrators and developers who run vulnix for vulnerability scanning.

## §V — Invariants

1. `download.sh` must exit on any error (`set -euo pipefail`).
2. `download.sh` must download feeds for a rolling 6-year window: `(current_year - 5)` through `current_year`, plus the `modified` feed.
3. Each download must retry up to 3 times with exponential backoff (60s, 120s base delays) before failing.
4. `curl` invocations must use `--retry 3 --retry-delay 60 --max-time 300` for network resilience.
5. All downloaded feeds land in the `public/` directory as `nvdcve-2.0-{year}.json.gz` files.
6. The GitHub Actions workflow runs daily at 04:00 UTC and supports manual `workflow_dispatch`.
7. Deployment uses `force_orphan: true` so the `gh-pages` branch carries no history accumulation.
8. The workflow has a 120-minute timeout to guard against hung downloads.
9. The feed URL base is `https://nvd.nist.gov/feeds/json/cve/2.0`.
10. The workflow requires `contents: write` permission and uses `actions/checkout@v6`.

## §I — Interfaces

### CLI — `download.sh`

```
bash download.sh
```

**Environment / globals used inside the script:**

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `mirror` | string | `https://nvd.nist.gov/feeds/json/cve/2.0` | NVD feed base URL |
| `outdir` | string | `public` | Output directory for downloaded feeds |
| `current_year` | int | `$(date +%Y)` | Current calendar year |
| `start_year` | int | `current_year - 5` | First year to mirror |
| `max_retries` | int | `3` | Maximum download attempts per feed |
| `base_delay` | int | `60` | Base backoff delay in seconds |

**Functions:**

- `download_with_retry(url: string, dest: string) -> 0 | 1` — Downloads a single URL to a destination path with retry/backoff logic. Prints `OK: <filename>` on success to stdout; prints `FAIL: <url>` and `Retry ...` messages to stderr.

**Output artifacts:**

- `public/nvdcve-2.0-{year}.json.gz` — one per year in the rolling window
- `public/nvdcve-2.0-modified.json.gz` — recently modified CVEs

### GitHub Actions — `.github/workflows/mirror.yml`

- **Trigger:** `schedule` (daily 04:00 UTC) or `workflow_dispatch` (manual)
- **Deployment:** `peaceiris/actions-gh-pages@v4` to GitHub Pages from `./public`

### GitHub Pages endpoint

```
https://pr0d1r2.github.io/nix-vulnix-nvd-mirror/nvdcve-2.0-{year}.json.gz
```

Used by vulnix via:

```
vulnix --mirror https://pr0d1r2.github.io/nix-vulnix-nvd-mirror/ ./result
```

### Config — `.rtk/filters.toml`

RTK filter configuration (schema version 1, currently empty filters).

## §T — Tasks

| status | id | goal |
|--------|----|------|
| `.` | T1 | Add a `shellcheck` lint step to the CI workflow to validate `download.sh` |
| `.` | T2 | Add integrity verification (checksum/SHA256) for downloaded feed files |
| `.` | T3 | Add a `test_download.sh` script that validates the script logic (mock curl, check retry behavior, verify year range) |
| `.` | T4 | Make `mirror` base URL configurable via environment variable for alternate NVD mirrors |
| `.` | T5 | Add a health-check step in CI that verifies the deployed Pages endpoint returns valid gzip files |
| `.` | T6 | Add `CONTRIBUTING.md` with development setup and contribution guidelines |
| `.` | T7 | Migrate from NVD 2.0 JSON feeds to the NVD API 2.0 (CVE Change History API), as NIST has deprecated the legacy feed format |
| `.` | T8 | Add concurrency control to the workflow to cancel in-progress runs when a new one starts |
| `.` | T9 | Add error notification (e.g., GitHub Actions failure badge or Slack webhook) on download failures |
| `.` | T10 | Pin `peaceiris/actions-gh-pages` to a specific SHA for supply-chain security |

## §B — Bugs / Known Issues

1. **Deprecated NVD feed format.** The script uses `https://nvd.nist.gov/feeds/json/cve/2.0` which NIST deprecated in favor of the NVD API 2.0. These feeds may stop working or become stale at any time.
2. **No integrity verification.** Downloaded `.json.gz` files are not verified against checksums or signatures; a truncated or corrupted download will be silently deployed.
3. **No concurrent run protection.** If the scheduled and manual workflows overlap, both will attempt to force-push to `gh-pages`, creating a race condition.
4. **Hardcoded base URL.** The NVD mirror URL is hardcoded in `download.sh` with no override mechanism, making it impossible to test against a local mirror or alternate endpoint without editing the script.
5. **Silent partial failure.** If one year's feed fails to download, `set -e` causes the script to exit immediately, but feeds from prior successful iterations remain in `public/`. The CI step will fail, but the `public/` directory is in an incomplete state. There is no cleanup of partial downloads.
6. **No tests.** The project has zero automated tests for the download script's logic (retry behavior, year range calculation, error handling).
7. **Action version not SHA-pinned.** `peaceiris/actions-gh-pages@v4` uses a mutable tag; a compromised upstream tag could inject malicious code into the deployment pipeline.
