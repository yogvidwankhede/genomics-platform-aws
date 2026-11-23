"""EventBridge (S3 Object Created on runs/<run_id>/samplesheet.csv) -> submit a pipeline run.

Idempotent: EventBridge delivers at least once, so the run record is created with a conditional
put and a duplicate event for the same run_id is a no-op.
"""

from __future__ import annotations

import json
import os
import re
from datetime import UTC, datetime
from decimal import Decimal

from botocore.exceptions import ClientError

from gp_trigger import clients
from gp_trigger.command import InvalidRunRequest, PlatformConfig, build_head_job, validate_run_id
from gp_trigger.observability import emit_metric, get_logger

log = get_logger(__name__)
KEY_RE = re.compile(r"^runs/(?P<run_id>[^/]+)/samplesheet\.csv$")


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _load_user_params(bucket: str, prefix: str) -> dict | None:
    try:
        obj = clients.client("s3").get_object(Bucket=bucket, Key=f"{prefix}/params.json")
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("NoSuchKey", "404", "AccessDenied"):
            return None
        raise
    data = json.loads(obj["Body"].read())
    if not isinstance(data, dict):
        raise InvalidRunRequest("params.json must be a JSON object")
    return data


def _notify(subject: str, message: dict) -> None:
    clients.client("sns").publish(
        TopicArn=os.environ["TOPIC_ARN"], Subject=subject[:100], Message=json.dumps(message, indent=2)
    )


def handler(event: dict, context: object = None) -> dict:
    detail = event.get("detail", {})
    bucket = detail.get("bucket", {}).get("name")
    key = detail.get("object", {}).get("key", "")
    match = KEY_RE.match(key)
    if not bucket or not match:
        log.warning("ignoring event", extra={"bucket": bucket, "key": key})
        return {"status": "IGNORED"}

    run_id = match.group("run_id")
    samplesheet = f"s3://{bucket}/{key}"
    runs = clients.table()

    try:
        validate_run_id(run_id)
    except InvalidRunRequest as exc:
        log.error("rejected run", extra={"run_id": run_id, "reason": str(exc)})
        emit_metric("RunsRejected", 1, run_id=run_id)
        return {"status": "REJECTED", "reason": str(exc)}

    try:
        runs.put_item(
            Item={
                "run_id": run_id,
                "status": "RECEIVED",
                "submitted_at": _now(),
                "samplesheet": samplesheet,
                "event_id": event.get("id", ""),
            },
            ConditionExpression="attribute_not_exists(run_id)",
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            log.info("duplicate event, run already registered", extra={"run_id": run_id})
            return {"status": "DUPLICATE", "run_id": run_id}
        raise

    try:
        config = PlatformConfig.from_dict(clients.platform_config())
        user_params = _load_user_params(bucket, f"runs/{run_id}")
        request = build_head_job(run_id, samplesheet, config, user_params)
    except (InvalidRunRequest, json.JSONDecodeError) as exc:
        # Not retryable: record why, tell a human, and do not raise (a retry would fail the same way).
        runs.update_item(
            Key={"run_id": run_id},
            UpdateExpression="SET #s = :s, status_reason = :r, updated_at = :u",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":s": "REJECTED", ":r": str(exc), ":u": _now()},
        )
        emit_metric("RunsRejected", 1, run_id=run_id)
        _notify(f"[gp] run {run_id} rejected", {"run_id": run_id, "reason": str(exc), "samplesheet": samplesheet})
        log.error("rejected run", extra={"run_id": run_id, "reason": str(exc)})
        return {"status": "REJECTED", "run_id": run_id, "reason": str(exc)}

    job = clients.client("batch").submit_job(**request)
    runs.update_item(
        Key={"run_id": run_id},
        UpdateExpression="SET #s = :s, job_id = :j, job_name = :n, params = :p, results_prefix = :o, updated_at = :u",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":s": "SUBMITTED",
            ":j": job["jobId"],
            ":n": job["jobName"],
            ":p": json.loads(json.dumps(user_params or {}), parse_float=Decimal),
            ":o": f"s3://{config.results_bucket}/runs/{run_id}",
            ":u": _now(),
        },
    )
    emit_metric("RunsSubmitted", 1, run_id=run_id, job_id=job["jobId"])
    log.info("submitted run", extra={"run_id": run_id, "job_id": job["jobId"]})
    return {"status": "SUBMITTED", "run_id": run_id, "job_id": job["jobId"]}
