# Azure Workload Identity OIDC workflow — stakeholder checklist

This document summarizes **Microsoft Entra ID (Azure AD)**, **AKS Workload Identity**, **JFrog Access** configuration, and **Kubernetes** concerns for the JFrog Kubelet Credential Provider when using **projected service account tokens** exchanged via **Azure Workload Identity**, then OIDC token exchange with Artifactory.

It is derived from:

- [`AZURE.md`](./AZURE.md) (Option B: Workload Identity / Step 3B)
- [`tomj-lab/azure-lab-exercise.md`](./tomj-lab/azure-lab-exercise.md)
- [`examples/azure-projected-sa-values.yaml`](./examples/azure-projected-sa-values.yaml)

Scope: **AKS Workload Identity path only** — not **Option A** (nodepool managed identity + Azure IMDS + federated credential whose issuer is `https://login.microsoftonline.com/...`).

---

## Azure and Entra ID objects (cloud / identity administrators)

| Area | What you need | Notes |
| ---- | ------------- | ----- |
| **Microsoft Entra ID — App registration** | **Application (client) ID**, optionally **object ID** for Graph updates | Same app can serve many workloads via **multiple** federated credentials. Follow [`AZURE.md`](./AZURE.md) Step 1 for creation, service principal, **`requestedAccessTokenVersion: 2`**, and (recommended) **Assignment required** + app role + self-assignment. |
| | **Federated identity credentials (Workload Identity)** | **One credential per** pulling `ServiceAccount`: **`issuer`** = AKS **OIDC issuer URL** (from `oidcIssuerProfile`), **`subject`** = `system:serviceaccount:<namespace>:<name>`, **`audiences`** = `["api://AzureADTokenExchange"]`. **Do not** rely on Option A’s federated credential (`issuer` = `login.microsoftonline.com/...`, kubelet/nodepool subject) for this flow—that trusts **IMDS-issued** tokens, not the **Kubernetes service account JWT** sent to JFrog. |
| **Microsoft Entra ID — Enterprise application** | Alignment with **Assignment required** and assignments | If the enterprise app requires assignment, the app’s own service principal must still be able to obtain tokens as documented in [`AZURE.md`](./AZURE.md). |
| **AKS cluster** | **OIDC issuer enabled** and **Workload Identity enabled** | `az aks create` / `az aks update` with `--enable-oidc-issuer` and `--enable-workload-identity`. Retrieve **`oidcIssuerProfile.issuerUrl`** (or ARM `issuerURL`); this string must match the service account JWT **`iss`** exactly (including a **trailing slash** if returned that way). |
| **Networking** | **Egress from nodes** | Nodes must reach **`https://<artifactory-host>`**, Entra token endpoints as used by the exchange, and Azure management/APIs your baseline requires. Private clusters need NAT, proxy, or approved private endpoints per org standards. |

**Not used** on the Helm **projected-token** path (compare Option A): **`azure_nodepool_client_id`**, and **nodepool user-assigned identity** for the **kubelet → IMDS** assertion that Option A exchanges with Entra.

---

## JFrog / platform objects

Often owned separately from the Azure team.

| Object | Purpose |
| ------ | ------- |
| **Access API: OIDC provider** | `POST .../access/api/v1/oidc` with **`issuer_url` / `token_issuer`** = **AKS OIDC issuer** (not `https://login.microsoftonline.com/<tenant>/v2.0`). **`provider_type`**: `Azure` per examples. Workload Identity samples often omit **`azure_app_id`** / audience fields on the provider compared to Option A—follow your Artifactory version’s API contract. |
| **Access API: identity mapping** | Maps JWT claims (**`iss`**, **`aud`**, **`sub`**) to an **Artifactory username** and token settings. For Workload Identity: **`aud`**: `api://AzureADTokenExchange`, **`iss`**: AKS issuer URL, **`sub`**: `system:serviceaccount:<namespace>:<service-account>`. **`expires_in`** should exceed Helm **`defaultCacheDuration`** (see [`AZURE.md`](./AZURE.md) warning for Option A; same idea applies here). |
| **Artifactory user** | Dedicated user(s) per mapping tier; Docker **read** (and other repo permissions) for target repositories. |
| **Admin access token** | To run Access API configuration. |

---

## Kubernetes / cluster objects (platform / Kubernetes administrators)

