# Local lab / demo assets (Tomj)

Runbooks, environment templates, sample Helm values, and Kubernetes manifests used to exercise the **JFrog Kubelet Credential Provider** on AWS EKS and Azure AKS. These files are **not** part of the published Helm chart; keep secrets out of git.

| Path | Purpose |
|------|---------|
| [aws-lab-exercise.md](./aws-lab-exercise.md) | EKS + IRSA / Cognito lab runbook |
| [azure-lab-exercise.md](./azure-lab-exercise.md) | AKS + Workload Identity lab runbook |
| [aws-env-secrets.sh](./aws-env-secrets.sh) | Example `export` block for AWS (edit before `source`) |
| [azure-env-secrets.sh](./azure-env-secrets.sh) | Example exports for Azure labs |
| [examples/](./examples/) | Tomjfrog-oriented Helm values, eksctl snippet, sample workloads |

**Shell:** From the **repository root**:

```bash
source tomj-lab/aws-env-secrets.sh
```

Main project docs: [AWS.md](../AWS.md), [AZURE.md](../AZURE.md), [README.md](../README.md).
