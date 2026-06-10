# Contributing to nix-vulnix-nvd-mirror

## Prerequisites

- **Bash** 4.0+
- **ShellCheck** for linting (`apt install shellcheck` / `nix-shell -p shellcheck`)
- **curl** and **gzip** (used by the download and health-check scripts)
- **jq** for JSON processing of NVD API 2.0 responses (`apt install jq` / `nix-shell -p jq`)
- **GNU coreutils** (`sha256sum`, `seq`, `date`)

## Repository layout

```
download.sh                  # Main NVD feed downloader
health_check.sh              # Post-deploy feed verification
test_download.sh             # Tests for download.sh
test_checksum.sh             # Tests for checksum generation
test_health_check.sh         # Tests for health_check.sh
.github/workflows/mirror.yml # CI: lint, download, deploy, health-check
public/                      # Output directory (git-ignored)
```

## Development setup

1. Clone the repository:
   ```
   git clone https://github.com/pr0d1r2/nix-vulnix-nvd-mirror.git
   cd nix-vulnix-nvd-mirror
   ```

2. Verify prerequisites:
   ```
   bash --version
   shellcheck --version
   ```

## Running tests

Run all test suites:

```
bash test_download.sh
bash test_checksum.sh
bash test_health_check.sh
```

Tests use mock `curl` and `sleep` to avoid network calls and run quickly.
Every test suite prints a pass/fail summary and exits non-zero on failure.

## Linting

All shell scripts must pass ShellCheck:

```
shellcheck download.sh health_check.sh
```

CI runs this check before every deployment.

## Running the download locally

```
bash download.sh
```

Downloaded feeds land in `public/`. Override the NVD API URL with:

```
NVD_MIRROR_URL=https://your-api.example.com/rest/json/cves/2.0 bash download.sh
```

Optionally set an NVD API key to increase rate limits:

```
NVD_API_KEY=your-key-here bash download.sh
```

## Contribution guidelines

1. **Open an issue first** for non-trivial changes to discuss the approach.
2. **Branch from `main`** and keep commits focused on a single change.
3. **Run ShellCheck and all tests** before submitting a pull request.
4. **Follow existing code style:** scripts use `set -Eeuo pipefail`, snake_case variables, and `#!/usr/bin/env bash` shebangs.
5. **Pin GitHub Actions to full commit SHAs**, not mutable tags.
6. **Do not weaken error handling.** The ERR trap and `set -Eeuo pipefail` are required invariants.
7. **Add tests** for new functionality — see the existing `test_*.sh` scripts for patterns.

## Key invariants

These project rules must be preserved in every change:

- `download.sh` uses `set -Eeuo pipefail` (the `-E` flag is required for ERR trap propagation).
- Downloads cover a rolling 6-year window plus the `modified` feed.
- Each download retries up to 3 times with exponential backoff.
- `curl` calls use `--retry 3 --retry-delay 60 --max-time 300`.
- Downloaded `.json.gz` files are verified with `gzip -t`.
- The ERR trap removes `public/` on failure to prevent deploying incomplete feeds.
- All GitHub Actions are SHA-pinned for supply-chain security.

## Reporting issues

Open an issue on the GitHub repository with:

- Steps to reproduce the problem
- Expected vs. actual behavior
- Relevant log output
