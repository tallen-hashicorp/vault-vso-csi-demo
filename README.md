# vault-vso-csi-demo

Demo for Vault VSO and CSI integration.  
This demo uses **Vault Enterprise 1.21.x**, which you can download from the [Vault releases page](https://releases.hashicorp.com/vault/).  
Vault Enterprise is required for this feature.

This walkthrough is based on the following guides, with additional context added for clarity:

- [VSO Tutorial](https://developer.hashicorp.com/validated-patterns/vault/vault-kubernetes-auth)
- [Vault CSI + VSO setup guide](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/csi/setup)
- [Vault CSI feature overview](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/csi)

## Start and Configure Vault

Start Vault Enterprise and initialise and unseal it. This lab assumes a single-node development-style setup and will deploy Vault Ent into K8s.

```bash
kubectl create namespace vault-server
export VAULT_LICENSE=$(cat /path/to/vault.hclic)

kubectl create secret generic vault-license \
  -n vault-server \
  --from-literal=license.hclic="$VAULT_LICENSE"

kubectl apply -f vault-k8s-deploy.yaml 
```

Lets port forward to access our vault
```bash
kubectl port-forward -n vault-server service/vault 8200:8200
```

Now that Vault has started in a new terminal lets init it
```bash
export VAULT_ADDR='http://127.0.0.1:8200'
vault operator init -key-shares=1 -key-threshold=1
vault operator unseal

export VAULT_TOKEN=''
```

## Create Namespaces and Enable KV Secrets

Create an admin namespace and a tenant namespace, then enable a KV v2 secrets engine and write some example secrets that will later be accessed via VSO and CSI.

If you are feeling lazy here simply run `bash config-vault.sh` to take you to [Configure VSO Static Secret Sync](#configure-vso-static-secret-sync)

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
  use_annotations_as_alias_metadata=true \
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
# Allows to read K/V secrets 
path "secret/data/{{identity.entity.aliases.$(cat accessor_kubernetes.txt).metadata.BusinessSegmentName}}/{{identity.entity.aliases.$(cat accessor_kubernetes.txt).metadata.AppName}}/*" {
    capabilities = ["read"]
}
# Allows reading K/V secret versions and metadata
path "secret/metadata/{{identity.entity.aliases.$(cat accessor_kubernetes.txt).metadata.BusinessSegmentName}}/{{identity.entity.aliases.$(cat accessor_kubernetes.txt).metadata.AppName}}/*" {
      capabilities = ["list", "read"]
}
# CSI Driver
path "sys/license/status" {
    capabilities = ["read"]
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

kubectl get secrets secretkv -n app-1 -o json \
  | jq -r '.data.password' | base64 --decode
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

**[config-vault.sh finished here](config-vault.sh)**

## Configure VSO Static Secret Sync

The Kubernetes administrator needs to deploy and configure the VaultAuth and VaultStaticSecret resources to enable syncing secrets from Vault to Kubernetes.

Define and apply the VaultAuth configuration by creating a YAML configuration file for the VaultAuth resource. The VaultAuth resource specifies how the VSO authenticates with Vault, including the namespace, authentication method, and the role associated with the Kubernetes Service Account. [static-secret.yaml](static-secret.yaml)

Define and apply the VaultStaticSecret configuration by creating a YAML configuration file for the VaultStaticSecret resource. This resource defines the secret to be synced from Vault to Kubernetes, including the type of secret, the path, and destination details. You also set a refresh interval (refreshAfter), which controls how often the secret is checked for updates.  For demonstration purposes this is set rather short to 30s, but this could also be longer depending on the needs of the consuming applications. [static-secret.yaml](static-secret.yaml)

```bash
kubectl apply -f static-auth.yaml
kubectl apply -f static-secret.yaml
```

Verify that the static secret is reconciled and synced to a Kubernetes Secret.

```bash
kubectl describe vaultstaticsecret.secrets.hashicorp.com/vault-kv-app -n app-1
kubectl get secrets secretkv -n app-1 -o yaml
```

**Optional**
```bash
vault kv put -namespace="admin/tenant-1" \
  -mount=secret team-a/my-app/test \
  username=moin \
  password=consul
```

## Deploy and sync a CSI secret
The Kubernetes administrator needs to deploy and configure the VaultAuth and CSISecrets resources to enable syncing secrets from Vault to Kubernetes using the CSI driver.

Define and apply the VaultAuth configuration by creating a YAML configuration file for the VaultAuth resource. The VaultAuth resource specifies how the VSO authenticates with Vault, including the namespace, authentication method, and the role associated with the Kubernetes Service Account. [static-auth.yaml](static-auth.yaml)

Define and apply the CSISecrets configuration by creating a YAML configuration file for the VaultStaticSecret resource. The CSISecrets resource defines the secrets to sync from Vault, including the mount path, secret path, access control patterns for service accounts/namespaces/pods, and container state sync configuration.

```bash
kubectl apply -f static-auth.yaml
kubectl apply -f csi-secret.yaml
```

Verify the CSISecrets resource deployment.

```bash
kubectl get CSISecrets vault-kv-app -n app-1
kubectl describe CSISecrets vault-kv-app -n app-1
```

Deploy a test application that consumes the CSI secrets. This deployment creates pods named my-app that mount the CSI secrets volume and continuously read the synced username and password values.

```bash
kubectl replace --force -f csi-deploy.yaml -n app-1
kubectl logs deploy/my-app -n app-1 --follow
```

This guide has walked you through the integration of HashiCorp Vault with Kubernetes service accounts to securely manage secrets across your Kubernetes environment. By leveraging Kubernetes service accounts and their metadata, you can ensure that only authorized applications have access to sensitive data.

## Open Shift Specific
On OpenShift, the Kubernetes administrator must grant the appropriate Security Context Constraints (SCCs) to the Vault Secrets Operator service accounts and explicitly trust the CSI driver so that it can mount secrets into application pods. First, grant the `privileged` SCC to the Vault Secrets Operator controller manager and CSI service accounts. This allows the operator components to run with the permissions required by OpenShift to manage CSI volumes.

```bash
$ oc adm policy add-scc-to-user privileged \
  -z vault-secrets-operator-controller-manager \
  -n vault-secrets-operator-system

$ oc adm policy add-scc-to-user privileged \
  -z vault-secrets-operator-csi \
  -n vault-secrets-operator-system
```

Next, label the `csi.vso.hashicorp.com` `CSIDriver` resource with the `security.openshift.io/csi-ephemeral-volume-profile=restricted` key. This instructs OpenShift to trust the Vault Secrets Operator CSI driver for use in restricted environments and to allow its ephemeral volumes to be attached to pods that use the restricted security profile.

```shell-session
$ oc label csidriver csi.vso.hashicorp.com \
  security.openshift.io/csi-ephemeral-volume-profile=restricted --overwrite

$ oc get csidriver csi.vso.hashicorp.com
```
