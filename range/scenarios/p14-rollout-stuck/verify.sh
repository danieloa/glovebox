#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk -n "$NS" rollout status deploy/storefront --timeout=90s >/dev/null 2>&1 \
  || fail "rollout status for deploy/storefront still does not complete"
spec="$(rk -n "$NS" get deploy storefront -o jsonpath='{.spec.replicas}')"
upd="$(rk -n "$NS" get deploy storefront -o jsonpath='{.status.updatedReplicas}')"
rdy="$(rk -n "$NS" get deploy storefront -o jsonpath='{.status.readyReplicas}')"
[ "${upd:-0}" = "$spec" ] && [ "${rdy:-0}" = "$spec" ] \
  || fail "updated=$upd ready=$rdy of $spec desired — not every pod is on the current revision and ready"
# The site was up throughout; it should still be. A rollout "fixed" by deleting
# the deployment and starting again passes a status check and fails the users.
svc_reachable "$NS" storefront 80 || fail "the rollout completed but svc/storefront no longer serves traffic"
pass "all $spec replicas are on the current revision, ready, and serving"
