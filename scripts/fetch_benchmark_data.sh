#!/usr/bin/env bash
# Fetch the GIAB HG001 (NA12878) chr20 benchmark slice used by the `benchmark` profile.
#
# Everything comes from public sources; nothing here is PHI.
#   reads : Google Brain Genomics public HG001 HiSeqX PCR-free 30x GRCh38 BAM (region slice,
#           converted back to paired FASTQ so the pipeline exercises alignment end-to-end)
#   ref   : UCSC hg38 chr20
#   truth : GIAB NISTv4.2.1 HG001 GRCh38 benchmark VCF + confident-region BED
#
# Usage: scripts/fetch_benchmark_data.sh [outdir] [region]
set -euo pipefail

OUT="${1:-data/benchmark}"
REGION="${2:-chr20:10000000-12000000}"
SAMTOOLS_IMG="quay.io/biocontainers/samtools:1.25--h9dcdb79_0"
BCFTOOLS_IMG="quay.io/biocontainers/bcftools:1.25--h118bc1c_1"

BAM_URL="https://storage.googleapis.com/brain-genomics-public/research/sequencing/grch38/bam/hiseqx/wgs_pcr_free/30x/HG001.hiseqx.pcr-free.30x.dedup.grch38.bam"
REF_URL="https://hgdownload.soe.ucsc.edu/goldenPath/hg38/chromosomes/chr20.fa.gz"
GIAB="https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/release/NA12878_HG001/NISTv4.2.1/GRCh38"
TRUTH_VCF="${GIAB}/HG001_GRCh38_1_22_v4.2.1_benchmark.vcf.gz"
TRUTH_BED="${GIAB}/HG001_GRCh38_1_22_v4.2.1_benchmark.bed"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
CHR="${REGION%%:*}"
RANGE="${REGION#*:}"
START="${RANGE%-*}"
END="${RANGE#*-}"
run() { docker run --rm --platform linux/amd64 -u "$(id -u):$(id -g)" -v "$OUT:/data" -w /data "$@"; }

echo "[1/4] reference ($CHR)"
if [[ ! -s "$OUT/${CHR}.fa" ]]; then
  curl -fsSL "$REF_URL" | gunzip -c > "$OUT/${CHR}.fa"
fi

echo "[2/4] reads ($REGION) from public HG001 30x BAM"
if [[ ! -s "$OUT/HG001_R1.fastq.gz" ]]; then
  run "$SAMTOOLS_IMG" bash -c "
    set -euo pipefail
    samtools view -b -F 0x900 -o slice.bam '$BAM_URL' '$REGION'
    samtools collate -u -O slice.bam tmpcollate \
      | samtools fastq -n -1 HG001_R1.fastq.gz -2 HG001_R2.fastq.gz -0 /dev/null -s /dev/null -
    rm -f slice.bam *.bai"
fi

echo "[3/4] GIAB v4.2.1 truth VCF + BED restricted to $REGION"
if [[ ! -s "$OUT/truth.vcf.gz" ]]; then
  run "$BCFTOOLS_IMG" bash -c "
    set -euo pipefail
    bcftools view -r '$REGION' -Oz -o truth.vcf.gz '$TRUTH_VCF'
    bcftools index -t truth.vcf.gz
    rm -f *.tbi.tmp HG001_GRCh38_1_22_v4.2.1_benchmark.vcf.gz.tbi"
fi
if [[ ! -s "$OUT/truth.bed" ]]; then
  curl -fsSL "$TRUTH_BED" \
    | awk -v c="$CHR" -v s="$START" -v e="$END" 'BEGIN{OFS="\t"} $1==c && $3>s && $2<e {if($2<s)$2=s; if($3>e)$3=e; print}' \
    > "$OUT/truth.bed"
fi

echo "[4/4] samplesheet + checksums"
cat > "$OUT/samplesheet.csv" <<EOF
sample,fastq_1,fastq_2
HG001,${OUT}/HG001_R1.fastq.gz,${OUT}/HG001_R2.fastq.gz
EOF
( cd "$OUT" && shasum -a 256 ${CHR}.fa HG001_R1.fastq.gz HG001_R2.fastq.gz truth.vcf.gz truth.bed > SHA256SUMS )
ls -la "$OUT"
