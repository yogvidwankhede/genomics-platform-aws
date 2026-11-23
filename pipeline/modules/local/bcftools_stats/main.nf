process BCFTOOLS_STATS {
    tag "${meta.id}"
    label 'process_single'
    container 'community.wave.seqera.io/library/bcftools_htslib:1.25--130aa7603bf3bf5c'

    input:
    tuple val(meta), path(vcf), path(tbi)

    output:
    tuple val(meta), path("${meta.id}.bcftools_stats.txt"), emit: stats
    tuple val("${task.process}"), val('bcftools'), eval("bcftools --version | head -1 | sed 's/bcftools //'"), topic: versions

    script:
    // Stats on PASS records only, i.e. what a downstream consumer would use.
    """
    bcftools stats --apply-filters PASS ${vcf} > ${meta.id}.bcftools_stats.txt
    """

    stub:
    """
    touch ${meta.id}.bcftools_stats.txt
    """
}
