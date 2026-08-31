#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
rk -n "$NS" create configmap web-content --from-literal=healthz=ok \
   --from-literal=index.html='web is serving' --dry-run=client -o yaml | rk apply -f - >/dev/null
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: web, namespace: $NS}
spec:
  replicas: 2
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      volumes: [{name: content, configMap: {name: web-content}}]
      containers:
      - name: app
        image: $GB_IMG_NGINX
        ports: [{containerPort: 80}]
        volumeMounts: [{name: content, mountPath: /usr/share/nginx/html}]
        # The app serves /healthz on 80. The probe was copied from a service
        # that used a separate admin port and nobody adjusted it.
        readinessProbe:
          httpGet: {path: /healthz, port: 8080}
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata: {name: web, namespace: $NS}
spec:
  selector: {app: web}
  ports: [{port: 80, targetPort: 80}]
YAML
settle_pods "$NS" 40
