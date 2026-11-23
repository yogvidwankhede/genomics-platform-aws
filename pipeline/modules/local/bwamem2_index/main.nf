process BWAMEM2_INDEX {
    tag "${fasta.baseName}"
    label 'process_high_memory'
    container 'community.wave.seqera.io/library/bwa-mem2_htslib_samtools:db98f81f55b64113'

    input:
    path fasta

    output:
    path "bwamem2", emit: index
    tuple val("${task.process}"), val('bwa-mem2'), eval("bwa-mem2 version 2>/dev/null | tail -1"), topic: versions

    script:
    """
    mkdir bwamem2
    bwa-mem2 index -p bwamem2/${fasta.baseName} ${fasta}
    """

    stub:
    """
    mkdir bwamem2
    touch bwamem2/${fasta.baseName}.{0123,amb,ann,bwt.2bit.64,pac}
    """
}
