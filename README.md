# nix-vulnix-nvd-mirror

[![Mirror NVD feeds](https://github.com/pr0d1r2/nix-vulnix-nvd-mirror/actions/workflows/mirror.yml/badge.svg)](https://github.com/pr0d1r2/nix-vulnix-nvd-mirror/actions/workflows/mirror.yml)

GitHub Pages mirror of NVD JSON feeds for use with
[vulnix](https://github.com/nix-community/vulnix).

## Usage

For an ad-hoc scan that can tolerate downloading feeds, use the Pages mirror:

```
vulnix --mirror https://pr0d1r2.github.io/nix-vulnix-nvd-mirror/ ./result
```

For cold CI runners, ephemeral builders, and live-ISO smoke tests, use the
pre-built cache instead. Configure the public binary cache once:

```nix
# /etc/nix/nix.conf or the equivalent NixOS settings
extra-substituters = https://pr0d1r2.cachix.org
extra-trusted-public-keys = pr0d1r2.cachix.org-1:NfWjbhgAj41byXhCKiaE+av3Vnphm1fTezHXEGsiQIM=
```

Then substitute the current database and seed a writable cache directory:

```bash
cache="$(nix build --no-link --print-out-paths \
  github:pr0d1r2/nix-vulnix-nvd-mirror#nvd-cache)"
sudo install -d -m0755 /var/cache/vulnix
sudo install -m0644 "$cache/Data.fs" /var/cache/vulnix/Data.fs
vulnix -c /var/cache/vulnix -R /run/current-system
```

`Data.fs` in the Nix store is read-only, while vulnix opens its database
read-write and creates lock/index files. Do not pass the store path itself to
`-c`; always copy `Data.fs` to a writable directory first. For an unprivileged
CI job, replace `/var/cache/vulnix` with a job-local directory such as
`"$RUNNER_TEMP/vulnix"`. The scan remains fatal on findings; only feed download
and compilation have moved out of scan time.

On a live ISO, include the flake input in the image closure so the cache is
already on the medium, then perform the same copy into the writable `/var`
overlay before scanning.

## Publishing from a residential machine (fast, un-throttled)

NVD heavily rate-limits datacenter / CI IPs, so the GitHub-hosted mirror job can
be slow. To build + publish from your own machine instead:

```bash
just publish        # first run prompts for the NVD key + stores it; then builds + pushes
```

`just publish` (or `./publish.sh`) resolves the NVD key **env → macOS Keychain →
first-run prompt**: the first time, it asks for your key and saves it to the
Keychain; every run after, it reads it back (Touch-ID gated) — the key never
lands in shell history, env, or argv. It then builds `public/` via `download.sh`
and force-pushes it to `gh-pages` (orphan, same as the workflow).

Get a free key at <https://nvd.nist.gov/developers/request-an-api-key>.
`just store-key` rotates/replaces the stored key explicitly.

## Development environment

The repo ships a flake devShell with every tool (`just`, `shellcheck`, `bats`,
`vulnix`, `cachix`, …) and a `.envrc` for auto-loading via
[direnv](https://direnv.net) + [nix-direnv](https://github.com/nix-community/nix-direnv):

```bash
direnv allow      # once — trust .envrc; tools load automatically on cd
# or, without direnv:
nix develop       # enter the devShell manually
```

## How it works

Daily GitHub Actions workflow downloads NVD 2.0 JSON feeds and deploys
to GitHub Pages via force-push (no history accumulation).

Feeds served: `nvdcve-2.0-{year}.json.gz` for the last 6 years plus
`nvdcve-2.0-modified.json.gz`.
