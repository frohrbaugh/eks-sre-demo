# Runbook: pod Pending or not Ready

**Running is not Ready. Ready is not in an EndpointSlice.** Establish which of
the three you actually have before diagnosing.

```bash
kubectl -n demo get pods -o wide
kubectl -n demo describe pod <pod>
kubectl -n demo get endpointslice -o yaml | grep -A3 addresses
kubectl -n demo get events --sort-by=.lastTimestamp | tail -30
```

## Pending

| Cause | Signal |
|---|---|
| Insufficient CPU/memory | `describe pod` -> FailedScheduling, "Insufficient cpu" |
| Topology constraint | Only if `whenUnsatisfiable: DoNotSchedule` — this chart uses ScheduleAnyway |
| Subnet IP exhaustion | CNI errors; VPC CNI assigns real VPC addresses to pods |
| Taints | `kubectl describe node <node>` |

## Running but not Ready

- Readiness probe failing: `describe pod` shows the probe result and the reason.
- Check the port name: the probe uses `port: http`, which must resolve to a
  declared container port.
- Startup probe still running: up to 60s (30 x 2s) before liveness engages.

## Ready but no traffic

Almost always the Service selector or the target port:

```bash
kubectl -n demo get svc demo-api -o yaml    # selector, targetPort
kubectl -n demo get endpointslice -o wide   # populated?
```

Empty EndpointSlices with Ready pods means the selector does not match. Populated
EndpointSlices with no traffic means look at the Ingress and the ALB.

## Do not

Remove resource requests or weaken the security context to make a pod schedule.
Fix the actual constraint.
