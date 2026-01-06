# vault-vso-csi-demo

Demo for Vault VSO and CSI integration.  
This demo uses **Vault Enterprise 1.21.x**, which you can download from the [Vault releases page](https://releases.hashicorp.com/vault/).  
Vault Enterprise is required for this feature.

This walkthrough is based on the following guids, with additional context added for clarity:

- [VSO Tutoiral](https://developer.hashicorp.com/validated-patterns/vault/vault-kubernetes-auth)
- [Vault CSI + VSO setup guide](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/csi/setup)
- [Vault CSI feature overview](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/csi)

### Start and Configure Vault
```bash
export VAULT_LICENSE=""
vault server -config=vault.hcl

## In New Terminal Tab
vault operator init -key-shares=1 -key-threshold=1
vault operator unseal 
```

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

```bash
kubectl create namespace vault-auth
kubectl create serviceaccount vault-sa -n vault-auth

kubectl create clusterrolebinding vault-auth-binding \
  -n vault-auth \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault-auth:vault-sa

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

vault auth list -namespace="admin/tenant-1" -format=json \
  | jq -r '.["kubernetes/"].accessor' \
  > accessor_kubernetes.txt

tee my-app-policy.hcl <<EOF
# Allows to read K/V secrets 
path "secret/data/{{identity.entity.aliases.$(cat accessor_kubernetes.txt).metadata.BusinessSegmentName}}/{{identity.entity.aliases.$(cat accessor_kubernetes.txt).metadata.AppName}}/*" {
    capabilities = ["read"]
}
# Allows reading K/V secret versions and metadata
path "secret/metadata/{{identity.entity.aliases.$(cat accessor_kubernetes.txt).metadata.BusinessSegmentName}}/{{identity.entity.aliases.$(cat accessor_kubernetes.txt).metadata.AppName}}/*" {
      capabilities = ["list", "read"]
}
EOF

vault policy write -namespace="admin/tenant-1" my-app-policy \
  my-app-policy.hcl

vault write -namespace="admin/tenant-1" auth/kubernetes/role/my-app \
    bound_service_account_names=my-app \
    bound_service_account_namespaces=app-1 \
    policies=my-app-policy \
    audience=https://kubernetes.default.svc.cluster.local \
    ttl=1h
```
** Next Install VSO **

```bash
kubectl create ns vault-secrets-operator-system
```

Rememeber to update IP in [vault-operator-values.yaml](vault-operator-values.yaml)

```bash
helm install vault-secrets-operator hashicorp/vault-secrets-operator \
  --namespace vault-secrets-operator-system \
  --values vault-operator-values.yaml
```

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

kubectl create ns app-1

kubectl apply -f service-account-my-app.yml

export APP_TOKEN=$(vault write -namespace="admin/tenant-1" -field="token" \
  auth/kubernetes/login \
  role=my-app \
  jwt=$(kubectl create token -n app-1 my-app))

VAULT_TOKEN=$APP_TOKEN vault kv get \
  -namespace="admin/tenant-1" \
  -mount=secret team-a/my-app/test 
```

```bash
kubectl apply -f static-auth.yaml
kubectl apply -f static-secret.yaml
```

```bash
kubectl describe vaultstaticsecret.secrets.hashicorp.com/vault-kv-app -n app-1
kubectl get secrets secretkv -n app-1 -o yaml
```