#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
# The workload genuinely needs ~256Mi: it buffers an image in a memory-backed
# volume. The limit says 64Mi. The kernel, not Kubernetes, resolves the
# disagreement, which is why nothing is written to the log on the way out.
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: resizer, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: resizer}}
  template:
    metadata: {labels: {app: resizer}}
    spec:
      volumes:
      - name: scratch
        emptyDir: {medium: Memory, sizeLimit: 512Mi}
      containers:
      - name: app
        image: $GB_IMG_BUSYBOX
        command: ["sh","-c","echo 'resizer starting'; dd if=/dev/zero of=/scratch/frame bs=1M count=256 2>/dev/null; echo 'buffered 256MB'; sleep 3600"]
        volumeMounts: [{name: scratch, mountPath: /scratch}]
        resources:
          requests: {memory: 64Mi}
          limits:   {memory: 64Mi}
YAML
wait_state "$NS" 'CrashLoopBackOff\|Error\|OOMKilled' 150 || true
