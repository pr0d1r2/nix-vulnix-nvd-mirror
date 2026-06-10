# SPEC — nix-vulnix-nvd-mirror

## §D — Description

A GitHub Pages mirror of NVD (National Vulnerability Database) JSON feeds for use with [vulnix](https://github.com/nix-community/vulnix), the Nix/NixOS vulnerability scanner. A daily GitHub Actions workflow fetches CVE data from the NVD API 2.0 (covering the last 6 years plus recently modified CVEs) and deploys them to GitHub Pages via force-push, providing a reliable, self-hosted mirror that avoids NVD rate limits and downtime. Target users are NixOS administrators and developers who run vulnix for vulnerability scanning.

Beyond the raw feeds, this project also aims to publish a **pre-built vulnix cache** as a Nix store path: a `flake.nix` output that compiles the mirrored feeds into vulnix's on-disk database (`Data.fs`) at build time and serves it through a binary cache (Cachix). Consumers then obtain a ready-to-use cache via a single store-path copy — **no NVD download and no local compile** — which matters on cold or ephemeral builders (freshly-rebooted CI hosts, stateless live-ISO smoke tests) where the current on-demand download-and-compile is slow and starves time-sensitive work such as QEMU boots.

## §V — Invariants

1. `download.sh` must exit on any error (`set -Eeuo pipefail`; `-E` ensures the ERR trap propagates into functions).
2. `download.sh` must download feeds for a rolling 6-year window: `(current_year - 5)` through `current_year`, plus the `modified` feed.
3. Each download must retry up to 3 times with exponential backoff (60s, 120s base delays) before failing.
4. `curl` invocations must use `--retry 3 --retry-delay 60 --max-time 300` for network resilience.
5. All downloaded feeds land in the `public/` directory as `nvdcve-2.0-{year}.json.gz` files.
6. The GitHub Actions workflow runs daily at 04:00 UTC and supports manual `workflow_dispatch`.
7. Deployment uses `force_orphan: true` so the `gh-pages` branch carries no history accumulation.
8. The workflow has a 120-minute timeout to guard against hung downloads.
9. The NVD API URL defaults to `https://services.nvd.nist.gov/rest/json/cves/2.0` and is overridable via `NVD_MIRROR_URL`.
10. The workflow requires `contents: write` permission and uses `actions/checkout@v6` (SHA-pinned).
11. All GitHub Actions are pinned to full commit SHAs (not mutable tags) for supply-chain security.
12. The workflow uses a concurrency group (`mirror-deploy`) with `cancel-in-progress: true` to prevent overlapping deployments.
13. On download failure, an ERR trap removes the `public/` directory to prevent deploying an incomplete feed set.
14. Each downloaded `.json.gz` file is verified with `gzip -t` before being accepted; corrupt files trigger a retry.
15. The pre-built cache (`flake.nix` `nvd-cache` output) is built **only** from the mirrored feeds plus vulnix; it requires no network at consumer use time and is reproducible from a given feed snapshot.
16. The pre-built cache is rebuilt on the same daily cadence as the feeds, so a consumer's cache never lags the published feeds by more than ~24h.
17. The pre-built cache is pushed to a public binary cache (Cachix) by CI, so consumers fetch the store path as a substitute without rebuilding it locally.

## §I — Interfaces

### CLI — `download.sh`

```
bash download.sh
```

**Environment / globals used inside the script:**

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `NVD_MIRROR_URL` | env var | `https://services.nvd.nist.gov/rest/json/cves/2.0` | NVD API 2.0 base URL (set to override the default) |
| `NVD_API_KEY` | env var | _(unset)_ | Optional NVD API key for higher rate limits |
| `NVD_RATE_DELAY` | env var | `6` | Seconds to wait between paginated API requests |
| `NOTIFICATION_WEBHOOK_URL` | env var | _(unset)_ | Optional webhook URL for failure notifications (Slack-compatible JSON payload) |
| `nvd_api_url` | string | `$NVD_MIRROR_URL` or default | Resolved NVD API base URL |
| `outdir` | string | `public` | Output directory for downloaded feeds |
| `current_year` | int | `$(date +%Y)` | Current calendar year |
| `start_year` | int | `current_year - 5` | First year to mirror |
| `max_retries` | int | `3` | Maximum download attempts per feed |
| `base_delay` | int | `60` | Base backoff delay in seconds |

**Functions:**

- `send_failure_notification() -> void` — Sends a JSON payload (`{"text": "..."}`) to `NOTIFICATION_WEBHOOK_URL` if set; silently skipped when unset. Called by the ERR trap handler. Notification failures are suppressed to avoid masking the original error.
- `cleanup_on_failure() -> void` — ERR trap handler that removes the output directory on failure, preventing deployment of incomplete feeds. Calls `send_failure_notification()` before cleanup.
- `_fetch_api_feed(url: string, dest: string) -> 0 | 1` — Fetches all pages from the NVD API 2.0 for a given query URL, aggregates the `vulnerabilities` arrays across pages, assembles the final JSON, and writes it as a gzip file to `dest`. Handles pagination via `startIndex`/`resultsPerPage` parameters. Returns non-zero on curl failure or invalid JSON response.
- `download_with_retry(url: string, dest: string) -> 0 | 1` — Downloads a complete NVD API 2.0 feed (potentially paginated) to a destination path with retry/backoff logic. Delegates to `_fetch_api_feed` for the actual fetch, then verifies gzip integrity (`gzip -t`); a failed fetch or check triggers a retry. Removes partial files between retries. Prints `OK: <filename>` on success to stdout; prints `FAIL: <url>` and `Retry ...` messages to stderr.

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

### Nix flake — pre-built vulnix cache

```
nix build github:pr0d1r2/nix-vulnix-nvd-mirror#nvd-cache
```

- **Output:** `packages.${system}.nvd-cache` — a store path containing a vulnix-compatible database (`Data.fs`) compiled from the mirrored feeds.
- **Consumed** by pointing vulnix at the store path instead of downloading and compiling:

```
vulnix -c "$(nix build --no-link --print-out-paths github:pr0d1r2/nix-vulnix-nvd-mirror#nvd-cache)" -R <path>
```

- **Binary cache:** the `nvd-cache` derivation is served from a Cachix substituter, so on a trusting host the copy is a pure substitution — zero download, zero compile.

### Config — `.rtk/filters.toml`

RTK filter configuration (schema version 1, currently empty filters).

## §T — Tasks

| status | id | goal |
|--------|----|------|
| `x` | T1 | Add a `shellcheck` lint step to the CI workflow to validate `download.sh` |
| `x` | T2 | Add integrity verification (checksum/SHA256) for downloaded feed files |
| `x` | T3 | Add a `test_download.sh` script that validates the script logic (mock curl, check retry behavior, verify year range) |
| `x` | T4 | Make `mirror` base URL configurable via environment variable for alternate NVD mirrors |
| `x` | T5 | Add a health-check step in CI that verifies the deployed Pages endpoint returns valid gzip files |
| `x` | T6 | Add `CONTRIBUTING.md` with development setup and contribution guidelines |
| `x` | T7 | Migrate from NVD 2.0 JSON feeds to the NVD API 2.0 (CVE Change History API), as NIST has deprecated the legacy feed format |
| `x` | T8 | Add concurrency control to the workflow to cancel in-progress runs when a new one starts |
| `x` | T9 | Add error notification (e.g., GitHub Actions failure badge or Slack webhook) on download failures |
| `x` | T10 | Pin `peaceiris/actions-gh-pages` to a specific SHA for supply-chain security |
| `.` | T11 | Add a `flake.nix` exposing `packages.<system>.nvd-cache` — a derivation that compiles the mirrored feeds into a pre-built vulnix database (`Data.fs`) store path, so consumers get zero-download and zero-compile |
| `.` | T12 | Build and push `nvd-cache` to a public Cachix binary cache from the daily workflow, so downstream consumers fetch the store path as a substitute |
| `.` | T13 | Document consumer usage of the pre-built cache (`vulnix -c <store-path>`), with examples for cold/ephemeral builders and live-ISO smoke seeding |
| `.` | T14 | Provide a Nix consumer helper (overlay or `nixosModules`) that wires `nvd-cache` into `/var/cache/vulnix` declaratively |

## §B — Bugs / Known Issues

1. ~~**Deprecated NVD feed format.**~~ Resolved by T7. The script now uses the NVD API 2.0 (`https://services.nvd.nist.gov/rest/json/cves/2.0`) with pagination support.
2. **No cryptographic verification.** Downloaded `.json.gz` files are verified for gzip integrity (`gzip -t`), but NVD legacy feeds do not provide checksums or signatures for independent authenticity verification.
3. **No tests.** The project has zero automated tests for the download script's logic (retry behavior, year range calculation, error handling).
