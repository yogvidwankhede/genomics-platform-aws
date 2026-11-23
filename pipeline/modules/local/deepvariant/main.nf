process DEEPVARIANT {
    tag "${meta.id}"
    label 'process_high'
    // DeepVariant publishes x86_64 images only; pinned to an exact release.
    container "${params.container_registry ?: ''}docker.io/google/deepvariant:1.10.0"

    input:
    tuple val(meta), path(bam), path(bai)
    path fasta
    path fai
    path dict
    path intervals

    output:
    tuple val(meta), path("${meta.id}.vcf.gz"), path("${meta.id}.vcf.gz.tbi"), emit: vcf
    tuple val("${task.process}"), val('deepvariant'), eval("/opt/deepvariant/bin/run_deepvariant --version 2>&1 | sed 's/^.*version //'"), topic: versions

    script:
    def args = task.ext.args ?: ''
    def regions = intervals ? "--regions ${intervals}" : ''
    """
    /opt/deepvariant/bin/run_deepvariant \\
        --model_type WGS \\
        --ref ${fasta} \\
        --reads ${bam} \\
        --output_vcf ${meta.id}.vcf.gz \\
        --num_shards ${task.cpus} \\
        --intermediate_results_dir tmp \\
        ${regions} \\
        ${args}
    """

    stub:
    """
    echo '' | gzip > ${meta.id}.vcf.gz
    touch ${meta.id}.vcf.gz.tbi
    """
}
