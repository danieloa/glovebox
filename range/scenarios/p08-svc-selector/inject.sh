#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: payments, namespace: $NS}
spec:
  replicas: 2
  selector: {matchLabels: {app: payments}}
  template:
    metadata: {labels: {app: payments}}
    spec:
      containers:
      - name: app
        image: $GB_IMG_NGINX
        ports: [{containerPort: 80}]
---
apiVersion: v1
kind: Service
metadata: {name: payments, namespace: $NS}
spec:
  # One character. The pods are labelled app=payments.
  selector: {app: payment}
  ports: [{port: 80, targetPort: 80}]
YAML
settle_pods "$NS" 40
