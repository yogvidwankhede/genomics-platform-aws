include { GATK4_HAPLOTYPECALLER } from '../../modules/local/gatk4_haplotypecaller'
include { DEEPVARIANT           } from '../../modules/local/deepvariant'
include { BCFTOOLS_NORM         } from '../../modules/local/bcftools_norm'
include { BCFTOOLS_FILTER       } from '../../modules/local/bcftools_filter'
include { BCFTOOLS_STATS        } from '../../modules/local/bcftools_stats'

// Call -> normalise -> soft-filter -> stats. The caller is a runtime choice (see ADR-0004).
workflow CALL_VARIANTS {
    take:
    bam        // channel: [ meta, bam, bai ]
    fasta      // value: path
    fai        // value: path
    dict       // value: path
    intervals  // value: path or []
    caller     // val: 'gatk' | 'deepvariant'
    filter_expr

    main:
    if (caller == 'deepvariant') {
        ch_raw = DEEPVARIANT(bam, fasta, fai, dict, intervals).vcf
    }
    else {
        ch_raw = GATK4_HAPLOTYPECALLER(bam, fasta, fai, dict, intervals).vcf
    }
    BCFTOOLS_NORM(ch_raw, fasta)
    BCFTOOLS_FILTER(BCFTOOLS_NORM.out.vcf, filter_expr)
    BCFTOOLS_STATS(BCFTOOLS_FILTER.out.vcf)

    emit:
    vcf   = BCFTOOLS_FILTER.out.vcf
    stats = BCFTOOLS_STATS.out.stats
}