| Object / concern | What you need |
| ---------------- | ------------- |
| **AKS + supported Kubernetes** | Cluster with **OIDC issuer** and **Workload Identity** wired (mutating webhook projects tokens for labeled pods). |
| **Per-pulling workload: ServiceAccount** | Annotations: **`azure.workload.identity/client-id`** = app registration **client ID**, **`JFrogExchange`** = **`true`** (required for the provider to use the projected token path for Azure). |
| **Per-pulling workload: Pod template** | **`spec.serviceAccountName`** set to that SA (not `default` unless intentionally annotated). Label **`azure.workload.identity/use: "true"`** so the Workload Identity webhook projects the token. Apply **namespace-level** labels if your AKS version / Microsoft guidance requires them. |
| **Entra federated credentials** | One **federated credential** subject per **(namespace, ServiceAccount)** that pulls through this flow; keep subjects in sync when you rename namespaces or service accounts. |
| **Helm release** | e.g. `jfrog/jfrog-credential-provider` with **`tokenAttributes.enabled: true`**, **`azure_app_client_id`**, **`azure_app_audience`** (typically `api://AzureADTokenExchange`), **`jfrog_oidc_provider_name`** aligned with JFrog. **omit** **`azure_nodepool_client_id`** for this path ([`examples/azure-projected-sa-values.yaml`](./examples/azure-projected-sa-values.yaml)). |
| **Chart-installed pieces** | DaemonSet, host integration, kubelet credential provider registration—per chart defaults ([`AZURE.md`](./AZURE.md) Step 4). |
| **Scheduling (if using sample values)** | Example values may use **`credentialsProviderEnabled=true`** node affinity—label nodes or adjust values. |
| **Network policies / firewalls** | Ensure controls do not block kubelet/registry behavior needed for image pulls and provider operation. |

**Interaction note (Azure vs AWS):** On AWS, **`JFrogExchange` + `eks.amazonaws.com/role-arn`** forces the **IRSA / `GetCallerIdentity`** path. On Azure, **`JFrogExchange` + `azure.workload.identity/client-id`** is the **intended** path for Workload Identity—there is no separate “override” to Option A on the same annotations; Option A is selected by **not** using projected tokens (`tokenAttributes.enabled: false` and nodepool client ID) and **not** annotating the workload SA for exchange.

---

## Viability summary (for stakeholders)

- **Azure footprint:** One (or more) app registration(s), **`requestedAccessTokenVersion: 2`**, **federated credentials** whose **issuer** is the **cluster OIDC URL** (not the v1 Entra login issuer used in Option A’s federated cred), AKS with **OIDC + Workload Identity**, and normal egress. **No** dependency on **IMDS** for the pulling identity in this design.
- **Operational coupling:** Adding a new pulling **ServiceAccount** requires a new **federated credential** subject and usually a new **JFrog identity mapping** (or broader claim rules if policy allows). Cluster issuer URL changes (rare) require updating Entra, JFrog `iss`, and mappings.
- **Kubernetes coupling:** Every pod that pulls from Artifactory under `matchImages` must use the **annotated ServiceAccount** and **Workload Identity** labels; **default** ServiceAccount without annotations will not drive the projected-token path. The **credential provider** must run on nodes that handle those pulls, with compatible **kubelet** configuration.

---

## Discovery questions for Azure, Kubernetes, and JFrog teams

Use these in workshops or email to surface blockers early. “Viable” here means: AKS exposes a stable **OIDC issuer**, Entra accepts **federated workload identity** exchanges for your app registration, workloads receive **projected tokens** with the expected **`iss` / `aud` / `sub`**, Artifactory accepts that issuer and claims, and clusters allow the **JFrog credential provider** installation pattern.

### Questions for the Azure / Entra ID team

