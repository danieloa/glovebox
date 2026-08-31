#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: $NS
  annotations:
    gb-range/release-notes: "v2 ships as nginx:1.27-alpine from the public library repo"
spec:
  replicas: 2
  strategy: {rollingUpdate: {maxUnavailable: 0, maxSurge: 1}}
  selector: {matchLabels: {app: checkout}}
  template:
    metadata: {labels: {app: checkout}}
    spec:
      containers:
      - name: app
        image: $GB_IMG_NGINX
        ports: [{containerPort: 80}]
---
apiVersion: v1
kind: Service
metadata: {name: checkout, namespace: $NS}
spec:
  selector: {app: checkout}
  ports: [{port: 80, targetPort: 80}]
YAML
rk -n "$NS" rollout status deploy/checkout --timeout=180s >/dev/null
# "Release v2." Two faults in one reference: a repository this cluster has no
# credentials for, AND a tag that does not exist. The tag error is reported
# first, so fixing it only reveals the second.
rk -n "$NS" set image deploy/checkout app=docker.io/gbprivate/checkout:1.27-alpin3 >/dev/null
wait_state "$NS" 'ImagePullBackOff\|ErrImagePull' 120 || true
