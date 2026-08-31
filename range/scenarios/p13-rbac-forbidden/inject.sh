#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
rk -n "$NS" create serviceaccount watcher --dry-run=client -o yaml | rk apply -f - >/dev/null
# No Role, no RoleBinding. The ServiceAccount exists and authenticates fine;
# it is authorisation that is missing, and those two failures read very
# differently in the API server's reply.
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: watcher, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: watcher}}
  template:
    metadata: {labels: {app: watcher}}
    spec:
      serviceAccountName: watcher
      containers:
      - name: app
        image: $GB_IMG_BUSYBOX
        command:
        - sh
        - -c
        - |
          SA=/var/run/secrets/kubernetes.io/serviceaccount
          while true; do
            code=\$(wget -q -O /tmp/out -S --no-check-certificate \
              --header="Authorization: Bearer \$(cat \$SA/token)" \
              "https://kubernetes.default.svc/api/v1/namespaces/\$(cat \$SA/namespace)/pods" 2>&1 \
              | awk '/HTTP\//{print \$2}' | tail -1)
            if [ "\$code" = 200 ]; then
              echo "watcher: listed pods OK"
            else
              echo "watcher: ERROR listing pods - HTTP \${code:-?} - \$(head -c 200 /tmp/out 2>/dev/null)"
            fi
            sleep 10
          done
YAML
settle_pods "$NS" 40
