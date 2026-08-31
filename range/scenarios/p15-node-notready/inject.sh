#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
node="$(node_any_worker)"
[ -n "$node" ] || die "no worker node to break"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: ledger, namespace: $NS}
spec:
  replicas: 2
  selector: {matchLabels: {app: ledger}}
  template:
    metadata: {labels: {app: ledger}}
    spec:
      containers:
      - name: app
        image: $GB_IMG_BUSYBOX
        command: ["sleep","3600"]
        resources: {requests: {cpu: 10m, memory: 16Mi}}
YAML
rk -n "$NS" rollout status deploy/ledger --timeout=120s >/dev/null 2>&1 || true
echo "$node" > "$GB_HOME/p15.node"
# The kubelet is a systemd unit on the node. Stopping it is the honest version
# of "the node stopped reporting": the container runtime keeps running, the
# workloads keep running for now, and the control plane stops hearing anything.
node_exec "$node" "systemctl stop kubelet" >/dev/null
c_dim "    stopped kubelet on $node — the node takes ~40s to be marked NotReady"
wait_until 120 bash -c "kubectl --kubeconfig '$RANGE_KUBECONFIG' get node '$node' \
  -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qv True" || true
