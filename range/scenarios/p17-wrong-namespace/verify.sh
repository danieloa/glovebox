#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
PROD=p17-prod
rk get namespace "$PROD" >/dev/null 2>&1 || fail "namespace $PROD no longer exists"
converge ep_atleast "$PROD" orders 1 || fail "svc/orders in $PROD still has no ready endpoints — production is still serving nothing"
svc_reachable "$PROD" orders 80 || fail "svc/orders in $PROD has endpoints but does not serve"
pass "production ($PROD) now has orders running behind its Service"
