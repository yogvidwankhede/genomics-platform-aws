process FASTQC {
    tag "${meta.id}"
    label 'process_low'
    container "${params.container_registry ?: ''}community.wave.seqera.io/library/fastqc:0.13.0--b342db7b694c9af4"

    input:
    tuple val(meta), path(reads)

    output:
    tuple val(meta), path("*.html"), emit: html
    tuple val(meta), path("*.zip"),  emit: zip
    tuple val("${task.process}"), val('fastqc'), eval("fastqc --version | sed 's/FastQC v//'"), topic: versions

    script:
    def args = task.ext.args ?: ''
    """
    fastqc ${args} --threads ${task.cpus} --memory 1024 ${reads}
    """

    stub:
    """
    touch ${meta.id}_R1_fastqc.html ${meta.id}_R1_fastqc.zip
    """
}
