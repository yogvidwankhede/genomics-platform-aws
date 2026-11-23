"""Data access: DynamoDB run registry + per-sample run_summary.json files in the results bucket."""

from __future__ import annotations

import json
import os
from decimal import Decimal
from typing import Any

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

VALID_STATUSES = {"RECEIVED", "SUBMITTED", "RUNNING", "SUCCEEDED", "FAILED", "REJECTED"}


def _plain(value: Any) -> Any:
    """DynamoDB Decimals -> int/float for JSON."""
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    if isinstance(value, dict):
        return {k: _plain(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_plain(v) for v in value]
    return value


class RunRepository:
    def __init__(self, table_name: str | None = None, results_bucket: str | None = None):
        self.table = boto3.resource("dynamodb").Table(table_name or os.environ["RUNS_TABLE"])
        self.bucket = results_bucket or os.environ["RESULTS_BUCKET"]
        self.s3 = boto3.client("s3")

    def list_runs(self, status: str | None = None, limit: int = 50) -> list[dict]:
        if status:
            resp = self.table.query(
                IndexName="by_status",
                KeyConditionExpression=Key("status").eq(status),
                ScanIndexForward=False,
                Limit=limit,
            )
            items = resp.get("Items", [])
        else:
            items, kwargs = [], {}
            while len(items) < limit:
                resp = self.table.scan(**kwargs)
                items.extend(resp.get("Items", []))
                if "LastEvaluatedKey" not in resp:
                    break
                kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
            items.sort(key=lambda i: i.get("submitted_at", ""), reverse=True)
        return [_plain(i) for i in items[:limit]]

    def get_run(self, run_id: str) -> dict | None:
        item = self.table.get_item(Key={"run_id": run_id}).get("Item")
        return _plain(item) if item else None

    def get_summaries(self, run_id: str) -> list[dict]:
        prefix = f"runs/{run_id}/summary/"
        out = []
        paginator = self.s3.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=self.bucket, Prefix=prefix):
            for obj in page.get("Contents", []):
                if obj["Key"].endswith(".run_summary.json"):
                    try:
                        body = self.s3.get_object(Bucket=self.bucket, Key=obj["Key"])["Body"].read()
                    except ClientError:  # pragma: no cover - deleted between list and get
                        continue
                    out.append(json.loads(body))
        return sorted(out, key=lambda d: d.get("sample", ""))
