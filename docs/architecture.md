# Architecture decisions

Decisions and their tradeoffs. The discovery narrative — including the parts
where I was wrong — lives in [learning-log.md](learning-log.md).

Full design document: [plan.md](plan.md).

---

## EKS only; no local cluster

**Decision.** Every stage runs against real EKS. No `kind`, no minikube.

**Why.** The subject of this project is operating managed Kubernetes on AWS.
Pod Identity, ALB provisioning, IAM least privilege, EKS access entries, and
control-plane logging have no local equivalent, and a local path would be a
second thing to maintain that proves less.

**Cost.** Practice time is metered at roughly $0.34/hr, and there is no free
place to make beginner mistakes. Managed by the session discipline in
[plan.md §10](plan.md): batch cluster work, capture evidence as you go, destroy
at the end. Roughly half the project needs no cluster at all.

**Consequence.** The repository must stand alone without a running cluster,
because that is the state every reader finds it in. Hence `docs/evidence/`
being load-bearing rather than decorative.

---

## All three delivery stages stay in the repository

**Decision.** `k8s/` (kubectl), `charts/` (Helm), and `gitops/` (Argo CD) all
remain, permanently.

**Why.** Deleting the simple version once the sophisticated one works removes
exactly the evidence this project exists to provide. It also makes the GitOps
argument concrete: stage 1 applies once, stage 3 applies forever.

**Tradeoff.** Three definitions of the same workload can drift. Mitigated by
`make diff-stages` and a CI job that renders both.

---

## One NAT gateway

**Decision.** `single_nat_gateway = true`.

**Why.** ~$32/month versus ~$64 for two, on a cluster that exists for hours.

**What production would do.** One per AZ, so losing an AZ cannot take out egress
for the others, plus VPC endpoints for ECR/S3/STS to cut NAT data charges and
tighten egress. Declared tradeoff, not an oversight.

---

## EKS Pod Identity over IRSA

**Decision.** Pod Identity is the workload identity mechanism.

**Why.** The IAM binding lives in AWS as an association on the
(cluster, namespace, service account) triple. The ServiceAccount manifest needs
no annotation, which is why it can stay in the cloud-agnostic `k8s/base/`.
IRSA would need `eks.amazonaws.com/role-arn` — both AWS-specific and
cluster-specific — forcing it into the overlay and changing per cluster.

**When IRSA is still right.** An add-on that requires it, or an organisational
standard. Compared in [plan.md §15.2](plan.md).

---

## No CPU limit, memory limit only

**Decision.** `requests.cpu: 100m`, `limits.memory: 256Mi`, no CPU limit.

**Why.** A CPU limit throttles rather than fails. Throttling under burst presents
as unexplained latency with healthy-looking pods — one of the harder things to
diagnose from a dashboard. The request is what the scheduler honours, and the
memory limit is what prevents a leak from taking down a node.

**Tradeoff.** A runaway pod can consume more CPU than budgeted. Acceptable on a
two-node demo cluster; would need review with noisy neighbours.

---

## `spec.replicas` omitted under autoscaling

**Decision.** The chart does not render `replicas` when the HPA is enabled.

**Why.** Otherwise Helm, Argo CD, and the HPA all write one integer, the count
oscillates, and nothing in the logs says why. Not rendering the field leaves
ownership unambiguous. Argo CD additionally uses `ServerSideApply=true` so field
ownership is explicit. See
[the deep dive](kubectl-apply-deep-dive.md#3-server-side-apply-and-field-ownership).

---

## `topologySpreadConstraints` with `ScheduleAnyway`

**Decision.** Prefer zone spread; do not require it.

**Why.** `DoNotSchedule` on a two-node cluster makes pods unschedulable the
moment capacity is tight — trading a real outage for a theoretical one.

---

## Immutable ECR tags, commit SHA only

**Decision.** `image_tag_mutability = "IMMUTABLE"`, tags are full git SHAs.

**Why.** It makes "the running pod is exactly this commit" a true statement
rather than a hopeful one, and it makes rollback unambiguous. With a moving tag,
evidence captured yesterday may not describe the bytes running today.

---

## The failure-injection endpoint

**Decision.** `/api/v1/work` honours `FAILURE_RATE` and `LATENCY_MS`.

**Why.** The reliability exercises need a way to produce controlled 5xx and
latency without breaking something real.

**Guardrails.** Both default to off, both are range-validated at startup, and
the endpoint is documented in [SECURITY.md](../SECURITY.md). In production this
would need an explicit guard; in a demo it is the mechanism under test.

---

## One repository, not two

**Decision.** Application, infrastructure, chart, and GitOps state together.

**Why.** Discoverability matters more than usual when the repository is also the
presentation.

**What larger organisations do.** Split application and environment repos so a
deployment does not require write access to application source, and so
environment history is auditable separately.
