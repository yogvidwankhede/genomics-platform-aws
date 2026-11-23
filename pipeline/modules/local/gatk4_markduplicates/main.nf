process GATK4_MARKDUPLICATES {
    tag "${meta.id}"
    label 'process_medium'
    container "${params.container_registry ?: ''}community.wave.seqera.io/library/gatk4-lite_samtools:9b6806e26dd32afe"

    input:
    tuple val(meta), path(bam)

    output:
    tuple val(meta), path("${meta.id}.md.bam"), path("${meta.id}.md.bam.bai"), emit: bam
    tuple val(meta), path("${meta.id}.md.metrics.txt"),                        emit: metrics
    tuple val("${task.process}"), val('gatk4'), eval("gatk --version 2>&1 | grep -m1 'The Genome Analysis Toolkit' | sed 's/.*v//'"), topic: versions

    script:
    def avail_mem = (task.memory.toMega() * 0.8).intValue()
    """
    gatk --java-options "-Xmx${avail_mem}M" MarkDuplicates \\
        --INPUT ${bam} \\
        --OUTPUT ${meta.id}.md.bam \\
        --METRICS_FILE ${meta.id}.md.metrics.txt \\
        --TMP_DIR . \\
        --VALIDATION_STRINGENCY SILENT
    samtools index -@ ${task.cpus} ${meta.id}.md.bam
    """

    stub:
    """
    touch ${meta.id}.md.bam ${meta.id}.md.bam.bai ${meta.id}.md.metrics.txt
    """
}
