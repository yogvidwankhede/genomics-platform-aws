#!/usr/bin/env bash
# Prove the AWS CLI that Batch instances mount into task containers runs inside every pinned
# tool image. Reproduces the instance setup from infra/modules/batch user-data (AL2023 host,
# /opt/aws-cli install, bundled libz + wrapper) and runs `aws --version` in each image.
# Needed since the first AWS run: hap.py's image has no libz.so.1.
# Usage: scripts/test_awscli_in_images.sh [workdir under $HOME; Colima only shares /Users]
set -euo pipefail
cd "$(dirname "$0")/.."
W="${1:-$PWD/data/awscli-compat}"
mkdir -p "$W/cli"
[[ -s "$W/awscli.zip" ]] || curl -fsSL -o "$W/awscli.zip" https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip

if [[ ! -x "$W/cli/bin/aws.real" ]]; then
  docker run --rm --platform linux/amd64 -v "$W:/w" -v "$W/cli:/opt/aws-cli" \
    -v "$PWD/scripts/lib/install_awscli_wrapper.sh:/install.sh:ro" amazonlinux:2023 bash /install.sh
fi

fail=0
while IFS= read -r img; do
  if [[ -n "${SKIP:-}" ]] && grep -Eq "$SKIP" <<<"$img"; then echo "SKIP  $img"; continue; fi
  if out=$(docker run --rm --platform linux/amd64 -v "$W/cli:/opt/aws-cli" "$img" /opt/aws-cli/bin/aws --version 2>&1); then
    echo "OK    $img  ($(cut -d' ' -f1 <<<"$out"))"
  else
    echo "FAIL  $img  ($(tail -1 <<<"$out"))"
    fail=1
  fi
done < <(grep -ho "container \"\${params.container_registry ?: ''}[^\"]*\"" pipeline/modules/local/*/main.nf \
  | sed -E "s/.*''\}([^\"]+)\"/\1/" | sort -u)
exit "$fail"
