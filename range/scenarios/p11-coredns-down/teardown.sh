#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
if [ -f "$GB_HOME/coredns.Corefile.bak" ]; then
  rk -n kube-system create configmap coredns --from-file=Corefile="$GB_HOME/coredns.Corefile.bak" \
     --dry-run=client -o yaml | rk apply -f - >/dev/null
  rm -f "$GB_HOME/coredns.Corefile.bak"
  rk -n kube-system rollout restart deploy/coredns >/dev/null 2>&1 || true
  rk -n kube-system rollout status deploy/coredns --timeout=120s >/dev/null 2>&1 || true
fi
