{ pkgs, lib, config }:

with lib;

rec {
  fetchers = {

    # File based fetcher
    file = let
      # TODO: parametrize/make configurable
      secretLocation = "/etc/secrets";
      targetPrefix = "/tmp";
    in pkgs.writeShellScript "secrets-copier" ''
      for secret in $1; do
        secret_file=${targetPrefix}/$secret
        secret_env_file=${targetPrefix}/$secret.env

        ${pkgs.coreutils}/bin/cp -a "${secretLocation}/$secret" "$secret_file"
        ${pkgs.coreutils}/bin/chmod -R 444 "$secret_file"
      done
    '';

    vault = throw "Unsupported";
    nixops = throw "Unsupported";
  };

  wrapWithSidecart = fetcher: secretIds: serviceName: serviceDef: {

    # Definition of the side-cart containers responsible for retrieving secrets
    # and populating the private tmp
    "${serviceName}-secrets" = {
      description = "side-cart for ${serviceName}";
      before = [ "${serviceName}.service" ];
      wantedBy = [ "${serviceName}.service" ];

      # This ensures that this is stopped once the consuming
      # service is stopped or killed.
      bindsTo = [ "${serviceName}.service" ];

      serviceConfig = {
        Type = "oneshot";
        # TODO: Maybe it would be nicer if the fetcher could render us out a command to account
        # for variations in how fetchers might want secrets Ids passed.
        ExecStart = "${fetcher} ${lib.concatStringsSep " " secretIds}";
        PrivateTmp = true;
        # This ensures we the namespace is retained
        RemainAfterExit = true;
      };
    };

    # TODO: Add guards to ensure that we're not already
    # joining some namespace. Maybe also check for PrivateTmp
    # not being false otherwise error out.
    "${serviceName}" = lib.recursiveUpdate serviceDef {
      #serviceConfig.ExecStartPre = "${pkgs.coreutils}/bin/sleep 30";
      serviceConfig.PrivateTmp = true;
      unitConfig.JoinsNamespaceOf = "${serviceName}-secrets.service";
    };
  };

  # creates an accompanying service loading the secrets for
  # each service in the attribute.
  withSecrets = secretIds: fetcher: serviceDefs:
    fold (a: b: a // b) { }
    (map (k: (wrapWithSidecart fetcher secretIds k serviceDefs."${k}"))
      (lib.attrNames serviceDefs));

  # This should live on the fetcher
  genSecretsAttrs = secretIds:
    lib.fold (a: b: a // b) { }
    # TODO: This relies on knowledge of targetPrefix, this should be generated somewhere
    # within the fetcher context
    (map (s: { "${s}" = "/tmp/${s}"; }) secretIds);

  mkSecretsScope = { type, loadSecrets }:
    if type == "folder" then
      let fetcher = fetchers.file;
      in serviceDefs:
      withSecrets loadSecrets fetcher
      (serviceDefs (genSecretsAttrs loadSecrets))
    else if type == "vault" then
      throw "Unsupported TODO"
    else
      throw "Unsupported store type: ${type}";

}
