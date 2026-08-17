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
      in {
        packages.nvd-cache = nvdCache;
        packages.default = nvdCache;
        devShells.default = pkgs.mkShell {
          packages = [ pkgs.bash pkgs.jq pkgs.shellcheck pkgs.shfmt pkgs.typos ];
          shellHook = ''
            ${set-and-setting.lib.mkSet}/bin/sync-set || true
            ${set-and-setting.lib.mkSetting}/bin/sync-setting || true
          '';
        };
        checks = {
          shellcheck = pkgs.runCommand "shellcheck-check" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''shellcheck ${./download.sh} ${./health_check.sh} ${./publish.sh} ${./republish.sh} ${./test_*.sh}; touch $out'';
          download = pkgs.runCommand "download-check" { } ''bash ${./test_download.sh}; touch $out'';
          checksum = pkgs.runCommand "checksum-check" { } ''bash ${./test_checksum.sh}; touch $out'';
          flake = pkgs.runCommand "flake-check" { } ''bash ${./test_flake.sh}; touch $out'';
          health-check = pkgs.runCommand "health-check" { } ''bash ${./test_health_check.sh}; touch $out'';
        };
      });
}
