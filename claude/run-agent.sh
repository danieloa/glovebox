#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ==============================================================================
# run-agent.sh — hand the cluster to Claude, under a mode.
#
# Invoked as `ws agent "..."` from the host, or `ws-diagnose "..."` from inside
# the container's shell. With no prompt it opens an interactive Claude session
# with the same guards in place.
#
# The design in one line: THE CONTAINER IS THE SANDBOX, and the guard shims are
# the policy inside it — so the agent runs without per-command prompting (there
# is nobody to prompt in a `-p` run) and enforcement happens at exec time, where
# it cannot be talked out of. Read docs/SECURITY.md for what that does and does
# not buy you.
# ==============================================================================
set -euo pipefail

MODE="${WS_MODE:-probe}"
SETTINGS="/opt/ws/claude/settings.${MODE}.json"
[ -f "$SETTINGS" ] || SETTINGS="/opt/ws/claude/settings.ro.json"

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  cat >&2 <<'MSG'
workstation: no ANTHROPIC_API_KEY in the environment.

  export ANTHROPIC_API_KEY=sk-ant-...      on the HOST, then re-run ./ws
  (the key is passed through at run time and is never written to an image layer)
MSG
  exit 1
fi

# The transcript is the deliverable. An assessment write-up reconstructed from
# memory is worse than one reconstructed from a log of every command that ran,
# and in an interview the log is the thing that proves the agent did what you
# said it did.
export WS_AUDIT_LOG="${WS_AUDIT_LOG:-/work/ws-audit-$(date -u +%Y%m%dT%H%M%SZ).log}"
touch "$WS_AUDIT_LOG" 2>/dev/null || true

# Give the model the operating instructions plus the live facts it would
# otherwise burn three tool calls discovering.
CONTEXT="$(cat /opt/ws/claude/AGENT.md)

## This session
- WS_MODE=$MODE
- kubeconfig: ${KUBECONFIG:-none}
- context: $(kubectl config current-context 2>/dev/null || echo unknown)
- api server: $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo unknown)
- transcript: $WS_AUDIT_LOG
- toolkit: /opt/ws/toolkit/*.sh are already sourced in your shell; run \`kt-help\`.
"

if [ "$MODE" = rw ]; then
  printf '\033[1;31m'
  cat <<'MSG'
  ┌────────────────────────────────────────────────────────────┐
  │  WS_MODE=rw — the agent may MODIFY this cluster.           │
  └────────────────────────────────────────────────────────────┘
MSG
  printf '\033[0m'
  printf '  context: \033[1m%s\033[0m\n\n' "$(kubectl config current-context 2>/dev/null)"
fi

cd /work

if [ $# -eq 0 ]; then
  # Interactive: the human is present, so permission prompts are useful again
  # and there is no reason to bypass them.
  exec claude --settings "$SETTINGS" --append-system-prompt "$CONTEXT" --add-dir /work
fi

exec claude -p "$*" \
  --settings "$SETTINGS" \
  --append-system-prompt "$CONTEXT" \
  --permission-mode bypassPermissions \
  --add-dir /work
