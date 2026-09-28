# Handoff: Azure Workload Identity isolation lab (paste into new agent)

## Goal for the new session

Review the current state of the **Azure Workload isolation lab & demo**, identify **older legacy files, statements, and examples**, and **remove or consolidate** them. Assume the proof validated **2026-09-28** is the **desired state**; re-evaluate older material aggressively for applicability.

Do **not** edit upstream product docs in ways that conflict with `jfrog/jfrog-credentials-provider` unless the fork intentionally carries lab-only deltas. **Do** prune fork-local `tomj-lab/` and fork-only checklists that describe obsolete Entra/FIC flows.

---

## What was validated (canonical truth)

### Architecture (JFrog credential provider **1.4.0**, Option B)

- **No** Entra app registration, **no** federated credentials, **no** `azure.workload.identity/client-id` on pulling workloads.
- Kubelet projects SA token → plugin (when SA has `JFrogExchange: "true"`) → Artifactory OIDC token exchange.
- Artifactory OIDC provider trusts **AKS cluster OIDC issuer** (not `login.microsoftonline.com`).
- Isolation: identity mappings on **`iss` + `sub`** (`system:serviceaccount:<namespace>:artifactory-pull`) → Artifactory user → permission target on **one Docker repo per team**.

### Live environment

| Resource | Value |
|----------|--------|
| AKS | `tomj-k8s-cluster`, RG `tomj-jfrog-credentials-provider-lab-rg`, subscription DevOps-Acceleration-team |
| Nodes | amd64, K8s **1.34.4** (control plane **1.35.1**) |
| OIDC issuer | `https://centralus.oic.prod-aks.azure.com/ad8b5a8c-9862-4c41-a341-aa838fc564df/16d7b4c6-03c2-40d9-a137-354bd22d8bb6/` |
| JFrog | `tomjpd2.jfrog.io`, OIDC provider **`aks-wi-lab-oidc`** |
| Helm | release **`jfrog-cp`**, ns **`jfrog`**, chart **1.4.0** |
| Current Helm values (post-T8) | `tomj-lab/examples/azure-projected-sa-values-tomjpd2-jfrog-audience.yaml` (`azure_app_audience: jfrog-artifactory`) |

### Artifactory lab objects

- Repos: `team-a-docker-local`, `team-b-docker-local`
- Users: `aks-team-a-puller`, `aks-team-b-puller` (**must not** be in `readers` group — breaks isolation)
- Permission targets: `aks-wi-lab-team-a`, `aks-wi-lab-team-b`
- Images: `alpine:wi-lab-amd64` (linux/amd64 via buildx), `alpine:wi-lab-t9-amd64` (revoke test)
- OIDC mappings (desired for T8 demo): `mapping-team-a-jfrog-aud`, `mapping-team-b-jfrog-aud` (`aud: jfrog-artifactory`)
- **Legacy mappings to remove in a clean demo:** `mapping-team-a-artifactory-pull`, `mapping-team-b-artifactory-pull` (`aud: api://AzureADTokenExchange`, priority 10)

### Kubernetes lab objects

- Namespaces: `team-a`, `team-b`, `team-c`
- SA: `artifactory-pull` with `JFrogExchange: "true"` only
- Test pods: `tomj-lab/examples/k8s/azure/*.yaml`

### Test matrix results (2026-09-28)

| ID | Result |
|----|--------|
| T1/T3a | Pull OK; pods **Running** after amd64 image fix |
| T2/T3b | **403** cross-repo |
| T4/T5 | **401** default SA / unmapped team-c |
| T6b | **403** same node, `Always` — **not** a cache leak |
| T7 | Node cache gap with `IfNotPresent` |
| T8 | `jfrog-artifactory` audience + Helm rev 2 — **pass** |
| T9 | Mapping delete → exchange **403**, new tag pull **401** (immediate); 5m kubelet cache not fully timed |

Full detail: `tomj-lab/azure-wi-isolation-evidence.md`.

---

## Canonical documentation (keep / maintain)

