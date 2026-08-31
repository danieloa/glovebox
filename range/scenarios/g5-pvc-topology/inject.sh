#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
rk apply -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: analytics-data, namespace: $NS}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
YAML
# The default class here is WaitForFirstConsumer, so the volume is created
# wherever the FIRST pod to use it lands — and it is pinned there for good. A
# short-lived primer pod, forced into zone-a, does that pinning.
rk apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: primer, namespace: $NS}
spec:
  restartPolicy: Never
  nodeSelector: {topology.kubernetes.io/zone: zone-a}
  volumes: [{name: data, persistentVolumeClaim: {claimName: analytics-data}}]
  containers:
  - name: app
    image: $GB_IMG_BUSYBOX
    command: ["sh","-c","echo primed > /data/marker"]
    volumeMounts: [{name: data, mountPath: /data}]
YAML
# Wait for the primer to have FINISHED, not merely for the claim to be Bound.
# WaitForFirstConsumer binds the moment the pod is scheduled, which is before
# its container has run — deleting the primer on Bound alone races the write,
# and the scenario then has no data for the verify step to insist on.
primer_done() { [ "$(rk_quiet -n "$1" get pod primer -o jsonpath='{.status.phase}')" = Succeeded ]; }
wait_until 240 primer_done "$NS" || die "the primer pod never completed — cannot arm the topology conflict"
pvc_bound() { [ "$(rk_quiet -n "$1" get pvc analytics-data -o jsonpath='{.status.phase}')" = Bound ]; }
wait_until 60 pvc_bound "$NS" || die "the claim never bound — cannot arm the topology conflict"
rk -n "$NS" delete pod primer --wait=true --timeout=90s >/dev/null 2>&1 || true
# The real workload, pinned to the other zone. The volume cannot follow.
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: analytics, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: analytics}}
  template:
    metadata: {labels: {app: analytics}}
    spec:
      nodeSelector: {topology.kubernetes.io/zone: zone-b}
      volumes: [{name: data, persistentVolumeClaim: {claimName: analytics-data}}]
      containers:
      - name: app
        image: $GB_IMG_BUSYBOX
        command: ["sleep","3600"]
        volumeMounts: [{name: data, mountPath: /data}]
        resources: {requests: {cpu: 10m, memory: 16Mi}}
YAML
settle_pods "$NS" 20
