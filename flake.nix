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
    set-and-setting.lib.mkConsumerFlake {
      inherit self nixpkgs set-and-setting;
      fragments = [
        "base"
        "nix"
        "ascii"
        "markdown"
        "yaml"
      ];
      src = ./.;
      # This project is a shell application whose public and test structure is
      # intentionally function-based. Keep the applicable shell linters without
      # opting into the functionless-script architecture policy.
      extraChecks = pkgs: {
        shellcheck = set-and-setting.lib.mkShellcheckCheck {
          inherit pkgs;
          src = ./.;
        };
        shfmt = set-and-setting.lib.mkShfmtCheck {
          inherit pkgs;
          src = ./.;
        };
      };
    };
}
