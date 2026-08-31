#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
rk apply -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: db-data, namespace: $NS}
spec:
  accessModes: [ReadWriteOnce]
  # The class this was written against does not exist on this cluster. A
  # storageClassName that names nothing never falls back to the default —
  # only an ABSENT field does that.
  storageClassName: fast-ssd
  resources: {requests: {storage: 1Gi}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: db, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: db}}
  template:
    metadata: {labels: {app: db}}
    spec:
      volumes: [{name: data, persistentVolumeClaim: {claimName: db-data}}]
      containers:
      - name: app
        image: $GB_IMG_BUSYBOX
        command: ["sh","-c","echo started > /data/marker; sleep 3600"]
        volumeMounts: [{name: data, mountPath: /data}]
        resources: {requests: {cpu: 10m, memory: 16Mi}}
YAML
settle_pods "$NS" 20
