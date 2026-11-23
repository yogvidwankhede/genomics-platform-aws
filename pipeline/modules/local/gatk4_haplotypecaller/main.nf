process GATK4_HAPLOTYPECALLER {
    tag "${meta.id}"
    label 'process_medium'
    container 'community.wave.seqera.io/library/gatk4-lite:4.7.0.0--79918b8b2632f4b1'

    input:
    tuple val(meta), path(bam), path(bai)
    path fasta
    path fai
    path dict
    path intervals

    output:
    tuple val(meta), path("${meta.id}.vcf.gz"), path("${meta.id}.vcf.gz.tbi"), emit: vcf
    tuple val("${task.process}"), val('gatk4'), eval("gatk --version 2>&1 | grep -m1 'The Genome Analysis Toolkit' | sed 's/.*v//'"), topic: versions

    script:
    def args = task.ext.args ?: ''
    def avail_mem = (task.memory.toMega() * 0.85).intValue()
    def interval_arg = intervals ? "--intervals ${intervals}" : ''
    """
    gatk --java-options "-Xmx${avail_mem}M -XX:-UsePerfData" HaplotypeCaller \\
        --input ${bam} \\
        --reference ${fasta} \\
        --output ${meta.id}.vcf.gz \\
        --native-pair-hmm-threads ${task.cpus} \\
        --tmp-dir . \\
        ${interval_arg} \\
        ${args}
    """

    stub:
    """
    echo '' | gzip > ${meta.id}.vcf.gz
    touch ${meta.id}.vcf.gz.tbi
    """
}
