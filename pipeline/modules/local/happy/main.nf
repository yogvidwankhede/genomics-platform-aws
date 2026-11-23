process HAPPY {
    tag "${meta.id}"
    label 'process_medium'
    container "${params.container_registry ?: ''}quay.io/biocontainers/hap.py:0.3.15--py27hcb73b3d_0"

    input:
    tuple val(meta), path(query_vcf), path(query_tbi), path(truth_vcf), path(truth_tbi), path(truth_bed)
    path fasta
    path fai
    path strata   // directory with strata.tsv + BEDs (GIAB stratifications) or [] to skip

    output:
    tuple val(meta), path("${meta.id}.happy.summary.csv"),  emit: summary
    tuple val(meta), path("${meta.id}.happy.extended.csv"), emit: extended
    tuple val(meta), path("${meta.id}.happy.vcf.gz"),       emit: vcf
    tuple val(meta), path("${meta.id}.happy.*"),            emit: all
    tuple val("${task.process}"), val('hap.py'), val('0.3.15'), topic: versions

    script:
    // xcmp engine; --pass-only scores FILTER=PASS calls. The annotated VCF (BD/BK per record)
    // feeds the bootstrap and paired-test statistics in research/analysis.
    def strat = strata ? "--stratification ${strata}/strata.tsv" : ''
    """
    hap.py \\
        ${truth_vcf} \\
        ${query_vcf} \\
        --false-positives ${truth_bed} \\
        --reference ${fasta} \\
        --pass-only \\
        ${strat} \\
        --threads ${task.cpus} \\
        -o ${meta.id}.happy
    """

    stub:
    """
    printf 'Type,Filter,TRUTH.TOTAL,TRUTH.TP,TRUTH.FN,QUERY.TOTAL,QUERY.FP,QUERY.UNK,FP.gt,FP.al,METRIC.Recall,METRIC.Precision,METRIC.Frac_NA,METRIC.F1_Score,TRUTH.TOTAL.TiTv_ratio,QUERY.TOTAL.TiTv_ratio,TRUTH.TOTAL.het_hom_ratio,QUERY.TOTAL.het_hom_ratio\\n' > ${meta.id}.happy.summary.csv
    touch ${meta.id}.happy.extended.csv
    echo '' | gzip > ${meta.id}.happy.vcf.gz
    """
}