1. **App registrations** — Can we register (or reuse) an application for **federated workload credentials** from AKS? Any naming, tagging, or approval process for **machine-oriented** apps?
2. **Federated credentials** — Are we allowed to create **many** federated credentials on one app (one per Kubernetes `ServiceAccount` subject)? Any limits or automation (IaC, landing zones) we must use?
3. **Issuer URL** — Will security accept **`issuer`** = **AKS-managed OIDC issuer URL** (per subscription/cluster), and do we have a process to **record** that URL for **dr** Entra/JFrog alignment?
4. **Token version** — Is **`requestedAccessTokenVersion: 2`** and use of **`login.microsoftonline.com`-style validation** downstream (as in [`AZURE.md`](./AZURE.md)) consistent with tenant policy?
5. **Assignment required** — If **Assignment required** is mandatory on enterprise apps, can we follow the **self-assignment** pattern in [`AZURE.md`](./AZURE.md) so the federated exchange still works?
6. **Conditional Access / session policies** — Do any policies block **client credential–style flows** or **federated token exchange** for this app that would break kubelet-time pulls?
7. **Privileged roles** — Who can run **`az ad app federated-credential create`** (or Graph equivalents) in production, and is there a **change ticket** requirement per subject?
8. **Multi-tenant / B2B** — If Artifactory or AKS boundaries span tenants, is **cross-tenant** federated trust explicitly designed (usually out of scope for a single-tenant lab)?
9. **Networking** — For **private** AKS API or locked-down egress, can nodes and control plane components still complete whatever **Entra** endpoints the provider and AKS runtime need, plus **HTTPS to Artifactory**?
10. **Auditing** — What **Entra sign-in / audit** expectations apply to **token issuance** driven by this app and workload identities?

### Questions for the Kubernetes / platform engineering team

1. **Kubelet credential provider** — Does our **AKS version** and **kubelet configuration** support the **kubelet credential provider** mechanism used by **`jfrog/jfrog-credential-provider`**? Who approves **kubelet** config or node image changes?
2. **Workload Identity** — Is **`--enable-workload-identity`** (and **OIDC issuer**) approved for production clusters? Any **version skew** or **addon** requirements (e.g. webhook) we must track during upgrades?
3. **Chart install model** — Can we install the chart via **Helm** (or **GitOps**) in a nominated namespace? Any restriction on **DaemonSets**, **hostPath**, or **privileged** patterns the chart uses?
4. **Mutations and policy** — Do **OPA / Kyverno / PSA** policies allow **`azure.workload.identity/use`** labels, projected volumes, or webhook-injected volumes? Can we enforce that **pulling pods** use the correct **ServiceAccount**?
5. **Identity lifecycle** — What is the process when a **namespace** or **ServiceAccount** is renamed—**Entra** federated subjects and **JFrog** mappings must update together?
6. **Scheduling** — Must the provider run on **all** image-pulling nodes, or only a **labeled** subset? How does that interact with **Spot**, **ARM**, and **taints**?
7. **Default ServiceAccount pitfall** — Can we **lint** or **gate** Deployments that pull from Artifactory so they do **not** rely on **`default`** SA without **`JFrogExchange`**?
8. **Private / mirrored registries** — If we use **mirrors** or **pull-through caches**, do **`matchImages`** patterns still invoke the credential provider as expected?
9. **Observability** — Can operators access **node-level provider logs** (e.g. `/var/log/jfrog-credential-provider.log`) and **kubelet events** for **ImagePullBackOff** triage?
10. **Change windows** — What is the process to roll **DaemonSet** or **kubelet** changes affecting **every** node, and what **rollback** is required?

### Questions for the JFrog / identity team (if separate from Azure/K8s)

1. Can we register an OIDC provider whose **`issuer_url` / `token_issuer`** is the **AKS OIDC issuer** (cluster-specific), with **`provider_type: Azure`** as in the examples?
2. Can we add **identity mappings** that pin **`sub`** to `system:serviceaccount:<namespace>:<service-account>` (and **`iss`** / **`aud`** as above), optionally one **Artifactory user** per workload tier?
3. Can **`token_spec.expires_in`** be set **longer** than the credential provider’s **cache duration** so clients are not handed near-expired registry tokens?
4. If we need **one JFrog OIDC provider per cluster** (different **`iss`**), is that acceptable operationally, or do we prefer **broader** claim rules—what does our **Artifactory version** support?

### Follow-up: what “yes” looks like

- **Azure / Entra:** App registration with **v2 access tokens**, **federated credentials** for each pulling **`ServiceAccount`** (**issuer** = cluster OIDC URL, **subject** = `system:serviceaccount:...`), **Assignment** model resolved if required.
- **AKS:** **OIDC issuer** and **Workload Identity** enabled; issuer URL **verified**; workloads use **annotated** ServiceAccounts and **`azure.workload.identity/use`** on pods (and namespace labels if required).
- **Kubernetes:** **JFrog credential provider** installed with **`tokenAttributes.enabled: true`** and **no** nodepool client ID; pilot **pulls** succeed for a representative workload.
- **JFrog:** **OIDC provider + mappings** live; test user(s) can **read** pilot repositories; **`expires_in`** vs cache documented.
