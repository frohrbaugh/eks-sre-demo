"""Demo API.

Small on purpose. The interesting engineering in this repository is how this
service is provisioned, secured, delivered, observed, and recovered -- not what
it computes.

Endpoint contract (see docs/plan.md section 11.1):

    GET /                 identity: service, version, request id
    GET /health/live      liveness  -- process can serve; no remote dependencies
    GET /health/ready     readiness -- safe to receive traffic
    GET /metrics          Prometheus exposition
    GET /api/v1/work      failure-exercise surface (latency / error injection)
    GET /api/v1/config    Pod Identity proof: reads exactly one S3 object
"""

from __future__ import annotations

import asyncio
import logging
import random
import time
import uuid

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

from .settings import settings

log = logging.getLogger("api")

app = FastAPI(
    title=settings.service_name,
    version=settings.version,
    docs_url="/docs",
)

REQUESTS = Counter(
    "http_requests_total",
    "HTTP requests",
    ["method", "route", "status"],
)

LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["method", "route"],
    # 0.3 is present deliberately. The latency SLO is "95% of requests under
    # 300 ms", and a classical histogram can only answer a threshold question
    # at a bucket edge. Without this boundary the SLO query would silently
    # measure a different threshold than the one written down.
    buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.3, 0.5, 1.0, 2.5, 5.0),
)


@app.middleware("http")
async def observe(request: Request, call_next):
    request_id = request.headers.get("x-request-id") or str(uuid.uuid4())
    start = time.perf_counter()
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        response.headers["x-request-id"] = request_id
        return response
    finally:
        elapsed = time.perf_counter() - start
        # Label with the route *template*, never the raw path. Raw paths are
        # unbounded cardinality and will eventually overwhelm Prometheus.
        route = request.scope.get("route")
        route_template = getattr(route, "path", "unmatched")
        REQUESTS.labels(request.method, route_template, str(status)).inc()
        LATENCY.labels(request.method, route_template).observe(elapsed)
        log.info(
            "request",
            extra={
                "request_id": request_id,
                "route": route_template,
                "method": request.method,
                "status": status,
                "duration_ms": round(elapsed * 1000, 2),
                "version": settings.version,
            },
        )


@app.get("/")
async def root(request: Request):
    return {
        "service": settings.service_name,
        "version": settings.version,
        "request_id": request.headers.get("x-request-id", "generated"),
    }


@app.get("/health/live")
async def live():
    """Liveness.

    Deliberately has no remote dependencies. If this checked S3, a transient
    dependency outage would make kubelet restart a perfectly healthy process --
    turning a degraded endpoint into an outage.
    """
    return {"status": "live"}


@app.get("/health/ready")
async def ready():
    """Readiness.

    Only gates on things that genuinely make this pod unable to serve. The S3
    dependency is not one of them: /api/v1/config degrades on its own, and the
    rest of the API is unaffected.
    """
    return {"status": "ready"}


@app.get("/metrics", include_in_schema=False)
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/api/v1/work")
async def work():
    """The surface used by the reliability exercises.

    Both knobs default to off. See docs/plan.md section 21.
    """
    if settings.latency_ms:
        await asyncio.sleep(settings.latency_ms / 1000)
    if settings.failure_rate and random.random() < settings.failure_rate:
        raise HTTPException(status_code=503, detail="injected failure")
    return {"status": "ok", "version": settings.version}


@app.get("/api/v1/config")
async def config():
    """Proof of least-privilege AWS access via EKS Pod Identity.

    The IAM role behind this pod can read exactly one object:
        arn:aws:s3:::<DEMO_BUCKET>/config/demo.json
    Any other key returns AccessDenied, which is the point of the exercise.
    """
    if not settings.s3_configured:
        # No AWS configured -- local `docker run`, or a cluster where the demo
        # bucket was not wired up. Degrade clearly rather than raising.
        return {"source": "disabled", "reason": "no bucket configured"}

    # Imported lazily so the no-AWS path never needs botocore at all.
    import boto3
    from botocore.exceptions import ClientError

    client = boto3.client("s3", region_name=settings.aws_region)
    try:
        result = client.get_object(
            Bucket=settings.demo_bucket,
            Key=settings.demo_object_key,
        )
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "Unknown")
        # Surface the AWS error code without leaking the full response. An
        # AccessDenied here is a demonstration, not a bug -- see runbooks/.
        log.warning("s3 get_object failed: %s", code)
        return JSONResponse(
            status_code=502,
            content={"source": "s3", "error": code, "bucket_key": settings.demo_object_key},
        )

    return {
        "source": "s3",
        "key": settings.demo_object_key,
        "config": result["Body"].read().decode("utf-8"),
    }
