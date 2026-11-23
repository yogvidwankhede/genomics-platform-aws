# Nextflow head ("driver") job for AWS Batch.
# Pipeline code and plugins are baked in: the job runs in private subnets with no internet, so
# nothing may be downloaded at runtime (NXF_OFFLINE=true). Image tag = pipeline version.
FROM nextflow/nextflow:26.10.7

ARG NF_SCHEMA_VERSION=2.8.0
ARG NF_AMAZON_VERSION=3.12.1
ARG PIPELINE_VERSION=0.0.0-dev

LABEL org.opencontainers.image.title="gp-nextflow-head" \
      org.opencontainers.image.source="https://github.com/yogvidwankhede/genomics-platform-aws" \
      org.opencontainers.image.version="${PIPELINE_VERSION}" \
      org.opencontainers.image.licenses="MIT"

ENV NXF_HOME=/opt/nextflow-home \
    NXF_ANSI_LOG=false \
    PIPELINE_DIR=/opt/pipeline

RUN nextflow plugin install nf-schema@${NF_SCHEMA_VERSION},nf-amazon@${NF_AMAZON_VERSION} \
 && mkdir -p /work \
 && chmod -R a+rX ${NXF_HOME} \
 && chmod a+rwx /work

COPY pipeline/ ${PIPELINE_DIR}/
COPY containers/nextflow-head/gp-run.sh /usr/local/bin/gp-run
RUN chmod 0755 /usr/local/bin/gp-run \
 && rm -rf ${PIPELINE_DIR}/tests ${PIPELINE_DIR}/work ${PIPELINE_DIR}/.nextflow* ${PIPELINE_DIR}/.nf-test*

# NXF_HOME must stay writable for Nextflow's own bookkeeping; run as an unprivileged UID.
RUN chown -R 1000:1000 ${NXF_HOME} /work
# From here on nothing may be fetched from the internet.
ENV NXF_OFFLINE=true
USER 1000:1000
WORKDIR /work

ENTRYPOINT ["/usr/local/bin/gp-run"]
CMD ["--help"]
