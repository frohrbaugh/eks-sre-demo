# Runbook: Pod Identity AccessDenied

**Expected in one case.** Requesting `not-allowed.json` returns AccessDenied by
design — that is the least-privilege proof, not a fault. Confirm which object was
requested before treating this as an incident.

```bash
kubectl -n demo get sa demo-api -o yaml
kubectl -n kube-system get pods -l app.kubernetes.io/name=eks-pod-identity-agent
aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION"
aws iam list-attached-role-policies --role-name sre-demo-api-pod
```

## Checklist

1. **Namespace and ServiceAccount must match the association exactly.** This is
   the most common cause. `demo`/`demo-api` in both places, no typos.
2. **Pod Identity Agent add-on running.** Without it the association exists in
   AWS but no credentials ever reach the pod.
3. **Trust policy** allows both `sts:AssumeRole` *and* `sts:TagSession` for
   `pods.eks.amazonaws.com`.
4. **Resource ARN** in the policy is the object, not the bucket:
   `arn:aws:s3:::<bucket>/config/demo.json`.
5. **Region** matches. A cross-region request fails confusingly.
6. **Credential chain order.** If `AWS_ACCESS_KEY_ID` is set in the pod env, it
   wins over Pod Identity. Check the Deployment env.
7. Pods started before the association was created need a restart:
   `kubectl -n demo rollout restart deploy/demo-api`

## Never

Add static access keys to the pod as a workaround, or widen the policy to
`s3:*`. Both discard the thing this demo exists to show.
