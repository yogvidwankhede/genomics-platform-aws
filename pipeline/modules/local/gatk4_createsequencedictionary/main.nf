process GATK4_CREATESEQUENCEDICTIONARY {
    tag "${fasta.baseName}"
    label 'process_single'
    container 'community.wave.seqera.io/library/gatk4-lite:4.7.0.0--79918b8b2632f4b1'

    input:
    path fasta

    output:
    path "*.dict", emit: dict
    tuple val("${task.process}"), val('gatk4'), eval("gatk --version 2>&1 | grep -m1 'The Genome Analysis Toolkit' | sed 's/.*v//'"), topic: versions

    script:
    def avail_mem = (task.memory.toMega() * 0.8).intValue()
    """
    gatk --java-options "-Xmx${avail_mem}M" CreateSequenceDictionary \\
        --REFERENCE ${fasta} \\
        --OUTPUT ${fasta.baseName}.dict
    """

    stub:
    """
    touch ${fasta.baseName}.dict
    """
}
