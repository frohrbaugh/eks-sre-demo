# Argo CD, the HPA, and who actually owns spec.replicas

Captured 2026-08-13. This did not go the way I expected, and the surprise is
the useful part.

## Setup

Argo CD v3.5.1 (pinned release manifest, not the `stable` branch), managing the
Helm chart from Git with `selfHeal: true`, `prune: true`, `ServerSideApply=true`.

```
$ kubectl -n argocd get application demo-api
NAME       SYNC     HEALTH
demo-api   Synced   Healthy
```

## The intended demo

Change the cluster by hand, watch Argo CD put it back:

```
$ kubectl -n demo scale deploy/demo-api --replicas=4
```

## What actually happened

```
t+10s   replicas=4   argo=Synced
t+20s   replicas=3   argo=Synced
...     replicas=3   argo=Synced      # held here for ~4.5 minutes
t+290s  replicas=2   argo=Synced
```

The replica count returned to 2 - but **Argo CD never reported OutOfSync, and
Argo CD did not do it.**

## Why Argo CD saw nothing

The chart deliberately does not render `spec.replicas` when the HPA is enabled:

```yaml
{{- if not .Values.autoscaling.enabled }}
replicas: {{ .Values.replicaCount }}
{{- end }}
```

```
$ helm template demo-api charts/api --set autoscaling.enabled=true | grep -c '^  replicas:'
0
```

If the field is never rendered, it is never part of Argo CD's desired state, so
a change to it is not drift. Argo CD was correct to stay Synced.

## Who did do it

```
$ kubectl -n demo get deploy demo-api --show-managed-fields
owns spec.replicas -> manager=kube-controller-manager  op=Update

$ kubectl -n demo describe hpa demo-api
Normal  SuccessfulRescale  5m37s  New size: 3; reason: All metrics below target
Normal  SuccessfulRescale  36s    New size: 2; reason: All metrics below target
```

The HorizontalPodAutoscaler. And the ~5 minute gap between the two steps is not
lag - it is the anti-flap window configured in the same chart:

```yaml
behavior:
  scaleDown:
    stabilizationWindowSeconds: 300
```

## Why this is worth more than the demo I planned

This is the "two controllers own one field" problem, resolved rather than
encountered. Had the chart rendered `replicas`, then Helm, Argo CD and the HPA
would all be writing the same integer: Argo would see the HPA's value as drift,
revert it, the HPA would scale again, and the count would oscillate with
nothing in any log explaining why.

Omitting the field costs one line of templating and removes the entire class of
problem. `ServerSideApply=true` on the Application is the belt to that braces -
it makes ownership explicit, so a genuine conflict surfaces as an error instead
of a silent fight.

## A prerequisite that is easy to miss

The HPA could not do any of this at first:

```
TARGETS: cpu: <unknown>/70%
ScalingActive=False  FailedGetResourceMetric
```

**EKS does not ship metrics-server.** Without it the HPA is declared but inert,
`kubectl top` returns nothing, and Argo CD reports the application `Degraded` -
correctly, because a control loop the chart declares cannot run. Fixed by adding
the managed add-on in Terraform:

```hcl
addons = {
  metrics-server = {}   # a Deployment, so it must come after compute
}
```

Argo CD went `Healthy` once the HPA could actually compute a replica count.
