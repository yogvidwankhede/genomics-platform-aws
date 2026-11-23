process BCFTOOLS_NORM {
    tag "${meta.id}"
    label 'process_low'
    container 'community.wave.seqera.io/library/bcftools_htslib:1.25--130aa7603bf3bf5c'

    input:
    tuple val(meta), path(vcf), path(tbi)
    path fasta

    output:
    tuple val(meta), path("${meta.id}.norm.vcf.gz"), path("${meta.id}.norm.vcf.gz.tbi"), emit: vcf
    tuple val("${task.process}"), val('bcftools'), eval("bcftools --version | head -1 | sed 's/bcftools //'"), topic: versions

    script:
    // Left-align + split multi-allelics so the caller output is comparable with the truth set.
    """
    bcftools norm \\
        --fasta-ref ${fasta} \\
        --multiallelics -any \\
        --check-ref w \\
        --threads ${task.cpus} \\
        -Oz -o ${meta.id}.norm.vcf.gz \\
        ${vcf}
    bcftools index --tbi ${meta.id}.norm.vcf.gz
    """

    stub:
    """
    echo '' | gzip > ${meta.id}.norm.vcf.gz
    touch ${meta.id}.norm.vcf.gz.tbi
    """
}
