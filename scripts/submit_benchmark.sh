#!/usr/bin/env bash
# Upload the GIAB benchmark slice to the inputs bucket.
#   MODE=direct : submit the head job straight to Batch (M3; no trigger needed)
#   MODE=event  : upload samplesheet.csv last and let EventBridge -> Lambda submit it (M4)
# Usage: scripts/submit_benchmark.sh <env> [run_id]
set -euo pipefail
ENV="${1:?usage: submit_benchmark.sh <env> [run_id]}"
RUN_ID="${2:-hg001-chr20-$(date -u +%Y%m%dt%H%M%S)}"
MODE="${MODE:-event}"
CALLER="${CALLER:-gatk}"
DATA="data/benchmark"
cd "$(dirname "$0")/.."
tfout() { terraform -chdir=infra/platform output -raw "$1"; }
INPUTS="$(terraform -chdir=infra/platform output -json buckets | python3 -c 'import json,sys;print(json.load(sys.stdin)["inputs"])')"
REF="s3://${INPUTS}/reference/hg38-chr20"
PREFIX="s3://${INPUTS}/runs/${RUN_ID}"

echo "reference + truth -> ${REF}"
for f in chr20.fa truth.vcf.gz truth.vcf.gz.tbi truth.bed calling_region.bed; do
  aws s3 cp --only-show-errors "${DATA}/${f}" "${REF}/${f}"
done

echo "reads -> ${PREFIX}"
aws s3 cp --only-show-errors "${DATA}/HG001_R1.fastq.gz" "${PREFIX}/HG001_R1.fastq.gz"
aws s3 cp --only-show-errors "${DATA}/HG001_R2.fastq.gz" "${PREFIX}/HG001_R2.fastq.gz"
cat > /tmp/gp-params.json <<JSON
{
  "fasta": "${REF}/chr20.fa",
  "intervals": "${REF}/calling_region.bed",
  "truth_vcf": "${REF}/truth.vcf.gz",
  "truth_bed": "${REF}/truth.bed",
  "caller": "${CALLER}"
}
JSON
aws s3 cp --only-show-errors /tmp/gp-params.json "${PREFIX}/params.json"
printf 'sample,fastq_1,fastq_2\nHG001,HG001_R1.fastq.gz,HG001_R2.fastq.gz\n' > /tmp/gp-samplesheet.csv

if [[ "$MODE" == "event" ]]; then
  # Uploaded last on purpose: this object is the trigger.
  aws s3 cp --only-show-errors /tmp/gp-samplesheet.csv "${PREFIX}/samplesheet.csv"
  echo "uploaded ${PREFIX}/samplesheet.csv -> EventBridge will submit run ${RUN_ID}"
else
  aws s3 cp --only-show-errors /tmp/gp-samplesheet.csv "${PREFIX}/samplesheet-direct.csv"
  python3 services/trigger/src/gp_trigger/cli.py submit --env "$ENV" --run-id "$RUN_ID" \
    --samplesheet "${PREFIX}/samplesheet-direct.csv" --params-file /tmp/gp-params.json
fi
