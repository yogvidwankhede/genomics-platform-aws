include { SAMTOOLS_FAIDX                 } from '../../modules/local/samtools_faidx'
include { GATK4_CREATESEQUENCEDICTIONARY } from '../../modules/local/gatk4_createsequencedictionary'
include { BWAMEM2_INDEX                  } from '../../modules/local/bwamem2_index'

// Build (or reuse) every reference artefact the pipeline needs.
// Pre-built indices can be passed in to skip the expensive bwa-mem2 index step on repeat runs.
workflow PREPARE_REFERENCE {
    take:
    fasta          // path
    fai            // path or null
    dict           // path or null
    bwamem2_index  // path (directory) or null

    main:
    ch_fai   = fai           ? channel.value(file(fai))           : SAMTOOLS_FAIDX(fasta).fai
    ch_dict  = dict          ? channel.value(file(dict))          : GATK4_CREATESEQUENCEDICTIONARY(fasta).dict
    ch_index = bwamem2_index ? channel.value(file(bwamem2_index)) : BWAMEM2_INDEX(fasta).index

    emit:
    fai   = ch_fai
    dict  = ch_dict
    index = ch_index
}
