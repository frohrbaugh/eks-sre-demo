"""Health, identity, and metrics behaviour."""

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_liveness_is_ok():
    r = client.get("/health/live")
    assert r.status_code == 200
    assert r.json() == {"status": "live"}


def test_readiness_is_ok():
    r = client.get("/health/ready")
    assert r.status_code == 200
    assert r.json() == {"status": "ready"}


def test_root_reports_identity():
    r = client.get("/")
    assert r.status_code == 200
    body = r.json()
    assert body["service"]
    assert body["version"]


def test_request_id_is_echoed_back():
    r = client.get("/health/live", headers={"x-request-id": "abc-123"})
    assert r.headers["x-request-id"] == "abc-123"


def test_metrics_exposes_counter_and_histogram():
    client.get("/health/live")
    body = client.get("/metrics").text
    assert "http_requests_total" in body
    assert "http_request_duration_seconds_bucket" in body


def test_histogram_has_the_300ms_bucket_the_slo_needs():
    """The latency SLO is 300 ms.

    A classical histogram can only answer a threshold question at a bucket
    edge, so le="0.3" must exist or the SLO query in docs/plan.md section 20.3
    would silently measure something else. This test is the guard against
    someone "tidying up" the bucket list later.
    """
    client.get("/health/live")
    body = client.get("/metrics").text
    assert 'le="0.3"' in body


def test_metrics_label_uses_route_template_not_raw_path():
    """Unbounded label cardinality is the classic way to take down Prometheus."""
    client.get("/health/live")
    body = client.get("/metrics").text
    assert 'route="/health/live"' in body
