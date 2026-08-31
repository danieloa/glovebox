#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
converge deploy_ready "$NS" catalog || fail "deployment catalog has no ready replicas"
img="$(rk -n "$NS" get pods -l app=catalog -o jsonpath='{.items[0].status.containerStatuses[0].image}' 2>/dev/null)"
[ -n "$img" ] || fail "no running container to inspect"
pass "catalog is Ready, running $img"
