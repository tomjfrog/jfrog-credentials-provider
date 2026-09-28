#!/usr/bin/env bash
# Phase 2 idempotent setup on tomjpd2 (repos, users, permissions, images).
# Lab users must NOT stay in the default 'readers' group (Anything permission).
set -euo pipefail

jf rt ping --server-id=tomjpd2

for repo in team-a-docker-local team-b-docker-local; do
  jf rt curl --server-id=tomjpd2 -XGET "/api/repositories/${repo}" >/dev/null 2>&1 || \
    echo "Create repo ${repo} via UI/MCP if missing"
done

for u in aks-team-a-puller aks-team-b-puller; do
  jf rt curl --server-id=tomjpd2 -XPUT "/api/security/users/${u}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${u}\",\"email\":\"lab@example.com\",\"password\":\"LabPullOnly2026!\",\"groups\":[],\"admin\":false}"
done

jf rt curl --server-id=tomjpd2 -XPUT /api/security/permissions/aks-wi-lab-team-a \
  -H "Content-Type: application/json" \
  -d '{"name":"aks-wi-lab-team-a","includesPattern":"**","repositories":["team-a-docker-local"],"principals":{"users":{"aks-team-a-puller":["r"]}}}'

jf rt curl --server-id=tomjpd2 -XPUT /api/security/permissions/aks-wi-lab-team-b \
  -H "Content-Type: application/json" \
  -d '{"name":"aks-wi-lab-team-b","includesPattern":"**","repositories":["team-b-docker-local"],"principals":{"users":{"aks-team-b-puller":["r"]}}}'

docker pull --platform linux/amd64 alpine:3.20
docker tag alpine:3.20 tomjpd2.jfrog.io/team-a-docker-local/alpine:wi-lab-amd64
docker tag alpine:3.20 tomjpd2.jfrog.io/team-b-docker-local/alpine:wi-lab-amd64
jf docker login tomjpd2.jfrog.io --server-id=tomjpd2
docker push tomjpd2.jfrog.io/team-a-docker-local/alpine:wi-lab-amd64
docker push tomjpd2.jfrog.io/team-b-docker-local/alpine:wi-lab-amd64

echo "Verify: team-a user pulls own repo OK, cross repo 403 (see runbook)."
