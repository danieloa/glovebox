#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
pvc_bound() { [ "$(rk_quiet -n "$1" get pvc "$2" -o jsonpath='{.status.phase}')" = Bound ]; }
converge pvc_bound "$NS" db-data \
  || fail "pvc/db-data is $(rk_quiet -n "$NS" get pvc db-data -o jsonpath='{.status.phase}' || echo missing), not Bound"
converge deploy_ready "$NS" db || fail "the claim is Bound but the db pod is still not ready"
pod="$(rk -n "$NS" get pods -l app=db -o name | head -1 | sed 's|pod/||')"
rk -n "$NS" exec "$pod" -c app -- test -f /data/marker \
  || fail "the pod is running but its volume is not mounted where the app expects it"
sc="$(rk -n "$NS" get pvc db-data -o jsonpath='{.spec.storageClassName}')"
pass "pvc/db-data is Bound via storageClass '${sc:-<default>}' and the pod has its volume"
