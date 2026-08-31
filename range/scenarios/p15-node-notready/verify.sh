#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
all_nodes_ready() { [ -z "$(rk get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{print $1}')" ]; }
# A kubelet that has just been started takes ~40s to be believed again.
converge all_nodes_ready \
  || fail "still not Ready: $(rk get nodes --no-headers | awk '$2!="Ready"{print $1}' | tr '\n' ' ')"
n="$(rk get nodes --no-headers | wc -l | tr -d ' ')"
[ "$n" -eq 3 ] || fail "the cluster should have 3 nodes, it has $n — deleting the node object is not the same as fixing it"
sched="$(rk get node "$(cat "$GB_HOME/p15.node" 2>/dev/null)" -o jsonpath='{.spec.unschedulable}' 2>/dev/null || true)"
[ "$sched" != true ] || fail "the node is Ready but still cordoned — nothing will schedule onto it until you uncordon"
converge deploy_ready "$NS" ledger || fail "the ledger deployment does not have both replicas ready"
pass "all 3 nodes Ready and schedulable, ledger back to full strength"
