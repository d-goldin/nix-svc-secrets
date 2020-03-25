{ config, lib, pkgs, ...}:

{

  imports = [
    # module implementing the secretsStore configuration of backends
    ./modules/secrets_store.nix
    # Simple echo systemd service using secrets
    ./modules/test_service.nix
  ];

  # This configures the various secrets backends system-wide.
  # Various services can be configured to use different backends if
  # needed. At least the way it's currently done in this POC.
  secretsStore = {
    enable = true;

    # The settings made here are merged with services secretsConfig
    # depending on the defined backend. This should allow for flexible
    # configuration on a per service basis without being too verbose.
    vault = {
      url = "http://localhost:8200";
      # Default mountpoint of the kv secrets engine
      mount = "secret";
      # File containing the token used to request the vault server.
      tokenPath = "/etc/secrets/service_secrets_token";
      refreshInterval = 30;
    };

    folder = {
      secretsDir = "/etc/secrets";
    };
  };

  services.secrets_test = {
    enable = true;
    secretsConfig = {

      # One can seamlessly switch between different backends
      # without changes to the service.

      #backend = "vault";
      #config = {
      #  path = "nixos-testsecrets";
      #  # If the secrets store supports reloading, it is possible to
      #  # force service restarts when secrets change. Some backends
      #  # have a configurable polling interval while others can detect
      #  # change immediately, while others might not support reloading
      #  # at all.
      #  reloadOnChange = true;
      #  # We can also override system-wide setting of a particular backend
      #  refreshInterval = 10;
      #};

      backend = "folder";
      config = {
        secretsDir = "/etc/secrets/";
        reloadOnChange = true;
      };
    };
  };
}
