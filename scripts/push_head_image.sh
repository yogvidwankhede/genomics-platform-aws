#!/usr/bin/env bash
# Build and push the Nextflow head image (pipeline + plugins baked in) to ECR.
# Usage: scripts/push_head_image.sh <head-repository-url> <version>
set -euo pipefail
REPO_URL="${1:?usage: push_head_image.sh <repo-url> <version>}"
VERSION="${2:?version}"
REGION="$(cut -d. -f4 <<<"$REPO_URL")"
cd "$(dirname "$0")/.."
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${REPO_URL%%/*}" >/dev/null
docker build --platform linux/amd64 -f containers/nextflow-head/Dockerfile \
  --build-arg PIPELINE_VERSION="$VERSION" -t "${REPO_URL}:${VERSION}" .
docker push "${REPO_URL}:${VERSION}"
