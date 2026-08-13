# Runbook: metrics or traces missing

**This is a monitoring outage, not a quiet period.** While `DemoApiTargetDown`
fires, every SLO alert is blind rather than green.

## Metrics

```bash
kubectl -n demo get servicemonitor demo-api -o yaml
kubectl -n demo get svc,endpointslice
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
# then check Status -> Targets
```

Checklist, most common first:

1. **`release:` label mismatch.** The ServiceMonitor must carry the label
   kube-prometheus-stack's Prometheus selects on (`release: monitoring` here).
   Wrong value = the object is created successfully and silently ignored.
2. **Port name.** The ServiceMonitor selects the Service port by *name* (`http`).
3. **`namespaceSelector`** must include `demo`.
4. **Selector labels** must match the Service.
5. Confirm the app itself serves data: `curl <pod-ip>:8080/metrics`.

## Traces

```bash
kubectl -n monitoring logs deploy/otel-collector --since=15m
```

Check the exporter endpoint and protocol in the app env, the collector's
receiver config, queue/drop counters, and backend connectivity.
