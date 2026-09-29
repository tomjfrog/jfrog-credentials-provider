# Azure Workload Identity OIDC workflow — stakeholder checklist (1.4.0 Option B)

**Updated for JFrog credential provider 1.4.0:** projected Kubernetes service account tokens go **directly** to Artifactory. **No** Entra app registration, **no** federated credentials, **no** `azure.workload.identity/client-id` annotation.

Lab runbook: [tomj-lab/azure-wi-isolation-lab.md](./tomj-lab/azure-wi-isolation-lab.md). Evidence: [tomj-lab/azure-wi-isolation-evidence.md](./tomj-lab/azure-wi-isolation-evidence.md).

Legacy Entra-centric checklist content referred to pre-1.4.0 behavior; see git history before upstream merge.

---

## Object taxonomy (simplified)

Full inventory with cardinalities: [tomj-lab/azure-wi-object-inventory.md](./tomj-lab/azure-wi-object-inventory.md).

```mermaid
erDiagram
    AKS_CLUSTER {
        string oidc_issuer_url
    }
    AKS_NODE {
        string kubelet_version
    }
    KUBELET_CRED_PROVIDER_CONFIG {
        string matchImages
        string serviceAccountTokenAudience
        string cacheType
        string defaultCacheDuration
    }
    K8S_NAMESPACE {
        string name
    }
    K8S_SERVICE_ACCOUNT {
        string annot_JFrogExchange
    }
    POD {
        string serviceAccountName
        string imagePullPolicy
    }
    PROJECTED_SA_TOKEN {
        string iss
        string sub
        string aud
    }
    JFROG_OIDC_PROVIDER {
        string issuer_url
    }
    JFROG_IDENTITY_MAPPING {
        string claim_iss
        string claim_sub
        string claim_aud
        int priority
    }
    ARTIFACTORY_USER {
        string username
        string groups
    }
    PERMISSION_TARGET {
        string actions
    }
    DOCKER_REPO {
        string key
    }
    AKS_CLUSTER ||--|{ AKS_NODE : runs
    AKS_NODE ||--|| KUBELET_CRED_PROVIDER_CONFIG : "kubelet reads"
    AKS_CLUSTER ||--o{ K8S_NAMESPACE : hosts
    K8S_NAMESPACE ||--o{ K8S_SERVICE_ACCOUNT : contains
    K8S_SERVICE_ACCOUNT ||--o{ POD : "runs as"
    AKS_NODE ||--o{ POD : schedules
    K8S_SERVICE_ACCOUNT ||--o{ PROJECTED_SA_TOKEN : "minted per cache miss"
    AKS_CLUSTER ||--o{ PROJECTED_SA_TOKEN : "signs (iss)"
    JFROG_OIDC_PROVIDER }o--|| AKS_CLUSTER : "trusts issuer"
    KUBELET_CRED_PROVIDER_CONFIG }o--|| JFROG_OIDC_PROVIDER : "provider_name"
    JFROG_OIDC_PROVIDER ||--o{ JFROG_IDENTITY_MAPPING : contains
    JFROG_IDENTITY_MAPPING }o--|| K8S_SERVICE_ACCOUNT : "matches sub"
    JFROG_IDENTITY_MAPPING }o--|| ARTIFACTORY_USER : "token_spec.username"
    ARTIFACTORY_USER }o--o{ PERMISSION_TARGET : "granted by"
    PERMISSION_TARGET }o--|{ DOCKER_REPO : covers
```

## Evaluated pull flow (lab, 2026-09-28)

```mermaid
flowchart TD
    A[Pod scheduled with serviceAccountName] --> P{IfNotPresent and image<br/>already on node?}
    P -->|Yes| Z0[Container starts, no registry<br/>or identity check<br/>T7 cache gap]
    P -->|No / Always| B{Image host matches<br/>matchImages?}
    B -->|No| Z1[Other provider or anonymous pull]
    B -->|Yes| C{SA has JFrogExchange<br/>annotation?}
    C -->|No| Z2[Plugin not invoked<br/>anonymous pull → 401<br/>T4 default SA]
    C -->|Yes| D{Credentials cached for<br/>this SA + registry?}
    D -->|Yes, within 5m| H
    D -->|No| E[Kubelet requests projected SA token<br/>aud = azure_app_audience]
    E --> F[Plugin POSTs token to<br/>Artifactory /access/api/v1/oidc/token]
    F --> G{Identity mapping matches<br/>iss + sub + aud?}
    G -->|No| Z3[Exchange fails, plugin exits<br/>anonymous pull → 401<br/>T5 unmapped, T9 revoked]
    G -->|Yes| H[Pull with mapped user's token]
    H --> I{User has read on<br/>target repo?}
    I -->|No| Z4[403 Forbidden<br/>T2, T3b, T6b]
    I -->|Yes| J[Image pulled → Running<br/>T1, T3a, T6a]
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
| Identity mapping | Match `iss`, `sub` (`system:serviceaccount:<ns>:<sa>`), `aud` (must equal Helm `azure_app_audience`; a dedicated value such as **`jfrog-artifactory`** needs an extra node RBAC rule and a DaemonSet restart — see [AZURE.md Step 4B](./AZURE.md#step-4b-workload-identity--projected-service-account-tokens-no-app-registration)) |
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
