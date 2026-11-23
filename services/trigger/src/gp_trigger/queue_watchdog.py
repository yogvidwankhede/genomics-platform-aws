"""Scheduled: emit the age of the oldest RUNNABLE job so a stuck queue (no Spot capacity,
broken launch template, missing image) raises an alarm instead of silently waiting."""

from __future__ import annotations

import os
import time

from gp_trigger import clients
from gp_trigger.observability import emit_metric, get_logger

log = get_logger(__name__)


def handler(event: dict | None = None, context: object = None) -> dict:
    batch = clients.client("batch")
    now_ms = int(time.time() * 1000)
    oldest_ms = None
    count = 0
    for page in batch.get_paginator("list_jobs").paginate(jobQueue=os.environ["JOB_QUEUE"], jobStatus="RUNNABLE"):
        for job in page.get("jobSummaryList", []):
            count += 1
            created = job.get("createdAt")
            if created and (oldest_ms is None or created < oldest_ms):
                oldest_ms = created
    age = 0.0 if oldest_ms is None else round((now_ms - oldest_ms) / 1000, 1)
    emit_metric("OldestRunnableJobAgeSeconds", age, unit="Seconds", runnable_jobs=count)
    log.info("queue check", extra={"runnable_jobs": count, "oldest_runnable_age_seconds": age})
    return {"runnable_jobs": count, "oldest_runnable_age_seconds": age}
