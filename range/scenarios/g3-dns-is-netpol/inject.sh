#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: worker, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: worker}}
  template:
    metadata: {labels: {app: worker}}
    spec:
      containers:
      - name: app
        image: $GB_IMG_NGINX
---
# A default-deny egress written by someone hardening the namespace, who allowed
# the app traffic they knew about and never thought about port 53. Everything
# in here now fails at resolution, which looks exactly like a DNS outage.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny-egress, namespace: $NS}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - to:
    - podSelector: {}
YAML
rk -n "$NS" rollout status deploy/worker --timeout=120s >/dev/null 2>&1 || true
if ! netpol_denied 60 rk -n "$NS" exec deploy/worker -- nslookup kubernetes.default.svc.cluster.local; then
  rk delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
  die "this cluster's CNI is not enforcing NetworkPolicy — resolution still works through the egress deny.
    p10 and g3 need an enforcing CNI. Check 'kind version', upgrade, then 'gb range down --cluster'."
fi
