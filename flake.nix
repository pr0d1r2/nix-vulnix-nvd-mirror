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
    set-and-setting.inputs.nixpkgs-lock.follows = "nixpkgs-lock";
  };

  outputs =
    {
      self,
      nixpkgs,
      set-and-setting,
      ...
    }:
    let
      # set-and-setting's actionlint check still passes a single regex to
      # sourceByRegex, while the locked nixpkgs API requires a list.
      nixpkgsCompat = nixpkgs // {
        lib = nixpkgs.lib // {
          sources = nixpkgs.lib.sources // {
            sourceByRegex = src: regex:
              nixpkgs.lib.sources.sourceByRegex src (if builtins.isList regex then regex else [ regex ]);
          };
        };
        legacyPackages = builtins.mapAttrs (_system: pkgs: pkgs // {
          lib = pkgs.lib // {
            sources = pkgs.lib.sources // {
              sourceByRegex = src: regex:
                pkgs.lib.sources.sourceByRegex src (if builtins.isList regex then regex else [ regex ]);
            };
          };
        }) nixpkgs.legacyPackages;
      };
    in
    set-and-setting.lib.mkConsumerFlake {
      inherit self set-and-setting;
      nixpkgs = nixpkgsCompat;
      fragments = [
        "base"
        "actions"
        "nix"
        "shell"
        "ascii"
        "markdown"
        "yaml"
      ];
      src = ./.;
    };
}
