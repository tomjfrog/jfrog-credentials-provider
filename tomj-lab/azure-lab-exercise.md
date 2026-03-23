# Lab exercise: JFrog Kubelet Credential Provider on AKS (Azure Workload Identity only)

This runbook uses **Option B — projected service account tokens + Azure Workload Identity** ([AZURE.md](../AZURE.md) Step 3B). It does **not** use Terraform or nodepool/IMDS identity (Option A).

**Why this path:** The token sent to JFrog is the **Kubernetes service account OIDC JWT** from your cluster issuer. Its `sub` claim is stable and workload-specific: `system:serviceaccount:<namespace>:<service-account>`. You can give each team, namespace, or app a dedicated ServiceAccount, a matching **Entra federated credential**, and a **JFrog identity mapping** on `sub` (and tighter claims if your JFrog version supports them)—so Artifactory sees identity that reflects **which Kubernetes workload** is pulling the image.

**Component name:** Install the **JFrog Kubelet Credential Provider** with Helm chart **`jfrog/jfrog-credential-provider`** ([helm/Chart.yaml](../helm/Chart.yaml)).

**JFrog:** You configure OIDC providers and identity mappings in JFrog; values below must match what you create there.

---

## 0. Environment variables

| Variable | Purpose |
|----------|---------|
| `TENANT_ID` | Entra tenant |
| `SUBSCRIPTION_ID` | Azure subscription |
| `RESOURCE_GROUP` | AKS resource group |
| `CLUSTER_NAME` | AKS name |
| `LOCATION` | Azure region |
| `APP_CLIENT_ID` | App registration **application (client) ID** — same value you put on `azure.workload.identity/client-id` |
| `APP_OBJECT_ID` | App registration object ID (Graph) |
| `SERVICE_ACCOUNT_ISSUER` | AKS OIDC issuer URL |
| `ARTIFACTORY_URL` | e.g. `your-instance.jfrog.io` (no `https://` in Helm `artifactoryUrl`) |
| `OIDC_PROVIDER_NAME` | JFrog OIDC provider name (= `jfrog_oidc_provider_name` in Helm) |
| `ARTIFACTORY_USER` | Artifactory user for a given mapping (often one per workload tier) |
| `NAMESPACE` | Kubernetes namespace for the workload SA (repeat per workload as needed) |
| `SERVICE_ACCOUNT_NAME` | Name of the SA that **pods pulling from Artifactory** use |

```bash
TENANT_ID=$(az account show --query tenantId -o tsv)
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

---

## 1. Azure resources (no Terraform)

### 1.1 Resource group

```bash
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
```

### 1.2 Networking

Use AKS defaults for a lab (`kubenet` or your org’s VNet design). Workload Identity does not require a special network mode beyond a supported AKS configuration.

---

## 2. Deploy AKS (OIDC issuer + Workload Identity)

Both are **required** for Option B.

```bash
az aks create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --location "$LOCATION" \
  --enable-managed-identity \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --network-plugin kubenet \
  --node-count 2 \
  --generate-ssh-keys
```

If the cluster already exists:

```bash
az aks update \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --enable-oidc-issuer \
  --enable-workload-identity
```

### 2.1 Issuer URL (needed for Entra + JFrog)

You need the cluster’s OIDC issuer string for Entra **federated credential** `issuer`, JFrog **OIDC provider** `issuer_url` / `token_issuer`, and identity mapping claim **`iss`**. It must match the service-account JWT **`iss`** claim exactly (including a **trailing slash** if the API returns one).

**Option A — `az aks show` (when your CLI accepts the AKS ARM API version):**

```bash
SERVICE_ACCOUNT_ISSUER=$(az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query "oidcIssuerProfile.issuerUrl" \
  -o tsv)

