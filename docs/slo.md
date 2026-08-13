# SLIs, SLOs, and the error budget

## The user journey

A client receives a valid response from `GET /api/v1/work` through the public ALB.

`/health/*` and `/metrics` are **excluded** from every SLI query. They are not
user journeys, they are high-volume, and they almost never fail — including them
would pad availability with traffic no user cares about.

## Targets

| SLI | Definition | Target | Window |
|---|---|---:|---:|
| Availability | non-5xx / all valid requests | 99.5% | rolling 30d |
| Latency | requests completed under 300 ms | 95% | rolling 30d |

Error budget at 99.5% = **0.5% of requests**. Request-based, not time-based:

```text
error budget = total eligible requests x 0.005
```

## Queries

Availability:

```promql
sum(rate(http_requests_total{route="/api/v1/work",status!~"5.."}[5m]))
/
sum(rate(http_requests_total{route="/api/v1/work"}[5m]))
```

Latency SLI — note `le="0.3"`:

```promql
sum(rate(http_request_duration_seconds_bucket{route="/api/v1/work",le="0.3"}[5m]))
/
sum(rate(http_request_duration_seconds_count{route="/api/v1/work"}[5m]))
```

> **Why the histogram has a 0.3 bucket.** A classical histogram can only answer a
> threshold question *at a bucket edge*. Declaring a 300 ms SLO while the nearest
> boundary is 500 ms means measuring a different SLO than the one written down —
> and the dashboard would look fine while doing it. The bucket is defined in
> [`app/app/main.py`](../app/app/main.py) and guarded by a unit test so it cannot
> be tidied away later. Native histograms are the other way out of this problem.

p95, for the dashboard rather than the SLO:

```promql
histogram_quantile(0.95,
  sum by (le) (rate(http_request_duration_seconds_bucket{route="/api/v1/work"}[5m])))
```

## Burn-rate alerting

```text
burn rate = observed error ratio / 0.005
```

| Alert | Burn | Windows | Budget consumed in | Severity |
|---|---:|---|---|---|
| `DemoApiErrorBudgetBurnFast` | 14.4x | 5m **and** 1h | ~2 days | critical |
| `DemoApiErrorBudgetBurnSlow` | 6x | 30m **and** 6h | ~5 days | warning |

Both windows must be breached simultaneously: the short one fires quickly, the
long one prevents a single blip from paging anyone. Both also require a minimum
request rate, so one failure against near-zero traffic is not an incident.

Two further alerts:

- `DemoApiLatencySLOViolated` — under 95% within 300 ms for 10 minutes.
- `DemoApiTargetDown` — Prometheus cannot scrape the app. **Without this, every
  SLI above goes blind rather than red.** Absence of data is not evidence of
  health, and a silent monitoring failure is worse than a loud service failure.

Defined in
[`charts/api/templates/prometheusrule.yaml`](../charts/api/templates/prometheusrule.yaml);
thresholds are computed from the SLO target rather than hardcoded.

## Error-budget policy

| Budget remaining | Response |
|---|---|
| > 50% | Normal feature and reliability work |
| 25–50% | Review top error contributors; prioritise bounded fixes |
| < 25% | Pause risky releases; reliability and rollback readiness only |
| Exhausted | Freeze non-essential change until back in policy, or an explicit, recorded exception |

The policy exists to make tradeoffs visible, not to assign blame. "We are out of
budget, so this release waits" is a decision the policy makes easy to state.
