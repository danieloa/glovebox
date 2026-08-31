#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
r="$(rk -n "$NS" get deploy notifications -o jsonpath='{.spec.replicas}' 2>/dev/null)"
[ "${r:-0}" -ge 3 ] || fail "deploy/notifications is scaled to ${r:-0} — it was running 3 before the incident"
converge deploy_ready "$NS" notifications || fail "not all $r replicas are ready yet"
paused="$(rk -n "$NS" get deploy notifications -o jsonpath='{.spec.paused}' 2>/dev/null)"
[ "$paused" != true ] || fail "it is serving, but the deployment is still paused — the next change to this deployment will silently not roll out. Leaving it paused is half a fix."
svc_reachable "$NS" notifications 80 || fail "pods are ready but svc/notifications does not serve"
pass "notifications is back to $r replicas, unpaused, and serving"
