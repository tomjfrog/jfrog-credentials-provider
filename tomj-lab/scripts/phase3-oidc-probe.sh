#!/usr/bin/env bash
# Phase 3: direct OIDC exchange (no kubelet). Requires kubectl + cluster access.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/azure-env-secrets.sh.example"

AUD="${AZURE_APP_AUDIENCE:-jfrog-artifactory}"
ADMIN_TOKEN=$(jf atc --server-id=tomjpd2 --grant-admin --expiry=3600 | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

kubectl apply -f "${ROOT}/tomj-lab/examples/k8s/azure/00-namespaces.yaml"
kubectl apply -f "${ROOT}/tomj-lab/examples/k8s/azure/01-serviceaccounts.yaml"

probe_exchange() {
  local ns=$1 label=$2
  local sa_token
  sa_token=$(kubectl create token artifactory-pull -n "$ns" --audience "$AUD" --duration=600s)
  echo "=== $label claims (jwt.io) ==="
  python3 - <<PY
import base64, json, sys
p = """$sa_token""".split(".")[1]
p += "=" * (-len(p) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(p)), indent=2))
PY
  curl -sS -w "\nHTTP:%{http_code}\n" -X POST "https://${ARTIFACTORY_URL}/access/api/v1/oidc/token" \
    -H "Content-Type: application/json" \
    -d "$(python3 - <<PY
import json
print(json.dumps({
  "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
  "provider_name": "$OIDC_PROVIDER_NAME",
  "subject_token_type": "urn:ietf:params:oauth:token-type:id_token",
  "subject_token": """$sa_token""",
  "provider_type": "Generic OpenID Connect",
  "audience": "*@*",
}))
PY
)"
}

probe_exchange team-a "team-a positive"
probe_exchange team-b "team-b positive"
probe_exchange team-c "team-c unmapped (expect fail)"

echo "Optional: create mapping with wildcard sub or kubernetes.io.namespace claim and re-run."
