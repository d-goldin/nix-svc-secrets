{ config, lib, pkgs, ... }:

with lib;

let
  secrets = import ../lib/secrets.nix { inherit pkgs; inherit lib; inherit config; };
  cfg = config.services.secrets_test;

  secretsScope = secrets.serviceSecretsScope {
    loadSecrets = [ "secret1" "secret2" ];
    backendConfig = cfg.secretsConfig;
  };

in {

  options.services.secrets_test = {
    enable = mkEnableOption "Enable secrets store test service";
    secretsConfig = secrets.secretsBackendOption;
  };

  config = mkIf cfg.enable {

    systemd.services = secretsScope ({ secret1, ... }: {

      # A simple service consuming secrets from files
      secrets_test_file = {
        description = "Simple test service using a secret";
        serviceConfig = {
          ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.coreutils}/bin/cat ${secret1}; sleep infinity'";
          DynamicUser = true;
        };
      };

      # A simple service consuming secrets from it's environment
      secrets_test_env = {
        description = "Simple test service using a secret";
        serviceConfig = {
          ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.coreutils}/bin/echo $secret1; sleep infinity'";
          DynamicUser = true;
        };
      };

    });
  };
}
