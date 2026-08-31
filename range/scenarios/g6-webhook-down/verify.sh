#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
probe="gb-g6-write-probe"
rk -n "$NS" delete configmap "$probe" --ignore-not-found >/dev/null 2>&1 || true
if ! rk -n "$NS" create configmap "$probe" --from-literal=ok=1 >/dev/null 2>&1; then
  fail "creating a ConfigMap in $NS is still rejected — writes to this namespace are still blocked"
fi
rk -n "$NS" delete configmap "$probe" --ignore-not-found >/dev/null 2>&1 || true
rk -n "$NS" set env deploy/ledger GB_VERIFY=1 >/dev/null 2>&1 \
  || fail "ConfigMaps can be created but updating a Deployment is still rejected"
rk -n "$NS" rollout status deploy/ledger --timeout=90s >/dev/null 2>&1 \
  || fail "the deployment update was accepted but never rolled out"
pass "writes to $NS are accepted again and a rollout completes"
