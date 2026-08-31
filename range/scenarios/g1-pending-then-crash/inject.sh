#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
# Two independent bugs, stacked. The second is invisible until the first is
# fixed, which is the entire lesson: leaving Pending is not the same as working.
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: indexer, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: indexer}}
  template:
    metadata: {labels: {app: indexer}}
    spec:
      containers:
      - name: app
        image: $GB_IMG_BUSYBOX
        command:
        - sh
        - -c
        - 'if [ -z "\$INDEX_URL" ]; then echo "FATAL: INDEX_URL missing from config"; exit 1; fi; echo "indexing against \$INDEX_URL"; sleep 3600'
        env:
        - name: INDEX_URL
          valueFrom:
            configMapKeyRef: {name: indexer-config, key: url}
        resources: {requests: {memory: "800Gi"}}
YAML
settle_pods "$NS" 20
