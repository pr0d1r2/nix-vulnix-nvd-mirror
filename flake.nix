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
    set-and-setting.lib.mkConsumerFlake {
      inherit self nixpkgs set-and-setting;
      fragments = [
        "base"
        "nix"
        "shell"
        "ascii"
        "markdown"
        "yaml"
      ];
      src = ./.;
      extraChecks = pkgs:
        let
          workflowSources = nixpkgs.lib.sources.sourceByRegex
            (nixpkgs.lib.sources.sourceFilesBySuffices ./. [ ".yml" ".yaml" ])
            [ "^\\.github/workflows/.*" ];
        in
        {
          # Pass the list required by the current Nixpkgs sourceByRegex API.
          actionlint = set-and-setting.lib.mkLefthookCheck {
            inherit pkgs;
            src = workflowSources;
            name = "actionlint";
            wrapper = pkgs.writeShellApplication {
              name = "actionlint-wrapper";
              runtimeInputs = [ pkgs.actionlint ];
              text = ''exec actionlint "$@"'';
            };
            suffices = null;
          };
        };
    };
}
