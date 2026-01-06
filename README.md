# vault-vso-csi-demo

Demo for Vault VSO and CSI integration.  
This demo uses **Vault Enterprise 1.21.x**, which you can download from the [Vault releases page](https://releases.hashicorp.com/vault/).  
Vault Enterprise is required for this feature.

This walkthrough is based on the following guides, with additional context added for clarity:

- [VSO Tutorial](https://developer.hashicorp.com/validated-patterns/vault/vault-kubernetes-auth)
- [Vault CSI + VSO setup guide](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/csi/setup)
- [Vault CSI feature overview](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/csi)

## Start and Configure Vault

Start Vault Enterprise and initialise and unseal it. This lab assumes a single-node development-style setup.

```bash
export VAULT_LICENSE=""
vault server -config=vault.hcl

## In a new terminal tab
vault operator init -key-shares=1 -key-threshold=1
vault operator unseal
```

## Create Namespaces and Enable KV Secrets

Create an admin namespace and a tenant namespace, then enable a KV v2 secrets engine and write some example secrets that will later be accessed via VSO and CSI.

```bash
vault namespace create admin
vault namespace create -namespace="admin" tenant-1

vault secrets enable -namespace="admin/tenant-1" -path="secret" kv-v2

vault kv put -namespace="admin/tenant-1" \
  -mount="secret" team-a/my-app/test \
  user=hello \
  password=kubernetes

vault kv put -namespace="admin/tenant-1" \
  -mount="secret" team-b/another-app/test \
  user=hello \
  password=nomad
```

## Create Kubernetes Service Account for Vault Auth

Create a service account and bind it with permissions so Vault can use it for Kubernetes authentication.

```bash
kubectl create namespace vault-auth
kubectl create serviceaccount vault-sa -n vault-auth

kubectl create clusterrolebinding vault-auth-binding \
  -n vault-auth \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault-auth:vault-sa
```

Create a token Secret for the service account.

```bash
cat <<EOF > vault-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: vault-sa-secret
  namespace: vault-auth
  annotations:
    kubernetes.io/service-account.name: vault-sa
type: kubernetes.io/service-account-token
EOF

kubectl apply -f vault-secret.yaml
```

## Configure Kubernetes Auth in Vault

Enable Kubernetes auth in the tenant namespace, collect cluster details, and configure the auth method.

```bash
vault auth enable -namespace="admin/tenant-1" kubernetes

export SA_TOKEN=$(kubectl get secret vault-sa-secret -n vault-auth \
  -o jsonpath="{.data.token}" | base64 --decode)
export KUBERNETES_CA=$(kubectl get secret vault-sa-secret -n vault-auth \
  -o jsonpath="{.data['ca\.crt']}" | base64 --decode)
export KUBERNETES_URL=$(kubectl config view --minify \
  -o jsonpath='{.clusters[0].cluster.server}')

vault write -namespace="admin/tenant-1" auth/kubernetes/config \
  use_annotationfs_as_alias_metadata=true \
  token_reviewer_jwt="${SA_TOKEN}" \
  kubernetes_host="${KUBERNETES_URL}" \
  kubernetes_ca_cert="${KUBERNETES_CA}"
```

Extract the Kubernetes auth accessor for use in a policy template.

```bash
vault auth list -namespace="admin/tenant-1" -format=json \
  | jq -r '.["kubernetes/"].accessor' \
  > accessor_kubernetes.txt
```

## Create a Vault Policy for App-Scoped Access

This policy allows workloads to read only the secrets that match their identity metadata values.

```bash
tee my-app-policy.hcl <<EOF
# Allows reading KV secrets for the bound application
path "secret/data/{{identity.entity.aliases.$(cat accessor_kubernetes.txt).metadata.BusinessSegmentName}}/{{identity.entity.aliases.$(cat accessor_kubernetes.txt).metadata.AppName}}/*" {
  capabilities = ["read"]
}

# Allows reading KV secret metadata and versions
path "secret/metadata/{{identity.entity.aliases.$(cat accessor_kubernetes.txt).metadata.BusinessSegmentName}}/{{identity.entity.aliases.$(cat accessor_kubernetes.txt).metadata.AppName}}/*" {
  capabilities = ["list", "read"]
}
EOF

vault policy write -namespace="admin/tenant-1" my-app-policy \
  my-app-policy.hcl
```

Create a Kubernetes auth role bound to the application’s service account.

```bash
vault write -namespace="admin/tenant-1" auth/kubernetes/role/my-app \
  bound_service_account_names=my-app \
  bound_service_account_namespaces=app-1 \
  policies=my-app-policy \
  audience=https://kubernetes.default.svc.cluster.local \
  ttl=1h
```

## Install Vault Secrets Operator (VSO)

Create the operator namespace.

```bash
kubectl create ns vault-secrets-operator-system
```

Update the Vault address in `vault-operator-values.yaml`, then install VSO.

```bash
helm install vault-secrets-operator hashicorp/vault-secrets-operator \
  --namespace vault-secrets-operator-system \
  --values vault-operator-values.yaml
```

## Grant VSO Permission to Read Service Accounts

```bash
kubectl create clusterrole read-serviceaccounts \
  --verb="list" \
  --verb="get" \
  --resource=serviceaccounts

kubectl create clusterrolebinding read-serviceaccounts-binding \
  --clusterrole=read-serviceaccounts \
  --serviceaccount=vault-auth:vault-sa

kubectl auth can-i get serviceaccounts \
  --as system:serviceaccount:vault-auth:vault-sa
```

## Deploy Application Namespace and Service Account

```bash
kubectl create ns app-1
kubectl apply -f service-account-my-app.yml
```

## Test Vault Authentication from the Application Context

Log in using the Kubernetes auth role and read a secret as the application.

```bash
export APP_TOKEN=$(vault write -namespace="admin/tenant-1" -field="token" \
  auth/kubernetes/login \
  role=my-app \
  jwt=$(kubectl create token -n app-1 my-app))

VAULT_TOKEN=$APP_TOKEN vault kv get \
  -namespace="admin/tenant-1" \
  -mount=secret team-a/my-app/test
```

## Configure VSO Static Secret Sync

Apply the VSO `VaultAuth` and `VaultStaticSecret` resources.

```bash
kubectl apply -f static-auth.yaml
kubectl apply -f static-secret.yaml
```

Verify that the static secret is reconciled and synced to a Kubernetes Secret.

```bash
kubectl describe vaultstaticsecret.secrets.hashicorp.com/vault-kv-app -n app-1
kubectl get secrets secretkv -n app-1 -o yaml
```