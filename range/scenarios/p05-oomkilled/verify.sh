#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
converge deploy_ready "$NS" resizer || fail "resizer has no ready replica"
pod="$(rk -n "$NS" get pods -l app=resizer -o name | head -1 | sed 's|pod/||')"
[ -n "$pod" ] || fail "no resizer pod"
reason="$(rk -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null)"
[ "$reason" = OOMKilled ] && fail "the current pod has already been OOMKilled once — the limit is still below what this workload needs"
# The workload must still be doing its job. Raising the limit is the fix;
# deleting the work the container does is not, and it would pass a check that
# only looked at whether the pod was up.
sz="$(rk -n "$NS" exec "$pod" -c app -- sh -c 'wc -c < /scratch/frame' 2>/dev/null | tr -d ' \r')"
[ -n "$sz" ] && [ "$sz" -ge 268435456 ] 2>/dev/null \
  || fail "the pod is up but has not buffered its 256MB frame (found: ${sz:-nothing}) — it must still do its work, not have the work removed"
lim="$(rk -n "$NS" get deploy resizer -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}')"
pass "resizer buffered its full 256MB frame under a limit of ${lim:-<none>}, with no OOM kill"
