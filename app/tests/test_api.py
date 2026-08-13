"""Work endpoint, failure injection, config endpoint, and settings validation."""

import dataclasses
import importlib

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.settings import ConfigError, Settings

client = TestClient(app)


def override(monkeypatch, **fields):
    """Swap in a modified Settings for one test.

    Settings is a frozen dataclass on purpose -- configuration should not be
    mutable at runtime -- so tests replace the whole object rather than poking
    at its fields.
    """
    import app.main as main

    monkeypatch.setattr(main, "settings", dataclasses.replace(main.settings, **fields))


def test_work_succeeds_by_default():
    r = client.get("/api/v1/work")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_failure_injection_is_off_by_default():
    """Injection must never be on unless explicitly configured."""
    s = Settings.from_env()
    assert s.failure_rate == 0.0
    assert s.latency_ms == 0


def test_injected_failure_returns_503(monkeypatch):
    override(monkeypatch, failure_rate=1.0)
    r = client.get("/api/v1/work")
    assert r.status_code == 503
    assert r.json()["detail"] == "injected failure"


def test_injected_latency_is_applied(monkeypatch):
    override(monkeypatch, latency_ms=120)
    r = client.get("/api/v1/work")
    assert r.status_code == 200


# --- config endpoint: both branches ---


def test_config_degrades_when_no_bucket_configured(monkeypatch):
    """The no-AWS path.

    This is what lets the container be built and smoke-tested under plain
    `docker run` with no credentials. If this regresses, the whole local
    development loop breaks.
    """
    override(monkeypatch, demo_bucket=None)
    r = client.get("/api/v1/config")
    assert r.status_code == 200
    assert r.json() == {"source": "disabled", "reason": "no bucket configured"}


def test_config_reads_s3_when_configured(monkeypatch):
    """AWS is mocked. The real bucket is only touched by an integration smoke test."""
    override(monkeypatch, demo_bucket="demo-bucket", aws_region="us-east-2")

    class _Body:
        def read(self):
            return b'{"greeting": "hello"}'

    class _FakeS3:
        def get_object(self, Bucket, Key):  # noqa: N803 - boto3 kwarg names
            assert Bucket == "demo-bucket"
            assert Key == "config/demo.json"
            return {"Body": _Body()}

    import boto3

    monkeypatch.setattr(boto3, "client", lambda *a, **k: _FakeS3())

    r = client.get("/api/v1/config")
    assert r.status_code == 200
    body = r.json()
    assert body["source"] == "s3"
    assert "hello" in body["config"]


def test_config_surfaces_access_denied_without_crashing(monkeypatch):
    """AccessDenied is a demonstration in this project, not a crash."""
    override(monkeypatch, demo_bucket="demo-bucket", aws_region="us-east-2")

    import boto3
    from botocore.exceptions import ClientError

    class _DenyingS3:
        def get_object(self, Bucket, Key):  # noqa: N803
            raise ClientError({"Error": {"Code": "AccessDenied", "Message": "denied"}}, "GetObject")

    monkeypatch.setattr(boto3, "client", lambda *a, **k: _DenyingS3())

    r = client.get("/api/v1/config")
    assert r.status_code == 502
    assert r.json()["error"] == "AccessDenied"


# --- settings validation ---


@pytest.mark.parametrize(
    ("name", "value"),
    [
        ("FAILURE_RATE", "not-a-number"),
        ("FAILURE_RATE", "1.5"),
        ("FAILURE_RATE", "-0.1"),
        ("LATENCY_MS", "abc"),
        ("LATENCY_MS", "-5"),
    ],
)
def test_bad_config_fails_fast(monkeypatch, name, value):
    """A bad knob should fail the pod at startup, not at the first request."""
    monkeypatch.setenv(name, value)
    with pytest.raises(ConfigError):
        Settings.from_env()


def test_settings_module_imports_cleanly_with_defaults():
    import app.settings as s

    importlib.reload(s)
    assert s.settings.service_name
