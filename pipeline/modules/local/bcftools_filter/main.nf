process BCFTOOLS_FILTER {
    tag "${meta.id}"
    label 'process_low'
    container "${params.container_registry ?: ''}community.wave.seqera.io/library/bcftools_htslib:1.25--130aa7603bf3bf5c"

    input:
    tuple val(meta), path(vcf), path(tbi)
    val exclude_expr

    output:
    tuple val(meta), path("${meta.id}.filtered.vcf.gz"), path("${meta.id}.filtered.vcf.gz.tbi"), emit: vcf
    tuple val("${task.process}"), val('bcftools'), eval("bcftools --version | head -1 | sed 's/bcftools //'"), topic: versions

    script:
    // Soft filter: failing records keep their row but get FILTER=LowQual.
    """
    bcftools filter \\
        --soft-filter LowQual \\
        --mode + \\
        --exclude '${exclude_expr}' \\
        -Oz -o ${meta.id}.filtered.vcf.gz \\
        ${vcf}
    bcftools index --tbi ${meta.id}.filtered.vcf.gz
    """

    stub:
    """
    echo '' | gzip > ${meta.id}.filtered.vcf.gz
    touch ${meta.id}.filtered.vcf.gz.tbi
    """
}
