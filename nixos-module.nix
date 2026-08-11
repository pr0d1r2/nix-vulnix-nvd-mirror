{ config, lib, pkgs, ... }:

let
  cfg = config.programs.vulnix-cache;
  cacheDir = lib.escapeShellArg cfg.cacheDir;
in
{
  options.programs.vulnix-cache = {
    enable = lib.mkEnableOption "pre-built vulnix vulnerability database seeding";

    package = lib.mkOption {
      type = lib.types.package;
      description = "Package containing the pre-built vulnix Data.fs database.";
    };

    cacheDir = lib.mkOption {
      type = lib.types.strMatching "^/.*";
      default = "/var/cache/vulnix";
      description = "Writable directory into which Data.fs is seeded.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.vulnix-cache-seed = {
      description = "Seed the writable vulnix vulnerability database";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      restartTriggers = [ cfg.package ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        ${lib.getExe' pkgs.coreutils "install"} -d -m0755 ${cacheDir}
        ${lib.getExe' pkgs.coreutils "install"} -m0644 \
          ${cfg.package}/Data.fs ${cacheDir}/Data.fs
      '';
    };
  };
}
