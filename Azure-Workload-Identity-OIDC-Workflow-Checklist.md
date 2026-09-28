# Azure Workload Identity OIDC workflow — stakeholder checklist (1.4.0 Option B)

**Updated for JFrog credential provider 1.4.0:** projected Kubernetes service account tokens go **directly** to Artifactory. **No** Entra app registration, **no** federated credentials, **no** `azure.workload.identity/client-id` annotation.

Lab runbook: [tomj-lab/azure-wi-isolation-lab.md](./tomj-lab/azure-wi-isolation-lab.md). Evidence: [tomj-lab/azure-wi-isolation-evidence.md](./tomj-lab/azure-wi-isolation-evidence.md).

Legacy Entra-centric checklist content referred to pre-1.4.0 behavior; see git history before upstream merge.

---

## Object taxonomy (simplified)

```mermaid
erDiagram
    AKS_CLUSTER {
        string oidc_issuer_url
        bool workload_identity_enabled
    }
    K8S_NAMESPACE {
        string name
    }
    K8S_SERVICE_ACCOUNT {
        string annot_JFrogExchange
    }
    KUBELET_CRED_PROVIDER {
        bool tokenProjection_enabled
        string jfrog_oidc_provider_name
    }
    JFROG_OIDC_PROVIDER {
        string issuer_url
    }
    JFROG_IDENTITY_MAPPING {
        string claim_iss
        string claim_sub
        string claim_aud
    }
    ARTIFACTORY_USER {
        string username
    }
    AKS_CLUSTER ||--o{ K8S_NAMESPACE : hosts
    K8S_NAMESPACE ||--o{ K8S_SERVICE_ACCOUNT : contains
    JFROG_OIDC_PROVIDER }o--|| AKS_CLUSTER : issuer
    JFROG_OIDC_PROVIDER ||--o{ JFROG_IDENTITY_MAPPING : maps
    JFROG_IDENTITY_MAPPING }o--|| K8S_SERVICE_ACCOUNT : sub
    JFROG_IDENTITY_MAPPING }o--|| ARTIFACTORY_USER : token_spec
    KUBELET_CRED_PROVIDER }o--|| JFROG_OIDC_PROVIDER : name
    K8S_SERVICE_ACCOUNT ||--o{ KUBELET_CRED_PROVIDER : JFrogExchange
```

---

## Azure / platform administrators

| Area | Requirement |
|------|-------------|
| AKS | `--enable-oidc-issuer` (and historically WI flag; 1.4.0 path does not use Entra WI exchange for pulls) |
| Issuer URL | Record `oidcIssuerProfile.issuerUrl` exactly (trailing slash) for JFrog `iss` |
| Egress | Nodes reach `tomjpd2.jfrog.io` (or customer Artifactory) and cluster OIDC discovery |
| Entra | **Not required** for Option B 1.4.0 |

## JFrog administrators

| Object | Requirement |
|--------|-------------|
| OIDC provider | `issuer_url` / `token_issuer` = AKS OIDC issuer |
| Identity mapping | Match `iss`, `sub` (`system:serviceaccount:<ns>:<sa>`), `aud` (recommended: **`jfrog-artifactory`**, aligned with Helm `azure_app_audience`) |
| Artifactory user | Per team/namespace; repo permissions **without** global `readers` if testing isolation |
| Token TTL | `expires_in` > provider `defaultCacheDuration` |

## Kubernetes administrators

| Object | Requirement |
|--------|-------------|
| Helm chart | `jfrog/jfrog-credential-provider` ≥ 1.4.0, `tokenAttributes.enabled: true` |
| ServiceAccount | `JFrogExchange: "true"` on pulling workloads |
| Pods | `serviceAccountName` set; `imagePullPolicy: Always` for isolation tests on shared nodes |
| Provider | DaemonSet on all pulling nodes; verify merged kubelet credential provider YAML |

---

## Discovery questions (customer workshop)

### Azure / AKS

1. AKS version and support for kubelet credential provider + projected SA tokens?
2. Shared nodepools across tenants or dedicated nodepools?
3. Egress to Artifactory and to AKS OIDC issuer from nodes?

### Kubernetes

1. Admission policy for `imagePullPolicy: Always` on tenant workloads?
2. RBAC model: who can create pods / tokens in each namespace?
3. GitOps approval for Helm DaemonSet on nodes?

### JFrog

1. Accept cluster OIDC issuer as provider (Azure vs Generic type)?
2. Identity mapping: exact `sub` only vs namespace wildcard — what does your Access version support?
3. Default `readers` group membership for new users?

---

## Viability (honest)

- **Promising:** 1.4.0 removes Entra scaling limits; workload identity in JFrog is **`sub`-driven**.
- **Unproven until tested:** Same-node cross-namespace pull denial (T6), node image cache (T7), mapping wildcards.
- **Not a plugin feature:** Node-level cache and cluster RBAC boundaries.
