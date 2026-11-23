#!/usr/bin/env bash
# Read-only account preflight before `make apply`: surfaces the limits that broke the first
# deployment (docs/postmortem-first-aws-deployment.md). Changes nothing.
# Usage: scripts/preflight.sh [env]
set -uo pipefail
ENV="${1:-dev}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
cd "$(dirname "$0")/.."
TFVARS="infra/envs/${ENV}.tfvars"
warn=0
say()  { printf '  %-44s %s\n' "$1" "$2"; }
flag() { say "$1" "WARN: $2"; warn=1; }

echo "Preflight for env=${ENV} region=${REGION}"
acct=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || { echo "  no AWS credentials"; exit 2; }
arn=$(aws sts get-caller-identity --query Arn --output text)
say "account" "$acct"
[[ "$arn" == *":root" ]] && flag "caller" "root user; prefer an admin role for day-to-day use" || say "caller" "$arn"

lambda=$(aws lambda get-account-settings --region "$REGION" --query 'AccountLimit.ConcurrentExecutions' --output text)
reserve=$(sed -nE 's/^reserve_lambda_concurrency *= *(true|false).*/\1/p' "$TFVARS"); reserve=${reserve:-true}
if [[ "$lambda" -le 10 && "$reserve" == "true" ]]; then
  flag "Lambda concurrency limit" "$lambda; set reserve_lambda_concurrency = false in $TFVARS"
else
  say "Lambda concurrency limit" "$lambda (reserve=$reserve)"
fi

spot=$(aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code L-34B43A08 --query 'Quota.Value' --output text 2>/dev/null || echo "?")
maxv=$(sed -nE 's/^max_vcpus *= *([0-9]+).*/\1/p' "$TFVARS")
if [[ "$spot" != "?" && -n "$maxv" ]] && (( ${spot%.*} < maxv )); then
  flag "Spot vCPU quota" "${spot%.*} < max_vcpus ${maxv}; jobs beyond the quota stay RUNNABLE"
else
  say "Spot vCPU quota" "${spot%.*} (max_vcpus=${maxv:-default})"
fi

types=$(sed -nE 's/^batch_instance_types *= *\[(.*)\].*/\1/p' "$TFVARS" | tr -d '" ' | tr ',' ' ')
eligible=$(aws ec2 describe-instance-types --region "$REGION" --filters Name=free-tier-eligible,Values=true --query 'InstanceTypes[].InstanceType' --output text | tr '\t\n' '  ' | xargs)
plan_hint=$(aws ec2 describe-instance-types --region "$REGION" --instance-types m6i.large --query 'InstanceTypes[0].FreeTierEligible' --output text 2>/dev/null)
say "Free Tier eligible types" "${eligible}"
if [[ -n "$types" ]]; then
  for t in $types; do
    grep -qw "$t" <<<"$eligible" || say "  configured type $t" "not Free Tier eligible (fine unless the account is on the Free plan)"
  done
fi
[[ "$plan_hint" == "False" ]] && say "note" "on a Free plan account only the eligible types above can launch"

if aws s3api head-bucket --bucket "gp-tfstate-${acct}-${REGION}" >/dev/null 2>&1; then
  say "state bucket" "gp-tfstate-${acct}-${REGION} exists"
else
  flag "state bucket" "missing; run make bootstrap-plan / bootstrap-apply first"
fi

echo
(( warn )) && { echo "Preflight finished with warnings (see above)."; exit 1; } || echo "Preflight OK."
