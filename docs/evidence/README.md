# Evidence

Sanitized captures of everything that only exists while the cluster is running.

This directory is **load-bearing**. The cluster is destroyed at the end of every
working session, so for every reader after that point these files are not
documentation of the demo — they are the demo.

## Redaction rules

Before committing anything here, remove:

- AWS account IDs (12 digits, and inside every ECR URL and role ARN)
- S3 bucket names and the cluster API endpoint
- ALB hostnames
- Any IP address, especially the operator source IP

Redact while capturing, not as a cleanup pass at the end. A sweep over fifty
images will miss one.

## Planned captures

- [ ] `kubectl -v=8 apply` trace, annotated
- [ ] `managedFields` and a deliberate server-side apply conflict
- [ ] `kubectl get svc,endpointslice` before and after a pod deletion
- [ ] Argo CD showing Synced/Healthy, and a drift repair
- [ ] Grafana RED dashboard under load; SLO and error-budget panel
- [ ] A burn-rate alert firing and resolving
- [ ] One end-to-end trace: ALB -> FastAPI -> S3
- [ ] `AccessDenied` on the out-of-scope S3 key, alongside the allowed read
- [ ] ALB target group with healthy targets
- [ ] Failure-exercise timeline with detect/mitigate/recover timestamps

Nothing captured yet — the cluster has not been provisioned.
