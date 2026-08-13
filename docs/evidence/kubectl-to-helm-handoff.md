# Ladder stage 1 -> stage 2: handing objects from kubectl to Helm

Captured 2026-08-13. Three distinct failures, in order, on a live cluster.
None of these were contrived - this is simply what happens when Helm is asked
to take over objects that `kubectl apply` created.

## Failure 1: a CRD that belongs to a different chart

```
Error: unable to build kubernetes objects from release manifest:
  no matches for kind "PrometheusRule" in version "monitoring.coreos.com/v1"
  ensure CRDs are installed first
  no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1"
```

The chart renders a `ServiceMonitor` and a `PrometheusRule`. Those are *custom*
resources - their CRDs are installed by kube-prometheus-stack, which was not
yet on the cluster. The chart is not wrong; it has an undeclared dependency on
another chart's CRDs.

Worked around with `--set observability.serviceMonitor.enabled=false` until the
monitoring stack exists. The values flags exist precisely so the chart can be
installed before its optional CRDs.

## Failure 2: Helm refuses to adopt objects it did not create

```
Error: unable to continue with install: ServiceAccount "demo-api" in namespace
"demo" exists and cannot be imported into the current release:
  invalid ownership metadata;
  label validation error: key "app.kubernetes.io/managed-by" must equal "Helm":
    current value is "kubectl";
  annotation validation error: missing key "meta.helm.sh/release-name":
    must be set to "demo-api";
  annotation validation error: missing key "meta.helm.sh/release-namespace":
    must be set to "demo"
```

This is a guardrail, not a bug. Helm tracks a release as a set of objects it
owns; silently absorbing pre-existing objects would mean a later
`helm uninstall` deletes things Helm never created.

Two ways out. Deleting and recreating is simpler but drops the running pods.
Adoption keeps them:

```bash
for obj in serviceaccount/demo-api service/demo-api deployment/demo-api ingress/demo-api; do
  kubectl -n demo label    "$obj" app.kubernetes.io/managed-by=Helm --overwrite
  kubectl -n demo annotate "$obj" meta.helm.sh/release-name=demo-api \
                                  meta.helm.sh/release-namespace=demo --overwrite
done
```

## Failure 3: server-side apply field ownership - and a Helm 4 difference

```
Error: conflict occurred while applying object demo/demo-api apps/v1, Kind=Deployment:
  Apply failed with 1 conflict: conflict with "demo-cli":
  .spec.template.spec.containers[name="api"].env[name="POD_NAME"].valueFrom.fieldRef
```

`demo-cli` is the field manager used earlier during the server-side apply
experiment (see server-side-apply-conflict.md). It still owned that field.

**This is a Helm 4 behaviour worth knowing.** Helm 4 applies server-side by
default:

```
--server-side string      must be "true", "false" or "auto"  (default "auto")
--force-conflicts         if set server-side apply will force changes against conflicts
```

Helm 3 did not do this, so field-ownership conflicts are a *new* class of Helm
failure when migrating. Resolved by taking ownership explicitly:

```bash
helm upgrade --install demo-api charts/api ... --force-conflicts
```

## Result

```
$ helm -n demo list
NAME      REVISION  STATUS    CHART      APP VERSION
demo-api  2         deployed  api-0.1.0  0.1.0
```

The application kept serving throughout - the ALB never saw an outage:

```
$ curl http://<ALB-DNS>/api/v1/work
{"status":"ok","version":"f9440c59a9a1..."}
```

## Field ownership after the handoff

```
manager=demo-cli                op=Apply
manager=helm                    op=Apply
manager=kubectl-set             op=Update
manager=kubectl-label           op=Update
manager=kubectl-annotate        op=Update
manager=kube-controller-manager op=Update
```

Six managers on one Deployment, each owning a different slice of the object.
That accumulation is the whole point: every tool that touched this object left
a claim behind, and server-side apply is what keeps those claims from silently
overwriting each other.

It is also why the chart omits `spec.replicas` when the HPA is enabled. One
fewer contested field is one fewer thing to debug at 3am.
