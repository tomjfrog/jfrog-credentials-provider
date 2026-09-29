# Customer summary — AKS + JFrog credential provider (Option B)

## Executive summary (deck-ready)

- **What:** JFrog Kubelet Credential Provider **1.4.0** on AKS uses **projected service account tokens** (cluster OIDC issuer) — **no Entra app registration**.
- **Isolation model:** Artifactory **identity mapping** on `sub` (`system:serviceaccount:<namespace>:<sa>`) → dedicated user with **repo-scoped** permissions.
- **Validated on:** `tomj-k8s-cluster` + `tomjpd2.jfrog.io` (2026-09-28).
- **Results:** Cross-team pulls **403**; unmapped/default **401**; same-node adversarial test **403** with `imagePullPolicy: Always` (T6); mapping revoke immediate for new tags (T9). Dedicated audience **jfrog-artifactory** (T8) proven at the Artifactory exchange only — kubelet pulls in the lab still used `api://AzureADTokenExchange`.
- **Caveats:** Remove new users from global **`readers`** or repo isolation tests fail; node image cache with `IfNotPresent` (T7); kubelet credential cache up to **5m** after mapping revoke (not fully timed); one mapping per SA unless wildcards are proven on your Access version.

## Proven on AKS (2026-09-28, tomj-k8s-cluster)

**Artifactory (no Kubernetes):** Two Docker repos with distinct users enforce **repository-level** read isolation when users are **not** in `readers`. Cluster OIDC issuer is publicly discoverable (JWKS). OIDC provider + mappings target the **cluster issuer**, not `login.microsoftonline.com`.

**Kubernetes pulls:** **kubelet → plugin → Artifactory → pull** with projected SA + `JFrogExchange` only (~1.8s positive pulls). Cross-repo denial **403** (T2, T3b). Same node, `Always` — team-b cannot pull team-a image after team-a pull (**403**, T6). Default SA / unmapped namespace → **401** (T4, T5).

**Follow-up same day:** **linux/amd64** images via `docker buildx` → pods **Running** on amd64 pools. **T8 (partial):** Direct exchange of a `jfrog-artifactory`-audience SA token succeeds against matching mappings. The Helm change never reached the nodes (DaemonSet not restarted), and a custom audience also needs an extra node RBAC rule because the chart only authorizes `api://AzureADTokenExchange`. **T9:** Deleting team-a OIDC mappings → immediate **403** on exchange and **401** on pull for a **new** image tag.

**Mapping granularity:** Lab uses one SA name per namespace (`artifactory-pull`) and maps on exact `sub`. Wildcard or namespace-claim mappings were **not validated**.

## Still document / pending

- **T9 cache window:** Uncached revocation is immediate; pulls may still succeed until kubelet/provider cache expires (`defaultCacheDuration: 5m`) — full 5m wait not recorded.
- **T8 kubelet path:** add `rbac.role.additionalRules` for `jfrog-artifactory`, `rollout restart` the DaemonSet, delete legacy mappings, re-run T1/T2.
- **T10** direct token abuse demo.
- Wildcard / namespace-claim identity mappings.

## Out of scope / threat model

- Namespace RBAC: anyone who can create pods or `kubectl create token` for `artifactory-pull` in `team-a` obtains team-a pull identity.
- Compromised node / cluster admin.
- Entra Workload Identity federated credentials (not required for Option B 1.4.0).

## Microsoft docs mapping

| Doc topic | Relevant to this JFrog flow? |
|-----------|------------------------------|
| Enable OIDC issuer on AKS | Yes |
| Issuer discovery / JWKS | Yes (Artifactory validates SA JWTs) |
| Federated credentials (20/MI limit) | No — avoided in 1.4.0 Option B |
| `azure.workload.identity/use` webhook | No — kubelet projects token for credential provider |
| Identity bindings preview | No |

## Next step for customer workshop

1. Confirm AKS version ≥ 1.34 (projected SA for credential providers).
2. Confirm shared vs dedicated nodepools.
3. Run adversarial matrix on a pilot cluster; treat T6 failure as **stop** for shared-node multi-tenant claims.
