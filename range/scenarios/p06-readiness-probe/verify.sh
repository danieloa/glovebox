#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
converge deploy_ready "$NS" web || fail "web still has fewer ready replicas than it wants"
p="$(rk -n "$NS" get deploy web -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' 2>/dev/null)"
[ -n "$p" ] || fail "the pods are Ready because the readiness probe was deleted. That makes the symptom go away by removing the health check — the Service will now send traffic to pods that are not serving."
converge ep_atleast "$NS" web 2 || fail "the Service still has fewer than 2 ready endpoints"
svc_reachable "$NS" web 80 || fail "endpoints are ready but an HTTP GET through the Service still fails"
pass "both pods Ready, 2 endpoints, and traffic flows through svc/web"
