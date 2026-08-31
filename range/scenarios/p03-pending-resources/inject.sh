#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: reports, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: reports}}
  template:
    metadata: {labels: {app: reports}}
    spec:
      containers:
      - name: app
        image: $GB_IMG_BUSYBOX
        command: ["sleep","3600"]
        # Someone read "the report job is memory hungry" and wrote down the
        # number in the wrong unit. 900Gi, not 900Mi.
        resources:
          requests: {memory: "900Gi", cpu: "200"}
YAML
settle_pods "$NS" 20
