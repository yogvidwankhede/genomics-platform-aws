#!/usr/bin/env bash
# Fetch everything the M7 research benchmark needs, restricted to one genomic window.
#   samples : HG001 (NA12878) + the GIAB Ashkenazi trio HG002 (son), HG003 (father), HG004 (mother)
#             30x HiSeq X PCR-free GRCh38 BAMs (Google Brain Genomics public bucket), sliced and
#             converted back to paired FASTQ so the pipeline aligns from scratch
#   truth   : GIAB NISTv4.2.1 benchmark VCF + confident BED per sample
#   strata  : GIAB genome-stratifications v3.6 (GRCh38) for the difficult-region analysis
# Usage: research/scripts/fetch_research_data.sh [outdir] [region]
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-data/research}"
REGION="${2:-chr20:10000000-12000000}"
SAMTOOLS_IMG="quay.io/biocontainers/samtools:1.25--h9dcdb79_0"
BCFTOOLS_IMG="quay.io/biocontainers/bcftools:1.25--h118bc1c_1"
BAMS="https://storage.googleapis.com/brain-genomics-public/research/sequencing/grch38/bam/hiseqx/wgs_pcr_free/30x"
GIAB="https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/release"
STRAT="${GIAB}/genome-stratifications/v3.6/GRCh38@all"

mkdir -p "$OUT"/{reads,truth,strata}
OUT="$(cd "$OUT" && pwd)"
CHR="${REGION%%:*}"; RANGE="${REGION#*:}"; START="${RANGE%-*}"; END="${RANGE#*-}"
run() { docker run --rm --platform linux/amd64 -u "$(id -u):$(id -g)" -v "$OUT:/data" -w /data "$@"; }

truth_vcf() {
  case "$1" in
    HG001) echo "${GIAB}/NA12878_HG001/NISTv4.2.1/GRCh38/HG001_GRCh38_1_22_v4.2.1_benchmark.vcf.gz" ;;
    HG002) echo "${GIAB}/AshkenazimTrio/HG002_NA24385_son/NISTv4.2.1/GRCh38/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz" ;;
    HG003) echo "${GIAB}/AshkenazimTrio/HG003_NA24149_father/NISTv4.2.1/GRCh38/HG003_GRCh38_1_22_v4.2.1_benchmark.vcf.gz" ;;
    HG004) echo "${GIAB}/AshkenazimTrio/HG004_NA24143_mother/NISTv4.2.1/GRCh38/HG004_GRCh38_1_22_v4.2.1_benchmark.vcf.gz" ;;
  esac
}
truth_bed() {
  case "$1" in
    HG001) echo "${GIAB}/NA12878_HG001/NISTv4.2.1/GRCh38/HG001_GRCh38_1_22_v4.2.1_benchmark.bed" ;;
    *)     local v; v="$(truth_vcf "$1")"; echo "${v%.vcf.gz}_noinconsistent.bed" ;;
  esac
}
clip_bed() { awk -v c="$CHR" -v s="$START" -v e="$END" 'BEGIN{OFS="\t"} $1==c && $3>s && $2<e {if($2<s)$2=s; if($3>e)$3=e; print $1,$2,$3}'; }

echo "[reference]"
[[ -s "$OUT/${CHR}.fa" ]] || curl -fsSL "https://hgdownload.soe.ucsc.edu/goldenPath/hg38/chromosomes/${CHR}.fa.gz" | gunzip -c > "$OUT/${CHR}.fa"
printf '%s\t%s\t%s\n' "$CHR" "$START" "$END" > "$OUT/calling_region.bed"

for S in HG001 HG002 HG003 HG004; do
  echo "[$S] reads"
  if [[ ! -s "$OUT/reads/${S}_R1.fastq.gz" ]]; then
    run "$SAMTOOLS_IMG" bash -c "
      set -euo pipefail
      samtools view -b -F 0x900 -o reads/${S}.slice.bam '${BAMS}/${S}.hiseqx.pcr-free.30x.dedup.grch38.bam' '$REGION'
      samtools collate -u -O reads/${S}.slice.bam reads/${S}.tmp \
        | samtools fastq -n -1 reads/${S}_R1.fastq.gz -2 reads/${S}_R2.fastq.gz -0 /dev/null -s /dev/null -
      mv reads/${S}.slice.bam reads/${S}.slice.bam.done"
  fi
  echo "[$S] truth"
  if [[ ! -s "$OUT/truth/${S}.vcf.gz" ]]; then
    run "$BCFTOOLS_IMG" bash -c "
      set -euo pipefail
      bcftools view -r '$REGION' -Oz -o truth/${S}.vcf.gz '$(truth_vcf "$S")'
      bcftools index -t truth/${S}.vcf.gz"
  fi
  [[ -s "$OUT/truth/${S}.bed" ]] || curl -fsSL "$(truth_bed "$S")" | clip_bed > "$OUT/truth/${S}.bed"
done

echo "[truth] normalise (left-align + trim + split, like the pipeline's calls)"
mkdir -p "$OUT/truth_norm"
run "$BCFTOOLS_IMG" bash -c "
  set -euo pipefail
  for s in HG001 HG002 HG003 HG004; do
    [[ -s truth_norm/\$s.vcf.gz ]] && continue
    bcftools norm -f ${CHR}.fa -m -any --check-ref w -Oz -o truth_norm/\$s.vcf.gz truth/\$s.vcf.gz
    bcftools index -t truth_norm/\$s.vcf.gz
  done"

echo "[strata] GIAB v3.6"
# name <TAB> path relative to the stratification directory (hap.py --stratification format)
STRATA="alldifficult:Union/GRCh38_alldifficultregions.bed.gz
notinalldifficult:Union/GRCh38_notinalldifficultregions.bed.gz
tandemrepeats_homopolymers:LowComplexity/GRCh38_AllTandemRepeatsandHomopolymers_slop5.bed.gz
homopolymers_ge7:LowComplexity/GRCh38_AllHomopolymers_ge7bp_imperfectge11bp_slop5.bed.gz
lowmappability:Mappability/GRCh38_lowmappabilityall.bed.gz
segdups:SegmentalDuplications/GRCh38_segdups.bed.gz
gc_extreme:GCcontent/GRCh38_gclt25orgt65_slop50.bed.gz
coding:Functional/GRCh38_refseq_cds.bed.gz"
: > "$OUT/strata/strata.tsv"
while IFS=: read -r name path; do
  [[ -s "$OUT/strata/${name}.bed" ]] || curl -fsSL "${STRAT}/${path}" | gunzip -c | clip_bed > "$OUT/strata/${name}.bed"
  printf '%s\t%s\n' "$name" "${name}.bed" >> "$OUT/strata/strata.tsv"
done <<< "$STRATA"

( cd "$OUT" && shasum -a 256 "${CHR}.fa" reads/*.fastq.gz truth/* strata/*.bed > SHA256SUMS )
echo "done: $OUT"
