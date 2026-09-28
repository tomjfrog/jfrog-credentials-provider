# Lab: AKS projected SA tokens → JFrog (Option B, 1.4.0)

**Target:** tomjpd2.jfrog.io + `tomj-k8s-cluster`. **No Entra app registration.**

## Prerequisites

- `az login` (tenant `ad8b5a8c-9862-4c41-a341-aa838fc564df`)
- `kubectl`, `helm`, `jf` (server `tomjpd2`)
- Source env: copy [azure-env-secrets.sh.example](../azure-env-secrets.sh.example) to `azure-env-secrets.sh` at repo root, then `source azure-env-secrets.sh`

## 1. Re-baseline cluster

```bash
./tomj-lab/scripts/az-login-and-baseline.sh
```

Confirm `oidcIssuerProfile.enabled` and record the issuer URL. Update `SERVICE_ACCOUNT_ISSUER` in your secrets file if the URL changed (trailing slash matters).

## 2. Artifactory setup

```bash
./tomj-lab/scripts/setup-tomjpd2-artifactory.sh
```

Or follow [azure-wi-isolation-evidence.md](./azure-wi-isolation-evidence.md) Phase 2. **Remove lab users from the `readers` group** before trusting negative tests.

## 3. OIDC provider + mappings

Already provisioned for this lab (`aks-wi-lab-oidc`). **Demo prep:** delete legacy mappings if present so audience checks are unambiguous:

- `mapping-team-a-artifactory-pull`, `mapping-team-b-artifactory-pull` (priority 10, `aud: api://AzureADTokenExchange`)
- Typo mapping: `mapping-team-a aks-team-a-puller-artifactory-pull-jfrog-aud` (if created during a bad loop)

**Desired mappings** (exact `iss`, `sub`, `aud: jfrog-artifactory`):

| Name | `sub` | User |
|------|-------|------|
| `mapping-team-a-jfrog-aud` | `system:serviceaccount:team-a:artifactory-pull` | `aks-team-a-puller` |
| `mapping-team-b-jfrog-aud` | `system:serviceaccount:team-b:artifactory-pull` | `aks-team-b-puller` |

To probe direct exchange without kubelet:

```bash
./tomj-lab/scripts/phase3-oidc-probe.sh
```

Per-namespace isolation at the JFrog layer requires either one SA per namespace (this lab) or a verified wildcard/nested-claim mapping (run probes in phase3 script comments).

## 4. Install credential provider

```bash
helm repo add jfrog https://charts.jfrog.io && helm repo update
helm upgrade --install jfrog-cp jfrog/jfrog-credential-provider \
  --namespace jfrog --create-namespace \
  -f tomj-lab/examples/azure-projected-sa-values-tomjpd2-jfrog-audience.yaml
```

Verify on a node: `/var/lib/kubelet/credential-provider-config.yaml` contains `tokenAttributes` with `JFrogExchange` and `cacheType: ServiceAccount`.

## 5. Workloads

```bash
kubectl apply -f tomj-lab/examples/k8s/azure/
```

See [examples/k8s/azure/README.md](./examples/k8s/azure/README.md).

## 6. Adversarial matrix

```bash
./tomj-lab/scripts/run-isolation-matrix.sh
```

For **T6**, set the same `nodeName` on `test-pod-team-a-own.yaml` and `test-pod-team-b-cross.yaml`, both `imagePullPolicy: Always`. Record results in `azure-wi-isolation-evidence.md`.

**T8 (audience):** With legacy mappings removed, `kubectl create token artifactory-pull -n team-a --audience jfrog-artifactory` should exchange **200**; the same token with `--audience api://AzureADTokenExchange` should **fail** once only `jfrog-artifactory` mappings exist.

**Images:** On Apple Silicon dev machines, push amd64 via `./tomj-lab/scripts/push-lab-images-amd64.sh`.

## Customer claim language

Validated **2026-09-28:** T1–T9 pass on live cluster (T0/T10 not run). You may claim cross-namespace **403** on shared nodes with `imagePullPolicy: Always` (T6), dedicated-audience pulls (T8), and immediate mapping revoke for new tags (T9).

**Caveats to state explicitly:**

- New Artifactory users in the global **`readers`** group break repo-only isolation until removed.
- **T7:** node image cache with `IfNotPresent` can skip a registry pull after a prior successful pull on the node.
- **T9:** kubelet/provider credential cache (`defaultCacheDuration: 5m`) was not fully timed; uncached revoke for new tags was immediate.

## References

- [AZURE.md](../AZURE.md) Step 4B
- [Microsoft AKS Workload Identity overview](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview) — OIDC issuer relevant; Entra federated credentials and pod webhook **not** used for image pulls in this flow.