| File | Role |
|------|------|
| `tomj-lab/azure-wi-isolation-lab.md` | **Primary runbook** |
| `tomj-lab/azure-wi-isolation-evidence.md` | Test evidence |
| `tomj-lab/azure-wi-customer-summary.md` | Customer / deck summary |
| `Azure-Workload-Identity-OIDC-Workflow-Checklist.md` | Stakeholder checklist (1.4.0, no Entra) |
| `azure-env-secrets.sh.example` | Env template (no APP_CLIENT_ID) |
| `tomj-lab/examples/azure-projected-sa-values-tomjpd2.yaml` | Default aud (`api://AzureADTokenExchange`) |
| `tomj-lab/examples/azure-projected-sa-values-tomjpd2-jfrog-audience.yaml` | **Current cluster** aud |
| `tomj-lab/examples/k8s/azure/` | Isolation test manifests |
| `tomj-lab/scripts/*.sh` | Automation |

Upstream product reference: repo-root `AZURE.md` Step **4B** (merged from jfrog/main 1.4.0).

---

## Legacy / prune candidates (aggressive review)

**Strong delete or archive candidates**

- `tomj-lab/azure-lab-exercise.md` — already marked superseded; entire file is **pre-1.4.0 Entra FIC** model (~350 lines).
- `tomj-lab/azure-terminal-outputs-4-29-2026` — raw terminal log from April; historical only.
- `tomj-jfrog-credentials-provider.code-workspace` — local IDE file (gitignore or delete).

**Keep but separate (AWS lab, not Azure WI)**

- `tomj-lab/aws-lab-exercise.md`, `tomj-lab/examples/aws-*`, `tomj-lab/examples/k8s/jfrog-artifactory-*` (EKS/IRSA/Cognito), `aws-jfrog-irsa-*.json`, `scripts/eks-create-existing-vpc.sh`, `examples/eksctl-cluster-existing-vpc.yaml` — clarify in `tomj-lab/README.md` as **AWS-only** so Azure demo is not confused.

**Fork root**

- `AWS-Cognito-OIDC-Workflow-Checklist.md` — AWS-specific; unrelated to Azure WI (keep if AWS lab stays).
- Stashed git change on AWS checklist from pre-merge — resolve stash.

**Git**

- Branch `main` is **ahead of origin** (upstream merge + lab work); lab files largely **uncommitted**.
- Remote `upstream` = `jfrog/jfrog-credentials-provider`.

**tomjpd2 platform cleanup (optional, not git)**

- Delete duplicate/wrong OIDC mapping if present: `mapping-team-a aks-team-a-puller-artifactory-pull-jfrog-aud` (typo from bad loop).
- Remove legacy `api://AzureADTokenExchange` mappings if standardizing on T8 audience only.

---

## Scripts quick reference

```bash
source azure-env-secrets.sh.example   # copy to local secrets file as needed
./tomj-lab/scripts/push-lab-images-amd64.sh
./tomj-lab/scripts/setup-tomjpd2-artifactory.sh
./tomj-lab/scripts/az-login-and-baseline.sh
./tomj-lab/scripts/phase3-oidc-probe.sh
./tomj-lab/scripts/run-isolation-matrix.sh
```

---

## Suggested pruning tasks for the new agent

1. Delete or move to `tomj-lab/archive/` superseded Azure runbook + April terminal dump.
2. Restructure `tomj-lab/README.md`: **Azure WI (canonical)** vs **AWS lab (separate)**.
3. Remove broken cross-links from old docs; ensure nothing points to Entra steps for Option B.
4. Fix `azure-wi-customer-summary.md` / evidence if any remaining contradictions.
5. Add `.gitignore` entries for workspace file and `azure-env-secrets.sh` if used locally.
6. Optionally commit lab artifacts (user must request commit explicitly per user rules).

---

## One-paragraph prompt (copy-paste)

We validated JFrog kubelet credential provider **1.4.0 Option B** on **tomj-k8s-cluster** + **tomjpd2.jfrog.io**: projected SA tokens with **`JFrogExchange` only** (no Entra app), Artifactory OIDC on the **AKS issuer**, per-namespace **`sub` mappings** to **`aks-team-a-puller` / `aks-team-b-puller`**, repos **team-a/b-docker-local**, Helm **`jfrog-cp`** with audience **`jfrog-artifactory`**. Matrix proved cross-repo **403**, same-node **403** with Always, T7 cache caveat, T8/T9 audience and revoke behavior. Canonical docs live under **`tomj-lab/azure-wi-*.md`** and **`tomj-lab/examples/k8s/azure/`**. **Prune** legacy **`azure-lab-exercise.md`** (Entra FIC), April terminal output, and stale examples; keep AWS lab files clearly separated. Evidence: **`tomj-lab/azure-wi-isolation-evidence.md`**. Fork merged upstream **1.4.0**; lab changes mostly uncommitted.
