# Runbook: high 5xx rate

**Trigger:** `DemoApiErrorBudgetBurnFast` or `DemoApiErrorBudgetBurnSlow`.
**Impact:** users receive errors from `/api/v1/work`.

## 1. Is it real?

Check request volume first. At low traffic a handful of failures produces a
dramatic ratio. The alerts require a minimum rate, but confirm before acting.

```bash
kubectl -n demo get deploy,rs,pod -o wide
kubectl -n demo logs -l app.kubernetes.io/name=demo-api --since=15m --prefix
kubectl -n demo get events --sort-by=.lastTimestamp | tail -30
```

## 2. Scope it

- Which route and status? (`http_requests_total` by `route`, `status`)
- All pods or one? Compare by pod and by zone.
- Did it start at a deploy? `kubectl -n demo rollout history deploy/demo-api`

**Check `FAILURE_RATE` before anything else.** If a reliability exercise was left
running, this is self-inflicted:

```bash
kubectl -n demo get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].env}' | tr ',' '\n' | grep -i failure
```

## 3. Mitigate

If it correlates with a release, revert the GitOps commit — Argo CD performs the
rollback. Reverting Git is preferred over `kubectl rollout undo`, which self-heal
would undo again within the sync interval.

```bash
git revert <promotion-commit> && git push
```

## 4. Verify

Error ratio below threshold, pods Ready, ALB targets healthy, and the intended
SHA running:

```bash
kubectl -n demo get pod -o jsonpath='{.items[*].spec.containers[0].image}'
```

## 5. Preserve

Alert timestamps, dashboard snapshot, the release SHA, events, rollback commit.
Sanitize and file under `docs/evidence/`.
