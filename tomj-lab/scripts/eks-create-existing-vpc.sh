#!/usr/bin/env bash
# Create EKS in the VPC defined in tomj-lab/examples/eksctl-cluster-existing-vpc.yaml, then
# associate the OIDC provider (required for IRSA / JFrog kubelet credential provider).
#
# Prerequisites: aws CLI + eksctl + valid SSO (`aws sso login`) or credentials.
# Usage (from repo root):
#   source tomj-lab/aws-env-secrets.sh
#   ./scripts/eks-create-existing-vpc.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -f "${ROOT}/tomj-lab/aws-env-secrets.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/tomj-lab/aws-env-secrets.sh"
fi

: "${AWS_REGION:?Set AWS_REGION (e.g. source tomj-lab/aws-env-secrets.sh)}"
: "${EKS_CLUSTER_NAME:?Set EKS_CLUSTER_NAME}"

export AWS_PROFILE="${AWS_PROFILE:-}"
CONFIG="${ROOT}/tomj-lab/examples/eksctl-cluster-existing-vpc.yaml"

echo "==> Creating cluster from ${CONFIG}"
eksctl create cluster -f "${CONFIG}"

echo "==> Associating IAM OIDC provider (IRSA)"
eksctl utils associate-iam-oidc-provider \
  --cluster "${EKS_CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --approve

echo "==> kubeconfig"
aws eks update-kubeconfig --name "${EKS_CLUSTER_NAME}" --region "${AWS_REGION}"

echo "==> Done. kubectl get nodes:"
kubectl get nodes

echo ""
echo "Next: follow tomj-lab/aws-lab-exercise.md §3+ for IAM role, JFrog binding, and Helm install."
