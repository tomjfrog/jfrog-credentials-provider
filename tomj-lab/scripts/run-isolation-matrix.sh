#!/usr/bin/env bash
# Phase 4–6: install provider + run T0–T10 (append results to evidence file).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EVIDENCE="${ROOT}/tomj-lab/azure-wi-isolation-evidence.md"
VALUES="${ROOT}/tomj-lab/examples/azure-projected-sa-values-tomjpd2-jfrog-audience.yaml"
K8S="${ROOT}/tomj-lab/examples/k8s/azure"

log() { echo "[$(date -Iseconds)] $*" | tee -a "$EVIDENCE"; }

helm repo add jfrog https://charts.jfrog.io 2>/dev/null || true
helm repo update
helm upgrade --install jfrog-cp jfrog/jfrog-credential-provider \
  --namespace jfrog --create-namespace -f "$VALUES"

kubectl apply -f "${K8S}/00-namespaces.yaml"
kubectl apply -f "${K8S}/01-serviceaccounts.yaml"

run_test() {
  local id=$1 file=$2 expect=$3
  local ns name
  ns=$(grep -E '^\s+namespace:' "$file" | head -1 | awk '{print $2}')
  name=$(grep -E '^\s+name:' "$file" | head -1 | awk '{print $2}')
  kubectl delete pod -n "$ns" "$name" --ignore-not-found 2>/dev/null
  kubectl apply -f "$file"
  sleep 15
  local phase reason
  phase=$(kubectl get pod -n "$ns" "$name" -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)
  reason=$(kubectl describe pod -n "$ns" "$name" 2>/dev/null | grep -E 'Failed|Err|403|denied' | tail -3 || true)
  log "| $id | $expect | phase=$phase | $reason |"
}

log ""
log "## Matrix run $(date -Iseconds)"
run_test T1 "${K8S}/test-pod-team-a-own.yaml" PASS
run_test T2 "${K8S}/test-pod-team-a-cross.yaml" FAIL
run_test T3a "${K8S}/test-pod-team-b-own.yaml" PASS
run_test T3b "${K8S}/test-pod-team-b-cross.yaml" FAIL
run_test T4 "${K8S}/test-pod-default-sa.yaml" FAIL
run_test T5 "${K8S}/test-pod-team-c-unmapped.yaml" FAIL

log "T6: set nodeName on team-a-own and team-b-cross to same node, imagePullPolicy Always, then re-run manually."
