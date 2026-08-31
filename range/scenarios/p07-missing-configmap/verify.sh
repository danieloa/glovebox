#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
converge deploy_ready "$NS" billing || fail "billing still has no ready replica"
pod="$(rk -n "$NS" get pods -l app=billing -o name | head -1 | sed 's|pod/||')"
val="$(rk -n "$NS" exec "$pod" -c app -- sh -c 'echo "$APP_MODE"' 2>/dev/null | tr -d '\r')"
[ -n "$val" ] || fail "the container is up but APP_MODE is empty — the config it needs is still not reaching it"
src="$(rk -n "$NS" get deploy billing -o jsonpath='{.spec.template.spec.containers[0].env[0].valueFrom.configMapKeyRef.name}' 2>/dev/null)"
[ -n "$src" ] || fail "APP_MODE is set, but the value was hardcoded into the pod spec rather than coming from a ConfigMap — that is a different deployment, not a fixed one"
pass "billing is Ready with APP_MODE=$val, sourced from configmap/$src"
