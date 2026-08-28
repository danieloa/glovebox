#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ==============================================================================
# entrypoint.sh — prepare /work from the read-only bundle, then hand off.
#
# The bundle (kubeconfig, ssh keys, task description, manifests) is mounted at
# /bundle READ-ONLY. Three reasons everything is copied to /work first:
#
#   * kubectl writes to the kubeconfig — it stamps the current context and
#     caches discovery data — and fails confusingly on a read-only file.
#   * ssh refuses a private key with group/world-readable permissions, and you
#     cannot chmod a file on a read-only mount.
#   * you will never accidentally modify the artifacts the interviewer sent you,
#     which is exactly the kind of small thing that gets noticed.
#
# Modes:  shell | agent | exec <cmd...>
# ==============================================================================
set -euo pipefail

BUNDLE=/bundle
WORK=/work

hr()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m%s\033[0m\n' "$*" >&2; }

# ------------------------------------------------------------------------------
# stage_bundle — copy credentials out of the read-only mount, by shape not name.
#
# Discovery is by content and extension rather than a fixed filename list,
# because every company names these differently: kubeconfig, config, kube.conf,
# admin.conf, cluster.yaml. Guessing wrong means an empty shell and two minutes
# of confusion at the exact moment you can least afford it.
# ------------------------------------------------------------------------------
stage_bundle() {
  [ -d "$BUNDLE" ] || { warn "no /bundle mounted — cluster tools will have no credentials"; return 0; }

  mkdir -p "$WORK"
  # Copy the whole bundle so task.md, manifests and notes come along too. -L
  # dereferences symlinks: a bundle full of links pointing at the host would be
  # useless inside the container.
  cp -RL "$BUNDLE/." "$WORK/" 2>/dev/null || true

  # --- kubeconfig ---
  # Prefer an explicit name; otherwise take the first YAML that actually looks
  # like a kubeconfig (has both `clusters:` and `contexts:` keys).
  local kc=""
  for cand in kubeconfig config kube.conf admin.conf kubeconfig.yaml; do
    [ -f "$WORK/$cand" ] && { kc="$WORK/$cand"; break; }
  done
  if [ -z "$kc" ]; then
    for f in "$WORK"/*.yaml "$WORK"/*.yml "$WORK"/*.conf; do
      [ -f "$f" ] || continue
      if grep -q '^clusters:' "$f" 2>/dev/null && grep -q '^contexts:' "$f" 2>/dev/null; then
        kc="$f"; break
      fi
    done
  fi
  if [ -n "$kc" ]; then
    [ "$kc" = "$WORK/kubeconfig" ] || cp "$kc" "$WORK/kubeconfig"
    chmod 600 "$WORK/kubeconfig"
    export KUBECONFIG="$WORK/kubeconfig"
  fi

  # --- ssh keys ---
  # Any PEM-headed file, whatever it is called. 0600 or ssh will not touch it.
  for f in "$WORK"/*; do
    [ -f "$f" ] || continue
    if head -c 40 "$f" 2>/dev/null | grep -q 'BEGIN .*PRIVATE KEY'; then
      chmod 600 "$f"
      [ -z "${WS_SSH_KEY:-}" ] && export WS_SSH_KEY="$f"
    fi
  done

  # --- aws credentials ---
  # If the bundle ships a credentials file, wire it up rather than making the
  # user discover that AWS_SHARED_CREDENTIALS_FILE exists.
  if [ -f "$WORK/credentials" ]; then
    chmod 600 "$WORK/credentials"
    export AWS_SHARED_CREDENTIALS_FILE="$WORK/credentials"
  fi
}

# ------------------------------------------------------------------------------
# banner — what is mounted, who you are, and what mode you are in.
#
# Printed before every session because the single most expensive mistake with
# this tool would be running a fix against the wrong cluster. The context name
# and server URL go at the top for that reason alone.
# ------------------------------------------------------------------------------
banner() {
  hr "┌──────────────────────────────────────────────────────────────┐"
  hr "│  workstation — disposable SRE troubleshooting container      │"
  hr "└──────────────────────────────────────────────────────────────┘"
  local mode="${WS_MODE:-ro}" desc
  case "$mode" in
    ro)    desc="read-only (mutating kubectl/aws verbs are refused)" ;;
    probe) desc="read + exec/port-forward (no API object is modified)" ;;
    rw)    desc="READ-WRITE — this shell can change the cluster" ;;
    *)     desc="unknown" ;;
  esac
  printf '  mode      : %s — %s\n' "$mode" "$desc"

  if [ -f "${KUBECONFIG:-/nonexistent}" ]; then
    local ctx srv
    ctx="$(kubectl config current-context 2>/dev/null || echo '(none)')"
    srv="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
    printf '  context   : %s\n' "$ctx"
    printf '  api server: %s\n' "${srv:-(unknown)}"
  else
    warn "  kubeconfig: NOT FOUND in /bundle"
  fi

  [ -n "${ANTHROPIC_API_KEY:-}" ] \
    && printf '  agent     : available — try `ws-diagnose` or `claude`\n' \
    || printf '  agent     : no ANTHROPIC_API_KEY passed (tools still work)\n'
  [ -n "${WS_AUDIT_LOG:-}" ] && printf '  transcript: %s\n' "$WS_AUDIT_LOG"
  echo
  printf '  start with: \033[1mkt-triage\033[0m   (whole-stack overview)   |   \033[1mkt-help\033[0m\n'
  echo
}

stage_bundle

case "${1:-shell}" in
  shell)
    banner
    # --rcfile is used instead of relying on ~/.bashrc so that the exported
    # KUBECONFIG / WS_SSH_KEY computed above survive into the interactive shell:
    # bash would otherwise re-read .bashrc in a fresh environment.
    exec bash --rcfile <(
      cat /home/sre/.bashrc
      echo "export KUBECONFIG='${KUBECONFIG:-}' WS_SSH_KEY='${WS_SSH_KEY:-}'"
      echo "export AWS_SHARED_CREDENTIALS_FILE='${AWS_SHARED_CREDENTIALS_FILE:-}'"
    )
    ;;
  agent)
    shift
    exec /opt/ws/claude/run-agent.sh "$@"
    ;;
  exec)
    shift
    exec "$@"
    ;;
  *)
    exec "$@"
    ;;
esac
