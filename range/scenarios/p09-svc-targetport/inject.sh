#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
rk -n "$NS" create configmap api-nginx --from-literal=default.conf='server { listen 8080; location / { return 200 "api ok\n"; } }' \
   --dry-run=client -o yaml | rk apply -f - >/dev/null
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: api, namespace: $NS}
spec:
  replicas: 2
  selector: {matchLabels: {app: api}}
  template:
    metadata: {labels: {app: api}}
    spec:
      volumes: [{name: conf, configMap: {name: api-nginx}}]
      containers:
      - name: app
        image: $GB_IMG_NGINX
        # The app listens on 8080. The containerPort declaration agrees.
        ports: [{containerPort: 8080}]
        volumeMounts: [{name: conf, mountPath: /etc/nginx/conf.d}]
---
apiVersion: v1
kind: Service
metadata: {name: api, namespace: $NS}
spec:
  selector: {app: api}
  # ...and the Service was written from the template, which assumed 80.
  ports: [{port: 80, targetPort: 80}]
YAML
settle_pods "$NS" 40
