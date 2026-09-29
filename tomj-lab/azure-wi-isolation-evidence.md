# Azure WI isolation lab — evidence log

**Hypothesis:** Per-namespace image pull isolation via projected SA tokens → JFrog OIDC (Option B, chart 1.4.0).

**Gate:** T1–T7 and T9 **pass** on live cluster (2026-09-28); T8 **partial** (Artifactory side only, see matrix). **T0** and **T10** not run (provider was already installed; RBAC demo deferred).

## Environment

| Item | Value | Verified |
|------|-------|----------|
| Fork chart | 1.4.0 (merged upstream `main`) | Yes |
| JFrog instance | tomjpd2.jfrog.io | Yes (`jf rt ping`) |
| AKS cluster | tomj-k8s-cluster / tomj-jfrog-credentials-provider-lab-rg | Yes (2026-09-28) |
| Control plane / nodes | 1.35.1 / 1.34.4 | Yes |
| OIDC issuer | `https://centralus.oic.prod-aks.azure.com/ad8b5a8c-9862-4c41-a341-aa838fc564df/16d7b4c6-03c2-40d9-a137-354bd22d8bb6/` | Matches env file; discovery OK |
| Helm `jfrog-cp` | 1.4.0, 2/2 DaemonSet; rev 2 sets `jfrog-artifactory` aud in values/ConfigMap | Values yes; **nodes still on rev 1 audience** (`api://AzureADTokenExchange`) — DaemonSet not restarted |

## Phase 2 — Artifactory (no Kubernetes)

| Check | Result | Evidence |
|-------|--------|----------|
| Anonymous pull to lab repo | 401 on manifest probe | curl |
| Repos `team-a-docker-local`, `team-b-docker-local` | Created | MCP |
| Images `alpine:wi-lab-amd64` (linux/amd64) | Pushed to both repos | docker push |
| Users `aks-team-a-puller`, `aks-team-b-puller` | Created, **groups=[]** (removed default `readers`) | REST |
| Permission targets | Read only own repo | REST |
| team-a pulls team-a | OK | docker pull |
| team-a pulls team-b | 403 Forbidden | docker pull |
| team-b pulls team-b | OK | docker pull |
| team-b pulls team-a | 403 Forbidden | docker pull |

**Lesson:** New users were auto-added to `readers` → `Anything` permission masked isolation until groups cleared.

## Phase 3 — OIDC (Artifactory side)

| Item | Status |
|------|--------|
| OIDC provider `aks-wi-lab-oidc` | Created (`provider_type: Azure`, cluster issuer) |
| Mapping `mapping-team-a-artifactory-pull` → `aks-team-a-puller` | **Legacy** — `aud: api://AzureADTokenExchange`; remove for strict T8 |
| Mapping `mapping-team-b-artifactory-pull` → `aks-team-b-puller` | **Legacy** — same |
| Mapping `mapping-team-a-jfrog-aud` / `mapping-team-b-jfrog-aud` | **Current** — `aud: jfrog-artifactory` |
| Direct token exchange via `kubectl create token` | team-a/b **200** (matching aud), team-c **403** |
| Wildcard `sub` / `kubernetes.io.namespace` mapping | **NOT RUN** (exact `sub` sufficient) |

## Phase 4–6 — Provider + matrix

| Test | Status |
|------|--------|
| T0–T10 | See matrix below (2026-09-28 live run) |

## Test matrix (2026-09-28, node `aks-agentpool-42574423-vmss000000` for T6/T7)

| ID | Expected | Actual | Notes |
|----|----------|--------|-------|
| T0 | Fail | **NOT RUN** | Provider already installed |
| T1 | Pull OK | **Pull OK → Running** | After `buildx` **linux/amd64** push (`sha256:b93a7496…`) |
| T2 | Fail 403 | **403 Forbidden** | team-a → team-b repo |
| T3a | Pull OK | **Pull OK → Running (amd64)** | |
| T3b | Fail 403 | **403 Forbidden** | team-b → team-a repo |
| T4 | Fail | **401** anonymous | default SA |
| T5 | Fail | **401** anonymous | team-c unmapped |
| T6a | Pull OK | **Pull OK** | Same node |
| T6b | Fail 403 | **403 Forbidden** | **Not a blocker** — no registry cache leak |
| T7 | Cache gap | **already present on machine** | IfNotPresent, no pull |
| T8 | aud `jfrog-artifactory` | **PARTIAL** — direct exchange only | Direct exchange (`kubectl create token --audience jfrog-artifactory`) **200** via `mapping-*-jfrog-aud`. **Kubelet path not validated:** Helm rev 2 updated the ConfigMap (15:21Z) but DaemonSet pods (started 15:07Z) were never restarted, so both nodes still request `aud: api://AzureADTokenExchange`. T1 **Running** after rev 2 was served by the legacy priority-10 mapping. |
| T8 note | Legacy aud | Legacy `mapping-team-b-artifactory-pull` still present (re-checked 2026-09-28) | Before re-running: add node RBAC rule for `jfrog-artifactory` (chart ClusterRole only grants `api://AzureADTokenExchange`), `rollout restart` the DaemonSet, delete legacy mappings |
| T9 | Revoke mapping | **PASS (immediate)** | Delete team-a mappings: exchange **403**; new tag `wi-lab-t9-amd64` pull **401** (no anon). Re-pull of cached creds within `defaultCacheDuration` may still succeed — not measured to 5m |
| T10 | RBAC | **NOT RUN** | |

## Phase 7 — T7 mitigations (evaluation only)

| Mitigation | Notes |
|------------|--------|
| `imagePullPolicy: Always` + admission (Kyverno/Azure Policy) | Enforce on tenant namespaces; does not stop root on node |
| Kubelet `EnsureSecretPulledImages` | Check AKS/kubelet version and feature gate on re-baseline; not validated here |
| Dedicated nodepools + taints | Structural isolation; operational cost |
| `AlwaysPullImages` admission plugin | Classic cluster-level option if available on AKS |

## Upstream / doc issues to track

- T6 same-node denial **passed** (403 with `Always`) — not a kubelet registry cache leak.
- `AZURE.md` Step 4C still mentions Options A/B federated-credential scaling bottleneck incorrectly for Option B.
- Lab users on SaaS: default `readers` group breaks permission-only isolation tests.
