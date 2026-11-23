"""Build the AWS Batch SubmitJob request for a Nextflow head job.

Pure functions, no AWS calls: the Lambda trigger and the operator CLI share this code, so a run
submitted by hand is byte-for-byte the run an S3 upload would have submitted.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Mapping

RUN_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{2,62}$")
PARAM_KEY_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
# Parameters the platform owns. A user-supplied params.json may not redirect where data is read
# from/written to, which queue/role is used, or where images come from.
RESERVED_PARAMS = frozenset(
    {"input", "outdir", "aws_queue", "aws_region", "aws_logs_group", "task_role_arn",
     "container_registry", "publish_mode"}
)
HEAD_JOB_PREFIX = "gp-run-"


class InvalidRunRequest(ValueError):
    """The request cannot be turned into a safe job submission."""


@dataclass(frozen=True)
class PlatformConfig:
    job_queue: str
    job_definition: str
    work_bucket: str
    results_bucket: str
    log_group: str
    profile: str = "awsbatch"
    params: Mapping[str, str] | None = None

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> "PlatformConfig":
        try:
            return cls(
                job_queue=data["job_queue"],
                job_definition=data["job_definition"],
                work_bucket=data["work_bucket"],
                results_bucket=data["results_bucket"],
                log_group=data["log_group"],
                profile=data.get("profile", "awsbatch"),
                params=dict(data.get("params") or {}),
            )
        except KeyError as exc:  # pragma: no cover - message is the point
            raise InvalidRunRequest(f"platform config missing key: {exc}") from exc


def validate_run_id(run_id: str) -> str:
    if not RUN_ID_RE.match(run_id):
        raise InvalidRunRequest(
            f"run id {run_id!r} must be 3-63 chars of lowercase letters, digits and '-'"
        )
    return run_id


def merge_params(platform: Mapping[str, str], user: Mapping[str, Any] | None) -> dict[str, str]:
    """Platform params win; user params may only add pipeline options."""
    merged: dict[str, str] = {}
    for key, value in (user or {}).items():
        if not PARAM_KEY_RE.match(key):
            raise InvalidRunRequest(f"invalid parameter name {key!r}")
        if key in RESERVED_PARAMS:
            raise InvalidRunRequest(f"parameter {key!r} is set by the platform and cannot be overridden")
        if isinstance(value, (dict, list)) or value is None:
            raise InvalidRunRequest(f"parameter {key!r} must be a scalar")
        merged[key] = str(value).lower() if isinstance(value, bool) else str(value)
    merged.update({k: str(v) for k, v in platform.items()})
    return merged


def build_head_job(
    run_id: str,
    samplesheet_uri: str,
    config: PlatformConfig,
    user_params: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Return kwargs for ``batch.submit_job``."""
    validate_run_id(run_id)
    if not samplesheet_uri.startswith("s3://") or not samplesheet_uri.endswith(".csv"):
        raise InvalidRunRequest("samplesheet must be an s3:// URI ending in .csv")

    work = f"s3://{config.work_bucket}/runs/{run_id}"
    outdir = f"s3://{config.results_bucket}/runs/{run_id}"
    params = merge_params(config.params or {}, user_params)
    params.update(
        {
            "input": samplesheet_uri,
            "outdir": outdir,
            "aws_queue": config.job_queue,
            "aws_logs_group": config.log_group,
        }
    )

    command = ["-profile", config.profile, "-work-dir", f"{work}/work", "-resume"]
    for key in sorted(params):
        command += [f"--{key}", params[key]]

    return {
        "jobName": f"{HEAD_JOB_PREFIX}{run_id}",
        "jobQueue": config.job_queue,
        "jobDefinition": config.job_definition,
        "containerOverrides": {
            "command": command,
            "environment": [
                {"name": "NXF_CLOUDCACHE_PATH", "value": f"{work}/cache"},
                {"name": "RUN_LOG_URI", "value": f"{outdir}/logs"},
                {"name": "GP_RUN_ID", "value": run_id},
            ],
        },
        "tags": {"RunId": run_id},
        "propagateTags": True,
    }
