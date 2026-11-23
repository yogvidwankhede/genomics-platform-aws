import json

import boto3
import pytest
from moto import mock_aws

REGION = "us-east-1"


class FakeBatch:
    """Minimal Batch double: moto's Batch backend wants Docker; we only need the API contract."""

    def __init__(self):
        self.submitted = []
        self.runnable = []

    def submit_job(self, **kwargs):
        self.submitted.append(kwargs)
        return {"jobId": f"job-{len(self.submitted)}", "jobName": kwargs["jobName"]}

    def get_paginator(self, name):
        assert name == "list_jobs"
        runnable = self.runnable

        class _P:
            def paginate(self, **kwargs):
                assert kwargs["jobStatus"] == "RUNNABLE"
                yield {"jobSummaryList": runnable}

        return _P()


@pytest.fixture
def aws(monkeypatch):
    env = {
        "AWS_DEFAULT_REGION": REGION,
        "AWS_ACCESS_KEY_ID": "testing",
        "AWS_SECRET_ACCESS_KEY": "testing",
        "RUNS_TABLE": "gp-test-runs",
        "CONFIG_PARAMETER": "/gp-test/pipeline-config",
        "RESULTS_BUCKET": "gp-test-results",
        "INPUTS_BUCKET": "gp-test-inputs",
        "JOB_QUEUE": "gp-test-spot",
        "ENVIRONMENT": "test",
        "HEAD_JOB_PREFIX": "gp-run-",
    }
    for k, v in env.items():
        monkeypatch.setenv(k, v)

    with mock_aws():
        from gp_trigger import clients

        clients.reset_caches()
        ddb = boto3.client("dynamodb", region_name=REGION)
        ddb.create_table(
            TableName="gp-test-runs",
            BillingMode="PAY_PER_REQUEST",
            AttributeDefinitions=[
                {"AttributeName": "run_id", "AttributeType": "S"},
                {"AttributeName": "status", "AttributeType": "S"},
                {"AttributeName": "submitted_at", "AttributeType": "S"},
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
        s3 = boto3.client("s3", region_name=REGION)
        for b in ("gp-test-inputs", "gp-test-results"):
            s3.create_bucket(Bucket=b)
        topic = boto3.client("sns", region_name=REGION).create_topic(Name="gp-test-run-events")["TopicArn"]
        monkeypatch.setenv("TOPIC_ARN", topic)
        boto3.client("ssm", region_name=REGION).put_parameter(
            Name="/gp-test/pipeline-config",
            Type="SecureString",
            Value=json.dumps(
                {
                    "job_queue": "gp-test-spot",
                    "job_definition": "gp-test-nextflow-head",
                    "work_bucket": "gp-test-work",
                    "results_bucket": "gp-test-results",
                    "log_group": "/gp/test/batch",
                    "profile": "awsbatch",
                    "params": {
                        "container_registry": "123.dkr.ecr.us-east-1.amazonaws.com/mirror/",
                        "aws_region": REGION,
                    },
                }
            ),
        )
        fake = FakeBatch()
        real_client = clients.client

        def patched(name):
            return fake if name == "batch" else real_client(name)

        monkeypatch.setattr(clients, "client", patched)
        yield {
            "s3": s3,
            "ddb": ddb,
            "batch": fake,
            "table": boto3.resource("dynamodb", region_name=REGION).Table("gp-test-runs"),
        }
    # caches are reset at the start of the next test, once monkeypatch has restored clients.client


def s3_event(key, bucket="gp-test-inputs", event_id="evt-1"):
    return {
        "id": event_id,
        "source": "aws.s3",
        "detail-type": "Object Created",
        "detail": {"bucket": {"name": bucket}, "object": {"key": key}},
    }


def batch_event(run_id, status, started=None, stopped=None, reason=None):
    detail = {"jobName": f"gp-run-{run_id}", "jobId": "job-1", "status": status}
    if started:
        detail["startedAt"] = started
    if stopped:
        detail["stoppedAt"] = stopped
    if reason:
        detail["statusReason"] = reason
    return {"source": "aws.batch", "detail-type": "Batch Job State Change", "detail": detail}
