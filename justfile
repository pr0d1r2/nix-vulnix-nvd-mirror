# nix-vulnix-nvd-mirror — task runner
# `just` (https://github.com/casey/just). Run `just` to list recipes.

keychain_service := env_var_or_default("NVD_KEYCHAIN_SERVICE", "nvd-api-key")

# list recipes
default:
    @just --list

# Store the NVD API key in the macOS Keychain (Touch-ID-gated, not in history).
store-key:
    #!/usr/bin/env bash
    set -euo pipefail
    read -rs -p "NVD API key: " k; echo
    security add-generic-password -a "$USER" -s "{{keychain_service}}" -U -w "$k"
    unset k
    echo "stored in Keychain as '{{keychain_service}}'."

# Build the mirror locally and publish public/ -> gh-pages (key via env/Keychain).
publish:
    ./publish.sh

# Build feeds only (no publish), into public/.
build:
    bash download.sh

# Run the test suite.
test:
    for t in test_*.sh; do echo "== $t =="; bash "$t"; done

# Lint shell scripts.
lint:
    shellcheck download.sh health_check.sh publish.sh test_*.sh
