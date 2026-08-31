#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
api_up() { rk --request-timeout=8s get --raw /readyz >/dev/null 2>&1; }
# The kubelet notices the manifest change on its own, but not instantly, and a
# freshly-restarted api-server takes a moment to pass its own readiness.
converge api_up || fail "the API server still does not answer on :6443"
rk get nodes >/dev/null 2>&1 || fail "the API answers /readyz but cannot serve a node list"
apiserver_ready() { [ "$(rk -n kube-system get pods -l component=kube-apiserver --no-headers 2>/dev/null | awk '{print $2}' | head -1)" = "1/1" ]; }
converge apiserver_ready \
  || fail "kube-apiserver pod is $(rk -n kube-system get pods -l component=kube-apiserver --no-headers | awk '{print $2}' | head -1), not 1/1"
pass "the API server is back: /readyz answers and the static pod is 1/1"
