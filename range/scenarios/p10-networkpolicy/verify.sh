#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
converge ep_atleast "$NS" backend 1 || fail "svc/backend has no ready endpoints"
n="$(rk -n "$NS" get netpol -o name 2>/dev/null | grep -c . | tr -d ' ')"
[ "${n:-0}" -gt 0 ] || fail "traffic may flow, but every NetworkPolicy in the namespace has been deleted — that removes the isolation the policy existed to provide rather than fixing the rule"
fe_reaches_be() { rk -n "$NS" exec deploy/frontend -- wget -q -T 5 -O- http://backend/ >/dev/null 2>&1; }
converge fe_reaches_be || fail "a request from the frontend pod to svc/backend is still being dropped"
pass "frontend reaches backend, and the namespace is still governed by $n NetworkPolicy object(s)"
