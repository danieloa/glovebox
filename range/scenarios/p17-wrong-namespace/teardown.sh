#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk delete namespace "${NS}-prod" --wait=false --ignore-not-found >/dev/null 2>&1 || true
[ -f "$RANGE_BUNDLE/kubeconfig" ] && \
  kubectl --kubeconfig "$RANGE_BUNDLE/kubeconfig" config set-context --current --namespace=default >/dev/null 2>&1 || true
