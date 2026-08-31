#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
converge deploy_ready "$NS" checkout || fail "deployment checkout is not fully ready (readyReplicas != replicas, or replicas is 0)"
# Ready once is not the same as ready. A container that crashes every 40s spends
# most of its life Running, so the honest test is whether the restart count is
# still moving.
converge stable_for "$NS" app=checkout 45 \
  || fail "the restart count is still rising — checkout is up right now and still crashing"
pass "checkout is Ready and its restart count has stopped moving"
