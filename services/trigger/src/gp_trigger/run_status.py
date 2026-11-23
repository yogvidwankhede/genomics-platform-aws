"""EventBridge (Batch Job State Change for gp-run-* head jobs) -> update the run record, notify.

On SUCCEEDED the per-sample run_summary.json files written by the pipeline are folded into the
DynamoDB item, so listing runs with their headline QC/benchmark numbers needs no S3 reads.
"""

from __future__ import annotations

import json
import os
from datetime import UTC, datetime
from decimal import Decimal

from botocore.exceptions import ClientError

from gp_trigger import clients
from gp_trigger.observability import emit_metric, get_logger

log = get_logger(__name__)
TERMINAL = {"SUCCEEDED", "FAILED"}


def _iso(ms: int | None) -> str | None:
    if not ms:
        return None
    return datetime.fromtimestamp(ms / 1000, tz=UTC).isoformat(timespec="seconds")


def _to_dynamo(value):
    """JSON floats -> Decimal for DynamoDB."""
    return json.loads(json.dumps(value), parse_float=Decimal)


def load_summaries(bucket: str, run_id: str) -> dict:
    s3 = clients.client("s3")
    prefix = f"runs/{run_id}/summary/"
    out: dict = {}
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            if not obj["Key"].endswith(".run_summary.json"):
                continue
            doc = json.loads(s3.get_object(Bucket=bucket, Key=obj["Key"])["Body"].read())
            bench = doc.get("benchmark") or {}
            out[doc["sample"]] = {
                "reads_before_filtering": doc.get("qc", {}).get("reads_before_filtering"),
                "percent_duplication": doc.get("qc", {}).get("percent_duplication"),
                "snps": doc.get("variants", {}).get("snps"),
                "indels": doc.get("variants", {}).get("indels"),
                "snp_f1": bench.get("SNP", {}).get("f1"),
                "indel_f1": bench.get("INDEL", {}).get("f1"),
            }
    return out


def handler(event: dict, context: object = None) -> dict:
    detail = event.get("detail", {})
    job_name = detail.get("jobName", "")
    prefix = os.environ.get("HEAD_JOB_PREFIX", "gp-run-")
    if not job_name.startswith(prefix):
        return {"status": "IGNORED"}
    run_id = job_name[len(prefix) :]
    status = detail.get("status")
    runs = clients.table()

    names = {"#s": "status"}
    values = {
        ":s": status,
        ":u": datetime.now(UTC).isoformat(timespec="seconds"),
        ":j": detail.get("jobId", ""),
        ":done": "SUCCEEDED",
        ":failed": "FAILED",
    }
    sets = ["#s = :s", "updated_at = :u", "job_id = :j"]
    if detail.get("startedAt"):
        sets.append("started_at = :st")
        values[":st"] = _iso(detail["startedAt"])
    if detail.get("stoppedAt"):
        sets.append("stopped_at = :sp")
        values[":sp"] = _iso(detail["stoppedAt"])
    if detail.get("statusReason"):
        sets.append("status_reason = :r")
        values[":r"] = detail["statusReason"][:1000]

    duration = None
    if status in TERMINAL and detail.get("startedAt") and detail.get("stoppedAt"):
        duration = round((detail["stoppedAt"] - detail["startedAt"]) / 1000, 1)
        sets.append("duration_seconds = :d")
        values[":d"] = Decimal(str(duration))

    if status == "SUCCEEDED":
        summaries = load_summaries(os.environ["RESULTS_BUCKET"], run_id)
        sets.append("samples = :m")
        values[":m"] = _to_dynamo(summaries)

    try:
        # Out-of-order delivery must never move a finished run back to RUNNING.
        runs.update_item(
            Key={"run_id": run_id},
            UpdateExpression="SET " + ", ".join(sets),
            ConditionExpression="attribute_not_exists(#s) OR (#s <> :done AND #s <> :failed)",
            ExpressionAttributeNames=names,
            ExpressionAttributeValues=values,
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            log.info("stale event for finished run", extra={"run_id": run_id, "status": status})
            return {"status": "STALE", "run_id": run_id}
        raise

    if status in TERMINAL:
        metric = "RunsSucceeded" if status == "SUCCEEDED" else "RunsFailed"
        emit_metric(metric, 1, run_id=run_id)
        if duration is not None:
            emit_metric("RunDurationSeconds", duration, unit="Seconds", run_id=run_id)
        results = f"s3://{os.environ['RESULTS_BUCKET']}/runs/{run_id}"
        message = {
            "run_id": run_id,
            "status": status,
            "reason": detail.get("statusReason"),
            "duration_seconds": duration,
            "results": results,
            "nextflow_log": f"{results}/logs/nextflow.log",
            "batch_job_id": detail.get("jobId"),
        }
        clients.client("sns").publish(
            TopicArn=os.environ["TOPIC_ARN"],
            Subject=f"[gp] run {run_id} {status}"[:100],
            Message=json.dumps(message, indent=2, default=str),
        )
    log.info("run status updated", extra={"run_id": run_id, "status": status, "duration_seconds": duration})
    return {"status": status, "run_id": run_id}
