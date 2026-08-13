# Runbook: latency SLO violated

**Trigger:** `DemoApiLatencySLOViolated` — under 95% of requests within 300 ms.
**Impact:** service is slow but still returning 200s. Availability may look fine.

## Diagnose

```bash
kubectl -n demo top pods
kubectl -n demo get hpa
kubectl -n demo describe pod <pod> | grep -A5 -i throttl
```

Order of suspicion:

1. **`LATENCY_MS` left set** from an exercise. Check the Deployment env first.
2. **CPU saturation.** Compare usage against `requests.cpu: 100m`. HPA targets
   70% of the *request*, not the node.
3. **Not enough replicas.** Is the HPA at `maxReplicas`? Are new pods Pending
   for lack of node capacity? HPA adds pods; it does not add nodes.
4. **Downstream.** `/api/v1/config` calls S3. Check traces for where time goes.

Note there is no CPU limit, so this should not be throttling — verify rather
than assume.

## Mitigate

Raise `maxReplicas`, or scale the node group if pods are Pending. If it followed
a release, revert.

## Verify

p95 back under target and the latency SLI above 95% for a sustained window.
