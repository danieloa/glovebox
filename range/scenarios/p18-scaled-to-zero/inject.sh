#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notifications
  namespace: $NS
  annotations: {kubernetes.io/change-cause: "scaled down during the incident on the 14th"}
spec:
  replicas: 3
  selector: {matchLabels: {app: notifications}}
  template:
    metadata: {labels: {app: notifications}}
    spec:
      containers:
      - name: app
        image: $GB_IMG_NGINX
        ports: [{containerPort: 80}]
---
apiVersion: v1
kind: Service
metadata: {name: notifications, namespace: $NS}
spec:
  selector: {app: notifications}
  ports: [{port: 80, targetPort: 80}]
YAML
rk -n "$NS" rollout status deploy/notifications --timeout=120s >/dev/null 2>&1 || true
# Somebody took it out of service during an unrelated incident and paused the
# deployment so it "could not come back on its own". Then went on holiday.
rk -n "$NS" scale deploy/notifications --replicas=0 >/dev/null
rk -n "$NS" rollout pause deploy/notifications >/dev/null
settle_pods "$NS" 30
