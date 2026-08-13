# Server-side apply: field ownership and a deliberate conflict

Captured 2026-08-13 against EKS 1.35. This is the mechanism behind "two
controllers are fighting over one field" - reproduced on purpose rather than
met by accident.

## Setup: the object was created with client-side apply

Client-side apply records your previous configuration on the object itself:

```
$ kubectl -n demo get deploy demo-api \
    -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}'
{"apiVersion":"apps/v1","kind":"Deployment","metadata":{...}}   # 2211 bytes
```

That annotation is how kubectl knows which fields *you* set, and therefore
which to delete when you remove them from your file. A field some other
controller added was never in your recorded config, so it is left alone.

## Step 1: a second manager takes ownership of spec.replicas

```
$ kubectl -n demo scale deploy/demo-api --replicas=4
deployment.apps/demo-api scaled

manager=kubectl                   owns spec.replicas: True     <- new owner
manager=kubectl-client-side-apply owns spec.replicas: False
manager=kube-controller-manager   owns spec.replicas: True
```

## Step 2: apply a manifest that also specifies replicas

```
$ kubectl apply -k k8s/overlays/eks --server-side --field-manager=demo-cli

namespace/demo serverside-applied
serviceaccount/demo-api serverside-applied
service/demo-api serverside-applied
ingress.networking.k8s.io/demo-api serverside-applied
error: Apply failed with 2 conflicts:

conflicts with "kubectl" with subresource "scale" using apps/v1:
- .spec.replicas

conflicts with "kubectl-client-side-apply" using apps/v1:
- .spec.template.spec.containers[name="api"].env[name="POD_NAME"].valueFrom.fieldRef
```

The API server refused rather than silently overwriting. Two different causes:

1. **`.spec.replicas`** - the manual `kubectl scale` owns it.
2. **the env fieldRef** - the object was created with *client-side* apply, so
   that manager still owns fields server-side apply now wants. This is the
   standard CSA -> SSA migration conflict, and it appears once per object.

## Step 3: take ownership explicitly

```
$ kubectl apply -k k8s/overlays/eks --server-side --field-manager=demo-cli --force-conflicts
deployment.apps/demo-api serverside-applied

manager=demo-cli                op=Apply   owns spec.replicas: True
manager=kube-controller-manager op=Update  owns spec.replicas: True

replicas now: 2      # apply reasserted the manifest; the scale to 4 is gone
```

`kubectl-client-side-apply` no longer appears - server-side apply absorbed it.

## Why this matters in this repository

With an HPA managing `spec.replicas`, Helm rendering it, and Argo CD applying
Helm's output, three parties want the same integer. The replica count
oscillates and nothing in the logs explains why.

Two deliberate choices avoid it:

- `charts/api/templates/deployment.yaml` omits `spec.replicas` entirely when
  `autoscaling.enabled` is true. If you never render the field, you never
  contend for it.
- `gitops/applications/api-demo.yaml` sets `ServerSideApply=true`, so ownership
  is explicit and a conflict surfaces as an error instead of a silent fight.
