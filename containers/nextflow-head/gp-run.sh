#!/usr/bin/env bash
# Entry point of the Nextflow head job. Arguments are passed straight to `nextflow run`.
#
#   RUN_LOG_URI   s3:// prefix where .nextflow.log is copied on exit (success or failure),
#                 so failed runs can be triaged without CloudWatch spelunking.
#   NXF_CLOUDCACHE_PATH (set by the submitter) keeps the resume cache in S3, so a Spot-reclaimed
#                 head job that Batch retries continues with -resume instead of starting over.
set -uo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "usage: gp-run [nextflow run options]   (pipeline: ${PIPELINE_DIR})"
  nextflow -version
  exit 0
fi

echo "{\"event\":\"head_start\",\"run_log_uri\":\"${RUN_LOG_URI:-}\",\"args\":\"$*\"}"
nextflow run "${PIPELINE_DIR}" "$@"
status=$?

if [[ -n "${RUN_LOG_URI:-}" && -f .nextflow.log ]]; then
  nextflow fs cp .nextflow.log "${RUN_LOG_URI%/}/nextflow.log" \
    || echo '{"event":"log_upload_failed"}'
fi
echo "{\"event\":\"head_exit\",\"status\":${status}}"
exit "${status}"
