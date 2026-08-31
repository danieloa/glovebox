#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
converge deploy_ready "$NS" collector || fail "collector still has no ready replica"
node="$(rk -n "$NS" get pods -l app=collector -o jsonpath='{.items[0].spec.nodeName}')"
[ -n "$node" ] || fail "still unscheduled — no node assigned"
w="$(rk get node "$node" -o jsonpath='{.metadata.labels.gb-range/worker}' 2>/dev/null)"
[ "$w" = "1" ] || fail "the pod scheduled onto $node, but it must run on worker 1 — that is where its data is. Dropping the nodeSelector moves the pod away from its volume; it does not fix the reason it could not schedule."
pass "collector is running on $node, which is worker 1 as required"
