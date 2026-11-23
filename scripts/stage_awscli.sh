#!/usr/bin/env bash
# Stage the AWS CLI v2 bundle that Batch instances install at boot (they have no internet).
# The signature is verified against the AWS CLI public key before upload when gpg is available.
# Usage: scripts/stage_awscli.sh <artifacts-bucket>
set -euo pipefail
BUCKET="${1:?usage: stage_awscli.sh <artifacts-bucket>}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
curl -fsSL "$URL" -o "$TMP/awscli.zip"
curl -fsSL "$URL.sig" -o "$TMP/awscli.zip.sig"
if command -v gpg >/dev/null; then
  # Public key published at https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
  if [[ -f "$(dirname "$0")/aws-cli-public-key.asc" ]]; then
    gpg --batch --import "$(dirname "$0")/aws-cli-public-key.asc" 2>/dev/null
    gpg --batch --verify "$TMP/awscli.zip.sig" "$TMP/awscli.zip"
  else
    echo "WARN: scripts/aws-cli-public-key.asc missing; skipping signature check" >&2
  fi
fi
# SSE-S3, not KMS: instances read this object unsigned through the S3 gateway endpoint.
aws s3 cp --sse AES256 "$TMP/awscli.zip" "s3://${BUCKET}/bootstrap/awscli-exe-linux-x86_64.zip"
echo "staged s3://${BUCKET}/bootstrap/awscli-exe-linux-x86_64.zip"
