#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: storefront, namespace: $NS}
spec:
  replicas: 3
  # maxUnavailable 0 is why the site stayed up AND why the rollout can wedge
  # forever: Kubernetes will not remove a healthy old pod until a new one is
  # ready, and no new one ever will be.
  strategy: {rollingUpdate: {maxUnavailable: 0, maxSurge: 1}}
  selector: {matchLabels: {app: storefront}}
  template:
    metadata: {labels: {app: storefront}}
    spec:
      containers:
      - name: app
        image: $GB_IMG_NGINX
        ports: [{containerPort: 80}]
---
apiVersion: v1
kind: Service
metadata: {name: storefront, namespace: $NS}
spec:
  selector: {app: storefront}
  ports: [{port: 80, targetPort: 80}]
YAML
rk -n "$NS" rollout status deploy/storefront --timeout=180s >/dev/null
# Now "release v2".
rk -n "$NS" set image deploy/storefront app=nginx:1.27-alpine-v2-hotfix >/dev/null
wait_state "$NS" 'ImagePullBackOff\|ErrImagePull' 120 || true
