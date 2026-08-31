#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
rk -n "$NS" create configmap inv-nginx \
   --from-literal=default.conf='server { listen 8080; location / { return 200 "inventory ok\n"; } }' \
   --dry-run=client -o yaml | rk apply -f - >/dev/null
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: inventory, namespace: $NS}
spec:
  replicas: 2
  selector: {matchLabels: {app: inventory}}
  template:
    metadata: {labels: {app: inventory}}
    spec:
      volumes: [{name: conf, configMap: {name: inv-nginx}}]
      containers:
      - name: app
        image: $GB_IMG_NGINX
        ports: [{containerPort: 8080}]
        volumeMounts: [{name: conf, mountPath: /etc/nginx/conf.d}]
---
apiVersion: v1
kind: Service
metadata: {name: inventory, namespace: $NS}
spec:
  # Fault 1: selects nothing (the pods are app=inventory).
  # Fault 2: and even once it does, it forwards to a port nothing listens on.
  selector: {app: inventory-svc}
  ports: [{port: 80, targetPort: 80}]
YAML
settle_pods "$NS" 40
