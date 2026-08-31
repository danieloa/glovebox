#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
for n in $(rk get nodes -o name | sed 's|node/||'); do
  rk taint node "$n" gb-range/maintenance- >/dev/null 2>&1 || true
done
