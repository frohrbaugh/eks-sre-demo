# Runbook: Argo CD OutOfSync or Degraded

```bash
kubectl -n argocd describe application demo-api
kubectl -n argocd logs deploy/argocd-repo-server --since=15m
kubectl -n argocd logs statefulset/argocd-application-controller --since=15m
```

## Common causes

| Symptom | Cause |
|---|---|
| `ComparisonError`, values file not found | The `$values` ref in the Application is wrong — this repo uses the multi-source form deliberately |
| Perpetual OutOfSync on `spec.replicas` | HPA vs Argo. The chart omits `replicas` under autoscaling; confirm `autoscaling.enabled: true` |
| `Apply failed ... conflict` | Server-side apply field ownership. See docs/kubectl-apply-deep-dive.md |
| Immutable field error | Something changed `spec.selector`. Requires delete and recreate |
| Missing CRD | ServiceMonitor/PrometheusRule need the Prometheus Operator installed first |
| Rendering differs from local | Argo CD uses its OWN embedded Helm. Local is Helm 4 — compare `helm template` output between versions |

## Fix Git, not the cluster

Prefer correcting the repository over force-syncing. A force-sync that papers
over an unexplained difference removes the evidence of what caused it.

To make a manual change stick temporarily (during an exercise), disable auto-sync
explicitly and record that you did:

```bash
kubectl -n argocd patch application demo-api --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
```
