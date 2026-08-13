# What actually happens beneath `kubectl apply`

The point of the [delivery ladder](../README.md#the-delivery-ladder) is that
Helm and Argo CD are conveniences layered over one mechanism: HTTP requests to
the Kubernetes API server, and controllers reconciling toward whatever those
requests recorded. This document is that mechanism.

> **Status.** Sections marked *(capture pending)* need real output from a running
> cluster and will be filled in from `docs/evidence/` during the first session.
> The mechanics below are written from the manifests in this repository; the
> traces are not invented placeholders and will not be added until captured.

---

## 1. The request path

What happens when you run `kubectl apply -k k8s/overlays/eks`:

1. **kubeconfig is read** — cluster, user, namespace, context selected.
2. **Credentials are obtained.** For EKS the kubeconfig does not hold a
   credential; it holds a *command to run*:

   ```yaml
   users:
   - user:
       exec:
         command: aws
         args: ["--region", "us-east-2", "eks", "get-token", "--cluster-name", "sre-demo"]
   ```

   The AWS CLI exec plugin runs on every invocation and returns a short-lived
   token. This is why an expired AWS session breaks `kubectl` with an
   authentication error rather than a network error — a genuinely confusing
   symptom until you have seen where the credential comes from.
3. **API discovery.** kubectl asks the server which resources exist so it can map
   `kind: Deployment` to `apps/v1` and a REST path. This is also why a fresh
   kubectl against a new cluster makes more requests than you would expect.
4. **Authentication** proves *who* you are. On EKS the token is validated against
   IAM.
5. **Authorization** decides *whether you may*. This is Kubernetes RBAC, mapped
   from the IAM identity via an EKS **access entry**. Two distinct systems: AWS
   authenticates, Kubernetes authorizes.
6. **Admission** — mutating plugins and webhooks default and rewrite the object,
   then validating ones accept or reject it. Nothing client-side sees this step.
7. **Persistence** to etcd. At this moment the object exists; nothing is running.
8. **Controllers act.** Deployment controller creates a ReplicaSet; ReplicaSet
   controller creates Pods; scheduler binds Pods to nodes; kubelet asks the
   container runtime to pull and start; the VPC CNI wires networking; readiness
   probes gate membership in EndpointSlices; the AWS Load Balancer Controller
   sees the Ingress and reconciles a real ALB.

Step 8 is the part that never stops. `apply` is a single request. Everything
after it is a control loop, which is why deleting a pod gets you a new one and
nobody had to run a command.

*(capture pending: annotated `kubectl -v=8 apply` trace showing discovery, the
`GET` for the existing object, and the resulting `PATCH`.)*

---

## 2. Client-side apply and the annotation

Classic `kubectl apply` computes a **three-way merge** between:

- the configuration you previously applied,
- the object as it currently exists on the server,
- the configuration you are applying now.

The first of those has to be stored somewhere, so kubectl writes your last
applied configuration onto the object itself:

```bash
kubectl get deploy demo-api -n demo \
  -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}'
```

This explains a behaviour that otherwise looks arbitrary: **removing a field from
your file deletes it from the cluster, but only if you were the one who set it.**
A field some other controller added is left alone, because it never appeared in
your recorded configuration.

*(capture pending)*

---

## 3. Server-side apply and field ownership

Server-side apply moves the merge into the API server and, crucially, records
**which manager owns which field**:

```bash
kubectl apply --server-side --field-manager=demo-cli -k k8s/overlays/eks
kubectl get deploy demo-api -n demo --show-managed-fields -o yaml
```

`.metadata.managedFields` lists every manager and the exact field paths it owns.

### The conflict experiment

This is the single most instructive thing to do on the cluster, and it is worth
provoking deliberately rather than meeting by accident:

```bash
# A different manager takes ownership of spec.replicas
kubectl scale deployment/demo-api -n demo --replicas=4

# Now try to apply a file that also specifies replicas
kubectl apply --server-side --field-manager=demo-cli -k k8s/overlays/eks
```

Expected result — an error, not a silent overwrite:

```
Apply failed with 1 conflict: conflict with "kubectl-scale":
  .spec.replicas
```

Resolve by explicitly taking ownership:

```bash
kubectl apply --server-side --field-manager=demo-cli --force-conflicts -k k8s/overlays/eks
```

### Why this is not trivia

This is the same mechanism behind a real operational problem in this repository.
With an HPA managing `spec.replicas`, and Helm rendering it, and Argo CD applying
Helm's output, three parties want to own one integer. The replica count
oscillates and the cause is invisible unless you know to look at field ownership.

The fix is in [`charts/api/templates/deployment.yaml`](../charts/api/templates/deployment.yaml):

```yaml
{{- if not .Values.autoscaling.enabled }}
replicas: {{ .Values.replicaCount }}
{{- end }}
```

Don't render the field at all when the HPA owns it. And the Argo CD Application
sets `ServerSideApply=true` so ownership is explicit rather than inferred.

*(capture pending: real `managedFields` output and the conflict error.)*

---

## 4. `apply` versus everything else

| Command | Semantics | Where it bites |
|---|---|---|
| `apply` | Declarative merge; creates or updates | Immutable fields still fail — `spec.selector`, `spec.clusterIP` |
| `create` | Imperative; errors if the object exists | Not idempotent; wrong in CI |
| `replace` | Full overwrite, requires `resourceVersion` | Drops fields other controllers set |
| `patch` | Targeted change | Leaves no record of intent for the next `apply` |
| `edit` | Interactive patch | Invisible to Git — this *is* drift |

The immutability trap worth internalising: `spec.selector` on a Deployment cannot
be changed after creation. Anything that rewrites it — a new kustomize
`commonLabels` entry, a Helm helper that includes the chart version in the
selector — turns the next apply into a failure on an object that already exists.
Both are avoided deliberately in this repo; see
[the learning log](learning-log.md#2026-08-13--kustomize-labels-and-the-immutable-selector).

---

## 5. Dry run, diff, and prune

```bash
kubectl kustomize k8s/overlays/eks           # offline: renders and parses
kubectl apply -k k8s/overlays/eks --dry-run=client   # NOT offline (see below)
kubectl apply -k k8s/overlays/eks --dry-run=server   # full admission, no persist
kubectl diff -k k8s/overlays/eks                     # field-by-field delta
```

**`--dry-run=client` is misleadingly named.** It does not mean offline: modern
kubectl downloads the OpenAPI schema from the API server to validate, so with no
cluster reachable it fails outright:

```
failed to download openapi: Get "http://localhost:8080/openapi/v2?timeout=32s":
dial tcp 127.0.0.1:8080: connect: connection refused
```

What it actually skips is **admission** — no webhooks, no quota checks, no
defaulting. So it cannot catch a policy rejection or tell you what the server
would have filled in. `--dry-run=server` runs the whole chain and just declines
to persist, which is why it catches things client-side never can.

For genuinely offline validation, use `kubectl kustomize` to render and
`kubeconform` to check schemas. That is what CI does, because CI has no cluster.

**`--prune`** deletes objects matching a selector that are absent from the input.
It is genuinely dangerous: a too-broad selector deletes things you never
mentioned, and there is no confirmation. Its awkwardness is a good argument for
Argo CD's tracked pruning, which knows exactly which objects belong to an
Application rather than inferring it from a label match.

---

## 6. Proving the ladder collapses

Helm's output is just manifests. Argo CD renders the same chart and applies the
same output. Both claims are checkable:

```bash
# Helm produces manifests; the API server validates them like any others
helm template demo-api charts/api -f gitops/environments/demo/values.yaml \
  | kubectl apply --dry-run=server -f -

# And exactly what would change on the live cluster
helm template demo-api charts/api -f gitops/environments/demo/values.yaml \
  | kubectl diff -f -
```

Verified in this repository: the Deployment rendered by `kubectl kustomize
k8s/overlays/eks` and the one rendered by `helm template` agree on name,
selector, service account, rollout strategy, container port, security context,
resources, probes, termination grace period, and the full environment key set.

Different tools. Same objects. Same API calls.
