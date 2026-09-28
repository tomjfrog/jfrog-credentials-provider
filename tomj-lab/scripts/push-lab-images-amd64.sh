#!/usr/bin/env bash
# Push linux/amd64 lab images (required for AKS amd64 node pools; avoid arm64 exec format error on Mac builders).
set -euo pipefail
TAG="${1:-wi-lab-amd64}"
docker buildx build --platform linux/amd64 -f - \
  -t "tomjpd2.jfrog.io/team-a-docker-local/alpine:${TAG}" \
  -t "tomjpd2.jfrog.io/team-b-docker-local/alpine:${TAG}" \
  --push <<EOF
FROM alpine:3.20
EOF
docker buildx imagetools inspect "tomjpd2.jfrog.io/team-a-docker-local/alpine:${TAG}" | head -12
