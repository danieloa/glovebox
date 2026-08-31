#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
scheduled() { [ -n "$(rk_quiet -n "$1" get pods -l app=indexer -o jsonpath='{.items[0].spec.nodeName}')" ]; }
# Fixing the request replaces the ReplicaSet, so the new pod needs a moment to
# exist at all before it can have a node.
converge scheduled "$NS" || fail "layer 1: the pod is still unscheduled"
node="$(rk_quiet -n "$NS" get pods -l app=indexer -o jsonpath='{.items[0].spec.nodeName}')"
converge deploy_ready "$NS" indexer || fail "layer 2: it schedules now, but the deployment still has no ready replica — the second fault is behind the first"
converge stable_for "$NS" app=indexer 45 \
  || fail "layer 2: the restart count is still rising — it schedules and runs, and it is still crashing"
pass "indexer scheduled onto $node, running, and stable — both layers fixed"
