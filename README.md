# nix-vulnix-nvd-mirror

[![Mirror NVD feeds](https://github.com/pr0d1r2/nix-vulnix-nvd-mirror/actions/workflows/mirror.yml/badge.svg)](https://github.com/pr0d1r2/nix-vulnix-nvd-mirror/actions/workflows/mirror.yml)

GitHub Pages mirror of NVD JSON feeds for use with
[vulnix](https://github.com/nix-community/vulnix).

## Usage

```
vulnix --mirror https://pr0d1r2.github.io/nix-vulnix-nvd-mirror/ ./result
```

## Publishing from a residential machine (fast, un-throttled)

NVD heavily rate-limits datacenter / CI IPs, so the GitHub-hosted mirror job can
be slow. To build + publish from your own machine instead:

```bash
just store-key      # store your NVD API key in the macOS Keychain (Touch-ID gated)
just publish        # build feeds + force-push public/ -> gh-pages
```

`just publish` (or `./publish.sh`) resolves the key from `$NVD_API_KEY` or the
macOS Keychain, builds `public/` via `download.sh`, and force-pushes it to
`gh-pages` (orphan, same as the workflow). Get a free key at
<https://nvd.nist.gov/developers/request-an-api-key>.

## How it works

Daily GitHub Actions workflow downloads NVD 2.0 JSON feeds and deploys
to GitHub Pages via force-push (no history accumulation).

Feeds served: `nvdcve-2.0-{year}.json.gz` for the last 6 years plus
`nvdcve-2.0-modified.json.gz`.
