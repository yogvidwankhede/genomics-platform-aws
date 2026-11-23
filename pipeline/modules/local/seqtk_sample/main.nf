process SEQTK_SAMPLE {
    tag "${meta.id}"
    label 'process_single'
    container "${params.container_registry ?: ''}community.wave.seqera.io/library/seqtk:1.4--3fa479d3961a5b8d"

    input:
    tuple val(meta), path(reads)

    output:
    tuple val(meta), path("${meta.id}.ds_R{1,2}.fastq.gz"), emit: reads
    tuple val("${task.process}"), val('seqtk'), eval("seqtk 2>&1 | grep -m1 Version | sed 's/Version: //'"), topic: versions

    script:
    // Same seed for both mates keeps pairs intact; fraction + seed make every replicate reproducible.
    """
    seqtk sample -s ${meta.seed} ${reads[0]} ${meta.downsample} | gzip -c > ${meta.id}.ds_R1.fastq.gz
    seqtk sample -s ${meta.seed} ${reads[1]} ${meta.downsample} | gzip -c > ${meta.id}.ds_R2.fastq.gz
    """

    stub:
    """
    echo '' | gzip > ${meta.id}.ds_R1.fastq.gz
    echo '' | gzip > ${meta.id}.ds_R2.fastq.gz
    """
}
