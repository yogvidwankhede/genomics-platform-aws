import json

from conftest import batch_event

from gp_trigger import run_status

SUMMARY = {
    "schema_version": 1,
    "sample": "HG001",
    "qc": {"reads_before_filtering": 500604, "percent_duplication": 0.111},
    "variants": {"snps": 2815, "indels": 701},
    "benchmark": {"SNP": {"f1": 0.998116}, "INDEL": {"f1": 0.980198}},
}


def _seed(aws, run_id, status="SUBMITTED", job_id=None):
    item = {"run_id": run_id, "status": status, "submitted_at": "2026-11-22T00:00:00+00:00"}
    if job_id:
        item["job_id"] = job_id
    aws["table"].put_item(Item=item)


def test_success_folds_summaries_into_record(aws):
    _seed(aws, "r1")
    aws["s3"].put_object(
        Bucket="gp-test-results", Key="runs/r1/summary/HG001.run_summary.json", Body=json.dumps(SUMMARY)
    )
    out = run_status.handler(batch_event("r1", "SUCCEEDED", started=1_000_000, stopped=1_120_500))
    assert out["status"] == "SUCCEEDED"
    item = aws["table"].get_item(Key={"run_id": "r1"})["Item"]
    assert item["status"] == "SUCCEEDED"
    assert float(item["duration_seconds"]) == 120.5
    assert float(item["samples"]["HG001"]["snp_f1"]) == 0.998116
    assert int(item["samples"]["HG001"]["snps"]) == 2815


def test_multi_caller_summaries_do_not_collide(aws):
    _seed(aws, "r7")
    for caller, f1 in (("gatk", 0.998), ("deepvariant", 0.999)):
        doc = {
            **SUMMARY,
            "schema_version": 2,
            "caller": caller,
            "benchmark": {"SNP": {"f1": f1}, "INDEL": {"f1": 0.98}},
        }
        aws["s3"].put_object(
            Bucket="gp-test-results", Key=f"runs/r7/summary/HG001.{caller}.run_summary.json", Body=json.dumps(doc)
        )
    run_status.handler(batch_event("r7", "SUCCEEDED", started=1, stopped=2))
    samples = aws["table"].get_item(Key={"run_id": "r7"})["Item"]["samples"]
    assert set(samples) == {"HG001.gatk", "HG001.deepvariant"}
    assert float(samples["HG001.deepvariant"]["snp_f1"]) == 0.999


def test_failure_records_reason_and_metric(aws, capsys):
    _seed(aws, "r2")
    run_status.handler(
        batch_event("r2", "FAILED", started=1, stopped=2001, reason="Essential container in task exited")
    )
    item = aws["table"].get_item(Key={"run_id": "r2"})["Item"]
    assert item["status"] == "FAILED"
    assert item["status_reason"].startswith("Essential container")
    emf = [json.loads(line) for line in capsys.readouterr().out.splitlines() if line.startswith("{")]
    assert any(d.get("RunsFailed") == 1 for d in emf)


def test_late_running_event_does_not_regress_finished_run(aws):
    _seed(aws, "r3", status="SUCCEEDED")
    assert run_status.handler(batch_event("r3", "RUNNING", started=5))["status"] == "STALE"
    assert aws["table"].get_item(Key={"run_id": "r3"})["Item"]["status"] == "SUCCEEDED"


def test_running_sets_started_at(aws):
    _seed(aws, "r4")
    run_status.handler(batch_event("r4", "RUNNING", started=1_700_000_000_000))
    assert aws["table"].get_item(Key={"run_id": "r4"})["Item"]["started_at"] == "2023-11-14T22:13:20+00:00"


def test_ignores_non_head_jobs(aws):
    event = batch_event("x", "FAILED")
    event["detail"]["jobName"] = "nf-quay-io-biocontainers-fastp"
    assert run_status.handler(event)["status"] == "IGNORED"


def test_rerun_with_new_job_is_tracked(aws):
    # operator CLI re-registered a FAILED run with a new job id (rerun with -resume)
    _seed(aws, "r5", status="SUBMITTED", job_id="job-2")
    event = batch_event("r5", "SUCCEEDED", started=1000, stopped=61000)
    event["detail"]["jobId"] = "job-2"
    assert run_status.handler(event)["status"] == "SUCCEEDED"
    assert aws["table"].get_item(Key={"run_id": "r5"})["Item"]["status"] == "SUCCEEDED"


def test_late_event_from_superseded_job_is_ignored(aws):
    _seed(aws, "r6", status="RUNNING", job_id="job-2")
    old = batch_event("r6", "FAILED", started=1, stopped=2, reason="old attempt")
    old["detail"]["jobId"] = "job-1"
    assert run_status.handler(old)["status"] == "STALE"
    assert aws["table"].get_item(Key={"run_id": "r6"})["Item"]["status"] == "RUNNING"
