import pytest

from gp_trigger.command import (
    InvalidRunRequest,
    PlatformConfig,
    build_head_job,
    merge_params,
    validate_run_id,
)

CONFIG = PlatformConfig(
    job_queue="gp-dev-spot",
    job_definition="gp-dev-nextflow-head",
    work_bucket="gp-dev-work-123",
    results_bucket="gp-dev-results-123",
    log_group="/gp/dev/batch",
    params={"container_registry": "123.dkr.ecr.us-east-1.amazonaws.com/mirror/", "aws_region": "us-east-1"},
)


def test_build_head_job_shape():
    req = build_head_job("hg001-run-1", "s3://in/runs/hg001-run-1/samplesheet.csv", CONFIG, {"caller": "deepvariant"})
    assert req["jobName"] == "gp-run-hg001-run-1"
    assert req["jobQueue"] == "gp-dev-spot"
    cmd = req["containerOverrides"]["command"]
    assert cmd[:5] == ["-profile", "awsbatch", "-work-dir", "s3://gp-dev-work-123/runs/hg001-run-1/work", "-resume"]
    pairs = dict(zip(cmd[5::2], cmd[6::2]))
    assert pairs["--input"] == "s3://in/runs/hg001-run-1/samplesheet.csv"
    assert pairs["--outdir"] == "s3://gp-dev-results-123/runs/hg001-run-1"
    assert pairs["--caller"] == "deepvariant"
    assert pairs["--container_registry"].endswith("/mirror/")
    env = {e["name"]: e["value"] for e in req["containerOverrides"]["environment"]}
    assert env["NXF_CLOUDCACHE_PATH"] == "s3://gp-dev-work-123/runs/hg001-run-1/cache"
    assert env["RUN_LOG_URI"] == "s3://gp-dev-results-123/runs/hg001-run-1/logs"


def test_command_is_deterministic():
    a = build_head_job("abc", "s3://b/runs/abc/samplesheet.csv", CONFIG, {"z_opt": "1", "a_opt": "2"})
    b = build_head_job("abc", "s3://b/runs/abc/samplesheet.csv", CONFIG, {"a_opt": "2", "z_opt": "1"})
    assert a == b


@pytest.mark.parametrize("bad", ["", "ab", "UPPER", "has_underscore", "-leading", "x" * 64, "a b c"])
def test_rejects_bad_run_ids(bad):
    with pytest.raises(InvalidRunRequest):
        validate_run_id(bad)


@pytest.mark.parametrize("key", ["outdir", "input", "aws_queue", "task_role_arn", "container_registry"])
def test_user_cannot_override_platform_params(key):
    with pytest.raises(InvalidRunRequest, match="set by the platform"):
        merge_params({}, {key: "s3://attacker/"})


def test_rejects_non_scalar_and_bad_names():
    with pytest.raises(InvalidRunRequest):
        merge_params({}, {"caller": ["gatk"]})
    with pytest.raises(InvalidRunRequest):
        merge_params({}, {"--evil": "x"})


def test_booleans_become_nextflow_literals():
    assert merge_params({}, {"skip_fastqc": True}) == {"skip_fastqc": "true"}


def test_samplesheet_must_be_s3_csv():
    with pytest.raises(InvalidRunRequest):
        build_head_job("abc", "/local/samplesheet.csv", CONFIG)
    with pytest.raises(InvalidRunRequest):
        build_head_job("abc", "s3://b/runs/abc/samplesheet.tsv", CONFIG)
