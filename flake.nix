{
  description = "CHANGEME";

  nixConfig = {
    extra-substituters = [ "https://pr0d1r2.cachix.org" ];
    extra-trusted-public-keys = [ "pr0d1r2.cachix.org-1:NfWjbhgAj41byXhCKiaE+av3Vnphm1fTezHXEGsiQIM=" ];
  };

  inputs = {
    nixpkgs-lock.url = "github:pr0d1r2/nixpkgs-lock";
    nixpkgs.follows = "nixpkgs-lock/nixpkgs";

    set-and-setting.url = "github:pr0d1r2/set-and-setting";
  };

  outputs =
    {
      self,
      nixpkgs,
      set-and-setting,
      ...
    }:
    let
      supportedSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems =
        f: nixpkgs.lib.genAttrs supportedSystems (system: f nixpkgs.legacyPackages.${system});

      fragments = [
        "base"
        "nix"
      ];
    in
    {
      packages = forAllSystems (pkgs: {
        setting = (set-and-setting.lib.mkSetting { inherit pkgs; }).materialized;
      });

      devShells = forAllSystems (
        pkgs:
        let
          mat = set-and-setting.lib.materializationFor { inherit pkgs fragments; };
          sys = pkgs.stdenv.hostPlatform.system;
        in
        set-and-setting.lib.mkDevShells {
          inherit pkgs;
          basePackages = mat.packages;
          defaultShellHook = ''
            ${self.packages.${sys}.setting}/bin/sync-setting .
            cp -f ${mat.files}/lefthook.yml lefthook.yml
          '';
        }
      );

      checks = forAllSystems (
        pkgs:
        (set-and-setting.lib.checksFor {
          inherit pkgs fragments;
          src = ./.;
        })
        // {
          dep-graph = set-and-setting.lib.mkDepGraphCheck {
            inherit pkgs;
            projectRoot = ./.;
          };
          default = pkgs.runCommand "checks" { } "touch $out";
        }
      );

      apps = forAllSystems (pkgs: {
        confirm = {
          type = "app";
          program = "${
            pkgs.writeShellApplication {
              name = "confirm";
              runtimeInputs = [
                pkgs.coreutils
                pkgs.diffutils
                pkgs.findutils
                pkgs.gawk
                pkgs.git
                pkgs.gnugrep
              ];
              text = ''
                export FRAGMENTS_DIR="${set-and-setting}/setting/integrations/lefthook"
                export ASSEMBLE_SCRIPT="${set-and-setting}/setting/lib/assemble-lefthook.sh"
                export DETECT_SCRIPT="${set-and-setting}/setting/lib/detect-fragments.sh"
                export SETTING_SRC="${self.packages.${pkgs.stdenv.hostPlatform.system}.setting}"
                export CONFIRM_SCRIPT="${set-and-setting}/lib/confirm.sh"
                export CONFIRM_REV="${set-and-setting.rev or "unknown"}"
                bash "$CONFIRM_SCRIPT"
              '';
            }
          }/bin/confirm";
        };
      });
    };
}
