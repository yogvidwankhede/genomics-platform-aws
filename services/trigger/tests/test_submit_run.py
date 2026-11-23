import json

from conftest import s3_event

from gp_trigger import submit_run


def test_submits_run_and_records_it(aws):
    aws["s3"].put_object(
        Bucket="gp-test-inputs", Key="runs/hg001-a/params.json", Body=json.dumps({"caller": "deepvariant"})
    )
    out = submit_run.handler(s3_event("runs/hg001-a/samplesheet.csv"))

    assert out == {"status": "SUBMITTED", "run_id": "hg001-a", "job_id": "job-1"}
    req = aws["batch"].submitted[0]
    assert req["jobName"] == "gp-run-hg001-a"
    assert "--caller" in req["containerOverrides"]["command"]
    item = aws["table"].get_item(Key={"run_id": "hg001-a"})["Item"]
    assert item["status"] == "SUBMITTED"
    assert item["job_id"] == "job-1"
    assert item["params"] == {"caller": "deepvariant"}
    assert item["results_prefix"] == "s3://gp-test-results/runs/hg001-a"


def test_duplicate_event_is_idempotent(aws):
    submit_run.handler(s3_event("runs/hg001-b/samplesheet.csv", event_id="e1"))
    out = submit_run.handler(s3_event("runs/hg001-b/samplesheet.csv", event_id="e2"))
    assert out["status"] == "DUPLICATE"
    assert len(aws["batch"].submitted) == 1


def test_params_cannot_redirect_outputs(aws):
    aws["s3"].put_object(
        Bucket="gp-test-inputs", Key="runs/evil-run/params.json", Body=json.dumps({"outdir": "s3://elsewhere"})
    )
    out = submit_run.handler(s3_event("runs/evil-run/samplesheet.csv"))
    assert out["status"] == "REJECTED"
    assert aws["batch"].submitted == []
    item = aws["table"].get_item(Key={"run_id": "evil-run"})["Item"]
    assert item["status"] == "REJECTED"
    assert "set by the platform" in item["status_reason"]


def test_malformed_params_json_is_rejected_not_retried(aws):
    aws["s3"].put_object(Bucket="gp-test-inputs", Key="runs/bad-json/params.json", Body=b"{not json")
    assert submit_run.handler(s3_event("runs/bad-json/samplesheet.csv"))["status"] == "REJECTED"


def test_invalid_run_id_is_rejected_before_registering(aws):
    out = submit_run.handler(s3_event("runs/UPPER_case/samplesheet.csv"))
    assert out["status"] == "REJECTED"
    assert "Item" not in aws["table"].get_item(Key={"run_id": "UPPER_case"})


def test_unrelated_keys_are_ignored(aws):
    assert submit_run.handler(s3_event("runs/x/HG001_R1.fastq.gz"))["status"] == "IGNORED"
    assert submit_run.handler(s3_event("other/samplesheet.csv"))["status"] == "IGNORED"


def test_emits_emf_metric(aws, capsys):
    submit_run.handler(s3_event("runs/metric-run/samplesheet.csv"))
    emf = [json.loads(line) for line in capsys.readouterr().out.splitlines() if line.startswith("{")]
    assert any(
        d.get("RunsSubmitted") == 1 and d["_aws"]["CloudWatchMetrics"][0]["Namespace"] == "GenomicsPlatform"
        for d in emf
    )
