#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
converge ep_atleast "$NS" api 2 || fail "svc/api has fewer than 2 ready endpoints"
# The outcome, not the method: patching targetPort and reconfiguring the app to
# listen on 80 are both legitimate fixes, and asserting on targetPort==8080
# would fail the second one.
svc_reachable "$NS" api 80 || fail "an HTTP GET to http://api:80/ from inside the namespace still fails"
pass "traffic reaches the application through svc/api on port 80"
