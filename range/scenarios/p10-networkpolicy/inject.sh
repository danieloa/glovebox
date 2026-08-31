#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: backend, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: backend}}
  template:
    metadata: {labels: {app: backend}}
    spec:
      containers:
      - name: app
        image: $GB_IMG_NGINX
        ports: [{containerPort: 80}]
---
apiVersion: v1
kind: Service
metadata: {name: backend, namespace: $NS}
spec:
  selector: {app: backend}
  ports: [{port: 80, targetPort: 80}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: frontend, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: frontend}}
  template:
    metadata: {labels: {app: frontend}}
    spec:
      containers:
      - name: app
        image: $GB_IMG_NGINX
---
# A default-deny that someone added "to tighten things up", with an allow rule
# naming a label the frontend does not actually carry.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: backend-allow, namespace: $NS}
spec:
  podSelector: {matchLabels: {app: backend}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: {matchLabels: {role: frontend}}
    ports: [{protocol: TCP, port: 80}]
YAML
settle_pods "$NS" 60
rk -n "$NS" rollout status deploy/frontend --timeout=90s >/dev/null 2>&1 || true
rk -n "$NS" rollout status deploy/backend  --timeout=90s >/dev/null 2>&1 || true

# A NetworkPolicy that is not enforced is not a scenario, it is a lie. Policy
# enforcement is a property of the CNI, not of Kubernetes, and a cluster whose
# CNI ignores policy would arm a fault the trainee can never observe — they
# would chase a working system for twenty minutes. So prove the deny actually
# denies before declaring this armed, and refuse to arm if it does not.
if ! netpol_denied 60 rk -n "$NS" exec deploy/frontend -- wget -q -T 4 -O- http://backend/; then
  rk delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
  die "this cluster's CNI is not enforcing NetworkPolicy — traffic flows straight through the deny.
    p10 and g3 need an enforcing CNI. kindnetd gained policy support only in recent kind releases:
    check 'kind version', upgrade, and 'gb range down --cluster' to rebuild the range."
fi
