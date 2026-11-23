#!/usr/bin/env nextflow
/*
 * genomics-platform-aws :: germline short-variant pipeline
 * FASTQ -> FastQC/fastp -> BWA-MEM2 -> MarkDuplicates -> HaplotypeCaller|DeepVariant
 *       -> bcftools norm/filter -> hap.py (optional) -> MultiQC
 */
include { validateParameters; paramsSummaryLog; samplesheetToList } from 'plugin/nf-schema'
include { GERMLINE } from './workflows/germline'

// FASTQ paths in a samplesheet may be relative to the samplesheet itself. This lets an upload
// of `samplesheet.csv` + FASTQs under one S3 prefix trigger a run with no path rewriting.
def resolveFastq(String p, samplesheet) {
    def f = (p ==~ /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/.*/ || p.startsWith('/')) ? file(p) : samplesheet.parent.resolve(p)
    if (!f.exists()) {
        error("FASTQ not found: ${p} (resolved to ${f})")
    }
    return f
}

workflow {
    main:
    validateParameters()
    log.info(paramsSummaryLog(workflow))

    def samplesheet = file(params.input, checkIfExists: true)
    ch_samples = channel
        .fromList(samplesheetToList(params.input, "${projectDir}/assets/schema_input.json"))
        .map { meta, r1, r2 -> [meta, [resolveFastq(r1, samplesheet), resolveFastq(r2, samplesheet)]] }

    GERMLINE(ch_samples)

    onComplete:
    log.info("Pipeline ${workflow.success ? 'completed' : 'FAILED'}: ${workflow.runName} (${workflow.duration})")
}
