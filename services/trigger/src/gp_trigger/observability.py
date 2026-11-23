"""Structured logging + CloudWatch Embedded Metric Format (EMF) helpers.

Lambda is configured with log_format=JSON, so `logging` records arrive in CloudWatch as JSON
with any `extra=` fields. Metrics are emitted as EMF lines (one JSON object per print), which
CloudWatch turns into metrics without a PutMetricData call or extra IAM permissions.
"""

from __future__ import annotations

import json
import logging
import os
import time

NAMESPACE = os.environ.get("METRICS_NAMESPACE", "GenomicsPlatform")


def get_logger(name: str) -> logging.Logger:
    logger = logging.getLogger(name)
    logger.setLevel(os.environ.get("POWERTOOLS_LOG_LEVEL", "INFO"))
    return logger


def emit_metric(name: str, value: float, unit: str = "Count", **properties: object) -> dict:
    """Print one EMF document. Dimension: Environment. Extra kwargs become searchable properties."""
    environment = os.environ.get("ENVIRONMENT", "dev")
    doc = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [
                {
                    "Namespace": NAMESPACE,
                    "Dimensions": [["Environment"]],
                    "Metrics": [{"Name": name, "Unit": unit}],
                }
            ],
        },
        "Environment": environment,
        name: value,
        **properties,
    }
    print(json.dumps(doc, default=str))
    return doc
