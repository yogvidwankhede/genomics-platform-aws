import json

import boto3
import pytest
from fastapi.testclient import TestClient
from moto import mock_aws

REGION = "us-east-1"


@pytest.fixture
def client(monkeypatch):
    for k, v in {
        "AWS_DEFAULT_REGION": REGION,
        "AWS_ACCESS_KEY_ID": "testing",
        "AWS_SECRET_ACCESS_KEY": "testing",
        "RUNS_TABLE": "gp-test-runs",
        "RESULTS_BUCKET": "gp-test-results",
    }.items():
        monkeypatch.setenv(k, v)
    with mock_aws():
        ddb = boto3.client("dynamodb", region_name=REGION)
        ddb.create_table(
            TableName="gp-test-runs",
            BillingMode="PAY_PER_REQUEST",
            AttributeDefinitions=[
                {"AttributeName": n, "AttributeType": "S"} for n in ("run_id", "status", "submitted_at")
            ],
            KeySchema=[{"AttributeName": "run_id", "KeyType": "HASH"}],
            GlobalSecondaryIndexes=[
                {
                    "IndexName": "by_status",
                    "KeySchema": [
                        {"AttributeName": "status", "KeyType": "HASH"},
                        {"AttributeName": "submitted_at", "KeyType": "RANGE"},
                    ],
                    "Projection": {"ProjectionType": "ALL"},
                }
            ],
        )
        table = boto3.resource("dynamodb", region_name=REGION).Table("gp-test-runs")
        from decimal import Decimal

        table.put_item(
            Item={
                "run_id": "run-old",
                "status": "SUCCEEDED",
                "submitted_at": "2026-11-01T00:00:00+00:00",
                "duration_seconds": Decimal("120.5"),
                "samples": {"HG001": {"snp_f1": Decimal("0.998116")}},
            }
        )
        table.put_item(Item={"run_id": "run-new", "status": "FAILED", "submitted_at": "2026-11-20T00:00:00+00:00"})
        table.put_item(Item={"run_id": "run-pending", "status": "RUNNING", "submitted_at": "2026-11-21T00:00:00+00:00"})
        s3 = boto3.client("s3", region_name=REGION)
        s3.create_bucket(Bucket="gp-test-results")
        summary = json.load(open(__file__.replace("conftest.py", "fixtures/HG001.run_summary.json")))
        s3.put_object(
            Bucket="gp-test-results", Key="runs/run-old/summary/HG001.run_summary.json", Body=json.dumps(summary)
        )

        from gp_api import main

        main.get_repository.cache_clear()
        yield TestClient(main.app)
        main.get_repository.cache_clear()
