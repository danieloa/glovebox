#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
node="$(rk get nodes -l gb-range/worker=1 -o name | head -1 | sed 's|node/||')"
[ -n "$node" ] || die "no worker node labelled gb-range/worker=1"
# One node only. Tainting every worker would make the whole cluster unusable
# and would break any other scenario armed alongside this one.
rk taint node "$node" gb-range/maintenance=true:NoSchedule --overwrite >/dev/null
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: collector, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: collector}}
  template:
    metadata: {labels: {app: collector}}
    spec:
      # The collector is pinned to worker 1 because that is where the metrics
      # volume lives. Somebody then put worker 1 into maintenance.
      nodeSelector: {gb-range/worker: "1"}
      containers:
      - name: app
        image: $GB_IMG_BUSYBOX
        command: ["sleep","3600"]
        resources: {requests: {cpu: 10m, memory: 16Mi}}
YAML
settle_pods "$NS" 20
