process SAMTOOLS_FAIDX {
    tag "${fasta.baseName}"
    label 'process_single'
    container "${params.container_registry ?: ''}community.wave.seqera.io/library/htslib_samtools:1.25--704fb80d75745bd4"

    input:
    path fasta

    output:
    path "${fasta}.fai", emit: fai
    tuple val("${task.process}"), val('samtools'), eval("samtools version | head -1 | sed 's/samtools //'"), topic: versions

    script:
    """
    samtools faidx ${fasta}
    """

    stub:
    """
    touch ${fasta}.fai
    """
}
