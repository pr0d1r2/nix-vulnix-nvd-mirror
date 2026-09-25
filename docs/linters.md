# Linters

Every file type tracked in git has a linter or an explicit reason it is
exempt. The pre-push `linter-coverage` hook (`lefthook-linter-coverage-full`)
reads this table; the devShell points `LEFTHOOK_LINTER_COVERAGE_DOC` here.

| Extension | Linter | Notes |
| --------- | ------ | ----- |
| `.sh` | shellcheck | `checks.shellcheck` in `nix flake check`, plus the test suites |
| `.nix` | nix-flake-check | The flake must evaluate and its checks pass |
| `.md` | markdownlint, markdownlint-agentic | Prose lint, agentic ruleset for generated documents |
| `.yml` | yamllint, actionlint | actionlint additionally for `.github/workflows/*` |
| `.lock` | nix-flake-check | `flake.lock` is validated by evaluation; `feeds.lock` by `test_flake.sh` |
| `.py` | — | `serve-feeds.py`, exercised by every `nvd-cache` build |
| `.toml` | — | `_typos.toml`, read by typos itself; it rejects a malformed file |
| `justfile` | — | Parsed by just on every run; no linter in the fleet reads it |
| `.gitignore` | — | git's own format; no linter in the fleet reads it |
| `.envrc` | — | direnv stanza (`use flake`); shellcheck cannot resolve its builtins |
| `LICENSE` | — | Verbatim MIT text; linting it would edit the licence |

All files are additionally covered by `unicode-lint` (glob `*`), and commits by
`gitleaks`, `git-conflict-markers` and `git-no-local-paths`.
