include { FASTQC               } from '../modules/local/fastqc'
include { FASTP                } from '../modules/local/fastp'
include { BWAMEM2_MEM          } from '../modules/local/bwamem2_mem'
include { GATK4_MARKDUPLICATES } from '../modules/local/gatk4_markduplicates'
include { HAPPY                } from '../modules/local/happy'
include { SUMMARIZE_RUN        } from '../modules/local/summarize_run'
include { MULTIQC              } from '../modules/local/multiqc'
include { PREPARE_REFERENCE    } from '../subworkflows/local/prepare_reference'
include { CALL_VARIANTS        } from '../subworkflows/local/call_variants'

workflow GERMLINE {
    take:
    samples  // channel: [ meta, [ fastq_1, fastq_2 ] ]

    main:
    ch_fasta     = channel.value(file(params.fasta, checkIfExists: true))
    ch_intervals = params.intervals ? channel.value(file(params.intervals, checkIfExists: true)) : channel.value([])

    PREPARE_REFERENCE(ch_fasta, params.fasta_fai, params.fasta_dict, params.bwamem2_index)

    // ---- QC + trimming --------------------------------------------------------------------
    ch_fastqc_zip = channel.empty()
    if (!params.skip_fastqc) {
        ch_fastqc_zip = FASTQC(samples).zip
    }
    FASTP(samples)

    // ---- alignment + duplicate marking ----------------------------------------------------
    BWAMEM2_MEM(FASTP.out.reads, PREPARE_REFERENCE.out.index)
    GATK4_MARKDUPLICATES(BWAMEM2_MEM.out.bam)

    // ---- variant calling ------------------------------------------------------------------
    CALL_VARIANTS(
        GATK4_MARKDUPLICATES.out.bam,
        ch_fasta,
        PREPARE_REFERENCE.out.fai,
        PREPARE_REFERENCE.out.dict,
        ch_intervals,
        params.caller,
        params.filter_expr
    )

    // ---- benchmark against a truth set (GIAB) ---------------------------------------------
    ch_happy = channel.empty()
    if (params.truth_vcf && params.truth_bed) {
        ch_truth_vcf = channel.value(file(params.truth_vcf, checkIfExists: true))
        ch_truth_bed = channel.value(file(params.truth_bed, checkIfExists: true))
        ch_happy = HAPPY(CALL_VARIANTS.out.vcf, ch_truth_vcf, ch_truth_bed, ch_fasta, PREPARE_REFERENCE.out.fai).summary
    }

    // ---- machine-readable per-sample summary (consumed by the platform API) ---------------
    ch_summary_in = FASTP.out.json
        .join(GATK4_MARKDUPLICATES.out.metrics)
        .join(CALL_VARIANTS.out.stats)
        .join(ch_happy, remainder: true)
        .map { meta, fastp, md, stats, happy -> [meta, fastp, md, stats, happy ?: []] }
    SUMMARIZE_RUN(ch_summary_in)

    // ---- versions + MultiQC ---------------------------------------------------------------
    ch_versions = channel.topic('versions')
        .unique()
        .map { process, tool, version -> [process.tokenize(':').last(), "  ${tool}: \"${version.toString().trim()}\""] }
        .groupTuple()
        .map { process, lines -> "\"${process}\":\n" + lines.sort().join('\n') }
        .collectFile(name: 'software_mqc_versions.yml', newLine: true, sort: true)

    ch_multiqc_files = channel.empty()
        .mix(ch_fastqc_zip.map { _meta, f -> f })
        .mix(FASTP.out.json.map { _meta, f -> f })
        .mix(GATK4_MARKDUPLICATES.out.metrics.map { _meta, f -> f })
        .mix(CALL_VARIANTS.out.stats.map { _meta, f -> f })
        .mix(ch_happy.map { _meta, f -> f })
        .mix(ch_versions)
        .collect()
    MULTIQC(ch_multiqc_files, file("${projectDir}/assets/multiqc_config.yml", checkIfExists: true))

    emit:
    vcf     = CALL_VARIANTS.out.vcf
    summary = SUMMARIZE_RUN.out.json
    multiqc = MULTIQC.out.report
}
