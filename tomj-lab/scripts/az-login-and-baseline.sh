#!/usr/bin/env bash
# Phase 1: requires interactive az login (refresh token expired after 90d inactivity).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/azure-env-secrets.sh.example" 2>/dev/null || true

echo "==> Azure login (interactive)"
az login --tenant "${TENANT_ID}" --scope "https://management.core.windows.net//.default"

echo "==> Cluster baseline"
az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" \
  --query "{k8s:kubernetesVersion,oidc:oidcIssuerProfile,wi:securityProfile.workloadIdentity,location:location}" -o json

az aks get-credentials -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --overwrite-existing
kubectl get nodes -o wide

ISSUER=$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query "oidcIssuerProfile.issuerUrl" -o tsv)
echo "SERVICE_ACCOUNT_ISSUER=$ISSUER"
curl -sS "${ISSUER}.well-known/openid-configuration" | head -c 400
echo

NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
echo "==> Kubelet credential provider config on $NODE (via debug pod)"
kubectl debug "node/${NODE}" -it --image=busybox:1.36 -- chroot /host cat /var/lib/kubelet/credential-provider-config.yaml 2>/dev/null || \
  echo "Run manually: kubectl debug node/${NODE} -it --image=busybox -- chroot /host cat /var/lib/kubelet/credential-provider-config.yaml"
