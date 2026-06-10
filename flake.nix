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

        nvd-cache = pkgs.stdenv.mkDerivation {
          pname = "nvd-cache";
          version = builtins.substring 0 8 (self.lastModifiedDate or "19700101");

          src = ./public;

          nativeBuildInputs = [ pkgs.vulnix pkgs.python3Packages.zodb ];

          dontConfigure = true;

          buildPhase = ''
            runHook preBuild

            export HOME=$TMPDIR
            vulnix --mirror file://$PWD --cache-dir $TMPDIR/cache --update

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
      in
      {
        packages.nvd-cache = nvd-cache;
        packages.default = nvd-cache;
      }
    );
}
