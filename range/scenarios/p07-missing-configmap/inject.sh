#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: billing, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: billing}}
  template:
    metadata: {labels: {app: billing}}
    spec:
      containers:
      - name: app
        image: $GB_IMG_BUSYBOX
        # Block style, not a JSON flow sequence: the escaping needed to get
        # nested double quotes through a shell heredoc AND through YAML is the
        # kind of thing that silently produces a valid-but-wrong manifest.
        command:
        - sh
        - -c
        - 'echo "billing running in \$APP_MODE"; sleep 3600'
        env:
        - name: APP_MODE
          valueFrom:
            configMapKeyRef: {name: billing-config, key: mode}
YAML
settle_pods "$NS" 30
