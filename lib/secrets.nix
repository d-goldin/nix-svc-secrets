{ pkgs, lib, config }:

with lib;

let
  # This is not really configurable with systemd,
  # but to reduce hardcoding in the fetchers, like
  # this for now.
  privateMount = "/tmp";
in
rec {

  # The makeup of a fetcher is quite simple. The interface is just a list of secrets ids
  # and the output are secrets files a la /tmp/{secret-id1, secret-id1} and /tmp/secrets.env
  # for consumption from files or the environment.

  # A current restriction of secret ids is that they must be valid filenames without spaces etc,
  # mostly due to naive implementation in this poc.

  # A fetcher is supposed to remain running. When the fetcher terminates, this will cause the
  # a service restart, for instance because the secrets have changed.
  # This means that in a case with disabled reloading, the fetcher is expected to sleep indefinitely.
  fetchers = {

    # Basic folder/file based fetcher, copying the secrets to private temp and supporting
    # reloading watching inotify events of the files.
    folder = backendConfig: pkgs.writeShellScript "file-copy-fetcher" ''
      set -e

      PRIVATE_MNT="${privateMount}"
      SECRETS_STORE_PATH="${backendConfig.secretsDir}"
      SECRETS_ENV_FILE="$PRIVATE_MNT/secrets.env"

      function fetch_secrets() {
        echo "Fetching secrets: $@"

        for secret_id in $@; do
          secret_file="$PRIVATE_MNT/$secret_id"

          ${pkgs.coreutils}/bin/cp -a "$SECRETS_STORE_PATH/$secret_id" "$secret_file"
          echo "export $secret_id='$(<$secret_file)'" >> $SECRETS_ENV_FILE

          for f in $secret_file $SECRETS_ENV_FILE; do
            ${pkgs.coreutils}/bin/chmod -R 444 "$f"
          done
        done
      }

      function watch_changes() {
        watch_paths=""
        for s in $@; do
          watch_paths+=" $SECRETS_STORE_PATH/$s"
        done
        ${pkgs.inotify-tools}/bin/inotifywait -e MODIFY $watch_paths
      }

      fetch_secrets $@

      ${pkgs.systemd}/bin/systemd-notify --ready

      if [[ ${lib.boolToString backendConfig.reloadOnChange} == "true" ]]; then
        watch_changes $@
      else
        echo "Sleeping..."
        sleep infinity
      fi
    '';

    # A fetcher for vault.
    #
    # Secrets Ids refer to individual KV entries in a particular path/secret.
    #
    # Right now only a single path is supported for the vault backend,
    # which means that all secrets required for an individual service need to be entries
    # within one vault secret.
    #
    # As such, for rotations, the metadata of the secret is watched, but not
    # of individual entries within a secret. This also means that no secrets
    # from multiple paths can be used in this manner right now.
    #
    # Changes are detected based on the secret version
    vault = backendConfig: pkgs.writeShellScript "vault-fetcher" ''
      PRIVATE_MNT="${privateMount}"
      SECRETS_PATH="${backendConfig.path}"

      VAULT_MOUNT="${backendConfig.mount}"
      VAULT_SERVER="${backendConfig.url}"

      POLL_INTERVAL="${toString backendConfig.refreshInterval}"

      fetched_secrets_version=""

      function get_version() {
        payload=$(${pkgs.curl}/bin/curl -sf \
           -H "X-Vault-Token: $(<${backendConfig.tokenPath})" \
           $VAULT_SERVER/v1/$VAULT_MOUNT/data/$SECRETS_PATH)

        ${pkgs.python}/bin/python -c \
          "import sys, json; print(json.load(sys.stdin)['data']['metadata']['version'])" <<<$payload
      }

      function watch_changes() {
        echo "Started watching secrets"
        while true; do
          echo "polling secrets version..."
          current_version=$(get_version)

          echo "current version: $current_version"
          if [[ "$current_version" != "$fetched_secrets_version" ]]; then
            echo "Secrets version changed, exiting"
            exit
          fi

          sleep $POLL_INTERVAL
        done
      }

      function fetch_secrets() {
        echo "Fetching secrets: $@"
        local secrets_version;
        local secret;
        local secret_id;
        local payload;

        SECRETS_ENV_FILE="$PRIVATE_MNT/secrets.env"

        for secret_id in $@; do
          echo "Fetching secret: $secret_id"

          secret_file=$PRIVATE_MNT/$secret_id

          echo "DEBUG: ${pkgs.curl}/bin/curl -sf \
             --header "X-Vault-Token: <redacted> \
             $VAULT_SERVER/v1/$VAULT_MOUNT/data/$SECRETS_PATH"

          payload=$(${pkgs.curl}/bin/curl -sf \
             --header "X-Vault-Token: $(<${backendConfig.tokenPath})" \
             $VAULT_SERVER/v1/$VAULT_MOUNT/data/$SECRETS_PATH)

          if [[ $? -ne 0 ]]; then
            echo "Failed retrieving secret from vault."
            exit 1
          fi;

          # NOTE: For some reason Im having trouble with JQ core-dumping within the service,
          # so falling back to python for now.
          #secret=$(${pkgs.jq}/bin/jq -ra .data.data.$secret_id <<<$payload)

          secret=$(${pkgs.python}/bin/python -c \
            "import sys, json; print(json.load(sys.stdin)['data']['data']['$secret_id'])" <<<$payload)

          echo "$secret" > $secret_file
          echo "export $secret_id='$secret'" >> $SECRETS_ENV_FILE

          for f in $secret_file $SECRET_ENV_FILE; do
            ${pkgs.coreutils}/bin/chmod -R 444 "$f"
          done
        done

        # This is somewhat naive, but will do for a POC.
        # In a proper implementation, the version would be extracted from
        # the actual secrets retrieved and not after the fact, as this could
        # miss an update that would happen between the last key and the version
        # check. Also, tracking only a single version wouldn't work when using secrets
        # from different paths.
        fetched_secrets_version=$(get_version)
      }

      function run() {
        fetch_secrets $@

        ${pkgs.systemd}/bin/systemd-notify --ready

        if [[ ${lib.boolToString backendConfig.reloadOnChange} == "true" ]]; then
          watch_changes $@
        else
          echo "Sleeping..."
          sleep infinity
        fi
      }

      run $@
    '';

  };

  # Attached a sidecar for secrets injection to a systemd service,
  # configures lifecycle like reloading and ensures some necessary
  # settings like PrivateTmp.
  wrapWithSidecart = fetcher: secretIds: serviceName: serviceDef: let
      sidecartUnitName = "${serviceName}-secrets.service";
      serviceUnitName = "${serviceName}.service";
  in

  assert serviceDef.serviceConfig.PrivateTmp or true;
  assert serviceDef.unitConfig.JoinsNamespaceOf or null == null;

  {

    # Definition of the side-cart containers responsible for retrieving secrets
    # and populating the private tmp
    "${serviceName}-secrets" = {
      description = "side-cart for ${serviceName}";

      before = [ serviceUnitName ];
      requiredBy = [ serviceUnitName ];

      # Ensures the sidecar is stopped when the consuming service
      # terminates.
      bindsTo = [ serviceUnitName ];
      partOf = [ serviceUnitName ];

      serviceConfig = {
        Type = "notify";
        ExecStart = "${fetcher} ${lib.concatStringsSep " " secretIds}";
        PrivateTmp = true;
        Restart = "on-success";
      };
    };

    # Hooks up the original service definition with the sidecar secrets
    # service and enforces some settings, like private /tmp.
    "${serviceName}" = lib.recursiveUpdate serviceDef {

      partOf = serviceDef.partOf or [] ++ [ sidecartUnitName ];
      requires = serviceDef.requires or [] ++ [ sidecartUnitName ];

      # TODO: Maybe injecting into env should be optional
      serviceConfig.ExecStart = wrapExec serviceDef.serviceConfig.ExecStart;
      serviceConfig.PrivateTmp = true;
      unitConfig.JoinsNamespaceOf = sidecartUnitName;
    };
  };

  # creates an accompanying sidecar service loading specified secrets for
  # each provided serviceDef
  withSecrets = secretIds: fetcher: serviceDefs:
    fold (a: b: a // b) { }
    (map (k: (wrapWithSidecart fetcher secretIds k serviceDefs."${k}"))
      (lib.attrNames serviceDefs));

  genSecretsAttrs = secretIds:
    lib.fold (a: b: a // b) { }
      (map (s: { "${s}" = "${privateMount}/${s}"; }) secretIds);

  # Unfortunately EnvironmentFile is not really usable for our purpose, because
  # it's not part of PrivateTmp (neither is PreExec), so this is a simple wrapper to
  # source a generated secrets.env file for an arbitrary command
  wrapExec = cmd: pkgs.writeShellScript "secrets-env-wrapper" ''
    echo "Injecting secrets into environment for ${cmd}"
    source ${privateMount}/secrets.env
    ${cmd}
  '';

  serviceSecretsScope = { backendConfig, loadSecrets }:
    let
      fetcher = if backendConfig.backend == "folder"
        then
          fetchers.folder (config.secretsStore.folder or {} // backendConfig.config)
        else if backendConfig.backend == "vault" then
          fetchers.vault (config.secretsStore.vault or {} // backendConfig.config)
        else
          throw "Unsupported store type: ${type}";
    in serviceDefs:
      withSecrets loadSecrets fetcher
      # This injects "resolved" secret paths into the service definition
      (serviceDefs (genSecretsAttrs loadSecrets));

  # TODO: Possibly allow for configuring a mapping of secret-ids used in the module to secret "paths" in the
  # secrets store instead of hard convention.
  secretsBackendOption = mkOption {
    description = "Configuration for secrets backend";
    type = types.submodule {
      options = {
        backend = mkOption {
          type = types.str;
          description = "Name of the backend to use";
        };

        # TODO: Add some assertions for the different types
        config = mkOption {
          type = types.attrs;
          description = "backend settings";
        };
      };
    };
  };

}
