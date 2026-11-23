"""FastAPI app. Deployed behind an IAM-authenticated Lambda function URL (SigV4 callers only)."""

from __future__ import annotations

import functools
from typing import Annotated, Any

from fastapi import Depends, FastAPI, HTTPException, Path, Query
from pydantic import BaseModel

from gp_api import __version__
from gp_api.repository import VALID_STATUSES, RunRepository

RUN_ID = Annotated[str, Path(pattern=r"^[a-z0-9][a-z0-9-]{2,62}$")]

app = FastAPI(
    title="genomics-platform-aws API",
    version=__version__,
    description="Runs, QC metrics and variant/benchmark summaries for the germline pipeline.",
)


@functools.cache
def get_repository() -> RunRepository:
    return RunRepository()


Repo = Annotated[RunRepository, Depends(get_repository)]


class Health(BaseModel):
    status: str
    version: str


class SampleQC(BaseModel):
    sample: str
    reads_before_filtering: int | None = None
    reads_after_filtering: int | None = None
    q30_rate_after_filtering: float | None = None
    percent_duplication: float | None = None


class BenchmarkMetrics(BaseModel):
    truth_total: int | None = None
    true_positives: int | None = None
    false_negatives: int | None = None
    false_positives: int | None = None
    recall: float | None = None
    precision: float | None = None
    f1: float | None = None


class SampleVariants(BaseModel):
    sample: str
    records: int | None = None
    snps: int | None = None
    indels: int | None = None
    ts_tv: float | None = None
    benchmark: dict[str, BenchmarkMetrics] | None = None


def _require_run(repo: RunRepository, run_id: str) -> dict:
    run = repo.get_run(run_id)
    if run is None:
        raise HTTPException(status_code=404, detail=f"run {run_id} not found")
    return run


def _require_summaries(repo: RunRepository, run_id: str) -> list[dict]:
    run = _require_run(repo, run_id)
    summaries = repo.get_summaries(run_id)
    if not summaries:
        raise HTTPException(status_code=409, detail=f"run {run_id} has no results yet (status {run.get('status')})")
    return summaries


@app.get("/health", response_model=Health)
def health() -> Health:
    return Health(status="ok", version=__version__)


@app.get("/runs")
def list_runs(
    repo: Repo,
    status: Annotated[str | None, Query(description="Filter by run status")] = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
) -> dict[str, Any]:
    if status is not None and status.upper() not in VALID_STATUSES:
        raise HTTPException(status_code=422, detail=f"status must be one of {sorted(VALID_STATUSES)}")
    runs = repo.list_runs(status.upper() if status else None, limit)
    return {"count": len(runs), "runs": runs}


@app.get("/runs/{run_id}")
def get_run(run_id: RUN_ID, repo: Repo) -> dict[str, Any]:
    return _require_run(repo, run_id)


@app.get("/runs/{run_id}/qc", response_model=list[SampleQC])
def get_qc(run_id: RUN_ID, repo: Repo) -> list[SampleQC]:
    return [
        SampleQC(sample=s["sample"], **{k: v for k, v in s.get("qc", {}).items() if k in SampleQC.model_fields})
        for s in _require_summaries(repo, run_id)
    ]


@app.get("/runs/{run_id}/variants", response_model=list[SampleVariants])
def get_variants(run_id: RUN_ID, repo: Repo) -> list[SampleVariants]:
    out = []
    for s in _require_summaries(repo, run_id):
        v = {k: val for k, val in s.get("variants", {}).items() if k in SampleVariants.model_fields}
        out.append(SampleVariants(sample=s["sample"], benchmark=s.get("benchmark"), **v))
    return out
