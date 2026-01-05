# vault-vso-csi-demo
Demo for Vault VSO and CSI demo. This demo uses Vault Ent 1.21.x this can be downloaded from [here](https://releases.hashicorp.com/vault/1.21.1+ent/). Note Vault enterprise is required for this feature. We will be using [this guide](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/csi/setup) as a base for this and details on this feature can be found [here](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/csi)


## Start Vault
We will run Vault Ent in dev mode for this to make it simple, to do that run the following command in a new terminal tab. I also have vault enterprise installed as `vault-ent` this may not be the case for you and you may need to use `vault` instead. For the `VAULT_LICENSE` you will need to add you vault licence to this. 

```bash
export VAULT_LICENSE=""
vault-ent server -dev 
```

## Setup Vault KV

First lets connect to our new vault, add you vault token to the `VAULT_TOKEN` one:

```bash
export VAULT_TOKEN=''
export VAULT_ADDR='http://127.0.0.1:8200'
```

Now lets setup some KV for us to use
```bash
vault secrets enable -path=example-kv -version=2 kv

vault kv put example-kv/password value="super-secret-password"
vault kv put example-kv/api-key key="abc123"
```

Next a AppRole
```bash
vault auth enable approle

vault write auth/approle/role/example-role \
  token_policies="default" \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=1h \
  secret_id_num_uses=0
```

## Create the VSO Policy
The policy can be found in [csi-driver.hcl](csi-driver.hcl), lets run:

```bash
vault policy write csi-driver csi-driver.hcl
```
