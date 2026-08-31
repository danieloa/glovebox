#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
converge ep_any "$NS" inventory || fail "layer 1: svc/inventory still selects no pods — zero endpoint addresses"
converge ep_atleast "$NS" inventory 2 || fail "layer 1: fewer than 2 ready endpoints"
svc_reachable "$NS" inventory 80 \
  || fail "layer 2: the endpoints are ready, so the selector is fixed — and traffic through the Service still does not arrive. There is a second fault under the first."
pass "svc/inventory selects both pods and traffic actually reaches the application"
