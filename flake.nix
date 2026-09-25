{
  description = "Reproducible NVD vulnerability mirror and vulnix cache";

  nixConfig = {
    extra-substituters = [ "https://pr0d1r2.cachix.org" ];
    extra-trusted-public-keys = [
      "pr0d1r2.cachix.org-1:NfWjbhgAj41byXhCKiaE+av3Vnphm1fTezHXEGsiQIM="
    ];
  };

  inputs = {
    # nixpkgs.url is supplied by the pinned nixpkgs-lock input below.
    nixpkgs-lock.url = "github:pr0d1r2/nixpkgs-lock";
    nixpkgs.follows = "nixpkgs-lock/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    set-and-setting.url = "github:pr0d1r2/set-and-setting";
    set-and-setting.inputs.nixpkgs-lock.follows = "nixpkgs-lock";
  };

  outputs = { self, nixpkgs, flake-utils, set-and-setting, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            (_final: prev: {
              lib = prev.lib // {
                sources = prev.lib.sources // {
                  sourceByRegex = src: regex:
                    prev.lib.sources.sourceByRegex src
                      (if builtins.isList regex then regex else [ regex ]);
                };
              };
            })
          ];
        };
        lock = if builtins.pathExists ./feeds.lock
          then builtins.fromJSON (builtins.readFile ./feeds.lock) else {};
        feeds = builtins.attrNames lock;
        mkFeed = name: let file = "nvdcve-2.0-${name}.json.gz"; in
          pkgs.fetchurl { name = file; url = "https://pr0d1r2.github.io/nix-vulnix-nvd-mirror/${file}"; sha256 = lock.${name}; };
        feedFarm = pkgs.linkFarm "nvd-feeds" (map (name: {
          name = "nvdcve-2.0-${name}.json.gz";
          path = mkFeed name;
        }) feeds);
        nvdCache = pkgs.stdenv.mkDerivation {
          pname = "nvd-cache";
          version = builtins.substring 0 12 (builtins.hashString "sha256" (builtins.readFile ./feeds.lock));
          dontUnpack = true;
          nativeBuildInputs = [ pkgs.vulnix pkgs.curl pkgs.python3 ];
          buildPhase = ''
            export HOME=$TMPDIR
            mkdir -p $TMPDIR/cache
            port=$((20000 + $(echo $NIX_BUILD_TOP | cksum | cut -d' ' -f1) % 20000))
            ${pkgs.python3}/bin/python ${./serve-feeds.py} ${feedFarm} $port & server=$!
            trap "kill $server" EXIT
            until ${pkgs.curl}/bin/curl -sf http://127.0.0.1:$port/nvdcve-2.0-modified.json.gz -o /dev/null; do sleep 0.2; done
            printf '{}\n' > $TMPDIR/packages.json
            vulnix -m http://127.0.0.1:$port/ -c $TMPDIR/cache --from-file $TMPDIR/packages.json || true
            test -s $TMPDIR/cache/Data.fs
          '';
          installPhase = "mkdir -p $out; cp $TMPDIR/cache/Data.fs $out/";
        };
      in let
        materialization = set-and-setting.lib.materializationFor {
          inherit pkgs;
          fragments = [ "base" "actions" "nix" "shell" "ascii" "markdown" "yaml" ];
        };
        # The pinned set-and-setting builds lefthook-linter-coverage-full
        # without substituting its awk-program placeholder, so the wrapper
        # always dies with `gawk: cannot open source file` (SPEC §B.26).
        # Rebuild it the way its own flake does and swap it in.
        coverageSrc = set-and-setting.inputs.nix-lefthook-linter-coverage-src;
        linterCoverage = pkgs.writeShellApplication {
          name = "lefthook-linter-coverage-full";
          runtimeInputs = [ pkgs.gawk pkgs.git pkgs.gnused ];
          text = builtins.replaceStrings
            [ "LEFTHOOK_LINTER_COVERAGE_AWK_PROGRAM_PATH" ]
            [ "${coverageSrc}/linter-coverage.awk" ]
            (builtins.readFile "${coverageSrc}/lefthook-linter-coverage-full.sh");
        };
        withFixedWrappers = wrappers:
          builtins.filter (p: (p.name or "") != linterCoverage.name) wrappers
          ++ [ linterCoverage ];
      in {
        packages.nvd-cache = nvdCache;
        packages.default = nvdCache;
        # The shared guardrails workflow invokes the standard materialization
        # output directly as `.#setting` on every target system. The value
        # nested inside apps.confirm is not addressable as `.#setting`.
        packages.setting = set-and-setting.lib.mkSetting { inherit pkgs; };
        # The shared guardrails workflow runs this consumer-facing acceptance
        # app after materializing the standard settings. Keep it at the flake
        # boundary so the repo satisfies the set-and-setting contract while
        # retaining the project's own package and check outputs.
        apps.confirm = set-and-setting.lib.mkConfirmApp {
          inherit pkgs;
          standard = set-and-setting;
          setting = set-and-setting.lib.mkSetting { inherit pkgs; };
          materialization = set-and-setting.lib.materializationFor {
            inherit pkgs;
            fileClassOverrides = { };
            fragments = [ "base" "actions" "nix" "shell" "ascii" "markdown" "yaml" ];
          };
          confirmRev = set-and-setting.rev or set-and-setting.dirtyRev or "unknown";
        };
        devShells = set-and-setting.lib.mkDevShells {
          inherit pkgs;
          # Keep materialization.packages: it carries the lefthook-* wrappers
          # the committed lefthook.yml invokes (SPEC §B.23). The rest is the
          # CI/local toolchain SPEC §V.19 requires.
          basePackages = withFixedWrappers materialization.packages ++ [
            pkgs.actionlint
            pkgs.bash
            pkgs.bats
            pkgs.cachix
            pkgs.curl
            pkgs.gzip
            pkgs.jq
            pkgs.just
            pkgs.nix
            pkgs.shellcheck
            pkgs.shfmt
            pkgs.typos
            pkgs.vulnix
          ];
          # lefthook-linter-coverage-full needs its doc path; nothing upstream
          # sets it for this repo (SPEC §B.26).
          settingHook = ''
            export LEFTHOOK_LINTER_COVERAGE_DOC=docs/linters.md
            ${(set-and-setting.lib.mkSet { inherit pkgs; })}/bin/sync-set || true
            ${(set-and-setting.lib.mkSetting { inherit pkgs; })}/bin/sync-setting || true
          '';
        };
        checks = {
          # The test scripts resolve sibling files through SCRIPT_DIR.  Pass
          # the complete source tree explicitly: interpolating an individual
          # script path would copy only that file into the sandbox, making
          # repository-aware checks see a fictitious empty repository.
          shellcheck = pkgs.runCommand "shellcheck-check" {
            nativeBuildInputs = [ pkgs.shellcheck ];
            src = ./.;
          } ''shellcheck $src/download.sh $src/health_check.sh $src/publish.sh $src/republish.sh $src/test_checksum.sh $src/test_download.sh $src/test_flake.sh $src/test_health_check.sh $src/test_workflow.sh; touch $out'';
          download = pkgs.runCommand "download-check" {
            nativeBuildInputs = [ pkgs.jq pkgs.gzip pkgs.curl ];
            src = ./.;
          } ''bash $src/test_download.sh; touch $out'';
          checksum = pkgs.runCommand "checksum-check" {
            nativeBuildInputs = [ pkgs.jq pkgs.gzip ];
            src = ./.;
          } ''bash $src/test_checksum.sh; touch $out'';
          flake = pkgs.runCommand "flake-check" {
            nativeBuildInputs = [ pkgs.jq ];
            src = ./.;
          } ''bash $src/test_flake.sh; touch $out'';
          health-check = pkgs.runCommand "health-check" {
            nativeBuildInputs = [ pkgs.jq pkgs.gzip pkgs.curl ];
            src = ./.;
          } ''bash $src/test_health_check.sh; touch $out'';
        };
      });
}
