#!/usr/bin/env bash
# Reproducibility experiments on the HG001 benchmark slice (GATK path, local Docker).
#
#   R1 repeat     : identical run twice in fresh launch dirs (no -resume)  -> same VCF?
#   R2 threads    : every task capped at 2 vs 8 CPUs, bwa-mem2 -K fixed    -> same VCF?
#   R3 no -K      : same thread comparison with bwa-mem2's default batching -> does it drift?
#   R4 local/AWS  : compared separately against the AWS Batch run (same FASTQs, 2-vCPU tasks)
# Each run gets its own launch dir and outdir; the comparison is analyze.py compare-vcf.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
OUT="$ROOT/data/runs/repro"
PY="${PYTHON:-$ROOT/.venv/bin/python}"
mkdir -p "$OUT"

run() {  # name, extra args...
  local name="$1"; shift
  local launch="$ROOT/data/launch/repro-$name"
  mkdir -p "$launch"
  if [[ -s "$OUT/$name/variants/HG001.gatk/HG001.gatk.filtered.vcf.gz" ]]; then
    echo "[$name] exists, skipping"; return
  fi
  echo "[$name] running"
  ( cd "$launch" && nextflow run "$ROOT/pipeline" -profile benchmark,docker --skip_fastqc \
      --outdir "$OUT/$name" "$@" > "$OUT/$name.log" 2>&1 )
}

cat > "$OUT/cpus2.config" <<'EOF'
process.resourceLimits = [cpus: 2, memory: 12.GB, time: 4.h]
EOF

run r1_a
run r1_b
run r2_cpu2 -c "$OUT/cpus2.config"
run r3_noK_cpu8 --bwamem2_batch_bases 0
run r3_noK_cpu2 --bwamem2_batch_bases 0 -c "$OUT/cpus2.config"

vcf() { echo "$OUT/$1/variants/HG001.gatk/HG001.gatk.filtered.vcf.gz"; }
RES="$ROOT/research/results/reproducibility.jsonl"
: > "$RES"
cd "$ROOT/research/analysis"
cmp() { PYTHONPATH=src "$PY" -m gp_research.analyze compare-vcf "$(vcf "$2")" "$(vcf "$3")" --label "$1" --out "$RES" >/dev/null; }
cmp "R1 repeat (8 CPU, -K)"            r1_a       r1_b
cmp "R2 threads 8 vs 2 (-K fixed)"     r1_a       r2_cpu2
cmp "R3 threads 8 vs 2 (no -K)"        r3_noK_cpu8 r3_noK_cpu2
cmp "-K vs no -K (8 CPU)"              r1_a       r3_noK_cpu8

# R4: the AWS Batch run of the same FASTQs (downloaded into data/runs/ before teardown)
AWS_VCF="$ROOT/data/runs/aws-hg001-chr20-gatk-3/variants/HG001.gatk/HG001.gatk.filtered.vcf.gz"
if [[ -s "$AWS_VCF" ]]; then
  PYTHONPATH=src "$PY" -m gp_research.analyze compare-vcf "$AWS_VCF" "$(vcf r2_cpu2)" \
    --label "R4 AWS Batch (2 vCPU) vs laptop (2 CPU)" --out "$RES" >/dev/null
  PYTHONPATH=src "$PY" -m gp_research.analyze compare-vcf "$AWS_VCF" "$(vcf r1_a)" \
    --label "R4 AWS Batch (2 vCPU) vs laptop (8 CPU)" --out "$RES" >/dev/null
fi

# Alignment level: checksum of the sorted alignment records (fields 1-11, i.e. without
# read-group/program tags) of each run's duplicate-marked BAM.
echo "alignment record checksums:" | tee "$ROOT/research/results/alignment_checksums.txt"
for run in r1_a r1_b r2_cpu2 r3_noK_cpu8 r3_noK_cpu2; do
  docker run --rm --platform linux/amd64 -v "$OUT:/r" -w /r quay.io/biocontainers/samtools:1.25--h9dcdb79_0 \
    bash -c "printf '%-12s %s records, md5 %s\n' $run \$(samtools view -c $run/alignment/HG001.md.bam) \$(samtools view $run/alignment/HG001.md.bam | cut -f1-11 | sort | md5sum | cut -c1-16)"
done | tee -a "$ROOT/research/results/alignment_checksums.txt"
cat "$RES"
