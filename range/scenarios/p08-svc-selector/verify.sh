#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
converge ep_any "$NS" payments || fail "svc/payments still selects no pods at all — zero endpoint addresses"
converge ep_atleast "$NS" payments 2 || fail "svc/payments has endpoints but fewer than 2 are ready"
svc_reachable "$NS" payments 80 || fail "endpoints are ready but an HTTP GET through svc/payments still fails"
pass "svc/payments selects both pods and traffic flows"
