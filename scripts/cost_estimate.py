#!/usr/bin/env python3
"""Pre-apply cost estimate for one environment.

Reads infra/envs/<env>.tfvars and prints what the platform costs while it is up (idle) and per
benchmark run. Prices are us-east-1 list prices used as *assumptions*; they are not measured.
Measured costs go in RESULTS.md, from Cost Explorer, after a real run.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# us-east-1 on-demand list prices (USD). Spot is variable: SPOT_VCPU_HOUR is a deliberately
# pessimistic average for m6i/m5/c6i/r6i Spot capacity.
PRICES = {
    "interface_endpoint_hour": 0.01,  # per endpoint per AZ
    "kms_key_month": 1.00,  # per customer-managed key (2: state + data)
    "cloudwatch_alarm_month": 0.10,  # standard-resolution alarm
    "ecr_gb_month": 0.10,
    "ebs_gp3_gb_month": 0.08,
    "spot_vcpu_hour": 0.025,
    "s3_standard_gb_month": 0.023,
}
INTERFACE_ENDPOINTS = 8  # infra/modules/network default list
ALARMS = 4 + 4  # run_failed, queue_stuck, dlq, + 4 Lambda error alarms
MIRRORED_IMAGES_GB = 12.0  # approximate total of mirrored tool images (DeepVariant dominates)
HOURS_PER_MONTH = 730


def parse_tfvars(path: Path) -> dict:
    values: dict = {}
    for line in path.read_text().splitlines():
        m = re.match(r'^\s*([a-z_]+)\s*=\s*"?([^"#]+?)"?\s*(#.*)?$', line)
        if m:
            values[m.group(1)] = m.group(2).strip()
    return values


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("env", choices=["dev", "prod"])
    ap.add_argument("--hours-up", type=float, default=3.0, help="how long the stack stays deployed")
    ap.add_argument("--runs", type=int, default=1, help="benchmark runs during that window")
    ap.add_argument(
        "--run-vcpu-hours",
        type=float,
        default=8.0,
        help="billed vCPU-hours per run: whole instances incl. boot + idle scale-down "
        "(pessimistic: one 8-vCPU Spot instance for 1 h; tasks alone used ~0.3 vCPU-h locally)",
    )
    args = ap.parse_args(argv)

    tfvars = parse_tfvars(Path(__file__).resolve().parent.parent / "infra" / "envs" / f"{args.env}.tfvars")
    az = int(tfvars.get("az_count", 1))
    budget = float(tfvars.get("monthly_budget_usd", 10))

    p = PRICES
    hourly_idle = {
        f"interface endpoints ({INTERFACE_ENDPOINTS} x {az} AZ)": INTERFACE_ENDPOINTS
        * az
        * p["interface_endpoint_hour"],
        "KMS keys (2)": 2 * p["kms_key_month"] / HOURS_PER_MONTH,
        f"CloudWatch alarms ({ALARMS})": ALARMS * p["cloudwatch_alarm_month"] / HOURS_PER_MONTH,
        f"ECR storage (~{MIRRORED_IMAGES_GB:.0f} GB)": MIRRORED_IMAGES_GB * p["ecr_gb_month"] / HOURS_PER_MONTH,
        "Batch compute (scaled to zero)": 0.0,
        "NAT gateway (none by design)": 0.0,
    }
    per_run = {
        f"Spot compute ({args.run_vcpu_hours} vCPU-h)": args.run_vcpu_hours * p["spot_vcpu_hour"],
        "EBS 100 GB gp3 while instances run (~1 h)": 100 * p["ebs_gp3_gb_month"] / HOURS_PER_MONTH,
        "S3 storage (~1 GB inputs+results, 1 month)": 1 * p["s3_standard_gb_month"],
        "Lambda / DynamoDB / EventBridge / SNS": 0.0,
    }

    idle = sum(hourly_idle.values())
    run = sum(per_run.values())
    total = idle * args.hours_up + run * args.runs

    print(
        f"Cost estimate: env={args.env}, up {args.hours_up:g} h, {args.runs} run(s)  [list-price ASSUMPTIONS, not measured]"
    )
    print("-" * 78)
    print("While deployed (per hour):")
    for k, v in hourly_idle.items():
        print(f"  {k:<58} ${v:>8.4f}")
    print(f"  {'= idle per hour':<58} ${idle:>8.4f}   (~${idle * 24:.2f}/day if left up)")
    print("Per benchmark run:")
    for k, v in per_run.items():
        print(f"  {k:<58} ${v:>8.4f}")
    print(f"  {'= per run':<58} ${run:>8.4f}")
    print("-" * 78)
    print(f"  ESTIMATED TOTAL for this window: ${total:.2f}   (budget alarm at ${budget:.0f}/month)")
    if idle * 24 * 30 > budget:
        print(
            f"  WARNING: leaving {args.env} up all month (~${idle * 730:.0f}) exceeds the budget. Run `make destroy ENV={args.env}`."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