echo "$SERVICE_ACCOUNT_ISSUER"
```

**Option B — `az rest` (if `az aks show` fails with `InvalidApiVersionParameter`, or you prefer raw ARM):**

Use an API version your subscription accepts (e.g. `2025-04-01`). Ensure **`$RESOURCE_GROUP` is set**—if it is empty, the URL becomes `.../resourceGroups/providers/...` and ARM returns **Not Found**.

```bash
SERVICE_ACCOUNT_ISSUER=$(az rest --method GET \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerService/managedClusters/$CLUSTER_NAME?api-version=2025-04-01" \
  --query "properties.oidcIssuerProfile.issuerURL" \
  -o tsv)

echo "$SERVICE_ACCOUNT_ISSUER"
```

**ARM JSON uses `issuerURL`, not `issuerUrl`:** Recent AKS REST payloads expose the field as **`issuerURL`** (capital `URL`). A JMESPath query for `properties.oidcIssuerProfile.issuerUrl` against `az rest` output returns **empty** even when OIDC is enabled. The `az aks show ... oidcIssuerProfile.issuerUrl` query often still works when the CLI succeeds because the command layer maps the response shape for you.

**Empty issuer:** If `oidcIssuerProfile` is missing, `enabled` is false, or the URL is still blank, enable the OIDC issuer (see §2 `az aks create` / `az aks update`) and wait for the operation to finish. Inspect the block with:

```bash
az rest --method GET \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerService/managedClusters/$CLUSTER_NAME?api-version=2025-04-01" \
  --query "properties.oidcIssuerProfile" -o json
```

### 2.2 kubeconfig

```bash
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --overwrite-existing
kubectl get nodes
```

---

## 3. Entra ID: app registration (single app, many workloads)

One app registration can trust **many** Kubernetes service accounts via **multiple federated identity credentials** (different `subject`, same `issuer` = `$SERVICE_ACCOUNT_ISSUER`).

### 3.1 Create app + service principal

```bash
APP_DISPLAY_NAME="jfrog-credentials-provider-aks-wi"

APP_CLIENT_ID=$(az ad app create \
  --display-name "$APP_DISPLAY_NAME" \
  --query appId -o tsv)

az ad sp create --id "$APP_CLIENT_ID"
```

### 3.2 Access token version v2

```bash
OBJECT_ID=$(az ad app show --id "$APP_CLIENT_ID" --query "id" -o tsv)

az rest --method PATCH \
  --headers "Content-Type=application/json" \
  --uri "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
  --body '{"api":{"requestedAccessTokenVersion": 2}}'
```

### 3.3 (Recommended) Assignment required + self-assignment

If your baseline requires **Assignment required** on the enterprise app, follow [AZURE.md](../AZURE.md) Step 1 (“Enable Assignment Required” + app role + self-assignment). Workload Identity token exchange still needs the app to be usable by the intended federated identities.

### 3.4 Federated credential **per** ServiceAccount (workload-specific trust)

For **each** Kubernetes `ServiceAccount` that will participate in image pulls with this flow, create a federated credential whose **subject** is exactly:

`system:serviceaccount:<namespace>:<service-account-name>`

```bash
# Example: one workload in namespace "team-a", SA "artifactory-pull"
NAMESPACE="team-a"
SERVICE_ACCOUNT_NAME="artifactory-pull"
SUBJECT="system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT_NAME}"
FED_NAME="fed-${NAMESPACE}-${SERVICE_ACCOUNT_NAME}"   # unique per SA; max 120 chars on Azure side

az ad app federated-credential create \
  --id "$APP_CLIENT_ID" \
  --parameters "{
    \"name\": \"$FED_NAME\",
    \"issuer\": \"$SERVICE_ACCOUNT_ISSUER\",
    \"subject\": \"$SUBJECT\",
    \"audiences\": [\"api://AzureADTokenExchange\"],
    \"description\": \"Workload Identity for $SUBJECT -> JFrog pulls\"
  }"
