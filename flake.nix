{
  description = "Pre-built vulnix NVD cache from mirrored feeds";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        pagesUrl = "https://pr0d1r2.github.io/nix-vulnix-nvd-mirror";

        # feeds.lock is committed (SPEC §V.26, §V.49). Guard a missing lock so the
        # flake still evaluates (devShell/checks keep working); only nvd-cache
        # needs a populated lock.
        lock =
          if builtins.pathExists ./feeds.lock
          then builtins.fromJSON (builtins.readFile ./feeds.lock)
          else { };

        # §V.15b — feed list is the single source of truth: feeds.lock keys.
        feeds = builtins.attrNames lock;

        # §V.15 — each feed is a flat fixed-output derivation; its store path is
        # f(name, sha256) only, independent of the URL, so mirror/CI/consumer all
        # compute the same nvd-cache derivation hash and the Cachix substitute hits.
        mkFeed = n:
          let f = "nvdcve-2.0-${n}.json.gz";
          in pkgs.fetchurl {
            name = f;
            url = "${pagesUrl}/${f}";
            sha256 = lock.${n};
          };

        feedFarm = pkgs.linkFarm "nvd-feeds"
          (map (n: { name = "nvdcve-2.0-${n}.json.gz"; path = mkFeed n; }) feeds);

        nvd-cache = pkgs.stdenv.mkDerivation {
          pname = "nvd-cache";
          # §V.44 — version is content-addressed to feeds.lock, NOT the flake date,
          # so two revs with identical feeds yield the same store path.
          version =
            builtins.substring 0 12
              (builtins.hashString "sha256" (builtins.readFile ./feeds.lock));

          dontUnpack = true;

          nativeBuildInputs = [ pkgs.vulnix pkgs.python3 pkgs.curl ];

          buildPhase = ''
            runHook preBuild

            export HOME=$TMPDIR
            mkdir -p $TMPDIR/cache

            # vulnix is HTTP-only (no file:// adapter), so serve feeds on loopback
            # (§V.46). serve-feeds.py synthesizes an empty feed for any absent
            # in-range year so a 404 never aborts vulnix's update (§V.48).
            port=$(( 20000 + $(echo "$NIX_BUILD_TOP" | cksum | cut -d' ' -f1) % 20000 ))
            python3 ${./serve-feeds.py} ${feedFarm} "$port" &
            server=$!
            trap "kill $server" EXIT

            until curl -sf "http://127.0.0.1:$port/nvdcve-2.0-modified.json.gz" -o /dev/null; do
              sleep 0.2
            done

            # Scan a tiny real package to drive feed retrieval into the cache-dir
            # (§V.47). vulnix exits non-zero when it FINDS vulns — that must not
            # fail asset generation (§V.45), so ignore its exit and gate on the
            # artifact instead.
            vulnix -m "http://127.0.0.1:$port/" -c $TMPDIR/cache ${pkgs.hello} || true

            # §V.40/§V.45 — the real success criterion: a non-empty database.
            test -s $TMPDIR/cache/Data.fs

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out
            cp $TMPDIR/cache/Data.fs $out/

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Pre-built vulnix NVD vulnerability database (Data.fs)";
            license = licenses.free;
            platforms = platforms.all;
          };
        };
        # §V.21/§V.34 — each check is a sandboxed derivation carrying its own
        # tool closure; building a check runs its test. (The test_*.sh are plain
        # bash, run with `bash`, not bats.)
        mkCheck = name: inputs: cmd:
          pkgs.runCommand "check-${name}" { nativeBuildInputs = inputs; } ''
            cp -r ${self}/. work && chmod -R u+w work && cd work
            ${cmd}
            touch $out
          '';
      in
      {
        packages.nvd-cache = nvd-cache;
        packages.default = nvd-cache;

        checks = {
          shellcheck = mkCheck "shellcheck" [ pkgs.shellcheck ]
            "shellcheck download.sh health_check.sh";
          # test_download.sh / test_checksum.sh execute download.sh against a
          # mocked curl, so they need download.sh's full toolset.
          download = mkCheck "download" [ pkgs.bash pkgs.jq pkgs.gzip pkgs.gnugrep pkgs.coreutils pkgs.findutils ]
            "bash test_download.sh";
          checksum = mkCheck "checksum" [ pkgs.bash pkgs.jq pkgs.gzip pkgs.gnugrep pkgs.coreutils pkgs.findutils ]
            "bash test_checksum.sh";
          flake = mkCheck "flake" [ pkgs.bash pkgs.jq pkgs.gnugrep ]
            "bash test_flake.sh";
          health-check = mkCheck "health-check" [ pkgs.bash pkgs.gzip pkgs.gnugrep pkgs.coreutils ]
            "bash test_health_check.sh";
          workflow = mkCheck "workflow" [ pkgs.bash pkgs.gnugrep ]
            "bash test_workflow.sh";
        };

        # §V.19 — devShell carrying every CI/local tool (incl. just), auto-loaded
        # via .envrc (§V.51). set-and-setting wiring (§V.20) is the rest of T17.
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.just pkgs.bash pkgs.shellcheck pkgs.bats
            pkgs.curl pkgs.jq pkgs.gzip pkgs.coreutils pkgs.gnugrep pkgs.findutils
            pkgs.nix pkgs.vulnix pkgs.cachix
          ];
        };
      }
    );
}
