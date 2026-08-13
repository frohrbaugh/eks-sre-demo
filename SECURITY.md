# Security

## What this repository is

A personal learning and portfolio project that provisions a disposable Amazon EKS
environment. It is **not** a production template and should not be used as one
without review. Several choices here are explicit demo tradeoffs that would be
wrong in production, and they are labelled as such in [docs/plan.md](docs/plan.md):

- A single NAT gateway instead of one per Availability Zone
- Short metric retention and ephemeral telemetry storage
- Argo CD reachable only by port-forward, with default access settings
- A deliberately minimal application with a failure-injection endpoint

## Data

No real data of any kind. The only object the application reads is a synthetic
`config/demo.json` created by Terraform. There is no PHI, no PII, no customer
data, and no employer configuration in this repository.

## Secrets

This repository is public and contains **no** credentials by design:

- No AWS access keys anywhere. CI authenticates with GitHub OIDC and short-lived
  STS credentials; pods authenticate with EKS Pod Identity.
- Account IDs, bucket names, cluster endpoints, load balancer hostnames, and the
  operator's source IP are placeholders in committed files. Real values live in
  gitignored `terraform.tfvars` and `backend.hcl`.
- GitHub secret scanning with push protection is enabled.

If you believe you have found a committed credential or an unredacted identifier
in this repository — including inside a screenshot under `docs/evidence/` —
please open an issue saying only *where* it is, without repeating the value.

## The failure-injection endpoint

`/api/v1/work` honours `FAILURE_RATE` and `LATENCY_MS` environment variables so
that reliability exercises can be run against the demo. Both default to disabled.
This is intentional for a demo and would be unacceptable in a production service
without a guard; it is discussed in the plan.
