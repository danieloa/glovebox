#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk -n "$NS" rollout status deploy/checkout --timeout=90s >/dev/null 2>&1 \
  || fail "the rollout still does not complete"
spec="$(rk -n "$NS" get deploy checkout -o jsonpath='{.spec.replicas}')"
upd="$(rk -n "$NS" get deploy checkout -o jsonpath='{.status.updatedReplicas}')"
[ "${upd:-0}" = "$spec" ] || fail "only ${upd:-0} of $spec replicas are on the current revision"
converge deploy_ready "$NS" checkout || fail "not all replicas are ready"
svc_reachable "$NS" checkout 80 || fail "the rollout completed but svc/checkout does not serve"
pass "all $spec replicas on the current revision, ready, and serving"
