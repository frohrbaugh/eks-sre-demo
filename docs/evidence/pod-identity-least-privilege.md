# EKS Pod Identity: least privilege, proven both ways

Captured 2026-08-13 against the live cluster. Identifiers redacted.

The pod's IAM role allows exactly one action on exactly one object:

```hcl
statement {
  sid       = "ReadExactlyOneDemoObject"
  actions   = ["s3:GetObject"]                                  # not s3:*
  resources = ["arn:aws:s3:::<DEMO_BUCKET>/config/demo.json"]   # not the bucket
}
```

## The pod holds no credentials

```
env keys: APP_VERSION, AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE,
          AWS_CONTAINER_CREDENTIALS_FULL_URI, AWS_REGION,
          AWS_STS_REGIONAL_ENDPOINTS, DEMO_BUCKET, DEMO_OBJECT_KEY,
          FAILURE_RATE, LATENCY_MS, POD_NAME, SERVICE_NAME

static AWS credentials present: NONE

volumes: eks-pod-identity-token, tmp, kube-api-access-...
```

`AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`
and the `eks-pod-identity-token` volume are injected by the EKS Pod Identity
Agent. boto3 finds them via the default credential chain - the application code
contains no AWS credential handling at all.

The ServiceAccount carries no annotation. Under Pod Identity the binding lives
in AWS, on the (cluster, namespace, service account) triple, which is why
`k8s/base/serviceaccount.yaml` can stay cloud-agnostic. Under IRSA it would
need `eks.amazonaws.com/role-arn` - AWS-specific and cluster-specific - forcing
it into the overlay.

## Allowed: config/demo.json

```
$ curl http://<svc>/api/v1/config
{
  "source": "s3",
  "key": "config/demo.json",
  "config": "{\"environment\":\"demo\",\"greeting\":\"hello from s3\",
              \"note\":\"Synthetic demo data. No PHI, no PII...\",\"synthetic\":true}"
}
```

## Denied: not-allowed.json

```
$ kubectl -n demo set env deploy/demo-api DEMO_OBJECT_KEY=not-allowed.json
$ curl http://<svc>/api/v1/config
{"source":"s3","error":"AccessDenied","bucket_key":"not-allowed.json"}
HTTP 502
```

## The object exists - so this is authorization, not a 404

This is the step that turns a coincidence into a proof. Queried with
administrator credentials rather than the pod role:

```
$ aws s3api head-object --bucket <DEMO_BUCKET> --key not-allowed.json
{ "size": 79, "type": "application/json" }
```

The object is present and readable by an admin. The pod cannot read it because
its role's resource ARN does not cover that key. Same bucket, same API call,
different key - denied.

## What stayed healthy

Only `/api/v1/config` failed. `/health/live`, `/health/ready` and
`/api/v1/work` were unaffected, because liveness deliberately has no remote
dependency: a dependency outage must not cause kubelet to restart an otherwise
healthy process.
