# Local lab / demo assets (Tomj fork)

Runbooks, environment templates, sample Helm values, and Kubernetes manifests for the **JFrog Kubelet Credential Provider**. These files are **not** part of the published Helm chart; keep secrets out of git.

Product docs: [AZURE.md](../AZURE.md), [AWS.md](../AWS.md), [README.md](../README.md).

---

## Azure Workload Identity isolation (canonical, 1.4.0 Option B)

Validated **2026-09-28** on `tomj-k8s-cluster` + `tomjpd2.jfrog.io`: projected service account tokens with **`JFrogExchange` only** (no Entra app), Artifactory OIDC on the **AKS cluster issuer**, identity mappings on **`sub`** → per-team Artifactory users and Docker repos. Cross-repo **403**, same-node **403** with `imagePullPolicy: Always`, audience **`jfrog-artifactory`**, mapping revoke on new tags. Caveats: global **`readers`** group, node cache (`IfNotPresent`), 5m credential cache not fully timed for revoke.

| Path | Purpose |
|------|---------|
| [azure-wi-isolation-lab.md](./azure-wi-isolation-lab.md) | **Primary runbook** |
| [azure-wi-isolation-evidence.md](./azure-wi-isolation-evidence.md) | Test matrix + evidence |
| [azure-wi-customer-summary.md](./azure-wi-customer-summary.md) | Customer / deck summary |
| [Azure-Workload-Identity-OIDC-Workflow-Checklist.md](../Azure-Workload-Identity-OIDC-Workflow-Checklist.md) | Stakeholder checklist |
| [azure-env-secrets.sh.example](../azure-env-secrets.sh.example) | Env template (copy to `azure-env-secrets.sh` at repo root) |
| [examples/azure-projected-sa-values-tomjpd2-jfrog-audience.yaml](./examples/azure-projected-sa-values-tomjpd2-jfrog-audience.yaml) | **Current** Helm values (`jfrog-artifactory` aud) |
| [examples/azure-projected-sa-values-tomjpd2.yaml](./examples/azure-projected-sa-values-tomjpd2.yaml) | Fallback (`api://AzureADTokenExchange`; legacy mappings) |
| [examples/k8s/azure/](./examples/k8s/azure/) | Isolation test manifests |

**Scripts (run order):**

1. [scripts/az-login-and-baseline.sh](./scripts/az-login-and-baseline.sh)
2. [scripts/setup-tomjpd2-artifactory.sh](./scripts/setup-tomjpd2-artifactory.sh)
3. [scripts/phase3-oidc-probe.sh](./scripts/phase3-oidc-probe.sh)
4. Helm install (see runbook) — or [scripts/run-isolation-matrix.sh](./scripts/run-isolation-matrix.sh) for matrix automation
5. [scripts/push-lab-images-amd64.sh](./scripts/push-lab-images-amd64.sh) (amd64 images from Apple Silicon)

```bash
# From repository root
cp azure-env-secrets.sh.example azure-env-secrets.sh   # edit locally; gitignored
source azure-env-secrets.sh
```

---

## AWS lab (separate, AWS-only)

EKS **IRSA** and **Cognito OIDC** paths — not the Azure WI demo.

| Path | Purpose |
|------|---------|
| [aws-lab-exercise.md](./aws-lab-exercise.md) | EKS lab runbook |
| [AWS-Cognito-OIDC-Workflow-Checklist.md](../AWS-Cognito-OIDC-Workflow-Checklist.md) | Cognito stakeholder checklist |
| [aws-env-secrets.sh.example](../aws-env-secrets.sh.example) | Env template (copy to `aws-env-secrets.sh` at repo root) |
| [examples/aws-projected-sa-values-tomjfrog.yaml](./examples/aws-projected-sa-values-tomjfrog.yaml) | IRSA Helm values |
| [examples/aws-cognito-oidc-values.yaml](./examples/aws-cognito-oidc-values.yaml) | Cognito Helm values |
| [examples/eksctl-cluster-existing-vpc.yaml](./examples/eksctl-cluster-existing-vpc.yaml) | eksctl snippet |
| [examples/k8s/jfrog-artifactory-*.yaml](./examples/k8s/) | EKS sample workloads ([k8s/README.md](./examples/k8s/README.md)) |
| [aws-jfrog-irsa-trust.json](./aws-jfrog-irsa-trust.json), [aws-jfrog-irsa-permissions.json](./aws-jfrog-irsa-permissions.json) | IRSA policy snippets |
| [scripts/eks-create-existing-vpc.sh](./scripts/eks-create-existing-vpc.sh) | EKS bootstrap helper |

```bash
cp aws-env-secrets.sh.example aws-env-secrets.sh
source aws-env-secrets.sh
```

---

## Archive

Obsolete material (pre-1.4.0 Entra FIC Azure runbook, April terminal log, agent handoff): [archive/](./archive/).
