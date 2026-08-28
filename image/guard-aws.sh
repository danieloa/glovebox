#!/usr/bin/env bash
# ==============================================================================
# guard-aws — operation allow-list in front of the AWS CLI v2.
#
# Same contract as guard-kubectl: accident-prevention, not a boundary. AWS gives
# you a real boundary for free and you should use it — assume a role whose
# policy is ReadOnlyAccess, or add an inline Deny on everything mutating, and
# then it does not matter what the CLI is asked to do. See docs/SECURITY.md.
#
# The policy here is prefix-based rather than a list of operations, because AWS
# has upwards of fifteen thousand of them and any hand-maintained list is wrong
# the week after you write it. Read-shaped verbs are enumerated; everything else
# is refused. That fails closed: a new API nobody has heard of is denied by
# default, which is the correct direction for a mistake to point.
# ==============================================================================
set -euo pipefail

REAL=/opt/ws/bin.real/aws
MODE="${WS_MODE:-ro}"

# ---- policy ------------------------------------------------------------------
# Prefixes on the operation name that indicate a read. `aws ec2 describe-
# instances` -> "describe". Anything not matching is treated as a write.
READ_PREFIXES="describe- get- list- lookup- search- scan- query- head- batch-get-
               select- test- validate- estimate- preview- simulate- filter-
               check- view- count- discover- detect- export- generate-credential-
               retrieve-"

# Whole operations that read but do not carry a read-shaped prefix.
READ_EXACT="ls help version wait sts-get-caller-identity"

# Services whose entire surface is refused outside rw, regardless of verb shape:
# these have operations that read like queries but move money or delete data.
# (`aws s3 sync` is a "read" by no reasonable prefix rule and can still wipe a
# bucket with --delete.)
GUARDED_SERVICES="s3"

service="${1:-}"
operation="${2:-}"

# ---- decision ----------------------------------------------------------------
allowed=0

# No args, or a help request: always fine.
case "$service" in ""|help|--version|version) allowed=1 ;; esac

if [ "$allowed" = 0 ]; then
  for p in $READ_PREFIXES; do
    case "$operation" in "$p"*) allowed=1; break ;; esac
  done
fi

if [ "$allowed" = 0 ]; then
  for e in $READ_EXACT; do
    [ "$operation" = "$e" ] && { allowed=1; break; }
  done
fi

# s3: only the listing verbs. `cp`/`mv`/`rm`/`sync`/`presign` are writes or
# exfiltration and none of them are needed to diagnose a cluster.
for g in $GUARDED_SERVICES; do
  if [ "$service" = "$g" ]; then
    case "$operation" in ls) allowed=1 ;; *) allowed=0 ;; esac
  fi
done

# `eks update-kubeconfig` writes only to the local kubeconfig file, never to
# AWS, and it is how you get a kubeconfig for an EKS cluster in the first place.
# Refusing it would make the AWS half of this image useless.
if [ "$service" = eks ] && [ "$operation" = update-kubeconfig ]; then allowed=1; fi

[ "$MODE" = rw ] && allowed=1

# ---- audit -------------------------------------------------------------------
if [ -n "${WS_AUDIT_LOG:-}" ]; then
  printf '%s  [%s] %s aws %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODE" \
    "$([ "$allowed" = 1 ] && echo RUN || echo DENY)" "$*" >> "$WS_AUDIT_LOG" 2>/dev/null || true
fi

if [ "$allowed" = 0 ]; then
  cat >&2 <<MSG
workstation: refusing 'aws $service $operation' — WS_MODE=$MODE is read-only.

  Allowed shapes: describe-*, get-*, list-*, scan, query, s3 ls,
                  sts get-caller-identity, eks update-kubeconfig.

  To override for one command:  WS_MODE=rw aws $service $operation ...
  Better: attach a ReadOnlyAccess role instead of trusting this wrapper.
MSG
  exit 77
fi

exec "$REAL" "$@"
