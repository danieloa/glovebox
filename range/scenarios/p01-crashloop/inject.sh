#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?scenario scripts run via: gb range up <id>}"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: checkout, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: checkout}}
  template:
    metadata: {labels: {app: checkout}}
    spec:
      containers:
      - name: app
        image: $GB_IMG_BUSYBOX
        # The app reads its backend address from DB_HOST and exits when it is
        # not set. Realistic: the overwhelming majority of real CrashLoops are
        # a config the container needed and did not get.
        command: ["sh","-c",'if [ -z "\$DB_HOST" ]; then echo "FATAL: DB_HOST is not set - cannot reach the database"; exit 1; fi; echo "connected to \$DB_HOST"; sleep 3600']
YAML
wait_state "$NS" CrashLoopBackOff 150 || true
