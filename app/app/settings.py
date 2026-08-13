"""Configuration, validated once at import time.

Everything is read from the environment. Values that could make the service
misbehave silently -- the failure-injection knobs in particular -- are validated
eagerly so a bad value fails the pod at startup, where a readiness probe will
catch it, rather than at the first request.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


class ConfigError(ValueError):
    """Raised when the environment holds a value the service cannot honour."""


def _float_in_range(name: str, default: str, low: float, high: float) -> float:
    raw = os.getenv(name, default)
    try:
        value = float(raw)
    except ValueError as exc:
        raise ConfigError(f"{name} must be a number, got {raw!r}") from exc
    if not low <= value <= high:
        raise ConfigError(f"{name} must be between {low} and {high}, got {value}")
    return value


def _int_in_range(name: str, default: str, low: int, high: int) -> int:
    raw = os.getenv(name, default)
    try:
        value = int(raw)
    except ValueError as exc:
        raise ConfigError(f"{name} must be an integer, got {raw!r}") from exc
    if not low <= value <= high:
        raise ConfigError(f"{name} must be between {low} and {high}, got {value}")
    return value


@dataclass(frozen=True)
class Settings:
    service_name: str
    version: str
    aws_region: str | None
    demo_bucket: str | None
    demo_object_key: str
    failure_rate: float
    latency_ms: int

    @property
    def s3_configured(self) -> bool:
        """True only when there is enough configuration to attempt an S3 read.

        When false, /api/v1/config degrades to a "disabled" response instead of
        raising. That is what lets the container run under plain `docker run`
        with no AWS credentials, which is most of the development loop.
        """
        return bool(self.demo_bucket and self.aws_region)

    @classmethod
    def from_env(cls) -> Settings:
        return cls(
            service_name=os.getenv("SERVICE_NAME", "sre-demo-api"),
            version=os.getenv("APP_VERSION", "dev"),
            aws_region=os.getenv("AWS_REGION") or None,
            demo_bucket=os.getenv("DEMO_BUCKET") or None,
            demo_object_key=os.getenv("DEMO_OBJECT_KEY", "config/demo.json"),
            # Demo-only failure injection. Both default to off; see SECURITY.md.
            failure_rate=_float_in_range("FAILURE_RATE", "0.0", 0.0, 1.0),
            latency_ms=_int_in_range("LATENCY_MS", "0", 0, 60_000),
        )


settings = Settings.from_env()
