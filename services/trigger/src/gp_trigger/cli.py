#!/usr/bin/env python3
"""Operator CLI: submit a run exactly as the S3 trigger would (useful for M3 and for reruns).

    python3 services/trigger/src/gp_trigger/cli.py submit --env dev --run-id my-run \
        --samplesheet s3://gp-dev-inputs-.../runs/my-run/samplesheet.csv [--params-file p.json]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from gp_trigger.command import PlatformConfig, build_head_job  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("submit")
    s.add_argument("--env", required=True, choices=["dev", "prod"])
    s.add_argument("--run-id", required=True)
    s.add_argument("--samplesheet", required=True)
    s.add_argument("--params-file", type=Path)
    s.add_argument("--dry-run", action="store_true", help="print the SubmitJob request only")
    args = ap.parse_args(argv)

    import boto3  # imported late so --help works without boto3

    ssm = boto3.client("ssm")
    raw = ssm.get_parameter(Name=f"/gp-{args.env}/pipeline-config", WithDecryption=True)
    config = PlatformConfig.from_dict(json.loads(raw["Parameter"]["Value"]))
    user_params = json.loads(args.params_file.read_text()) if args.params_file else None
    request = build_head_job(args.run_id, args.samplesheet, config, user_params)

    if args.dry_run:
        print(json.dumps(request, indent=2))
        return 0
    job = boto3.client("batch").submit_job(**request)
    print(json.dumps({"run_id": args.run_id, "job_id": job["jobId"], "job_name": job["jobName"]}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
