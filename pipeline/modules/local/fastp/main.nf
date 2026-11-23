process FASTP {
    tag "${meta.id}"
    label 'process_medium'
    container "${params.container_registry ?: ''}community.wave.seqera.io/library/fastp:1.4.0--df415eab5e33cb11"

    input:
    tuple val(meta), path(reads)

    output:
    tuple val(meta), path("${meta.id}_R{1,2}.trim.fastq.gz"), emit: reads
    tuple val(meta), path("${meta.id}.fastp.json"),           emit: json
    tuple val(meta), path("${meta.id}.fastp.html"),           emit: html
    tuple val("${task.process}"), val('fastp'), eval("fastp --version 2>&1 | sed 's/fastp //'"), topic: versions

    script:
    def args = task.ext.args ?: ''
    """
    fastp \\
        --in1 ${reads[0]} --in2 ${reads[1]} \\
        --out1 ${meta.id}_R1.trim.fastq.gz --out2 ${meta.id}_R2.trim.fastq.gz \\
        --json ${meta.id}.fastp.json --html ${meta.id}.fastp.html \\
        --thread ${task.cpus} \\
        --detect_adapter_for_pe \\
        ${args}
    """

    stub:
    """
    echo '' | gzip > ${meta.id}_R1.trim.fastq.gz
    echo '' | gzip > ${meta.id}_R2.trim.fastq.gz
    echo '{}' > ${meta.id}.fastp.json
    touch ${meta.id}.fastp.html
    """
}
