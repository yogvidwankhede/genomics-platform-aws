#!/usr/bin/env bash
# Build the tiny nf-test dataset (committed under pipeline/tests/data) from the benchmark slice.
# A 100 kb window of chr20 is extracted and renamed `chr20_slice`, with truth coordinates shifted
# accordingly, so tests exercise every step in about a minute.
set -euo pipefail
SRC="${1:-data/benchmark}"
OUT="${2:-pipeline/tests/data}"
START=10000001
END=10100000
OFFSET=$((START - 1))
BAM_URL="https://storage.googleapis.com/brain-genomics-public/research/sequencing/grch38/bam/hiseqx/wgs_pcr_free/30x/HG001.hiseqx.pcr-free.30x.dedup.grch38.bam"
IMG="quay.io/biocontainers/samtools:1.25--h9dcdb79_0"
BIMG="quay.io/biocontainers/bcftools:1.25--h118bc1c_1"
mkdir -p "$OUT"
SRC="$(cd "$SRC" && pwd)"; OUT="$(cd "$OUT" && pwd)"
run() { docker run --rm --platform linux/amd64 -u "$(id -u):$(id -g)" -v "$SRC:/src" -v "$OUT:/out" -w /out "$@"; }

run "$IMG" bash -c "
  set -euo pipefail
  samtools faidx /src/chr20.fa chr20:${START}-${END} | sed 's/^>.*/>chr20_slice/' > ref.fa
  samtools view -b -F 0x900 -o slice.bam '$BAM_URL' chr20:${START}-${END}
  samtools collate -u -O slice.bam tmp | samtools fastq -n -1 test_R1.fastq.gz -2 test_R2.fastq.gz -0 /dev/null -s /dev/null -
  rm -f slice.bam *.bai"

run "$BIMG" bash -c "
  set -euo pipefail
  bcftools view -h /src/truth.vcf.gz | grep -v '^##contig' | sed '1a ##contig=<ID=chr20_slice,length=$((END-OFFSET))>' > truth.vcf
  bcftools view -H -r chr20:${START}-${END} /src/truth.vcf.gz | awk -v o=$OFFSET 'BEGIN{OFS=\"\t\"}{\$1=\"chr20_slice\"; \$2=\$2-o; print}' >> truth.vcf
  bgzip -f truth.vcf && tabix -f -p vcf truth.vcf.gz"

awk -v s=$START -v e=$END -v o=$OFFSET 'BEGIN{OFS="\t"} $3>s-1 && $2<e {if($2<s-1)$2=s-1; if($3>e)$3=e; print "chr20_slice",$2-o,$3-o}' "$SRC/truth.bed" > "$OUT/truth.bed"
printf 'sample,fastq_1,fastq_2\ntest,%s,%s\n' 'test_R1.fastq.gz' 'test_R2.fastq.gz' > "$OUT/samplesheet.csv"
ls -la "$OUT"
