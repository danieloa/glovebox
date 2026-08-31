#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
for n in $(docker ps --filter "label=io.x-k8s.kind.cluster=$RANGE_CLUSTER" --format '{{.Names}}'); do
  node_exec "$n" "systemctl start kubelet" >/dev/null 2>&1 || true
done
node="$(cat "$GB_HOME/p15.node" 2>/dev/null || true)"
[ -n "$node" ] && rk uncordon "$node" >/dev/null 2>&1 || true
rm -f "$GB_HOME/p15.node"
# Not just "the kubelet is running": the node has to be believed again, and
# kube-proxy has to reprogram this node's service rules, before the next
# scenario can trust what it sees.
wait_cluster_healthy 240 || c_warn "    cluster has not fully settled after restarting the kubelet"
