import json
import time

from gp_trigger import queue_watchdog


def test_reports_zero_when_queue_empty(aws, capsys):
    assert queue_watchdog.handler({})["oldest_runnable_age_seconds"] == 0.0
    doc = json.loads(capsys.readouterr().out.splitlines()[0])
    assert doc["OldestRunnableJobAgeSeconds"] == 0.0


def test_reports_oldest_runnable_age(aws):
    now = int(time.time() * 1000)
    aws["batch"].runnable[:] = [{"jobId": "a", "createdAt": now - 3_600_000}, {"jobId": "b", "createdAt": now - 60_000}]
    out = queue_watchdog.handler({})
    assert out["runnable_jobs"] == 2
    assert 3590 <= out["oldest_runnable_age_seconds"] <= 3700
