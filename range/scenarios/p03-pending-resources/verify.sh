#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
converge deploy_ready "$NS" reports || fail "deployment reports still has no ready replica"
node="$(rk -n "$NS" get pods -l app=reports -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)"
[ -n "$node" ] || fail "the pod still has no node assigned — it has not been scheduled"
# A request the node can satisfy is the fix; deleting the requests entirely is
# not, because a workload with no requests is unschedulable in a different and
# more subtle way later. Insist a request is still declared.
req="$(rk -n "$NS" get deploy reports -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}' 2>/dev/null)"
[ -n "$req" ] || fail "the pod schedules, but resources.requests.memory is now unset — a workload with no request is a scheduling and eviction problem waiting to happen"
pass "reports scheduled onto $node with a request of $req"
