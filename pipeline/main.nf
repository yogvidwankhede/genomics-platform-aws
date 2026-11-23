#!/usr/bin/env nextflow
/*
 * genomics-platform-aws :: germline short-variant pipeline
 * FASTQ -> FastQC/fastp -> BWA-MEM2 -> MarkDuplicates -> HaplotypeCaller|DeepVariant
 *       -> bcftools norm/filter -> hap.py (optional) -> MultiQC
 */
include { validateParameters; paramsSummaryLog; samplesheetToList } from 'plugin/nf-schema'
include { GERMLINE } from './workflows/germline'

// Paths in a samplesheet may be relative to the samplesheet itself. This lets an upload of
// `samplesheet.csv` + FASTQs under one S3 prefix trigger a run with no path rewriting.
def resolvePath(String p, samplesheet) {
    def f = (p ==~ /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/.*/ || p.startsWith('/')) ? file(p) : samplesheet.parent.resolve(p)
    if (!f.exists()) {
        error("File not found: ${p} (resolved to ${f})")
    }
    return f
}

workflow {
    main:
    validateParameters()
    log.info(paramsSummaryLog(workflow))

    def samplesheet = file(params.input, checkIfExists: true)
    ch_rows = channel
        .fromList(samplesheetToList(params.input, "${projectDir}/assets/schema_input.json"))
        .map { meta, r1, r2, tvcf, tbed ->
            def m = meta + [individual: meta.individual ?: meta.id]
            // a row-level truth set wins over the run-level --truth_vcf/--truth_bed
            def vcf = tvcf ? resolvePath(tvcf, samplesheet) : (params.truth_vcf ? file(params.truth_vcf, checkIfExists: true) : null)
            def bed = tbed ? resolvePath(tbed, samplesheet) : (params.truth_bed ? file(params.truth_bed, checkIfExists: true) : null)
            [m, [resolvePath(r1, samplesheet), resolvePath(r2, samplesheet)], vcf, bed]
        }
    ch_samples = ch_rows.map { meta, reads, _v, _b -> [meta, reads] }
    ch_truth = ch_rows
        .filter { _m, _r, v, b -> v && b }
        // resolveSibling keeps the scheme: "${v}.tbi" turns s3://bucket/key into /bucket/key
        .map { meta, _r, v, b -> [meta.id, v, v.resolveSibling("${v.name}.tbi"), b] }

    GERMLINE(ch_samples, ch_truth)

    onComplete:
    log.info("Pipeline ${workflow.success ? 'completed' : 'FAILED'}: ${workflow.runName} (${workflow.duration})")
}
