#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
PROD="${NS}-prod"   # production, the namespace the ticket is actually about
for n in "$NS" "$PROD"; do
  rk create namespace "$n" --dry-run=client -o yaml | rk apply -f - >/dev/null
done
# The workload, applied to the wrong namespace during the release.
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: orders, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: orders}}
  template:
    metadata: {labels: {app: orders}}
    spec:
      containers:
      - name: app
        image: $GB_IMG_NGINX
        ports: [{containerPort: 80}]
---
apiVersion: v1
kind: Service
metadata: {name: orders, namespace: $NS}
spec:
  selector: {app: orders}
  ports: [{port: 80, targetPort: 80}]
---
# Production has the Service — created by the platform team months ago — and
# nothing behind it.
apiVersion: v1
kind: Service
metadata: {name: orders, namespace: $PROD}
spec:
  selector: {app: orders}
  ports: [{port: 80, targetPort: 80}]
YAML
# The whole scenario: the kubeconfig you were handed defaults to the wrong
# namespace, and every unqualified command you type lands there.
kubectl --kubeconfig "$RANGE_BUNDLE/kubeconfig" config set-context --current --namespace="$NS" >/dev/null
settle_pods "$NS" 40