```

Repeat `az ad app federated-credential create` for every distinct `(namespace, serviceAccount)` you want to treat as a separate identity in JFrog.

**Do not** use the Option A kubelet/nodepool federated credential (`issuer` = `https://login.microsoftonline.com/...`) for this lab—that path is for IMDS-based tokens, not the Kubernetes JWT you send to JFrog in Option B.

---

## 4. Kubernetes: wire each workload ServiceAccount

### 4.1 Namespace (if needed)

```bash
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
```

### 4.2 ServiceAccount annotations (required by provider + Azure WI)

The credential provider only uses the projected token path when the **pod’s** ServiceAccount has `JFrogExchange=true` ([internal/provider/provider.go](../internal/provider/provider.go)). Azure Workload Identity expects `azure.workload.identity/client-id` on that same ServiceAccount ([helm/templates/configmap-provider.yaml](../helm/templates/configmap-provider.yaml) `requiredServiceAccountAnnotationKeys`).

```bash
kubectl create serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl annotate serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$NAMESPACE" \
  azure.workload.identity/client-id="$APP_CLIENT_ID" \
  JFrogExchange="true" \
  --overwrite
```

### 4.3 Pods that pull from Artifactory must use that ServiceAccount

In every Deployment/Job/Pod that references an image under your `matchImages` pattern:

- Set `spec.serviceAccountName` to this ServiceAccount (not `default` unless you annotated `default`).
- Add the Workload Identity label so the mutating webhook projects the token ([Azure AKS Workload Identity](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview)):

```yaml
metadata:
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: artifactory-pull
```

If your cluster version or docs require a namespace label for Workload Identity, apply the same label on the namespace per current Microsoft guidance.

### 4.4 Making JFrog mappings as specific as possible

