# Changelog

All notable changes to this project are documented here.

## Unreleased

- The daily mirror lands `feeds.lock` on protected `main` through a pull request it opens and merges itself, after the pre-built cache is published. Since 2026-09-21 the direct push was refused, which also skipped the cache build and Cachix push (§B.27).
