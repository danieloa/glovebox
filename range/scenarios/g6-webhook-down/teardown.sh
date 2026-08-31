#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk delete validatingwebhookconfiguration gb-range-policy-guard --ignore-not-found >/dev/null 2>&1 || true
