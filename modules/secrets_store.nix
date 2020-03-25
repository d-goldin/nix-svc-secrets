{ config, pkgs, lib, ...}:

with lib;

let
  cfg = config.secretsStore;
in
{

  options.secretsStore = {
    enable = mkEnableOption "Enable secrets store";

    vault = mkOption {
      description = "Settings for the vault secrets backend";
      type = types.submodule {
        options = {
          url = mkOption {
            type = types.str;
            description = "URL of the vault service";
            default = "http://localhost:8200";
          };

          mount = mkOption {
            type = types.str;
            description = "Mount point of the secrets engine to use";
            default = "secret";
          };

          tokenPath = mkOption {
            type = types.str;
            description = "Path of the vault token";
          };

          refreshInterval = mkOption {
            type = types.int;
            description = "polling interval to detect changes of secrets";
            default = 60;
          };
        };
      };
    };

    folder = mkOption {
      description = "Settings for the file-based secrets backend";
      type = types.submodule {
        options = {
          secretsDir = mkOption {
            type = types.str;
            description = "Path to a directory storing the secrets files";
          };
        };
      };
    };
  };

  config = mkIf cfg.enable {

    # NOTE: This is just to illustrate some checks we could apply
    # during system activation. Right now this does not consider
    # the possibly overriden secrets configs of services.
    system.activationScripts.secretsStore = ''
        set -e
      ''
    + lib.optionalString (cfg ? vault) ''
        test -e ${cfg.vault.tokenPath} || \
             (echo "secretsStore: vault token not present in specified path '${cfg.vault.tokenPath}'"; exit 1)
        ''
    + lib.optionalString (cfg ? file) ''
        test -d ${cfg.file.secretsDir} || \
             (echo "secretsStore: file secrets directory '${cfg.file.secretLocation}' does not exist"; exit 1)
        '';
  };

}
