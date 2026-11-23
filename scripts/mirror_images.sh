#!/usr/bin/env bash
# Mirror every pinned pipeline container into ECR under mirror/<original-path>:<original-tag>.
# Batch instances live in private subnets without internet, so they can only pull from ECR.
# Usage: scripts/mirror_images.sh <account>.dkr.ecr.<region>.amazonaws.com
set -euo pipefail
REGISTRY="${1:?usage: mirror_images.sh <ecr-registry-host>}"
REGION="$(cut -d. -f4 <<<"$REGISTRY")"
cd "$(dirname "$0")/.."

mapfile -t IMAGES < <(grep -ho "container \"\${params.container_registry ?: ''}[^\"]*\"" pipeline/modules/local/*/main.nf \
  | sed -E "s/.*''\}([^\"]+)\"/\1/" | sort -u)
echo "Mirroring ${#IMAGES[@]} images to ${REGISTRY}/mirror/"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null

for src in "${IMAGES[@]}"; do
  repo="mirror/${src%:*}"
  tag="${src##*:}"
  if aws ecr describe-images --region "$REGION" --repository-name "$repo" --image-ids imageTag="$tag" >/dev/null 2>&1; then
    echo "  = ${repo}:${tag} (already present; tags are immutable)"
    continue
  fi
  echo "  + ${repo}:${tag}"
  docker pull --quiet --platform linux/amd64 "$src" >/dev/null
  docker tag "$src" "${REGISTRY}/${repo}:${tag}"
  docker push --quiet "${REGISTRY}/${repo}:${tag}" >/dev/null
done
echo "Done. Scan findings: aws ecr describe-image-scan-findings --repository-name <repo> --image-id imageTag=<tag>"
