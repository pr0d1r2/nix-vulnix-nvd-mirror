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
9. The feed URL base defaults to `https://nvd.nist.gov/feeds/json/cve/2.0` and is overridable via `NVD_MIRROR_URL`.
10. The workflow requires `contents: write` permission and uses `actions/checkout@v6` (SHA-pinned).
11. All GitHub Actions are pinned to full commit SHAs (not mutable tags) for supply-chain security.
12. The workflow uses a concurrency group (`mirror-deploy`) with `cancel-in-progress: true` to prevent overlapping deployments.
13. On download failure, an ERR trap removes the `public/` directory to prevent deploying an incomplete feed set.
14. Each downloaded `.json.gz` file is verified with `gzip -t` before being accepted; corrupt files trigger a retry.

## §I — Interfaces

### CLI — `download.sh`

```
bash download.sh
```

**Environment / globals used inside the script:**

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `NVD_MIRROR_URL` | env var | `https://nvd.nist.gov/feeds/json/cve/2.0` | NVD feed base URL (set to override the default) |
| `mirror` | string | `$NVD_MIRROR_URL` or default | Resolved NVD feed base URL |
| `outdir` | string | `public` | Output directory for downloaded feeds |
| `current_year` | int | `$(date +%Y)` | Current calendar year |
| `start_year` | int | `current_year - 5` | First year to mirror |
| `max_retries` | int | `3` | Maximum download attempts per feed |
| `base_delay` | int | `60` | Base backoff delay in seconds |

**Functions:**

- `cleanup_on_failure() -> void` — ERR trap handler that removes the output directory on failure, preventing deployment of incomplete feeds.
- `download_with_retry(url: string, dest: string) -> 0 | 1` — Downloads a single URL to a destination path with retry/backoff logic. Verifies gzip integrity (`gzip -t`) after each download; a failed check triggers a retry. Removes partial files between retries. Prints `OK: <filename>` on success to stdout; prints `FAIL: <url>` and `Retry ...` messages to stderr.

**Output artifacts:**

- `public/nvdcve-2.0-{year}.json.gz` — one per year in the rolling window
- `public/nvdcve-2.0-modified.json.gz` — recently modified CVEs

### GitHub Actions — `.github/workflows/mirror.yml`

- **Trigger:** `schedule` (daily 04:00 UTC) or `workflow_dispatch` (manual)
- **Concurrency:** `mirror-deploy` group with `cancel-in-progress: true`
- **Deployment:** `peaceiris/actions-gh-pages@v4.1.0` (SHA-pinned) to GitHub Pages from `./public`

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
| `x` | T4 | Make `mirror` base URL configurable via environment variable for alternate NVD mirrors |
| `.` | T5 | Add a health-check step in CI that verifies the deployed Pages endpoint returns valid gzip files |
| `.` | T6 | Add `CONTRIBUTING.md` with development setup and contribution guidelines |
| `.` | T7 | Migrate from NVD 2.0 JSON feeds to the NVD API 2.0 (CVE Change History API), as NIST has deprecated the legacy feed format |
| `x` | T8 | Add concurrency control to the workflow to cancel in-progress runs when a new one starts |
| `.` | T9 | Add error notification (e.g., GitHub Actions failure badge or Slack webhook) on download failures |
| `x` | T10 | Pin `peaceiris/actions-gh-pages` to a specific SHA for supply-chain security |

## §B — Bugs / Known Issues

1. **Deprecated NVD feed format.** The script uses `https://nvd.nist.gov/feeds/json/cve/2.0` which NIST deprecated in favor of the NVD API 2.0. These feeds may stop working or become stale at any time.
2. **No cryptographic verification.** Downloaded `.json.gz` files are verified for gzip integrity (`gzip -t`), but NVD legacy feeds do not provide checksums or signatures for independent authenticity verification.
3. **No tests.** The project has zero automated tests for the download script's logic (retry behavior, year range calculation, error handling).
