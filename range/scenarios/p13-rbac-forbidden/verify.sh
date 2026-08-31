#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
sa="system:serviceaccount:$NS:watcher"
rk auth can-i list pods --as="$sa" -n "$NS" 2>/dev/null | grep -qx yes \
  || fail "$sa still cannot list pods in $NS"
# Least privilege is part of the fix, not a nicety: cluster-admin also makes
# the 403 go away, and would be a finding in any review of the change.
if rk auth can-i delete pods --as="$sa" -A 2>/dev/null | grep -qx yes; then
  fail "$sa can now list pods — but it can also delete pods cluster-wide. That is a grant far wider than the app needs; scope it to a Role in this namespace with get/list/watch."
fi
if rk auth can-i '*' '*' --as="$sa" -A 2>/dev/null | grep -qx yes; then
  fail "$sa was granted cluster-admin. It works, and it is the wrong fix."
fi
pass "$sa can list pods in $NS and nothing wider"
