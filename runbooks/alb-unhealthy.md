# Runbook: ALB 503 or unhealthy targets

Verify **both** Kubernetes endpoints and AWS target health before declaring
recovery. They are independent signals and can disagree.

```bash
kubectl -n demo describe ingress demo-api
kubectl -n demo get svc,endpointslice,pods -o wide
kubectl -n kube-system logs deploy/aws-load-balancer-controller --since=15m
```

## Ingress has no ADDRESS

The most common cause is **missing subnet discovery tags**. The controller has
no way to know which subnets to use:

```text
public subnets:  kubernetes.io/role/elb = 1
private subnets: kubernetes.io/role/internal-elb = 1
```

Terraform sets these. If the Ingress was created before the controller was
installed, delete and recreate it.

Also check: controller running, its IAM role attached, `ingressClassName: alb`.

## Targets unhealthy

```bash
aws elbv2 describe-target-health --region "$AWS_REGION" --target-group-arn <arn>
```

The ALB health check is a *second* readiness signal, independent of the kubelet
probe. Both point at `/health/ready` here — if they disagree, check that the
health-check port matches the container port, and that the node security group
permits the ALB to reach pod IPs.

## Ordering trap

Deleting the cluster before the Ingress orphans the ALB, its target groups, and
security groups — which keep billing. Always delete Ingress first and confirm
the ALB is gone. `make destroy` enforces this.
