# nix-vulnix-nvd-mirror

GitHub Pages mirror of NVD JSON feeds for use with
[vulnix](https://github.com/nix-community/vulnix).

## Usage

```
vulnix --mirror https://pr0d1r2.github.io/nix-vulnix-nvd-mirror/ ./result
```

## How it works

Daily GitHub Actions workflow downloads NVD 2.0 JSON feeds and deploys
to GitHub Pages via force-push (no history accumulation).

Feeds served: `nvdcve-2.0-{year}.json.gz` for the last 6 years plus
`nvdcve-2.0-modified.json.gz`.
