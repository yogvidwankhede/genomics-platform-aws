process BWAMEM2_MEM {
    tag "${meta.id}"
    label 'process_high'
    container "${params.container_registry ?: ''}community.wave.seqera.io/library/bwa-mem2_htslib_samtools:db98f81f55b64113"

    input:
    tuple val(meta), path(reads)
    path index

    output:
    tuple val(meta), path("${meta.id}.sorted.bam"), emit: bam
    tuple val("${task.process}"), val('bwa-mem2'), eval("bwa-mem2 version 2>/dev/null | tail -1"), topic: versions
    tuple val("${task.process}"), val('samtools'), eval("samtools version | head -1 | sed 's/samtools //'"), topic: versions

    script:
    def read_group = "@RG\\tID:${meta.id}\\tSM:${meta.individual}\\tLB:${meta.individual}\\tPL:ILLUMINA"
    def sort_threads = Math.max(1, task.cpus.intdiv(2))
    def batch = params.bwamem2_batch_bases ? "-K ${params.bwamem2_batch_bases}" : ''
    // -K fixes the bases per batch so alignments do not depend on the thread count (bwa's default
    // batch size scales with -t). Set --bwamem2_batch_bases 0 to reproduce the thread-dependent default.
    """
    INDEX=\$(find -L ${index}/ -name "*.amb" | sed 's/\\.amb\$//')
    bwa-mem2 mem ${batch} -t ${task.cpus} -R '${read_group}' \$INDEX ${reads} \\
        | samtools sort -@ ${sort_threads} -m 768M -o ${meta.id}.sorted.bam -
    """

    stub:
    """
    touch ${meta.id}.sorted.bam
    """
}
