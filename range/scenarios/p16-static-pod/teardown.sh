#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
cp="$RANGE_CLUSTER-control-plane"
if [ -s "$GB_HOME/p16.kube-apiserver.yaml.bak" ]; then
  docker cp "$GB_HOME/p16.kube-apiserver.yaml.bak" \
    "$cp:/etc/kubernetes/manifests/kube-apiserver.yaml" >/dev/null
  rm -f "$GB_HOME/p16.kube-apiserver.yaml.bak"
  c_dim "    restored the api-server manifest; waiting for the control plane"
  wait_until 180 bash -c "kubectl --kubeconfig '$RANGE_KUBECONFIG' --request-timeout=3s get --raw /readyz >/dev/null 2>&1" \
    || c_warn "the API server has not come back yet — give it a minute, then: gb range down --cluster"
  # /readyz is the API server's opinion of itself. Everything downstream of it —
  # kube-proxy's rules, CoreDNS's endpoints — is still catching up, and a
  # scenario armed on top of that inherits symptoms it did not cause.
  wait_cluster_healthy 300 || c_warn "    cluster has not fully settled after the control plane came back"
fi
