# vault-vso-csi-demo

Demo for Vault VSO and CSI integration.  
This demo uses **Vault Enterprise 1.21.x**, which you can download from the [Vault releases page](https://releases.hashicorp.com/vault/).  
Vault Enterprise is required for this feature.

This walkthrough is based on the following guide, with additional context added for clarity:

- [Vault CSI + VSO setup guide](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/csi/setup)
- [Vault CSI feature overview](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/csi)

## Start Vault

We will run Vault Enterprise in **dev mode** to keep things simple.

Run the following command in a new terminal tab.  
In this example the binary is named `vault-ent`, but if your binary is simply `vault`, use that instead.

You will also need to provide a valid Vault Enterprise license value in `VAULT_LICENSE`.

```bash
export VAULT_LICENSE=""
vault-ent server -dev
```

Dev mode automatically unseals Vault and prints the root token.

## Configure Vault CLI

In another terminal, configure your Vault environment variables.
Replace VAULT_TOKEN with the root token printed when Vault started.

```bash
export VAULT_TOKEN=""
export VAULT_ADDR="http://127.0.0.1:8200"
```

## Set up KV secrets

Next, enable a KV v2 secrets engine and create some example secrets that the CSI driver will read later.

```bash
vault secrets enable -path=example-kv -version=2 kv

vault kv put example-kv/password value="super-secret-password"
vault kv put example-kv/api-key key="abc123"
```

## Create an AppRole

Enable the AppRole auth method and create an example AppRole that we will reference later.

```bash
vault auth enable approle

vault write auth/approle/role/example-role \
  token_policies="default" \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=1h \
  secret_id_num_uses=0
```

## Create the VSO / CSI policy

The CSI driver requires a Vault policy to allow it to read secrets and (optionally) generate AppRole secret IDs.

The policy definition is stored in [csi-driver.hcl](csi-driver.hcl).

Apply the policy using:
```bash
vault policy write csi-driver csi-driver.hcl
```

## Install VSO
Install the Vault Secrets Operator Helm chart with the csi.enabled flag set to true to deploy the CSI driver as a DaemonSet running on every node:

```bash
helm repo update
helm install                           \
    --version 1.0.0                    \
    --create-namespace                 \
    --namespace vault-secrets-operator \
    --set "csi.enabled=true"           \
    vault-secrets-operator             \
    hashicorp/vault-secrets-operator

```

