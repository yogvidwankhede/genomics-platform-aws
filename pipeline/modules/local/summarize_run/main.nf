process SUMMARIZE_RUN {
    tag "${meta.id}"
    label 'process_single'
    container "${params.container_registry ?: ''}community.wave.seqera.io/library/multiqc:1.35--c17fb751507e9dfc"

    input:
    tuple val(meta), path(fastp_json), path(markdup_metrics), path(bcftools_stats), path(happy_summary)
    val target_bp

    output:
    tuple val(meta), path("${meta.id}.run_summary.json"), emit: json

    script:
    def happy_arg = happy_summary ? "--happy ${happy_summary}" : ''
    """
    summarize_run.py \\
        --sample ${meta.sample_id} \\
        --caller ${meta.caller} \\
        --individual ${meta.individual} \\
        --downsample ${meta.downsample} \\
        --seed ${meta.seed} \\
        --target-bp ${target_bp} \\
        --fastp ${fastp_json} \\
        --markdup ${markdup_metrics} \\
        --bcftools-stats ${bcftools_stats} \\
        ${happy_arg} \\
        --pipeline-version ${workflow.manifest.version} \\
        --run-name ${workflow.runName} \\
        --output ${meta.id}.run_summary.json
    """

    stub:
    """
    echo '{"sample": "${meta.sample_id}", "caller": "${meta.caller}"}' > ${meta.id}.run_summary.json
    """
}
