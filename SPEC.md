# SPEC — nix-vulnix-nvd-mirror

## §D — Description

A GitHub Pages mirror of NVD (National Vulnerability Database) JSON feeds for use with [vulnix](https://github.com/nix-community/vulnix), the Nix/NixOS vulnerability scanner. A daily GitHub Actions workflow fetches CVE data from the NVD API 2.0 (covering the last 6 years plus recently modified CVEs) and deploys them to GitHub Pages via force-push, providing a reliable, self-hosted mirror that avoids NVD rate limits and downtime. Target users are NixOS administrators and developers who run vulnix for vulnerability scanning.

Beyond the raw feeds, this project also aims to publish a **pre-built vulnix cache** as a Nix store path: a `flake.nix` output that compiles the mirrored feeds into vulnix's on-disk database (`Data.fs`) at build time and serves it through a binary cache (Cachix). Consumers then obtain a ready-to-use cache via a single store-path copy — **no NVD download and no local compile** — which matters on cold or ephemeral builders (freshly-rebooted CI hosts, stateless live-ISO smoke tests) where the current on-demand download-and-compile is slow and starves time-sensitive work such as QEMU boots.

## §V — Invariants

1. `download.sh` must exit on any error (`set -Eeuo pipefail`; `-E` ensures the ERR trap propagates into functions).
2. **Incremental mirror, never a full re-fetch.** `download.sh` maintains a rolling 6-year window of per-year feeds by composing the timeline over time (§V.35–§V.39): each daily run fetches a single ≤120-day `lastMod` window and upserts it into the existing published feeds, rather than re-querying whole years. (A full-year `pubStartDate`/`pubEndDate` query is impossible — NVD caps any date range at 120 days, §V.36.)
3. Each download must retry up to 3 times with exponential backoff (60s, 120s base delays) before failing.
4. `curl` invocations must use `--retry 3 --retry-delay 60 --max-time 300` for network resilience.
5. All downloaded feeds land in the `public/` directory as `nvdcve-2.0-{year}.json.gz` files, **one for every in-window id-year** (`current-5…current`) plus `nvdcve-2.0-modified.json.gz` — a year with no CVEs yet is an empty-but-valid feed, so vulnix's request for any in-window year never 404s (§V.38).
6. The GitHub Actions workflow runs daily at 04:00 UTC and supports manual `workflow_dispatch`.
7. Deployment uses `force_orphan: true` so the `gh-pages` branch carries no history accumulation.
8. The workflow has a 120-minute timeout to guard against hung downloads.
9. The NVD API URL defaults to `https://services.nvd.nist.gov/rest/json/cves/2.0` and is overridable via `NVD_MIRROR_URL`.
10. The workflow requires `contents: write` permission and uses `actions/checkout@v6` (SHA-pinned).
11. All GitHub Actions are pinned to full commit SHAs (not mutable tags) for supply-chain security.
12. The workflow uses a concurrency group (`mirror-deploy`) with `cancel-in-progress: true` to prevent overlapping deployments.
13. On download failure, an ERR trap removes the **local** `public/` working directory (and the staging dir, §V.30) so an incomplete set is never deployed. Because the accumulated timeline lives in the already-published mirror (§V.37), a failed run simply aborts and **retains the previous day's deploy** — no data loss.
14. Each downloaded `.json.gz` file is verified with `gzip -t` before being accepted; corrupt files trigger a retry.
15. The pre-built cache (`flake.nix` `nvd-cache` output) builds from feeds modelled as **flat fixed-output derivations** (`pkgs.fetchurl { name; url = "<pages>/<file>"; sha256 = feeds.lock.<n>; }`). A flat FOD's store path is `f(name, sha256)` **only** — independent of the URL or fetch source. Pinned by the committed `feeds.lock` (§V.26), every evaluator (mirror, CI, consumer) computes the **same** `nvd-cache` derivation hash, so the Cachix substitute hits. The build needs no working-tree `public/` and no NVD download; the feed FODs are pure (verified by `sha256`) and skipped on a cache hit. The *output* `Data.fs` is **not** byte-reproducible (ZODB embeds transaction timestamps/serials), but that is fine: substitution keys on the **derivation hash** (the feed FOD inputs + `feeds.lock`-derived version, §V.44), not on output bytes — consumers fetch the one pushed path, never needing two builds to agree bit-for-bit.
15a. **No Pages-propagation dependency at build time.** Because the feed FOD path depends only on `(name, sha256)`, `mirror.yml` pre-seeds those exact paths from the freshly-downloaded **local** `public/` bytes via `nix-store --add-fixed sha256 <file>` (flat hashing, matching `fetchurl`) *before* `nix build`. The build then finds every feed already in the store and never fetches from the lagging Pages CDN; a consumer on a cache miss fetches the same FOD from the Pages URL — both converge on the identical store path. (`nix store add-file` uses NAR mode and is the wrong tool — it yields a different path.)
15b. **`feeds.lock` keys are the single source of truth for the feed list.** `flake.nix` derives the year/feed set from `builtins.attrNames (feeds.lock)`, never by recomputing the date, so the flake, `download.sh`'s window, and the lock cannot desync at year rollover.
16. The pre-built cache is rebuilt on the same daily cadence as the feeds, so a consumer's cache never lags the published feeds by more than ~24h.
17. The pre-built cache is pushed to the public Cachix cache **`pr0d1r2.cachix.org`** by CI, so consumers fetch the store path as a substitute without rebuilding it locally.
18. `flake.nix` pins `nixpkgs` through [`nixpkgs-lock`](https://github.com/pr0d1r2/nixpkgs-lock) via `nixpkgs.follows = "nixpkgs-lock/nixpkgs"`, so this repo tracks the same nixpkgs revision as the rest of the pr0d1r2 Nix ecosystem (~80 repos) instead of an independent `nixos-unstable` pin. A daily cron runs `nix flake update nixpkgs-lock` and opens a PR only when the locked rev changes; no cross-repo token is needed — each repo polls `nixpkgs-lock` on its own schedule.
19. `flake.nix` exposes `devShells.${system}.default` whose closure contains **every tool the CI workflow + local tasks invoke** — `bash`, `shellcheck`, `bats`, `curl`, `jq`, `gzip`, `nix`, `vulnix`, `cachix`, and **`just`** (the task runner; the repo ships a `justfile`) — so `nix develop` reproduces the environment exactly and CI runs its steps inside `nix develop` (single source of truth; no `apt`/`uses:`-installed tool drift).
20. The dev shell wires [`set-and-setting`](https://github.com/pr0d1r2/set-and-setting) `libmkSet` and `libmkSetting` together via `set-and-setting.lib.mkSet` / `set-and-setting.lib.mkSetting`: `mkSet` (categories `generic`, `git`, `nix`, `security`) provides the agent skill set + `sync-set` binary; `mkSetting` provides the env standards (`editorconfig`, `gitattributes`, `gitignore`, `markdownlint`, `yamllint`, lefthook `fileSizeLimits`) + `sync-setting` binary. Both derivations are members of the dev shell's `buildInputs`, so a single `nix develop` closure carries CI tooling **and** the agent set/setting, and `sync-set` / `sync-setting` populate the working tree on entry. The synced output is mixed-tracking: some files are committed (e.g. `.editorconfig`, `.gitattributes`, lint configs), others are `.gitignore`d local materializations (e.g. agent skill files) — the [`set-and-setting`](https://github.com/pr0d1r2/set-and-setting) upstream README is authoritative on which is which. Sync must be **idempotent**: (a) `sync-set`/`sync-setting` overwrite from the store path (never append), so a re-run is byte-identical; (b) the materialized skill files are `.gitignore`d, so re-sync never appears as a tree change; (c) `shellHook` is guarded with `[ -z "$CI" ]` so CI — which builds derivations directly and needs no synced tree — never dirties the working tree before `git`/build steps.
21. `flake.nix` exposes `checks.${system}` that wrap every current verification script — `shellcheck` lint, `test_download.sh`, `test_checksum.sh`, `test_flake.sh`, `test_health_check.sh` — so `nix flake check` is the single command that runs all checks. CI must invoke `nix flake check` rather than calling the scripts ad-hoc. **CI builds first, then checks.** `nix flake check` builds **only the `checks` output, never `packages`/`apps`** (per the Nix manual), so it would *not* build `nvd-cache` regardless — that risk is moot. The build-then-check split is a deliberate flow choice: CI explicitly `nix build`s the closures it wants cached — the devShell and each **named** check (`nix build .#devShells.${system}.default .#checks.${system}.shellcheck .#checks.${system}.download …`; there is **no `.*` attr wildcard** in nix, installables must be named) — which `cachix-action` pushes, and then runs **`nix flake check --no-build`**, which evaluates + runs the already-built checks and **builds nothing**. `nvd-cache` is never named in the build set and `--no-build` builds nothing, so the cache stays mirror-only (§V.22).
22. **Cache build+push lives in `mirror.yml`, after the daily feed refresh.** `nvd-cache` builds reproducibly from the committed `feeds.lock` (§V.15, §V.26), so it could in principle build anywhere — but only the daily mirror run has *fresh* feeds + an updated lock, so that is where it builds and pushes. After `download.sh` + Pages deploy, `mirror.yml` updates `feeds.lock`, commits it, then `nix build .#nvd-cache` and pushes the store path to `pr0d1r2.cachix.org`. `ci.yml` (push/PR) does **not** build `nvd-cache` (it would only rebuild the already-cached path); it runs `nix flake check` (feed-independent checks, §V.21) and pushes the resulting check/devShell closures.
23. Cachix pushes use the `CACHIX_AUTH_TOKEN` secret; pushes are skipped (not failed) when the secret is absent (e.g. fork PRs) so untrusted PRs still pass checks.
24. The mirror workflow gates deployment on `nix flake check`: feeds are deployed to GitHub Pages **only after** `nix flake check` passes, so a broken script/flake never ships a mirror. The cache build+push (§V.22) runs on the same daily mirror run, so the published cache never lags the published feeds (§V.16).
25. For consumers to substitute the cache with zero compile, `flake.nix` declares `nixConfig.extra-substituters = [ "https://pr0d1r2.cachix.org" ]` and `nixConfig.extra-trusted-public-keys = [ "pr0d1r2.cachix.org-1:<pubkey>" ]` (the public key is the one Cachix prints for the cache). A flake's `nixConfig` substituter is **ignored unless the consumer trusts it** — they must pass `--accept-flake-config` (or be a trusted user, or add the substituter+key to their own `nix.conf`). When untrusted and not configured, Nix silently falls back to building locally; with §V.15's reproducible derivation this still yields a correct cache (fetches feeds from Pages), just without the zero-compile shortcut.
26. `feeds.lock` is a committed JSON file mapping each mirrored feed (`{year}` and `modified`) to the `sha256` of its published `.json.gz` on the Pages mirror. It is the reproducibility anchor for `nvd-cache` (§V.15) — analogous to `flake.lock` for inputs. `mirror.yml` regenerates and commits it on every daily run **after** the feeds are deployed, so the lock always matches the live bytes. The `modified` feed's hash changes every run; that is expected (the whole cache rebuilds daily anyway, §V.16).
27. `download.sh` in `mirror.yml` receives `NVD_API_KEY` from the `NVD_API_KEY` secret (passed as env) so the daily fetch uses authenticated NVD rate limits; the run still succeeds (slower) if the secret is absent. `NVD_API_KEY` is a **pure speed optimization, never a reliability requirement** — the anonymous path is made reliable by the per-page resilience of §V.28–§V.32.
28. **Per-page retry, not per-feed.** Within a paginated feed fetch, each individual page request retries independently with exponential backoff (`5,10,20,40,80,160s` + ±20% jitter, capped at 300s, ≥6 attempts) before the feed is considered failed. A transient failure on one page never re-fetches already-completed pages.
29. **Honor server back-pressure.** On HTTP `429`/`503`, `_fetch_page` reads the `Retry-After` response header (`curl -D`) and sleeps for that duration, overriding the computed backoff; this is what keeps the anonymous (keyless) path within NVD's 5-requests/30s limit.
30. **Checkpoint = continuation.** Page fetches write into a per-feed staging dir **outside `public/`** — `${staging_dir}/<feed>/` (default `${TMPDIR:-/tmp}/nvd-part`) — one `page-<startIndex>.json` per page plus a `checkpoint` file recording `lastIndex` and `totalResults`. A feed-level retry resumes from `lastIndex` rather than `startIndex=0`; completed pages are never re-requested within a run. Scope is **within-run** (across the `max_retries` feed attempts); the staging dir is not persisted across separate workflow runs (feeds rebuild daily regardless), and the ERR trap removes both the staging dir and `public/` on fatal failure so a partial feed never deploys.
31. **Dedup-by-id, then completeness guard.** NVD's `totalResults` can drift *during* a paginated fetch (CVEs published while paging), which both shifts entries across pages (the same CVE appearing twice) and changes the running total. So aggregation **deduplicates by CVE id** (keeping the newest `lastModified`) before any check — making a window fetch idempotent — and the guard accepts the feed when the **deduped count ≥ the `totalResults` of the final page** (not strict equality against the first page). A deduped count materially short of `totalResults` (real truncation/gaps) triggers a retry; never a deploy. Dedup makes re-fetch and merge safe to repeat.
32. **Atomic assembly, staging outside `public/`.** The live `public/nvdcve-2.0-<feed>.json.gz` is written only after the full feed is aggregated, count-verified (§V.31), and `gzip -t`-validated. Per-page chunks + `checkpoint` stage in a dir **outside** the deployed tree (`${TMPDIR:-/tmp}/nvd-part/<feed>/`, overridable via `staging_dir`), never under `public/`, so a partial feed can never be force-pushed to Pages. The assembled `.gz` is moved into `public/` atomically; the staging dir is removed on success. A partial fetch never overwrites a good prior file.
33. **Cachix retention ~1 week.** Because the `modified` feed hash changes daily (§V.26), `nvd-cache` is a fresh store path each run; CI runs `cachix gc` / a pin-retention policy keeping ~7 days of `nvd-cache` paths so `pr0d1r2.cachix.org` does not grow unbounded. Older paths are collectable; consumers always resolve the current rev.
34. **Each `checks.${system}` derivation carries its own tool closure.** A check runs in the Nix sandbox and does not inherit the dev shell, so every check derivation lists the binaries it invokes in `nativeBuildInputs` — including **`pkgs.bats`** for every check that runs a `.bats`/`bats test_*.sh` (e.g. the `download` check pulls `bats`+`bash`/`jq`/`gzip`/`coreutils`; the `shellcheck` check pulls `shellcheck`). A missing `bats` is the easy mistake.

41. **Deterministic gzip — feed bytes are a pure function of CVE content.** Every feed `.gz` is written with `gzip -n` (omit original filename **and** mtime from the header) at a fixed compression level, so recompressing identical CVE content yields **byte-identical** output. This is load-bearing: it is what keeps a feed's `sha256` — hence its `feeds.lock` entry and FOD path (§V.15/§V.26) — stable across runs when its content is unchanged, so only feeds whose CVEs actually changed move the lock and trigger an `nvd-cache` rebuild / Cachix push (§V.16, §V.33). Plain `gzip` (with header mtime) would make every feed's hash churn daily and defeat the reproducible-cache design.

42. **`.gitignore` must always ignore `public/` and `staging_dir`, and must never ignore `feeds.lock`.** `sync-setting` composes the repo `.gitignore` from fragments (§V.20); the composition MUST include a project fragment ignoring `public/` and the staging dir, or a sync would un-ignore the generated feeds and let `download.sh`'s output get committed — breaking the gitignored-`public/` premise the whole FOD/`feeds.lock` design rests on (§V.15). `feeds.lock` is committed (§V.26) and must stay tracked. T17 verifies the post-sync `.gitignore` still ignores `public/`.

### Incremental mirror (§V.2)

35. **Daily window = single small `lastMod` query.** A normal run fetches one window `lastModStartDate = now − daily_window_days` … `lastModEndDate = now` (`daily_window_days = 7` by default), paginated (§V.28–§V.32). It does **not** issue any `pubStartDate`/`pubEndDate` year query. The window is deliberately **much smaller than the 120-day cap**: a 120-day `lastMod` window is 100k+ CVEs (~100MB, ~1.5h to download anon and large enough to OOM/segfault naive processing), whereas a daily incremental only needs to cover the gap since the last successful run plus slack. `window_days = 120` remains the NVD hard cap (§V.36) and the **bootstrap** chunk size (§V.39); `daily_window_days` (≤ `window_days`) is the daily lookback and self-heal horizon — 7 days self-heals up to a week of missed runs while staying fast and bounded. Longer gaps need a one-off larger `DAILY_WINDOW_DAYS` or a re-bootstrap.
36. **NVD 120-day hard limit.** No single NVD API query may span more than 120 days (applies to both `pubStart/pubEnd` and `lastModStart/lastModEnd`); a wider range is rejected by NVD. Every query the script issues — daily window and each bootstrap window — respects this.
37. **Prior state is the published mirror.** At run start `download.sh` seeds `public/` by downloading the currently-published feeds over HTTP from `pages_url` (the previous day's deploy — stable, not affected by the current run's propagation). The accumulated timeline is this published set; each run reads it, merges the new window, and redeploys.
38. **Bucket by CVE-ID year (NVD convention), upsert by id + `lastModified`.** A CVE's bucket is the **`YYYY` in its CVE id** (`CVE-2023-1234` → `nvdcve-2.0-2023.json.gz`), **not** its publication date — this matches what NVD/vulnix expect from `nvdcve-*-{year}` files. Each CVE in the fetched window is upserted into its id-year bucket: replace an existing entry only if the incoming `lastModified` is newer, insert if absent. The `modified` feed is **the recent slice** of the window — only CVEs with `lastModified ≥ now − modified_days` (`modified_days = 2` by default), **not** the whole merge window — so it stays small (well under GitHub's 100 MB/file git limit) even when NVD mass-modifies, while the **full** wide window is still merged into the year buckets (the buckets are the complete source of truth; `modified` is the recent-delta convenience feed). `modified_days ≤ daily_window_days`. Re-emit only the affected year files. The rolling window is defined over **id-years** `(current_year-5)…current_year`; buckets outside it are pruned. (A recently-published CVE with an older id-year that falls outside the window is intentionally dropped — the mirror is a bounded recent-window mirror, §V.2.) **Every in-window id-year must have a feed**, even with zero CVEs: vulnix requests all of `current-5…current` and a missing file 404s (and `raise_for_status()` aborts its whole update), so a year with no `CVE-{year}-*` yet (e.g. a freshly-rolled-over January) is published as an **empty-but-valid** feed (`{…,totalResults:0,vulnerabilities:[]}`). **In December the mirror also pre-publishes an empty `current_year+1` feed**, so a consumer running at 00:00 UTC on Jan 1 — whose `current` already ticked over before the mirror's first new-year run — still finds the year it asks for instead of 404-aborting. Thus `feeds.lock` carries the in-window years (+ the pre-published next year in December) + `modified`.
39. **One-time bootstrap.** When the mirror is empty (no prior state), `download.sh` backfills history by querying **sequential ≤120-day `pubStart/pubEnd` windows** spanning the retained id-years (~19 windows), routing every returned CVE to its **id-year bucket** (§V.38) and discarding any whose id-year is outside the window, then proceeds as normal. Bootstrap and the daily path use the **same** id-year bucketing + upsert, so they cannot disagree. A bootstrap is idempotent and resumable via the §V.30 checkpoint. Missed daily runs self-heal: the 120-day lookback far exceeds the daily cadence, so no gap forms.

### vulnix compatibility (§D)

44. **`nvd-cache` version is content-addressed to `feeds.lock`, not the flake date.** `version = hashString sha256 (readFile ./feeds.lock)` (truncated), never `self.lastModifiedDate`. The flake's `lastModifiedDate` changes on every commit (including the daily `feeds.lock` commit), so a date-based version would give two revs with *identical* feeds different store paths → cross-rev cache misses. Keying the version to `feeds.lock` content means the `nvd-cache` path changes **iff** a feed hash changed, maximising substitute hits.

43. **Read-only store path is not usable as a cache-dir — consumers must copy `Data.fs`.** Confirmed from source: vulnix opens `ZODB.FileStorage.FileStorage(Data.fs)` **read-write (no `read_only` flag)** and `os.makedirs(cache_dir)`, so pointing `-c` at the read-only `/nix/store` path **fails** — there is no read-only invocation to fall back on. Consumers copy `Data.fs` into a writable dir (`install -m644 <store>/Data.fs /var/cache/vulnix/Data.fs`); FileStorage rebuilds its `.index` there from `Data.fs` alone. The consumer helper (T14) performs this copy into `/var/cache/vulnix`; docs (T13) state it explicitly.

40. **The `nvd-cache` build is the integration test.** `nvd-cache` drives `vulnix` against the mirrored feeds at build time (§V.15); if the pinned `vulnix` cannot consume the published layout, the build fails and CI/mirror go red — verified continuously, not assumed. vulnix (current) **is NVD-API-2.0-native** and expects exactly our `nvdcve-2.0-{year|modified}.json.gz` over its `-m/--mirror`, with year range `current-5…current` — matching `download.sh`. It uses **ETag** conditional requests, **not** `.meta` sidecars, so the mirror needs no `.meta` files (GitHub Pages serves ETags automatically).
46. **Feeds are served to vulnix over loopback HTTP at build time (vulnix is HTTP-only).** vulnix fetches via `requests.get(mirror + file)` and ships **no `file://` adapter**, so `-m file://…` raises `InvalidSchema`. The `nvd-cache` build instead starts a throwaway HTTP server bound to `127.0.0.1` serving `${feedFarm}`, and points `vulnix -m http://127.0.0.1:<port>/`. The Nix build sandbox permits loopback (but not external) networking, so this stays hermetic — all bytes come from the local feed FODs, never the network. The server is killed on phase exit. The port is **derived per-build** (e.g. from `$NIX_BUILD_TOP`) rather than a fixed constant: on Linux each build has its own network namespace so collisions are impossible, but on macOS (sandbox often disabled) the loopback is shared, so a build-unique high port avoids clashes between concurrent builds.
49. **`feeds.lock` and `serve-feeds.py` must be committed before the flake is used (no eval chicken-egg).** The flake reads `./feeds.lock` and references `${./serve-feeds.py}` at evaluation time, so both must exist in-tree or `nix flake check`/`nix build`/`nix develop` fail to evaluate — which would break the very PR that introduces the flake (T23). Therefore T23 commits an **initial real `feeds.lock`** (seeded from a first manual mirror run, or hand-written for the current six id-years + `modified`) **and** `serve-feeds.py` in the same change. The flake additionally guards a missing lock (`pathExists` → `{}`, §V.15 sketch) so the devShell and checks still evaluate; only `nvd-cache` requires a populated lock. After go-live the daily mirror keeps the lock current (§V.26).

48. **The build's HTTP server synthesizes an empty feed for any absent in-range year (404-abort immunity).** vulnix computes its requested year set as `current-5…current` from **today's date** and calls `raise_for_status()` — so a single missing year feed (HTTP 404) **aborts the whole update**. But `feeds.lock`/`${feedFarm}` is a *snapshot* from the last mirror run, which can lag vulnix's date at year rollover (e.g. a build on Jan 1 wants the new year before the mirror has published it). To stay robust, the server does **not** plain-serve a static dir: for a requested `nvdcve-2.0-<year>.json.gz` that is **not** in `feedFarm`, it returns a synthetic **empty-but-valid** feed (`{…,totalResults:0,vulnerabilities:[]}`, gzipped) with HTTP 200 instead of 404; real feeds are served as-is. This makes the build immune to the build-date↔lock-snapshot skew (and to vulnix requesting a year the mirror legitimately has no CVEs for). Consumers using the **raw mirror** (`vulnix --mirror <pages>`) are protected at rollover by §V.38's December pre-publish of the next-year empty feed; the prebuilt `nvd-cache` substitute is unaffected either way.
47. **The build uses an empty package manifest to trigger retrieval.** vulnix processes scan targets *before* NVD retrieval. A store path makes it call `nix-store -qd`, but a pure build sandbox has a private, empty store database even though input paths are mounted, so the lookup fails before feeds are fetched. Passing `--from-file packages.json` with `{}` loads zero derivations without querying `nix-store`, then proceeds normally into `NVD.update()`. This reliably drives feed compilation into the cache directory while keeping the build hermetic.
45. **Build success is decoupled from vulnix's vulnerability exit code.** vulnix exits **non-zero when it finds vulnerabilities** — that is a normal scan result, not a build failure. The `nvd-cache` build therefore ignores vulnix's exit status (`vulnix … || true`) and keys success on a **separate artifact check**: `test -s $cache/Data.fs` (a non-empty database was produced). Finding vulns while building must never block asset generation; only a missing/empty `Data.fs` (vulnix couldn't fetch/parse the feeds) fails the build, which is exactly the §V.40 integration signal. (vulnix has **no `--update` verb**; the cache is populated as a side-effect of running one scan.)

50. **Feed payloads never pass through a shell variable or `jq --argjson`; all feed merge/transform is file/stream-based.** A real id-year bucket holds 25k+ CVEs (~100MB JSON). Slurping a feed into a shell variable and passing it as a single `argv` string (`jq --argjson a "$existing"`) overflows the kernel per-arg limit (`MAX_ARG_STRLEN`, 128 KiB on Linux) and crashes (`exit 139`). Therefore `merge_window` (and any feed transform) decompresses feeds to **files** and feeds jq from files (`--slurpfile` / `-s` / positional file args) — bounded memory, no argv limit — so it scales to real feeds. Tests MUST exercise a **realistically large window** (thousands of CVEs in one feed), since a 1-CVE mock cannot surface this class (it passed CI while the live nightly crashed — §B.9).

51. **The repo ships a committed `.envrc` (`use flake`) so [direnv](https://direnv.net) + [nix-direnv](https://github.com/nix-community/nix-direnv) auto-load `devShells.default` on `cd`** — developers get every project tool (`just`, `shellcheck`, `bats`, `vulnix`, `cachix`, …, §V.19) without a manual `nix develop`. Each developer runs `direnv allow` once to trust the file (security: `.envrc` is executable config). `.direnv/` is `.gitignore`d. Requires the devShell to exist (T17).

## §I — Interfaces

### CLI — `download.sh`

```
bash download.sh
```

**Environment / globals used inside the script:**

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `NVD_MIRROR_URL` | env var | `https://services.nvd.nist.gov/rest/json/cves/2.0` | NVD API 2.0 base URL (set to override the default) |
| `NVD_API_KEY` | env var | _(unset)_ | Optional NVD API key for higher rate limits (5→50 req/30s); sent as `apiKey:` header. Acquire at <https://nvd.nist.gov/developers/request-an-api-key> (form → one-time email activation link → UUID shown once), then store as the repo `NVD_API_KEY` secret (§V.27) |
| `NVD_RATE_DELAY` | env var | `6` | Seconds to wait between paginated API requests |
| `NOTIFICATION_WEBHOOK_URL` | env var | _(unset)_ | Optional webhook URL for failure notifications (Slack-compatible JSON payload) |
| `nvd_api_url` | string | `$NVD_MIRROR_URL` or default | Resolved NVD API base URL |
| `outdir` | string | `public` | Output directory for downloaded feeds |
| `current_year` | int | `$(date +%Y)` | Current calendar year |
| `start_year` | int | `current_year - 5` | First **CVE-id year** to keep (older id-year buckets pruned, §V.38) |
| `window_days` | int | `120` | Daily/bootstrap query window — NVD's max range (§V.35, §V.36) |
| `pages_url` | string | `https://pr0d1r2.github.io/nix-vulnix-nvd-mirror` | Prior-state source for the incremental seed (§V.37) |
| `max_retries` | int | `3` | Maximum feed-level download attempts (resumes via checkpoint, §V.30) |
| `base_delay` | int | `60` | Feed-level base backoff delay in seconds |
| `results_per_page` | int | `2000` | NVD page size (`resultsPerPage`, API max) |
| `max_page_retries` | int | `6` | Per-page retry attempts (§V.28) |
| `page_base_delay` | int | `5` | Per-page base backoff in seconds (×2 each attempt) |
| `page_max_delay` | int | `300` | Per-page backoff cap in seconds |
| `staging_dir` | string | `${TMPDIR:-/tmp}/nvd-part` | Per-feed checkpoint staging, **outside** `public/` (§V.30, §V.32) |

**Functions:**

- `send_failure_notification() -> void` — Sends a JSON payload (`{"text": "..."}`) to `NOTIFICATION_WEBHOOK_URL` if set; silently skipped when unset. Called by the ERR trap handler. Notification failures are suppressed to avoid masking the original error.
- `cleanup_on_failure() -> void` — ERR trap handler that removes the output directory `public/` **and** `staging_dir` on failure, preventing deployment of incomplete feeds (§V.13, §V.30). Calls `send_failure_notification()` before cleanup. A failed run retains the previous day's published deploy.
- `_fetch_page(url: string, start_index: int, dest_dir: string) -> 0 | 1` — Fetches one page (`startIndex=<n>&resultsPerPage=2000`) with per-page exponential backoff + jitter (§V.28). On HTTP `429`/`503` reads `Retry-After` (via `curl -D`) and sleeps that long (§V.29). On success writes `page-<start_index>.json` (the page's `vulnerabilities[]`) into `dest_dir` and updates `checkpoint`. Returns non-zero only after exhausting per-page attempts.
- `_fetch_api_feed(url: string, dest: string) -> 0 | 1` — Drives pagination for one feed using a checkpoint dir `${staging_dir}/<feed>/` (**outside `public/`**, §V.30): reads `checkpoint` to resume from `lastIndex` (or starts at 0), reads `totalResults` from the first page, then loops `_fetch_page` until `startIndex >= totalResults` (§V.30). Aggregates all `page-*.json`, **dedups by CVE id** (newest `lastModified` wins) and verifies the deduped count ≥ the final page's `totalResults` (§V.31), assembles the final JSON, gzips it **deterministically (`gzip -n`, §V.41)**, validates with `gzip -t`, atomically moves it to `dest`, and removes `${staging_dir}/<feed>/` (§V.32). Returns non-zero on any page exhaustion, count mismatch, or invalid JSON.
- `download_with_retry(url: string, dest: string) -> 0 | 1` — Feed-level wrapper: retries `_fetch_api_feed` up to `max_retries` with backoff; because `_fetch_api_feed` resumes from the checkpoint (§V.30), a retry continues rather than restarts. Prints `OK: <filename>` on success to stdout; prints `FAIL: <url>` and `Retry ...` to stderr.
- `seed_prior_state() -> void` — Downloads the currently-published feeds from `pages_url` into `public/` so the run starts from the accumulated timeline (§V.37). Absent prior state ⇒ triggers bootstrap (`is_bootstrap=1`).
- `merge_window(window_json: path) -> void` — Upserts the CVEs of a fetched ≤120-day window into **id-year buckets** in `public/` (bucket = the `YYYY` in the CVE id, §V.38), keyed by CVE id + `lastModified` (newer wins), rewrites `nvdcve-2.0-modified.json.gz`, re-emits only affected year files (recompressed with `gzip -n`, §V.41), and prunes buckets outside `start_year…current_year` (dropping CVEs whose id-year is out of window).
- `bootstrap() -> void` — When `public/` has no prior state, backfills via sequential ≤120-day `pubStart/pubEnd` windows over the retained id-years (§V.39), each fetched by `download_with_retry` and fed to `merge_window` (same id-year bucketing, so out-of-window id-years are discarded). Resumable via the §V.30 checkpoint.

**Top-level flow:** `seed_prior_state` → (`bootstrap` if empty) → fetch one `lastMod` window (`now-window_days`…`now`) → `merge_window` → write `sha256sums.txt` → verify.

**Output artifacts:**

- `public/nvdcve-2.0-{year}.json.gz` — one per year in the rolling window
- `public/nvdcve-2.0-modified.json.gz` — recently modified CVEs (the latest ≤120-day window)
- `public/sha256sums.txt` — hex `sha256` of each `.json.gz` (T2); `feeds.lock` SRI (§V.26) is derivable from these, avoiding a second hashing pass

**Transient staging (continuation, §V.30):** lives in `staging_dir` **outside** `public/`; removed on success, never deployed.

- `${staging_dir}/<feed>/page-<startIndex>.json` — per-page `vulnerabilities[]` chunks
- `${staging_dir}/<feed>/checkpoint` — resume state, e.g.:

```
lastIndex=4000
totalResults=24891
```

### GitHub Actions — `.github/workflows/ci.yml`

- **Trigger:** `push`, `pull_request`, and `workflow_call` (so `mirror.yml` can reuse it as a gate). `push` sets `paths-ignore: [feeds.lock]` so the daily data-only `feeds.lock` commit (§V.26) does not spend a redundant CI run.
- **Steps (build first, then check — §V.21):**
  1. `actions/checkout` (SHA-pinned) + `cachix/install-nix-action` (SHA-pinned) configured with `extra_nix_config: experimental-features = nix-command flakes` (required for `nix build`/`nix flake check`).
  2. `cachix/cachix-action` (SHA-pinned) with `name: pr0d1r2` and `authToken: ${{ secrets.CACHIX_AUTH_TOKEN }}` — auto-pushes whatever the build step produces; no-op when the token is absent (§V.23).
  3. **Build** the intended closures, each **named** (no `.*` wildcard): `nix build .#devShells.${system}.default .#checks.${system}.shellcheck .#checks.${system}.download .#checks.${system}.checksum .#checks.${system}.flake .#checks.${system}.health-check` — pushed to Cachix by step 2.
  4. **Check** with `nix flake check --no-build` — evaluates + runs the already-built `checks.${system}`; **builds nothing** (§V.21, §V.34).
- **Never builds `nvd-cache`** — `nix flake check` builds only `checks` (not `packages`), it is not in the step-3 build set, and `--no-build` builds nothing; the cache build is mirror-only (§V.22).

### GitHub Actions — `.github/workflows/mirror.yml`

- **Trigger:** `schedule` (daily 04:00 UTC) or `workflow_dispatch` (manual)
- **Concurrency:** `mirror-deploy` group with `cancel-in-progress: true`
- **Gate:** a `check` job calls `ci.yml` via `uses: ./.github/workflows/ci.yml`; the deploy job sets `needs: check`, so feeds deploy only after `nix flake check` passes (§V.24).
- **Secrets:** `NVD_API_KEY` (env for `download.sh`, §V.27), `CACHIX_AUTH_TOKEN` (cache push, §V.23).
- **Checkout:** `fetch-depth: 0` so the daily `feeds.lock` commit can `git pull --rebase`/push without non-fast-forward errors on a shallow clone.
- **Nix config:** `install-nix-action` sets `experimental-features = nix-command flakes` (needed by `nix build .#nvd-cache`).
- **Steps (deploy job, after gate):**
  1. `download.sh` — seeds `public/` from the published mirror, merges the latest ≤120-day window (bootstraps if empty), uses `NVD_API_KEY` if set (§V.35–§V.39).
  2. `peaceiris/actions-gh-pages@v4.1.0` (SHA-pinned) — deploys `./public` to GitHub Pages.
  3. `health_check.sh` — post-deploy verification that the live Pages endpoint serves valid gzip feeds (T5).
  4. Regenerate `feeds.lock` (`nix hash file --sri --type sha256` per `public/*.json.gz`) and **commit to `main`** — `git pull --rebase` first to avoid non-fast-forward; commit message carries `[skip ci]` as a backstop to `paths-ignore` (§V.26).
  5. **Pre-seed feed FODs from local bytes:** `nix-store --add-fixed sha256 public/nvdcve-2.0-*.json.gz` — populates the exact flat-FOD store paths so the next build skips the lagging Pages fetch (§V.15a).
  6. `nix build .#nvd-cache` — feed FODs already in store; `cachix-action` (`CACHIX_AUTH_TOKEN`) pushes the result to `pr0d1r2.cachix.org` (§V.22, §V.24); a retention step trims to ~7 days (§V.33).

### GitHub Pages endpoint

```
https://pr0d1r2.github.io/nix-vulnix-nvd-mirror/nvdcve-2.0-{year}.json.gz
```

Used by vulnix via:

```
vulnix --mirror https://pr0d1r2.github.io/nix-vulnix-nvd-mirror/ ./result
```

### Nix flake — pre-built vulnix cache

**Inputs:**

```nix
inputs = {
  nixpkgs-lock.url = "github:pr0d1r2/nixpkgs-lock";
  nixpkgs.follows = "nixpkgs-lock/nixpkgs";
  flake-utils.url = "github:numtide/flake-utils";
  set-and-setting.url = "github:pr0d1r2/set-and-setting";
  set-and-setting.inputs.nixpkgs.follows = "nixpkgs";
};
```

`nixpkgs` resolves transitively to the ecosystem-wide pinned revision (see §V.18); a daily cron bumps `nixpkgs-lock` and PRs only on rev change.

**Consumer substituter config** (§V.25) — declared at flake top level so trusting hosts substitute the cache with zero compile:

```nix
nixConfig = {
  extra-substituters = [ "https://pr0d1r2.cachix.org" ];
  extra-trusted-public-keys = [ "pr0d1r2.cachix.org-1:<pubkey>" ];
};
```

```
nix build github:pr0d1r2/nix-vulnix-nvd-mirror#nvd-cache
```

- **Output:** `packages.${system}.nvd-cache` — a store path containing a vulnix-compatible database (`Data.fs`) compiled from the mirrored feeds.
- **Build source:** feeds are flat fixed-output derivations pinned by `sha256` in `feeds.lock` (§V.15, §V.26) — **not** a working-tree `public/`. The FOD path is `f(name, sha256)` only, so it is reproducible from any checkout and (via §V.15a pre-seed) builds without depending on Pages propagation. The feed list comes from `feeds.lock` keys (§V.15b).

```nix
# sketch
let
  pages = "https://pr0d1r2.github.io/nix-vulnix-nvd-mirror";
  # feeds.lock is committed (§V.26, §V.49); guard so the flake still EVALUATES
  # if it is ever absent (devShell/checks keep working; only nvd-cache needs it).
  lock  = if builtins.pathExists ./feeds.lock
          then builtins.fromJSON (builtins.readFile ./feeds.lock) else {};
  feeds = builtins.attrNames lock;                          # §V.15b single source of truth
  mkFeed = n: let f = "nvdcve-2.0-${n}.json.gz"; in
    pkgs.fetchurl { name = f; url = "${pages}/${f}"; sha256 = lock.${n}; };  # flat FOD
  feedFarm = pkgs.linkFarm "nvd-feeds"
    (map (n: { name = "nvdcve-2.0-${n}.json.gz"; path = mkFeed n; }) feeds);
in pkgs.stdenv.mkDerivation {
  pname = "nvd-cache";
  # version derived from feeds.lock content, NOT the flake date — so two revs
  # with identical feeds yield the SAME store path (cross-rev cache hit). §V.44
  version = builtins.substring 0 12 (builtins.hashString "sha256" (builtins.readFile ./feeds.lock));
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.vulnix ];   # vulnix already depends on ZODB (§V; Q3) — no extra zodb
  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR; mkdir -p $TMPDIR/cache
    # vulnix is HTTP-only (no file:// adapter), so serve feeds on loopback (§V.46).
    # Custom handler: absent in-range year -> synthetic empty feed (200), not 404 (§V.48).
    port=$(( 20000 + $(echo $NIX_BUILD_TOP | cksum | cut -d' ' -f1) % 20000 ))   # build-unique (§V.46)
    ${pkgs.python3}/bin/python ${./serve-feeds.py} ${feedFarm} $port & server=$!
    trap "kill $server" EXIT
    until ${pkgs.curl}/bin/curl -sf http://127.0.0.1:$port/nvdcve-2.0-modified.json.gz -o /dev/null; do sleep 0.2; done
    vulnix_mirror=http://127.0.0.1:$port/
    # empty manifest reaches NVD.update() without sandbox-inaccessible nix-store metadata (§V.47)
    printf '{}\n' > $TMPDIR/packages.json
    vulnix -m $vulnix_mirror -c $TMPDIR/cache --from-file $TMPDIR/packages.json || true
    test -s $TMPDIR/cache/Data.fs                                       # real success gate (§V.40/§V.45)
    runHook postBuild
  '';
  installPhase = "mkdir -p $out; cp $TMPDIR/cache/Data.fs $out/";
}
```

- **Consumed** by pointing vulnix at the store path instead of downloading and compiling:

```
vulnix -c "$(nix build --no-link --print-out-paths github:pr0d1r2/nix-vulnix-nvd-mirror#nvd-cache)" -R <path>
```

> **Read-only store caveat (§V.43, T13/T14):** the `nvd-cache` store path is read-only, but vulnix opens `Data.fs` **read-write** (confirmed: no `read_only` flag), needing a writable dir for the lock + rebuilt `.index`. Pointing `--cache-dir` straight at `/nix/store/…` **fails** — there is no read-only mode. Consumers must **copy `Data.fs` into a writable dir** first: `install -m644 <store>/Data.fs /var/cache/vulnix/Data.fs` (FileStorage regenerates `.index` from `Data.fs` alone). The `nixosModules` helper (T14) does this copy declaratively.

- **Binary cache:** the `nvd-cache` derivation is served from `pr0d1r2.cachix.org`, so on a trusting host the copy is a pure substitution — zero download, zero compile.

### Feeds lock — `feeds.lock`

Committed JSON pinning each published feed's gzip hash as **SRI** (`sha256-…`, from `nix hash file --sri --type sha256`); the reproducibility anchor for `nvd-cache` (§V.26) and the single source of truth for the feed list (§V.15b). Regenerated + committed daily by `mirror.yml` after deploy. Keys are the feed names (`{year}`, `modified`); values feed `fetchurl`/FOD directly.

```json
{
  "2021": "sha256-…", "2022": "sha256-…", "2023": "sha256-…",
  "2024": "sha256-…", "2025": "sha256-…", "2026": "sha256-…",
  "modified": "sha256-…"
}
```

### Nix flake — CI dev shell (`devShells.default`)

`nix develop` enters a closure carrying every CI tool plus the agent set/setting (see §V.19, §V.20). CI runs each step inside this shell, so local and CI environments are identical.

```nix
devShells.${system}.default = pkgs.mkShell {
  buildInputs = [
    # CI tools — must match every binary mirror.yml invokes
    pkgs.bash pkgs.shellcheck pkgs.bats pkgs.curl pkgs.jq pkgs.gzip
    pkgs.nix pkgs.vulnix pkgs.cachix pkgs.just

    # set-and-setting: agent skills + env standards, wired together
    (set-and-setting.lib.mkSet {
      inherit pkgs;
      categories = [ "generic" "git" "nix" "security" ];
    })
    (set-and-setting.lib.mkSetting {
      inherit pkgs;
      editorconfig = true;
      gitattributes = true;
      gitignore = true;
      markdownlint = true;
      yamllint = true;
    })
  ];

  # populate working tree with the composed set + setting on shell entry
  shellHook = ''
    sync-set
    sync-setting
  '';
};
```

Usage:

```
nix develop            # enter CI-equivalent shell; sync-set + sync-setting run
shellcheck *.sh        # same shellcheck CI uses
bats test_*.sh         # same bats CI uses
```

### Nix flake — checks (`nix flake check`)

`checks.${system}` wraps every verification script as a derivation, so one command runs them all (§V.21):

Each check is a sandboxed derivation carrying its own tool closure (§V.34):

```nix
checks.${system} = {
  shellcheck   = run [ pkgs.shellcheck ]                          "shellcheck *.sh";
  download     = run [ pkgs.bats pkgs.bash pkgs.jq pkgs.gzip pkgs.coreutils ] "bats test_download.sh";
  checksum     = run [ pkgs.bats pkgs.bash pkgs.coreutils ]       "bats test_checksum.sh";
  flake        = run [ pkgs.bats pkgs.bash ]                      "bats test_flake.sh";
  health-check = run [ pkgs.bats pkgs.bash pkgs.gzip ]            "bats test_health_check.sh";
};
# run = inputs: cmd: pkgs.runCommand "check" { src = ./.; nativeBuildInputs = inputs; }
#                      "cd $src; ${cmd}; touch $out";
# Every bats-running check MUST include pkgs.bats in its inputs (§V.34).
```

```
nix flake check          # run all checks (CI / ci.yml)
nix build .#nvd-cache    # build cache — only in mirror.yml, after feeds.lock (§V.22)
```

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
| `x` | T11 | Add a `flake.nix` exposing `packages.<system>.nvd-cache` — a derivation that compiles the mirrored feeds into a pre-built vulnix database (`Data.fs`) store path, so consumers get zero-download and zero-compile |
| `.` | T17 | **(pick first)** Scaffold `devShells.${system}.default` in `flake.nix` and wire [`set-and-setting`](https://github.com/pr0d1r2/set-and-setting): add the input, compose `set-and-setting.lib.mkSet` (`generic`/`git`/`nix`/`security`) + `lib.mkSetting` (`editorconfig`/`gitattributes`/`gitignore`/`markdownlint`/`yamllint`) plus every CI/local tool (`bash`/`shellcheck`/`bats`/`curl`/`jq`/`gzip`/`nix`/`vulnix`/`cachix`/`just`) into `buildInputs`, and run `sync-set` + `sync-setting` in `shellHook` (§V.19, §V.20). Ensure the composed `.gitignore` still ignores `public/` + `staging_dir` and keeps `feeds.lock` tracked (§V.42). Ship `.envrc` (`use flake`) for direnv auto-loading (§V.51) |
| `.` | T15 | Adopt [`nixpkgs-lock`](https://github.com/pr0d1r2/nixpkgs-lock): change `flake.nix` inputs to `nixpkgs.follows = "nixpkgs-lock/nixpkgs"`, regenerate `flake.lock`, and add a daily cron workflow running `nix flake update nixpkgs-lock` that opens a PR only when the locked rev changes — unifying the nixpkgs version across the pr0d1r2 ecosystem (§V.18) |
| `x` | T19 | Add `checks.${system}` to `flake.nix` wrapping `shellcheck` + every `test_*.sh` as derivations, so `nix flake check` runs all verifications (§V.21) |
| `x` | T20 | Add `.github/workflows/ci.yml` (push/PR/`workflow_call`): install Nix, **build** the devShell + each **named** check (`nix build .#devShells.${system}.default .#checks.${system}.{shellcheck,download,checksum,flake,health-check}` — no `.*` wildcard; pushed to `pr0d1r2.cachix.org` via `cachix-action` + `CACHIX_AUTH_TOKEN`, skip when absent), **then** `nix flake check --no-build`. Never builds `nvd-cache` (§V.21, §V.22, §V.23) |
| `.` | T21 | Gate `mirror.yml` on `ci.yml`: add a `check` job `uses: ./.github/workflows/ci.yml` and set the deploy job `needs: check`, so feeds deploy only after `nix flake check` passes (§V.24) |
| `x` | T23 | **Refactor `nvd-cache` for reproducibility:** drop `src = ./public`; model each feed as a flat fixed-output `pkgs.fetchurl` (path = `f(name,sha256)`), pin via committed `feeds.lock`, derive the feed list from `builtins.attrNames lock` (§V.15b), assemble with `linkFarm`. Same derivation hash for mirror/CI/consumer → Cachix substitute hits (§V.15, §V.15a, §V.26). **Fix the broken buildPhase** (§B.8): drop `pkgs.python3Packages.zodb`, serve `feedFarm` on loopback HTTP via a small handler that synthesizes empty feeds for absent in-range years (§V.46/§V.48), load an empty package manifest (§V.47), `… || true`, gate on `test -s Data.fs` (§V.45). **Commit `serve-feeds.py` and an initial real `feeds.lock` in the same PR** so the flake evaluates (§V.49). **Also update `test_flake.sh`** (Test 4 "feeds from public/" assertion is obsolete; keep Test 2's `packages.nvd-cache` grep matching) so the gated check stays green |
| `.` | T12 | In `mirror.yml` deploy job, after Pages deploy + `health_check.sh`: regenerate `feeds.lock` (SRI) and commit to `main` (`git pull --rebase`, `[skip ci]`); `nix-store --add-fixed sha256 public/*.json.gz` to pre-seed feed fixed-output derivations (§V.15a); `nix build .#nvd-cache`; push to `pr0d1r2.cachix.org` via `cachix-action`; trim to ~7 days (§V.16, §V.22, §V.24, §V.26, §V.33) |
| `.` | T24 | Pass `NVD_API_KEY` secret as env to `download.sh` in `mirror.yml` for authenticated NVD rate limits; run still succeeds if absent (§V.27). Document acquisition (request form → email activation → UUID → repo secret) in `CONTRIBUTING.md`/`README.md` |
| `.` | T22 | Add `nixConfig.extra-substituters` + `extra-trusted-public-keys` for `pr0d1r2.cachix.org` to `flake.nix` so trusting consumers substitute with zero compile; document the `--accept-flake-config`/trust requirement (§V.25) |
| `.` | T18 | Make CI run its steps inside `nix develop` (replace ad-hoc `uses:`/`run:` tool installs with the dev-shell closure) so local and CI environments are identical (§V.19) |
| `x` | T25 | **Resumable per-page fetch** (foundation for T28): `_fetch_page` with per-page exponential backoff + jitter and `Retry-After` handling, `${staging_dir}/<feed>/` checkpoint **outside `public/`**, resume-from-`lastIndex`, `totalResults` completeness guard, deterministic `gzip -n` assembly (§V.28–§V.32, §V.41) — makes the keyless path reliable and feed bytes reproducible |
| `x` | T28 | **Incremental-mirror rewrite of `download.sh`** (fixes the live 120-day bug §B.5; builds on T25): `seed_prior_state` from `pages_url`, daily single ≤120-day `lastMod` window, `merge_window` upsert into **id-year** buckets (newer `lastModified` wins) + prune + **emit empty feeds for in-window years with no CVEs + pre-publish an empty `current_year+1` feed in December** (§V.38, so vulnix never 404s, incl. the UTC rollover), one-time `bootstrap` over sequential ≤120-day windows, self-heal (§V.2, §V.35–§V.39) |
| `.` | T26 | Extend `test_download.sh`: for T25 — HTTP 429 + `Retry-After`, per-page retry, checkpoint resume, **dedup-by-id idempotence** + `totalResults`-drift tolerance (count ≥ final page), staging never in `public/` (§V.28–§V.32); for T28 — **120-day window cap**, **id-year bucketing** (CVE-2023→2023 feed regardless of pub date), `merge_window` upsert (newer wins / new insert), out-of-window prune, **empty-year feed emitted** (zero-CVE in-window year still produces a valid feed), bootstrap (§V.35–§V.39) |
| `.` | T27 | Add Cachix retention to CI: keep ~7 days of `nvd-cache` paths (`cachix gc` / pin policy) so `pr0d1r2.cachix.org` doesn't grow unbounded (§V.33) |
| `.` | T29 | **Verify vulnix consumes the published 2.0 feed layout** (§B.6, §V.40): drive the pinned `vulnix -m http://127.0.0.1:<port>/ -c <dir> --from-file packages.json` (loopback-served feeds, §V.46; empty manifest, §V.47; exit decoupled, §V.45); confirm `nvd-cache` builds a non-empty `Data.fs`. (vulnix source confirms 2.0 + our filenames; this closes the residual end-to-end check.) |
| ~~`.`~~ | ~~T30~~ | ~~Emit legacy `.meta` sidecars.~~ **Dropped** — vulnix uses ETag conditional requests, not `.meta`; GitHub Pages serves ETags automatically (§V.40, §B.6). |
| `.` | T31 | Widen `health_check.sh` budget (e.g. `max_attempts=10`, `attempt_delay=60` ⇒ 10 min) or make it non-fatal, to absorb rare GitHub Pages CDN propagation lag without a false-negative red run. Its date-derived `start_year..current_year` list stays correct because every in-window year is published (incl. empty, §V.38) — no Jan-rollover false-fail |
| `.` | T13 | Document consumer usage of the pre-built cache, **including the read-only-store caveat** (copy `Data.fs` to a writable dir; don't point `--cache-dir` at `/nix/store`, §V.43), with examples for cold/ephemeral builders and live-ISO smoke seeding |
| `.` | T14 | Provide a Nix consumer helper (overlay or `nixosModules`) that **copies** `nvd-cache`'s `Data.fs` into a writable `/var/cache/vulnix` declaratively (§V.43) |

## §B — Bugs / Known Issues

1. ~~**Deprecated NVD feed format.**~~ Resolved by T7. The script now uses the NVD API 2.0 (`https://services.nvd.nist.gov/rest/json/cves/2.0`) with pagination support.
2. **No cryptographic verification.** Downloaded `.json.gz` files are verified for gzip integrity (`gzip -t`), but NVD legacy feeds do not provide checksums or signatures for independent authenticity verification.
3. **No tests.** The project has zero automated tests for the download script's logic (retry behavior, year range calculation, error handling).
4. **Cache substitution broken until T23.** The current `nvd-cache` uses `src = ./public`, but `public/` is gitignored, so the derivation hash a consumer computes (empty `public/`) never matches the one CI pushes (feeds present) → cache miss → a silently-empty `Data.fs` is built locally. Fixed by T23 (feeds as flat FODs pinned in `feeds.lock`, mirror pre-seeds paths from local bytes so the build ignores Pages lag, §V.15/§V.15a/§V.15b/§V.26).
5. **LIVE BUG — year feeds exceed NVD's 120-day limit.** `download.sh:127-131` queries a full year (`pubStartDate={year}-01-01`…`pubEndDate={year}-12-31`, 365 days). NVD API 2.0 rejects any date range > 120 days, so **every per-year fetch currently fails** against the real API (only the 120-day `modified` feed works). Fixed by T25 + the incremental redesign (§V.2, §V.35–§V.39): daily ≤120-day `lastMod` window upserted into the published timeline; one-time bootstrap backfills history in ≤120-day windows.
6. ~~**Unverified vulnix↔feed-format compatibility.**~~ Largely resolved by reading vulnix source: it is NVD-API-2.0-native, expects exactly `nvdcve-2.0-{year|modified}.json.gz`, year range `current-5…current`, uses ETag (no `.meta` needed), stores ZODB `Data.fs` — all matching this mirror. Residual: confirm the assembled API-response JSON shape parses cleanly end-to-end (T29, also continuously guarded by §V.40). `.meta` emission (old T30) is **not needed** and dropped.
7. **Non-deterministic gzip (latent).** `download.sh:90` writes feeds with plain `gzip`, embedding mtime+filename in the header, so each run's `.gz` differs byte-wise even when CVE content is identical. Harmless today (feeds aren't hashed for reproducibility yet) but it would silently defeat the `feeds.lock`/FOD design (§V.15/§V.26/§V.41) once T23/T12 land. Fix: `gzip -n` at a fixed level everywhere feeds are written (§V.41); a one-line change to `:90` now, enforced by T25/T28.
8. **LIVE BUG — `nvd-cache` build never worked.** Committed `flake.nix` buildPhase is `vulnix --mirror file://… --cache-dir … --update`, which fails two ways: (a) vulnix has **no `--update` option** (click errors on it); (b) vulnix is **HTTP-only** (`requests`, no `file://` adapter) so `file://` raises `InvalidSchema`. So T11's cache has almost certainly never built. Fixed by §V.45 (decouple vuln-exit, gate on `test -s Data.fs`), §V.46 (serve feeds on loopback HTTP), §V.47 (dogfood `${self}` scan); implemented in T23.
9. **2026-06-28 — `merge_window` segfaults (exit 139) on real feed sizes.** The T28 incremental merge slurped whole feeds into shell variables and passed them to `jq --argjson a "$existing"`; a real id-year bucket (25k+ CVEs, ~100MB) overflows the kernel per-arg limit (`MAX_ARG_STRLEN` 128 KiB) → crash. The §B.5 120-day fix itself worked (NVD accepted the windows; the live run downloaded for 1h37m before crashing in merge), but the 1-CVE mock never exercised scale, so CI was green. Fixed by **§V.50** (file/stream-based merge) + a large-window test. Root cause: feed payload through `argv`.
10. **2026-06-28 (recurrence) — `_fetch_api_feed` segfaults `bash` on the 120-day window.** §B.9's fix covered `merge_window` but **not** the other huge-shell-var path: `_fetch_api_feed` captured the whole aggregated window into `agg=$(…)`. The daily run used the **120-day** `lastMod` window (~100k CVEs, ~100MB); holding that string segfaulted **bash itself** (`PID … Segmentation fault … bash download.sh`) after a 1h20m download. Two fixes: (a) **§V.50 applied to `_fetch_api_feed`** — aggregate via files (`jq -s … > agg.json`), no shell-var capture; (b) **§V.35** — the daily window became `daily_window_days = 30` (later 7), not the 120-day max, so the daily payload is ~¼ the size and fast. Lesson: a §V invariant must be applied to **every** site of its class, not just the one that first failed — `grep` for the pattern (here, `$(… feed …)` captures / `--argjson`) when fixing.
11. **2026-08-17 — `guardrails / check` failed while evaluating the shared actionlint check.** The pinned `set-and-setting` check passed a regex string to nixpkgs' `sourceByRegex`, whose locked API now requires a list, producing `expected a list but found a string`. Fixed with a flake-boundary compatibility adapter that normalizes the argument while retaining the actionlint check.
12. **2026-08-17 — `guardrails / check` failed the execute-permissions check.** Five helper scripts (`publish.sh`, `republish.sh`, `test_checksum.sh`, `test_download.sh`, and `test_flake.sh`) were tracked as executable even though the repository's guardrail requires non-executable scripts to be run explicitly with Bash. Fixed by removing their executable bits.
13. **2026-08-17 — `guardrails / check` failed the file-size check because `config/lefthook/file_size_limits.yml` was missing.** Fixed by adding the required policy with the checker defaults and a larger limit for the committed lock file.
14. **2026-08-17 — `guardrails / check` failed the linter-coverage check because `config/linter-coverage-exemptions.yml` was missing.** Fixed by adding the required empty exemption policy; no files are exempted from lint coverage.
15. **2026-08-17 — `guardrails / check` failed the file-size check for the repository's intentionally large specification and shell test files.** Fixed by defining explicit limits for Markdown and shell files in the required policy.
16. **2026-08-17 — `guardrails / check` flagged the established fixed-output-derivation acronym `FOD` as a typo.** Fixed by documenting the domain abbreviation in the repository typos configuration.
17. **2026-08-17 — `guardrails / check` flagged dummy API-key text in a test fixture as a secret.** Fixed by marking the two non-secret fixture occurrences for the scanner.
18. **2026-08-17 — `guardrails / check` failed because the flake exposed only the guardrail consumer and no `nvd-cache` package.** Fixed by restoring the feeds.lock-backed fixed-output feeds, loopback vulnix build, default package, and named verification checks required by the flake tests.
19. **2026-08-17 — `guardrails / check` failed with `syntax error, unexpected '.'` while evaluating the flake.** The shellcheck derivation used the invalid Nix path interpolation `${./test_*.sh}`; Nix does not expand globs in path literals. Fixed by listing each test script explicitly.
20. **2026-08-17 — flake evaluation failed after parsing with `cannot coerce a function to a string`.** The devShell interpolated the locked `mkSet` and `mkSetting` Nix functions without applying their required package argument. Fixed by invoking both functions with `{ inherit pkgs; }` before interpolating their derivation paths.
21. **2026-08-17 — `guardrails / check` ran repository-aware tests against isolated single-file store paths.** The flake checks interpolated each test script directly, so Nix copied only that script into the sandbox while `SCRIPT_DIR`-based tests expected `flake.nix`, `feeds.lock`, and other siblings. Fixed by passing the complete source tree to every check derivation and declaring the test runtime tools (`jq`, `gzip`, and `curl`) as inputs.
21. **2026-08-17 — `guardrails / check` failed because the flake did not expose the required `confirm` app.** The shared `set-and-setting` guardrail invokes `nix run .#confirm` for its post-materialization acceptance suite, but this consumer flake only exposed packages, shells, and checks. Fixed by wiring the standard `mkConfirmApp` with this flake's pinned settings and `base`/`shell` materialization.
22. **2026-08-17 — `guardrails / check` failed because the generated `lefthook.yml` was absent before the shared guardrail ran.** The file was ignored and only materialized by the dev-shell `sync-setting` hook, which runs after the guardrail's completeness/executability checks. Fixed by committing the canonical generated hook configuration and removing the ignore rule.
23. **2026-08-17 — `guardrails / check` failed because the committed `lefthook.yml` referenced five framework wrappers that the project dev shell did not provide.** The shell manually listed only general-purpose tools, while the pinned `set-and-setting` materialization package set contains the required `lefthook-actionlint`, `lefthook-markdownlint`, `lefthook-markdownlint-agentic`, `lefthook-unicode-lint`, and `lefthook-yamllint` commands. Fixed by building the dev shell with `materialization.packages` through `set-and-setting.lib.mkDevShells`.
24. **2026-08-18 — `guardrails / check-darwin` failed because the flake did not expose the shared standard's top-level `setting` output.** The consumer value existed only as `apps.confirm.setting`, so the guardrail's Darwin invocation of `nix run .#setting` could not resolve `packages.aarch64-darwin.setting` (or its fallback attributes). Fixed by exporting `set-and-setting.lib.mkSetting { inherit pkgs; }` as `packages.setting` for each system.
