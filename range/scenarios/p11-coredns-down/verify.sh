#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
converge deploy_ready kube-system coredns || fail "the coredns deployment still has no ready replicas"
converge ep_atleast kube-system kube-dns 1 || fail "svc/kube-dns still has no ready endpoints"
dns_works "$NS" kubernetes.default.svc.cluster.local \
  || fail "coredns looks healthy but a lookup from inside a pod still fails — resolution is the test, not pod status"
pass "coredns is serving and an in-cluster lookup resolves"
