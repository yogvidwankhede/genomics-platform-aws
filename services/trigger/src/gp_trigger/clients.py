"""Lazily created boto3 clients (module-level so they are reused across warm invocations)."""

from __future__ import annotations

import functools
import json
import os

import boto3


@functools.cache
def client(name: str):
    return boto3.client(name)


@functools.cache
def table():
    return boto3.resource("dynamodb").Table(os.environ["RUNS_TABLE"])


@functools.cache
def platform_config() -> dict:
    """Runtime config from SSM (SecureString). Cached per container; changes apply on cold start."""
    value = client("ssm").get_parameter(Name=os.environ["CONFIG_PARAMETER"], WithDecryption=True)
    return json.loads(value["Parameter"]["Value"])


def reset_caches() -> None:
    """For tests: drop cached clients/config so moto mocks take effect."""
    client.cache_clear()
    table.cache_clear()
    platform_config.cache_clear()
