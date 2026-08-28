#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ==============================================================================
# guard-kubectl — verb allow-list in front of kubectl.
#
# Sits on PATH as /usr/local/bin/kubectl and forwards to the real binary at
# /opt/glovebox/bin.real/kubectl only if the requested verb is permitted by GB_MODE.
#
#   GB_MODE=ro     reads only. The default, and what `gb agent` runs under.
#   GB_MODE=probe  ro + exec / port-forward / debug / cp — no API object is
#                  mutated, but you can reach into a pod to curl a service or
#                  read a config file. This is where most real diagnosis lives.
#   GB_MODE=rw     everything. `gb shell` (a human is driving) and
#                  `gb agent --fix` (you asked for it, explicitly).
#
# WHAT THIS IS NOT: a security boundary. Whatever can run this script can also
# read $KUBECONFIG and speak to the API server over plain HTTPS without ever
# touching kubectl. This stops accidents and honest mistakes — a fat-fingered
# `delete`, a model that reached for `scale` when you asked it to diagnose. For
# an actual boundary, scope the credential: `gb scope` mints a read-only
# ServiceAccount kubeconfig that the API server itself enforces. See
# docs/SECURITY.md, which says all of this at more length and with fewer commas.
# ==============================================================================
set -euo pipefail

REAL=/opt/glovebox/bin.real/kubectl
MODE="${GB_MODE:-ro}"

# ---- policy ------------------------------------------------------------------
# Verbs that only read. `diff` is included deliberately: it does hit the API, but
# as a server-side dry-run that never persists — and it is the single most useful
# command for showing an interviewer what a fix WOULD change before you apply it.
READ_VERBS="get describe logs top explain events api-resources api-versions
            version cluster-info config diff wait auth completion krew kustomize
            alpha options"

# Verbs that reach into a running container without changing any API object.
PROBE_VERBS="exec port-forward proxy cp attach debug"

# ---- argument scan -----------------------------------------------------------
# The verb is the first argument that is not a global flag. Walking the argv
# instead of just reading $1 matters: `kubectl -n kube-system --context=foo
# delete pod x` puts the dangerous word in position 4, and a naive $1 check
# would wave it straight through.
verb=""
skip_next=0
for arg in "$@"; do
  if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
  case "$arg" in
    # Flags that take a separate value: consume the value too, so that
    # `--namespace delete` cannot smuggle a verb into the scan.
    -n|--namespace|--context|--cluster|--user|--kubeconfig|--as|--as-group|\
    -s|--server|--token|--request-timeout|--cache-dir|-o|--output)
      skip_next=1; continue ;;
    --*|-*) continue ;;          # --flag=value and short flags: not the verb
    *) verb="$arg"; break ;;
  esac
done

# ---- impersonation -----------------------------------------------------------
# --as / --as-group escalate to another identity, which sidesteps the entire
# point of running under a scoped credential. Refuse outside rw regardless of
# how harmless the verb looks.
if [ "$MODE" != rw ]; then
  for arg in "$@"; do
    case "$arg" in
      --as|--as=*|--as-group|--as-group=*)
        echo "glovebox: refusing --as/--as-group in GB_MODE=$MODE (impersonation)" >&2
        exit 77 ;;
    esac
  done
fi

# ---- decision ----------------------------------------------------------------
allowed=0
case " $READ_VERBS " in *" $verb "*) allowed=1 ;; esac

# `config` reads and writes; only the read-only subcommands pass outside rw.
# Without this, `kubectl config set-credentials` would count as a "read".
if [ "$verb" = config ] && [ "$MODE" != rw ]; then
  sub=""
  seen=0
  for arg in "$@"; do
    [ "$arg" = config ] && { seen=1; continue; }
    [ "$seen" = 1 ] && case "$arg" in -*) continue ;; *) sub="$arg"; break ;; esac
  done
  case "$sub" in
    view|get-contexts|current-context|get-clusters|get-users|"") allowed=1 ;;
    *) allowed=0 ;;
  esac
fi

# `rollout` is mixed: status/history report, restart/undo/pause mutate.
if [ "$verb" = rollout ]; then
  sub=""
  seen=0
  for arg in "$@"; do
    [ "$arg" = rollout ] && { seen=1; continue; }
    [ "$seen" = 1 ] && case "$arg" in -*) continue ;; *) sub="$arg"; break ;; esac
  done
  case "$sub" in status|history) allowed=1 ;; esac
fi

if [ "$allowed" = 0 ] && [ "$MODE" = probe ]; then
  case " $PROBE_VERBS " in *" $verb "*) allowed=1 ;; esac
fi

[ "$MODE" = rw ] && allowed=1
[ -z "$verb" ] && allowed=1          # bare `kubectl` prints help; harmless

# ---- audit -------------------------------------------------------------------
# Every invocation is appended to the transcript when one is configured, allowed
# or not. In an assessment you hand this in; in an interview you scroll it. A
# refusal is at least as interesting as a success, so both are logged.
if [ -n "${GB_AUDIT_LOG:-}" ]; then
  printf '%s  [%s] %s kubectl %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODE" \
    "$([ "$allowed" = 1 ] && echo RUN || echo DENY)" "$*" >> "$GB_AUDIT_LOG" 2>/dev/null || true
fi

if [ "$allowed" = 0 ]; then
  cat >&2 <<MSG
glovebox: refusing 'kubectl $verb' — GB_MODE=$MODE is read-only.

  This cluster probably belongs to someone else. If you meant it:
    gb shell --rw ...        (human at the keyboard)
    gb agent --fix "..."     (agent may propose and apply changes)

  Or, inside this shell, for one command:
    GB_MODE=rw kubectl $verb ...
MSG
  exit 77
fi

exec "$REAL" "$@"
