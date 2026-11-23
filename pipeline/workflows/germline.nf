include { SEQTK_SAMPLE         } from '../modules/local/seqtk_sample'
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
    samples  // channel: [ meta, [ fastq_1, fastq_2 ] ]  meta: id, individual, downsample, seed
    truth    // channel: [ id, truth_vcf, truth_tbi, truth_bed ] for rows that have a truth set

    main:
    ch_fasta     = channel.value(file(params.fasta, checkIfExists: true))
    ch_intervals = params.intervals ? channel.value(file(params.intervals, checkIfExists: true)) : channel.value([])
    ch_strata    = params.stratification ? channel.value(file(params.stratification, checkIfExists: true)) : channel.value([])
    callers      = params.caller.tokenize(',')*.trim().unique()
    target_bp    = params.intervals ? file(params.intervals).readLines().findAll { it.trim() && !it.startsWith('#') }.sum { line -> def f = line.tokenize('\t'); (f[2] as long) - (f[1] as long) } : 0

    PREPARE_REFERENCE(ch_fasta, params.fasta_fai, params.fasta_dict, params.bwamem2_index)

    // ---- optional seeded downsampling (coverage titration) -------------------------------
    ch_in = samples.branch { meta, _reads ->
        downsample: (meta.downsample as double) < 1.0
        full: true
    }
    ch_reads = SEQTK_SAMPLE(ch_in.downsample).reads.mix(ch_in.full)

    // ---- QC + trimming --------------------------------------------------------------------
    ch_fastqc_zip = channel.empty()
    if (!params.skip_fastqc) {
        ch_fastqc_zip = FASTQC(ch_reads).zip
    }
    FASTP(ch_reads)

    // ---- alignment + duplicate marking ----------------------------------------------------
    BWAMEM2_MEM(FASTP.out.reads, PREPARE_REFERENCE.out.index)
    GATK4_MARKDUPLICATES(BWAMEM2_MEM.out.bam)

    // ---- variant calling (one branch per caller) ------------------------------------------
    CALL_VARIANTS(
        GATK4_MARKDUPLICATES.out.bam,
        ch_fasta,
        PREPARE_REFERENCE.out.fai,
        PREPARE_REFERENCE.out.dict,
        ch_intervals,
        callers,
        params.filter_expr
    )

    // ---- benchmark against the row's truth set (GIAB), stratified if requested ------------
    ch_happy_in = CALL_VARIANTS.out.vcf
        .map { meta, v, t -> [meta.sample_id, meta, v, t] }
        .combine(truth, by: 0)
        .map { _sid, meta, v, t, tv, tt, tb -> [meta, v, t, tv, tt, tb] }
    HAPPY(ch_happy_in, ch_fasta, PREPARE_REFERENCE.out.fai, ch_strata)

    // ---- machine-readable per-sample x caller summary (consumed by the API + analysis) ----
    ch_qc = FASTP.out.json
        .join(GATK4_MARKDUPLICATES.out.metrics)
        .map { meta, json, md -> [meta.id, json, md] }
    ch_summary_in = CALL_VARIANTS.out.stats
        .join(HAPPY.out.summary, remainder: true)
        .map { meta, stats, happy -> [meta.sample_id, meta, stats, happy ?: []] }
        .combine(ch_qc, by: 0)
        .map { _sid, meta, stats, happy, json, md -> [meta, json, md, stats, happy] }
    SUMMARIZE_RUN(ch_summary_in, target_bp)

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
        .mix(HAPPY.out.summary.map { _meta, f -> f })
        .mix(ch_versions)
        .collect()
    MULTIQC(ch_multiqc_files, file("${projectDir}/assets/multiqc_config.yml", checkIfExists: true))

    emit:
    vcf     = CALL_VARIANTS.out.vcf
    summary = SUMMARIZE_RUN.out.json
    multiqc = MULTIQC.out.report
}