- **Primary lever:** One ServiceAccount per isolation boundary (team, namespace, app). The JWT `sub` is unique per `(namespace, name)`, so one JFrog **identity mapping** per SA is the straightforward way to map workloads to different Artifactory users or token specs.
- **Optional:** Decode a real projected token (e.g. short-lived debug pod with the same SA) in [jwt.ms](https://jwt.ms) and see if extra claims exist (cluster/version dependent). If JFrog identity mappings support them, add predicates on those claims for tighter rules—always verify against your Artifactory version’s mapping capabilities.

---

## 5. Install the JFrog Kubelet Credential Provider (Helm)

Use [examples/azure-projected-sa-values.yaml](../examples/azure-projected-sa-values.yaml) as the base: `tokenAttributes.enabled: true`, no `azure_nodepool_client_id`.

```bash
helm repo add jfrog https://charts.jfrog.io
helm repo update
```

Copy the example and set at least:

- `artifactoryUrl`, `matchImages`
- `azure.azure_app_client_id` = `$APP_CLIENT_ID`
- `azure.azure_app_audience` = `api://AzureADTokenExchange` (default; must match what the projected token uses—chart sets `serviceAccountTokenAudience` from this)
- `azure.jfrog_oidc_provider_name` = your JFrog provider name

The chart sets `requireServiceAccount: true` and requires annotations `azure.workload.identity/client-id` and `JFrogExchange` for Azure + token projection ([helm/templates/configmap-provider.yaml](../helm/templates/configmap-provider.yaml)).

```bash
helm upgrade --install credential-provider jfrog/jfrog-credential-provider \
  --namespace jfrog \
  --create-namespace \
  -f examples/azure-projected-sa-values.yaml
```

**Affinity:** The example pins to nodes labeled `credentialsProviderEnabled=true`. Either label your nodes or remove/adjust `affinity` in your values file.

**RBAC:** Keep `rbac.create: true` as in the example (needed for projected service account token behavior in this chart).

---

## 6. JFrog (you configure): OIDC provider + identity mappings

### 6.1 One OIDC provider for the cluster issuer

Point JFrog at the **AKS OIDC issuer**, not `login.microsoftonline.com`:

```bash
curl -X POST "https://$ARTIFACTORY_URL/access/api/v1/oidc" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $ARTIFACTORY_ADMIN_TOKEN" \
  -d "{
    \"name\": \"$OIDC_PROVIDER_NAME\",
    \"issuer_url\": \"$SERVICE_ACCOUNT_ISSUER\",
    \"provider_type\": \"Azure\",
    \"token_issuer\": \"$SERVICE_ACCOUNT_ISSUER\",
    \"use_default_proxy\": false,
    \"description\": \"AKS Workload Identity -> JFrog\"
  }"
```

### 6.2 One identity mapping per ServiceAccount (workload-specific `sub`)

```bash
curl -X POST "https://$ARTIFACTORY_URL/access/api/v1/oidc/$OIDC_PROVIDER_NAME/identity_mappings" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $ARTIFACTORY_ADMIN_TOKEN" \
  -d "{
    \"name\": \"mapping-${NAMESPACE}-${SERVICE_ACCOUNT_NAME}\",
    \"description\": \"Pull identity for $NAMESPACE/$SERVICE_ACCOUNT_NAME\",
    \"claims\": {
      \"aud\": \"api://AzureADTokenExchange\",
      \"iss\": \"$SERVICE_ACCOUNT_ISSUER\",
      \"sub\": \"system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT_NAME}\"
    },
    \"token_spec\": {
      \"username\": \"$ARTIFACTORY_USER\",
      \"scope\": \"applied-permissions/user\",
      \"audience\": \"*@*\",
      \"expires_in\": 3600
    },
    \"priority\": 1
  }"
```

Repeat for each `(NAMESPACE, SERVICE_ACCOUNT_NAME)` with the appropriate `ARTIFACTORY_USER` / `token_spec` for that workload.

Ensure `token_spec.expires_in` is **greater than** the credential provider cache window (`defaultCacheDuration` in Helm, e.g. `5h` in the example—convert to seconds when comparing).

---

## 7. Token JFrog receives (Option B)

With `JFrogExchange=true`, the plugin sends **`request.ServiceAccountToken`** to JFrog’s OIDC token exchange API ([internal/provider/provider.go](../internal/provider/provider.go), [internal/handlers/jfrog.go](../internal/handlers/jfrog.go)).

That JWT is issued by **your AKS OIDC issuer** (`iss` = `$SERVICE_ACCOUNT_ISSUER`). The claim that makes the identity **workload-specific** is:

| Claim | Role |
|-------|------|
| `sub` | **`system:serviceaccount:<namespace>:<sa>`** — match this in JFrog for per-workload mappings |
| `iss` | AKS issuer URL — same for all workloads on the cluster (unless you use multiple clusters) |
| `aud` | Must match what you configure for projection; use `api://AzureADTokenExchange` consistently with Entra + JFrog |

The exchange call passes `audience` = `azure_app_client_id` ([internal/provider/provider.go](../internal/provider/provider.go)); your JFrog mapping `claims.aud` still follows the Kubernetes token’s audience (`api://AzureADTokenExchange` in the docs and examples).

Decode a live token from a test pod to confirm `sub`, `iss`, and `aud` before locking mappings.

---

## 8. Verification

```bash
kubectl get daemonset,pods -n jfrog
```

Run a pod in `$NAMESPACE` using `$SERVICE_ACCOUNT_NAME`, with the Workload Identity label, pulling an image that matches `matchImages`. See [AZURE.md](../AZURE.md) § Verification.

Plugin logs on nodes: `/var/log/jfrog-credential-provider.log` ([README.md](../README.md)). More detail: [debug.md](../debug.md).

---

## Reference

- [AZURE.md](../AZURE.md) — full Azure guide (Options A and B)
- [AKS Workload Identity overview](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview)
- [JFrog identity mappings](https://jfrog.com/help/r/jfrog-platform-administration-documentation/identity-mappings)
- [Create OIDC configuration (REST)](https://jfrog.com/help/r/jfrog-rest-apis/create-oidc-configuration)
- [Kubelet credential provider](https://kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider/)
