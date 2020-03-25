#! /usr/bin/env nix-shell
#! nix-shell -p vault -i bash

set -e

VAULT_ROOT_TOKEN="TEST_ROOT_TOKEN"
VAULT_ROOT_TOKEN_PATH="/etc/secrets/service_secrets_token"

export VAULT_ADDR='http://127.0.0.1:8200'

echo "Writing secret token to secret"
echo -n "$VAULT_ROOT_TOKEN" > "$VAULT_ROOT_TOKEN_PATH"

vault server -dev -dev-root-token-id="$VAULT_ROOT_TOKEN" &

# It takes a few seconds for vault to become available
sleep 5;

while true; do
    ts=$(date +'%s')
    echo "$ts: updating secrets"
    vault kv put secret/nixos-testsecrets secret1="VAULT_SECRET1_$ts" secret2="VAULT_SECRET2_$ts"
    sleep 10;
done

