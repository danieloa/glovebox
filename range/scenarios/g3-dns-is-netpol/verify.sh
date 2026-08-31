#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
n="$(rk -n "$NS" get netpol -o name 2>/dev/null | grep -c . | tr -d ' ')"
[ "${n:-0}" -gt 0 ] || fail "resolution may work, but the egress policy has been deleted rather than corrected — the namespace has lost its egress isolation entirely"
resolves() { rk -n "$NS" exec deploy/worker -- nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; }
converge resolves || fail "pods in $NS still cannot resolve cluster names"
pass "resolution works from inside $NS, and the namespace is still governed by $n egress policy object(s)"
