process MULTIQC {
    label 'process_single'
    container 'community.wave.seqera.io/library/multiqc:1.35--c17fb751507e9dfc'

    input:
    path multiqc_files, stageAs: '?/*'
    path multiqc_config

    output:
    path "multiqc_report.html", emit: report
    path "multiqc_report_data", emit: data
    // Deliberately NOT on the `versions` topic: MultiQC consumes that topic, so emitting to it would deadlock.
    path "multiqc_version.txt", emit: version

    script:
    """
    multiqc --force --config ${multiqc_config} --filename multiqc_report.html .
    multiqc --version | sed 's/.*version //' > multiqc_version.txt
    """

    stub:
    """
    mkdir multiqc_report_data
    touch multiqc_report.html multiqc_version.txt
    """
}
