# Service secrets PoC for [NixOS RFC 0059](https://github.com/NixOS/rfcs/pull/59)

This repository contains a proof of concept for an addition to the nixos module
system providing backend agnostic retrieval of secrets for systemd services.

*Disclaimer: This is a proof of concept, so the code is not overly robust (esp in the fetcher shell parts),
has not covered edge-cases etc. It mostly serves to demonstrate a possible API/interface and mechanics
of a possible solution*

## What's where

* [`config.nix`](./config.nix): what basic configuration of system-wide secrets store settings
  and use for a service could look like
* [`modules/secrets_store.nix`](./modules/secrets_store.nix): module for system wide secrets-store configuration of backends. such as vault configs.
* [`modules/test_service.nix`](./modules/test_service.nix): A simple module containing two systemd services that require secrets from the filesystem or environment.
* [`lib/secrets.nix`](./lib/secrets.nix): library functionality such as fetcher shell scripts and logic for attaching sidecar services to a systemd service definition

## How to try

Depending on whether you want to retrieve the secrets from vault or a folder
based store, you have to either populate state either manually or by using
somewhat similar to the small bootstrap scripts provided.

Currently only two backends are implemented, `folder` and `vault`. Former being
a simple, root-only readable folder containing secrets files. The Latter
retrieves secrets from vault from a configurable key.

### Folder based

The location of the secrets is configured via `secretsDir` (see `config.nix`).
For the example service it's necessary to create the following secrets:

```
mkdir /etc/secrets
chown -R root:root /etc/secrets
chmod 700 /etc/secrets
echo 'FOLDER_SECRET_1' > /etc/secrets/secret1
echo 'FOLDER_SECRET_2' > /etc/secrets/secret2
```

### Vault

The easiest bare-bones way to configure a vault development server sufficient
for this poc is contained in `bootstrap_vault.sh`. It essentially starts a
development service with a known root token which it persists to
`/etc/secrets/service_secrets_token` for the vault fetcher implementation to
use.

## Trying the test service

After populating the state for the different backends it should be sufficient to
include `config.nix` in your nixos configuration (or that of a VM) like so:

```
imports = [
  ...
  $repo_path/config.nix
  ...
]
```

This will apply the basic configuration necessary and also create two systemd
services, `secrets_test_file` which is a dummy service consuming a secret from a
file and `secrets_test_env`, a dummy service consuming a secret from the
environment. There is a very basic activationScript check for the system-wide
configured secrets backend settings, such as checking for the existence of
secrets directory or vault token file (note: right now, in this POC, this does
not consider the possibly overriden configs of individual services).

After applying the configuration the services should become available and should
produce an output similar to this:

```
$ journalctl -u secrets_test_file -u secrets_test_file-secrets -f

Apr 12 11:33:59 hercules systemd[1]: Starting side-cart for secrets_test_file...
Apr 12 11:33:59 hercules 9wfw6h3qvrv2gw7s8p62j1gsrkp382vg-vault-fetcher[20161]: Fetching secrets: secret1 secret2
Apr 12 11:33:59 hercules 9wfw6h3qvrv2gw7s8p62j1gsrkp382vg-vault-fetcher[20161]: Fetching secret: secret1
Apr 12 11:33:59 hercules 9wfw6h3qvrv2gw7s8p62j1gsrkp382vg-vault-fetcher[20161]: Fetching secret: secret2
Apr 12 11:33:59 hercules systemd[1]: Started side-cart for secrets_test_file.
Apr 12 11:33:59 hercules 9wfw6h3qvrv2gw7s8p62j1gsrkp382vg-vault-fetcher[20161]: Started watching secrets
Apr 12 11:33:59 hercules 9wfw6h3qvrv2gw7s8p62j1gsrkp382vg-vault-fetcher[20161]: polling secrets version...
Apr 12 11:33:59 hercules systemd[1]: Started Simple test service using a secret.
Apr 12 11:33:59 hercules 3cqqyhyac9nablpc4s7jc0v174qzxq7b-secrets-env-wrapper[20187]: Injecting secrets into environment for /nix/store/rm1hz1lybxangc8sdl7xvzs5dcvigvf7-bash-4.4-p23/bin/bash -c '/nix/store/9v78r3afqy9xn9zwdj9wfys6sk3vc01d-coreutils-8.31/bin/cat /tmp/secret1; sleep infinity'
Apr 12 11:33:59 hercules 3cqqyhyac9nablpc4s7jc0v174qzxq7b-secrets-env-wrapper[20187]: VAULT_SECRET1_1586684036
Apr 12 11:33:59 hercules 9wfw6h3qvrv2gw7s8p62j1gsrkp382vg-vault-fetcher[20161]: current version: 63
```

Both services will sleep indefinitely to allow for simple experimentation with
reloading/modifying secrets during the services runtime. The folder based store
watches the secrets files using inotify and vault is being periodically polled
for changes.
