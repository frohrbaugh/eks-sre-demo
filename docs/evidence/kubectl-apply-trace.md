# kubectl apply: captured HTTP trace

Captured 2026-08-13 against EKS 1.35, kubectl 1.35.7.
Identifiers redacted. Reproduce with: kubectl apply -k k8s/overlays/eks -v=8

## 1. Apply with nothing changed

Note what is absent: there is no PATCH. `apply` compared desired to actual,
found no difference, and issued no writes. "unchanged" is literal.

```
GET https://<CLUSTER-ENDPOINT>/openapi/v3?timeout=32s
GET https://<CLUSTER-ENDPOINT>/openapi/v3/api/v1?hash=79E2EAA6709FB44429DF0C2392F2A86D668A2100DB82CDEDDE9D23A776092AE2DDB903E9D03125803FEE7F658A05B5009BB3379FF59A7485B6B774B2C216C3CD&timeout=32s
GET https://<CLUSTER-ENDPOINT>/openapi/v3/apis/apps/v1?hash=381D31779DB6B4B0BF7BC377E2308E6D8BA1201A54160FE54EEFF7651AFF4AE4636EC89448E9C23F5B326D77CB0858F1803A8A11FA260E0499E7FD18635A3305&timeout=32s
GET https://<CLUSTER-ENDPOINT>/openapi/v3/apis/networking.k8s.io/v1?hash=E9137914D495C8280D7E7C67A94BD5F891B1A376BB2A55E9A196BC760DD85B5B51EFD4B6214554481E8D4A937C35E979CD50F3EC4DF3BC4B3ED49C1193013033&timeout=32s
GET https://<CLUSTER-ENDPOINT>/api/v1/namespaces/demo
GET https://<CLUSTER-ENDPOINT>/api/v1/namespaces/demo/serviceaccounts/demo-api
GET https://<CLUSTER-ENDPOINT>/api/v1/namespaces/demo/services/demo-api
GET https://<CLUSTER-ENDPOINT>/apis/apps/v1/namespaces/demo/deployments/demo-api
GET https://<CLUSTER-ENDPOINT>/apis/networking.k8s.io/v1/namespaces/demo/ingresses/demo-api
```

The four `/openapi/v3` requests are the schema download. This is why
`kubectl apply --dry-run=client` FAILS with no cluster reachable: despite the
name, it is not an offline operation. What `--dry-run=client` actually skips
is admission, not network I/O.

## 2. Apply with a real change

```
GET https://<CLUSTER-ENDPOINT>/api/v1/namespaces/demo
PATCH https://<CLUSTER-ENDPOINT>/api/v1/namespaces/demo?fieldManager=kubectl-client-side-apply&fieldValidation=Strict
GET https://<CLUSTER-ENDPOINT>/api/v1/namespaces/demo/serviceaccounts/demo-api
PATCH https://<CLUSTER-ENDPOINT>/api/v1/namespaces/demo/serviceaccounts/demo-api?fieldManager=kubectl-client-side-apply&fieldValidation=Strict
GET https://<CLUSTER-ENDPOINT>/api/v1/namespaces/demo/services/demo-api
PATCH https://<CLUSTER-ENDPOINT>/api/v1/namespaces/demo/services/demo-api?fieldManager=kubectl-client-side-apply&fieldValidation=Strict
GET https://<CLUSTER-ENDPOINT>/apis/apps/v1/namespaces/demo/deployments/demo-api
PATCH https://<CLUSTER-ENDPOINT>/apis/apps/v1/namespaces/demo/deployments/demo-api?fieldManager=kubectl-client-side-apply&fieldValidation=Strict
GET https://<CLUSTER-ENDPOINT>/apis/networking.k8s.io/v1/namespaces/demo/ingresses/demo-api
```

GET then PATCH, per object. Three things to notice in the URL:

- `fieldManager=kubectl-client-side-apply` - the manager name is in the request
- `fieldValidation=Strict` - unknown fields are rejected, not ignored
- `Content-Type: application/strategic-merge-patch+json` - the merge algorithm

The Ingress received only a GET: it was unchanged, so no write was sent.
