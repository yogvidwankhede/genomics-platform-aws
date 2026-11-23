include { GATK4_HAPLOTYPECALLER } from '../../modules/local/gatk4_haplotypecaller'
include { DEEPVARIANT           } from '../../modules/local/deepvariant'
include { BCFTOOLS_NORM         } from '../../modules/local/bcftools_norm'
include { BCFTOOLS_FILTER       } from '../../modules/local/bcftools_filter'
include { BCFTOOLS_STATS        } from '../../modules/local/bcftools_stats'

// Fan each alignment out to every requested caller, then normalise -> soft-filter -> stats.
// Output meta gains `caller`, and `id` becomes "<sample>.<caller>" (sample_id keeps the row id).
workflow CALL_VARIANTS {
    take:
    bam        // channel: [ meta, bam, bai ]
    fasta      // value: path
    fai        // value: path
    dict       // value: path
    intervals  // value: path or []
    callers    // list: ['gatk'] / ['gatk', 'deepvariant']
    filter_expr  // val: bcftools exclude expression, or null for the per-caller default

    main:
    ch_bam = bam
        .combine(channel.fromList(callers))
        .map { meta, b, i, caller -> [meta + [caller: caller, sample_id: meta.id, id: "${meta.id}.${caller}"], b, i] }
        .branch { meta, _b, _i ->
            deepvariant: meta.caller == 'deepvariant'
            gatk: true
        }

    ch_raw = GATK4_HAPLOTYPECALLER(ch_bam.gatk, fasta, fai, dict, intervals).vcf
        .mix(DEEPVARIANT(ch_bam.deepvariant, fasta, fai, dict, intervals).vcf)

    // QUAL scales differ between callers: a GATK-tuned QUAL<30 removed 602 of 3,536 DeepVariant
    // PASS calls on the HG001 chr20 benchmark, so the default expression is per caller.
    BCFTOOLS_NORM(ch_raw, fasta)
    ch_to_filter = BCFTOOLS_NORM.out.vcf.map { meta, v, t ->
        def expr = filter_expr ?: (meta.caller == 'deepvariant' ? 'FORMAT/DP<5' : 'QUAL<30 || FORMAT/DP<5')
        [meta, v, t, expr]
    }
    BCFTOOLS_FILTER(ch_to_filter)
    BCFTOOLS_STATS(BCFTOOLS_FILTER.out.vcf)

    emit:
    vcf   = BCFTOOLS_FILTER.out.vcf
    stats = BCFTOOLS_STATS.out.stats
}
