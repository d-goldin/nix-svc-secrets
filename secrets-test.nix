{ config, lib, pkgs, ... }:

with lib;

let
  secrets = import ./secretslib.nix { inherit pkgs; inherit lib; inherit config; };
  cfg = config.services.secretstest;

  secretsScope = secrets.mkSecretsScope {
    loadSecrets = [ "secret1" "secret2" ];
    type = "folder";
  };
in {

  options.services.secretstest = {
    enable = mkEnableOption "Tiny systemd secrets test";
  };

  config = mkIf cfg.enable {

    systemd.services = secretsScope ({ secret1, ... }: {
      foo = {
        description = "Simple test service using a secret";
        serviceConfig = {
          ExecStart = "${pkgs.coreutils}/bin/cat ${secret1}";
          DynamicUser = true;
        };
      };

      bar = {
        description =
          "Another simple test service using a secret from the environment";
        serviceConfig = {
          # TODO: This could be moved into a shell function that loads up
          # env files and wrap the actual command.
          ExecStart = ''
            ${pkgs.bash}/bin/bash -c "export SECRET=$(${pkgs.coreutils}/bin/cat ${secret1}); ${pkgs.coreutils}/bin/echo \"secret from env: $SECRET\""'';
          DynamicUser = true;
        };
      };

    });
  };
}
