# ALB ingress: from a Kubernetes object to a real load balancer

Captured 2026-08-13. Identifiers redacted.

## An Ingress is only desired state

The Ingress existed for some time with no address, because nothing was watching
it:

```
$ kubectl -n demo get ingress
NAME       CLASS   ADDRESS
demo-api   alb     <none>

$ kubectl get ingressclass
No resources found
```

The object was valid and accepted by the API server. It simply had no meaning
until a controller existed to give it one. **The controller is what makes the
resource real, and which controller you install determines what "real" means.**

## Installing the controller

IAM first, via Terraform - the controller runs in the cluster but calls AWS, so
it needs its own identity, distinct from the CI role and the application role:

```hcl
resource "aws_eks_pod_identity_association" "lb_controller" {
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lb_controller.arn
}
```

Then the chart, pinned:

```
$ helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace kube-system --version 3.5.0 --set clusterName=sre-demo ...
```

## A real failure worth keeping: the webhook had no endpoints

```
Warning  FailedAddFinalizer  (x11 over 52s)  failed calling webhook
  "vingress.elbv2.k8s.aws": no endpoints available for service
  "aws-load-balancer-webhook-service"
Normal   SuccessfullyReconciled
```

The controller registers a *validating admission webhook*, and that webhook is
served by the controller's own pods. For about 50 seconds the webhook was
registered but its Service had no ready endpoints, so every Ingress write was
rejected by admission.

This is the same Ready/EndpointSlice lesson one layer up: a Service with no
ready endpoints routes nowhere, and here that Service sat in the admission path
of the API server itself. It retried and self-healed - no intervention.

## The result

```
$ kubectl -n demo get ingress demo-api
ADDRESS: <ALB-NAME>.us-east-1.elb.amazonaws.com

$ aws elbv2 describe-load-balancers
{ "scheme": "internet-facing", "type": "application", "state": "active", "azs": 2 }

$ aws elbv2 describe-target-health --target-group-arn <TG>
health   port   target
healthy  8080   10.42.12.210
healthy  8080   10.42.23.81
```

The targets are **pod IPs on the container port**, not node IPs on a NodePort.
That is `alb.ingress.kubernetes.io/target-type: ip`, which removes the extra
kube-proxy hop. It works because the VPC CNI gives pods real VPC addresses.

## Full request path, end to end

```
$ curl http://<ALB-DNS>/health/ready
{"status":"ready"}

$ curl http://<ALB-DNS>/api/v1/work
{"status":"ok","version":"f9440c59a9a1..."}

$ curl http://<ALB-DNS>/api/v1/config
{"source":"s3","key":"config/demo.json","config":"{...synthetic demo data...}"}
```

That last one exercises the whole chain in a single request:

```
internet -> ALB -> Ingress rule -> ClusterIP Service -> ready pod
   -> EKS Pod Identity -> STS -> s3:GetObject on ONE permitted object -> response
```

## The immutable-image claim, verified rather than asserted

```
served by the API : f9440c59a9a1524d...
image tag in k8s  : f9440c59a9a1524d...
git commit exists : commit  ("chore: pin argo cd and helm chart versions")
imageTagMutability: IMMUTABLE
```

The version the API reports equals the deployed image tag equals a real commit
in this repository. ECR tag immutability is what keeps that true over time: the
tag can never be repointed at different bytes, so "the running pod is exactly
this commit" is a durable statement rather than a hopeful one.
