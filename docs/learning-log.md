# Learning log

What I expected, what actually happened, and what I still don't know.

This is separate from [architecture.md](architecture.md) on purpose. That file
holds decisions in a confident engineering voice. This one holds the discovery
narrative, including the parts where I was wrong. Blending them would make both
less useful.

Newest first.

---

## 2026-08-13 — `--dry-run=client` is not an offline check

**What I expected:** with no cluster yet, `kubectl apply -k k8s/overlays/eks
--dry-run=client` would validate my manifests locally. "Client" is right there
in the name.

**What actually happened:**

```
error: error validating "k8s/overlays/eks": error validating data:
failed to download openapi: Get "http://localhost:8080/openapi/v2?timeout=32s":
dial tcp 127.0.0.1:8080: connect: connection refused
```

**Why:** modern kubectl validates against the API server's OpenAPI schema, and
it downloads that schema from a live cluster. `--dry-run=client` does not mean
"offline" — what it actually skips is **admission**. It never runs webhooks,
quotas, or defaulting. `--dry-run=server` does all of that and simply declines
to persist the result, which is why it catches things client-side never will.

**What works with no cluster:**

| Command | Checks | Needs a cluster |
|---|---|---|
| `kubectl kustomize <dir>` | Renders, parses YAML, resolves kustomize refs | No |
| `kubectl apply --dry-run=client` | Structure + OpenAPI schema | **Yes** |
| `kubeconform -strict` | Schema, against a pinned k8s version | No |
| `kubectl apply --dry-run=server` | Everything incl. admission | Yes |

**What I changed:** CI and `make render` use `kubectl kustomize` plus
`kubeconform`, and I corrected the plan document, which had claimed the wrong
thing in five places.

**What I'd do differently:** read what a flag actually does before designing a
workflow around what its name implies.

---

## 2026-08-13 — The lock file has to be built on the target Python

**What I expected:** run `pip-compile --generate-hashes` locally, commit the
lock, done.

**What actually happened:** nothing broke immediately — which is the problem.
My WSL Python is 3.14; the container is `python:3.12-slim`. Resolving on 3.14
can pin wheels and version ranges that differ on 3.12, and with
`--require-hashes` in the Dockerfile that surfaces as a build failure much later,
looking like a Docker problem rather than a resolution problem.

**What I changed:** the lock is generated *inside* the target image:

```bash
docker run --rm -v "$PWD/app":/w -w /w python:3.12-slim sh -c \
  'pip install -q pip-tools && pip-compile --generate-hashes \
   --strip-extras --output-file requirements.lock requirements.in'
```

That is `make lock`. 27 packages, 549 hashes.

**What I learned:** "pinned" and "reproducible" are different claims. A lock file
resolved on the wrong interpreter is pinned but not reproducible.

---

## 2026-08-13 — `readOnlyRootFilesystem` needs somewhere to write

**What I expected:** the security context is just hardening; the app doesn't
write files.

**What actually happened:** it worked — but only because I mounted an `emptyDir`
at `/tmp` before testing. I verified deliberately rather than assuming:

```bash
docker run --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m ...
```

All endpoints fine, zero restarts.

**Why it matters:** plenty of Python libraries write to `/tmp` without saying so.
Had I not mounted it, this would have surfaced as a `CrashLoopBackOff` on the
cluster — at $0.34/hr, debugging something I could have caught locally for free.

**What I learned:** test the security context locally under `docker run` with the
same constraints Kubernetes will impose. The `--read-only` and `--tmpfs` flags
map almost directly onto `readOnlyRootFilesystem` and an `emptyDir`.

---

## 2026-08-13 — kustomize labels and the immutable selector

**What I expected:** `commonLabels` is the obvious way to stamp labels across
every object.

**What I found before getting burned:** `commonLabels` injects into
`spec.selector` too, and **`spec.selector` is immutable**. Adding or renaming a
common label later means the next apply tries to mutate an immutable field and
fails — on an object that already exists, with a confusing error.

**What I did:** used the newer `labels:` form and left `includeSelectors` at its
default of `false`. Identifying labels live in the manifests; descriptive labels
are added by kustomize and stay out of the selector. Verified:

```
selector: {'app.kubernetes.io/name': 'demo-api'}   # and nothing else
```

The same reasoning drove `api.selectorLabels` vs `api.labels` in the Helm chart
— the selector helper deliberately excludes the chart version and app version,
because those change on every release.

---

## 2026-08-13 — Installed Helm 4, and the ecosystem assumes Helm 3

**What happened:** `helm version` returned `v4.2.3`. Most chart documentation,
and most of my plan, assumed Helm 3.

**Why it might bite:** Argo CD renders charts with its *own embedded* Helm
binary, not my local one. So "renders fine locally, Argo CD disagrees" is a real
failure mode, and it would look like an Argo CD bug rather than a version skew.

**Current state:** my chart lints and renders correctly on Helm 4. I have not yet
confirmed what Argo CD embeds. Noted in `platform/versions.yaml` with the
mitigation: install Helm 3 as `helm3` and diff `helm template` output between the
two before debugging anything else.

**Still open.** Listed below.

---

## 2026-08-13 — Frozen config and what a test is allowed to reach into

**What happened:** I made `Settings` a frozen dataclass, then wrote tests that
did `monkeypatch.setattr(settings, "failure_rate", 1.0)`. Five tests failed with
`FrozenInstanceError`.

**The choice:** unfreeze the config to make testing easy, or fix the tests.

**What I did:** fixed the tests. Configuration being immutable at runtime is the
property I actually want — it means nothing can quietly change the failure-
injection rate after startup. Tests now build a replacement with
`dataclasses.replace()` and swap the whole object.

**What I learned:** when a test can't reach something, that is sometimes the
design working. Worth asking which one it is before loosening the code.

---

## What I still don't know

Kept specific on purpose. "Still learning!" says nothing; this says where the
edges actually are.

- **etcd operations.** I understand that the API server persists state there and
  that EKS manages it. I have never sized, backed up, restored, or debugged it.
- **CNI internals.** I know the VPC CNI assigns real VPC addresses to pods and
  that this bounds pod density by subnet size. I could not explain ENI attachment
  limits per instance type without looking them up.
- **kube-proxy modes.** iptables vs IPVS vs eBPF dataplanes — I know they exist
  and roughly what differs. I have not measured or operated any of them.
- **Admission webhooks.** I can explain where they sit in the request path. I
  have never written one.
- **Argo CD's embedded Helm version** and whether Helm 4 rendering differs. Open
  question from today.
- **Node autoscaling.** Karpenter and Cluster Autoscaler are not installed here.
  I can explain how HPA (pod count) differs from node capacity, but I have not
  operated either autoscaler.
- **Prometheus at scale.** Retention, sharding, remote write, cardinality
  budgets. This demo runs one replica with days of retention.
- **Real incident response under load.** The failure exercises here are
  self-inflicted on a cluster with synthetic traffic and no users.
