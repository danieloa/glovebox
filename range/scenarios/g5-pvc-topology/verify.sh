#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
pvc_bound() { [ "$(rk_quiet -n "$1" get pvc "$2" -o jsonpath='{.status.phase}')" = Bound ]; }
converge pvc_bound "$NS" analytics-data || fail "pvc/analytics-data is no longer Bound"
converge deploy_ready "$NS" analytics || fail "the analytics pod is still not running"
pod="$(rk -n "$NS" get pods -l app=analytics -o name | head -1 | sed 's|pod/||')"
rk -n "$NS" exec "$pod" -- test -f /data/marker \
  || fail "the pod runs, but it is not mounting the original volume — the data written before the incident is not there. A fresh empty PVC makes the pod schedule and loses the data."
node="$(rk -n "$NS" get pod "$pod" -o jsonpath='{.spec.nodeName}')"
pass "analytics is running on $node with its original volume attached"
