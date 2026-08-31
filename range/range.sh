#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ==============================================================================
# range.sh — the practice range. Reached as `gb range ...`.
#
# Plants one deliberate fault at a time in a throwaway kind cluster, shows you
# only the symptom, and grades your fix by observing the cluster rather than by
# diffing it against an answer key.
#
# The design in one line: this is the inverse of the rest of glovebox. The
# toolkit answers "what is broken"; the range asks it.
# ==============================================================================
set -euo pipefail

export GB_RANGE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$GB_RANGE_LIB"

GB_ROOT="$(cd "$RANGE_ROOT/.." && pwd)"
mkdir -p "$GB_HOME"

# ------------------------------------------------------------------------------
# scenario metadata
# ------------------------------------------------------------------------------

# meta.env is sourced shell, not YAML, for one reason: the runner is host-side
# bash and `yq` is not something you can assume on a laptop the morning of an
# interview. A five-line dependency-free parser that is wrong about quoting is
# worse than a sourced file whose contents are already executed anyway.
scenario_ids() { ls -1 "$SCENARIOS" 2>/dev/null | sort; }

load_meta() {
  local id="$1"
  [ -d "$SCENARIOS/$id" ] || die "no such scenario: $id  (try: gb range list)"
  TITLE=""; TIER=""; CATEGORY=""; SOURCE=""; BUDGET=""; EXAM=""; SYMPTOM=""; NEEDS=""
  # shellcheck disable=SC1090
  . "$SCENARIOS/$id/meta.env"
  ID="$id"
  NS="$id"
  export ID NS
}

tier_colour() {
  case "$1" in
    ns)      printf '\033[0;32m%-7s\033[0m' "$1" ;;
    cluster) printf '\033[0;33m%-7s\033[0m' "$1" ;;
    node)    printf '\033[0;31m%-7s\033[0m' "$1" ;;
    *)       printf '%-7s' "$1" ;;
  esac
}

# ------------------------------------------------------------------------------
# state — which scenarios are armed, and since when
#
# Tab-separated: id, epoch when it was injected, mode (practice|exam). Kept on
# disk rather than inferred from the cluster because "what was I working on" has
# to survive closing the laptop, and because exam mode needs a start time it can
# trust.
# ------------------------------------------------------------------------------
state_add()    { printf '%s\t%s\t%s\n' "$1" "$(date +%s)" "${2:-practice}" >> "$RANGE_STATE"; }
state_remove() { [ -f "$RANGE_STATE" ] || return 0
                 # awk rather than a grep pattern containing a literal tab: an
                 # editor that helpfully converts tabs to spaces would turn that
                 # into a silent no-op, and teardown would stop clearing state.
                 awk -F'\t' -v i="$1" '$1!=i' "$RANGE_STATE" > "$RANGE_STATE.tmp" || true
                 mv "$RANGE_STATE.tmp" "$RANGE_STATE"; }
state_ids()    { [ -f "$RANGE_STATE" ] && cut -f1 "$RANGE_STATE" || true; }
state_started(){ [ -f "$RANGE_STATE" ] && awk -F'\t' -v i="$1" '$1==i{print $2}' "$RANGE_STATE" | head -1 || true; }
state_mode()   { [ -f "$RANGE_STATE" ] && awk -F'\t' -v i="$1" '$1==i{print $3}' "$RANGE_STATE" | head -1 || true; }
state_active() { state_ids | grep -qx "$1"; }

elapsed_of() {
  local st; st="$(state_started "$1")"
  [ -n "$st" ] || { echo "-"; return; }
  local d=$(( $(date +%s) - st ))
  printf '%dm%02ds' $((d/60)) $((d%60))
}

# ------------------------------------------------------------------------------
# the cluster
# ------------------------------------------------------------------------------
cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$RANGE_CLUSTER"; }

cluster_up() {
  command -v kind    >/dev/null || die "kind is required: https://kind.sigs.k8s.io"
  command -v kubectl >/dev/null || die "kubectl is required on the host"
  command -v docker  >/dev/null || die "docker is required"

  if ! cluster_exists; then
    c_info "creating the range cluster '$RANGE_CLUSTER' (1 control plane, 2 workers — a couple of minutes)"
    kind create cluster --config "$RANGE_ROOT/kind-cluster.yaml" --kubeconfig "$RANGE_KUBECONFIG" >&2
  fi
  # Refresh both kubeconfigs every time: kind reassigns the host port when a
  # cluster is recreated, and a stale port is a confusing way to fail.
  kind get kubeconfig --name "$RANGE_CLUSTER" > "$RANGE_KUBECONFIG"
  chmod 600 "$RANGE_KUBECONFIG"
  mkdir -p "$RANGE_BUNDLE"
  # The bundle kubeconfig is the --internal one: it names the control plane by
  # its address on the kind docker network, which is what a container joined to
  # that network can reach. The host one points at loopback. Same cluster, two
  # vantage points, and mixing them up is a five-minute confusion.
  if [ ! -f "$RANGE_BUNDLE/kubeconfig" ] || [ "${1:-}" = --refresh-bundle ]; then
    kind get kubeconfig --name "$RANGE_CLUSTER" --internal > "$RANGE_BUNDLE/kubeconfig"
    chmod 600 "$RANGE_BUNDLE/kubeconfig"
  fi

  # The marker. range_guard refuses to break any cluster that does not carry it.
  rk -n kube-system create configmap gb-range-marker \
     --from-literal=created="$(date -u +%FT%TZ)" \
     --from-literal=warning="this cluster is a glovebox practice range and gets deliberately broken" \
     --dry-run=client -o yaml 2>/dev/null | rk apply -f - >/dev/null
}

# ------------------------------------------------------------------------------
# verbs
# ------------------------------------------------------------------------------

cmd_list() {
  local want_tier="${1:-}"
  printf '\n    \033[1m%-22s %-7s %-13s %-5s %s\033[0m\n' ID TIER CATEGORY '~MIN' TITLE
  printf '  %s\n' "$(printf '─%.0s' $(seq 1 110))"
  local id
  for id in $(scenario_ids); do
    load_meta "$id"
    [ -n "$want_tier" ] && [ "$TIER" != "$want_tier" ] && continue
    local mark=" "; state_active "$id" && mark="●"
    printf '  %s %-22s %s %-13s %-5s %s\n' "$mark" "$id" "$(tier_colour "$TIER")" "$CATEGORY" "$BUDGET" "$TITLE"
  done
  cat <<'LEGEND'

  ● = currently armed        tiers:
                               ns       one namespace. Teardown deletes it. Always safe.
                               cluster  touches kube-system or a node object. Reversible.
                               node     docker exec into a node — stops the kubelet, edits a
                                        static-pod manifest. Breaks the cluster on purpose.

  gb range up <id>     arm one          gb range check    grade what is armed
  gb range hint <id>   a nudge          gb range solve    the full answer
  gb range exam [n]    n at once, timed gb range down     put it back
LEGEND
}

cmd_up() {
  local mode=practice ids=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --exam) mode=exam ;;
      random) ids+=("$(scenario_ids | while read -r i; do load_meta "$i"; [ "$EXAM" = true ] && echo "$i"; done | sort -R | head -1)") ;;
      -*) die "unknown flag $1" ;;
      *)  ids+=("$1") ;;
    esac
    shift
  done
  [ "${#ids[@]}" -gt 0 ] || die "which scenario? try: gb range list"

  cluster_up
  range_guard

  local id
  for id in "${ids[@]}"; do
    load_meta "$id"
    state_active "$id" && { c_warn "$id is already armed — skipping"; continue; }
    [ "$TIER" = node ] && c_warn "$id is a node-tier fault: it breaks the cluster itself, not just a namespace"
    c_info "arming $id  (${BUDGET} min budget, tier=$TIER)"
    GB_RANGE_LIB="$GB_RANGE_LIB" bash "$SCENARIOS/$id/inject.sh" || die "inject failed for $id"
    state_add "$id" "$mode"
  done

  echo
  for id in "${ids[@]}"; do show_symptom "$id"; done
  cat <<EOF
  Work it in the container:   ./gb range shell
  Grade it:                   ./gb range check
  Stuck:                      ./gb range hint ${ids[0]}

EOF
}

show_symptom() {
  load_meta "$1"
  printf '\033[1;36m  ┌─ %s\033[0m\n' "$ID"
  printf '\033[1m  │  %s\033[0m\n' "$TITLE"
  printf '  │\n'
  printf '%s\n' "$SYMPTOM" | sed 's/^/  │  /'
  printf '  └─ namespace: %s   budget: %s min\n\n' "$NS" "$BUDGET"
}

cmd_status() {
  local ids; ids="$(state_ids)"
  [ -n "$ids" ] || { c_info "nothing armed. gb range up <id>"; return; }
  printf '\n  \033[1mARMED                  ELAPSED   MODE      TITLE\033[0m\n'
  printf '  %s\n' "$(printf '─%.0s' $(seq 1 78))"
  local id
  for id in $ids; do
    load_meta "$id"
    printf '  %-22s %-9s %-9s %s\n' "$id" "$(elapsed_of "$id")" "$(state_mode "$id")" "$TITLE"
  done
  echo
}

cmd_check() {
  local ids="${1:-}"
  [ -n "$ids" ] || ids="$(state_ids)"
  [ -n "$ids" ] || { c_info "nothing armed to check"; return 0; }
  range_guard
  local id passn=0 failn=0
  echo
  for id in $ids; do
    load_meta "$id"
    printf '  \033[1m%-22s\033[0m %s\n' "$id" "$TITLE"
    if GB_RANGE_LIB="$GB_RANGE_LIB" bash "$SCENARIOS/$id/verify.sh"; then
      passn=$((passn+1))
      printf '         %s elapsed, %s min budget\n' "$(elapsed_of "$id")" "$BUDGET"
    else
      failn=$((failn+1))
    fi
    echo
  done
  printf '  \033[1m%d passed, %d still broken\033[0m\n\n' "$passn" "$failn"
  [ "$failn" -eq 0 ] || return 1
}

cmd_hint() {
  local id="${1:-}" level="${2:-}"
  [ -n "$id" ] || { local a; a="$(state_ids | head -1)"; id="$a"; }
  [ -n "$id" ] || die "which scenario?"
  load_meta "$id"
  # Hints are a ladder, not a page: the file is split on '## ' headings and only
  # the level you asked for is printed. Reading the answer by accident while
  # looking for a nudge is the one way a hint file can actively harm practice.
  local n="${level:-1}"
  awk -v want="$n" '
    /^## /{ lvl++; next }
    lvl==want { print "  " $0 }
  ' "$SCENARIOS/$id/hints.md"
  local max; max="$(grep -c '^## ' "$SCENARIOS/$id/hints.md")"
  if [ "$n" -lt "$max" ]; then
    c_dim "  (more: gb range hint $id $((n+1))  —  full answer: gb range solve $id)"
  fi
}

cmd_solve() {
  local id="${1:-}"
  [ -n "$id" ] || id="$(state_ids | head -1)"
  [ -n "$id" ] || die "which scenario?"
  load_meta "$id"
  c_warn "  ── $id: the answer ──"
  local max; max="$(grep -c '^## ' "$SCENARIOS/$id/hints.md")"
  cmd_hint "$id" "$max"
}

cmd_down() {
  local ids="${1:-}"
  if [ "$ids" = --cluster ]; then
    cluster_exists && kind delete cluster --name "$RANGE_CLUSTER"
    rm -f "$RANGE_STATE" "$RANGE_KUBECONFIG"
    rm -rf "$RANGE_BUNDLE"
    c_ok "range cluster deleted"
    return
  fi
  [ -n "$ids" ] || ids="$(state_ids)"
  [ -n "$ids" ] || { c_info "nothing armed"; return; }
  range_guard
  local id
  for id in $ids; do
    load_meta "$id"
    c_info "tearing down $id"
    if [ -x "$SCENARIOS/$id/teardown.sh" ] || [ -f "$SCENARIOS/$id/teardown.sh" ]; then
      GB_RANGE_LIB="$GB_RANGE_LIB" bash "$SCENARIOS/$id/teardown.sh" || c_warn "teardown reported a problem for $id"
    fi
    rk delete namespace "$NS" --wait=false --ignore-not-found >/dev/null 2>&1 || true
    state_remove "$id"
  done
  c_ok "done — the cluster stays up for the next one (gb range down --cluster to remove it)"
}

# ------------------------------------------------------------------------------
# exam — n faults at once, a clock, and no hints unless you ask
#
# This is the mode that matches the actual exercise. A single fault at a time
# teaches the mechanism; several at once teach the thing people actually fail,
# which is triage order under a clock. Only scenarios marked EXAM=true are
# eligible: a fault that takes cluster DNS or all writes down would not be a
# harder exam, it would be an exam where the other four questions are unreadable.
# ------------------------------------------------------------------------------
cmd_exam() {
  local n="${1:-4}"
  [ -n "$(state_ids)" ] && die "something is still armed — gb range down first"
  cluster_up
  range_guard
  local pool picked
  pool="$(for i in $(scenario_ids); do load_meta "$i"; [ "$EXAM" = true ] && echo "$i"; done)"
  picked="$(echo "$pool" | sort -R | head -"$n")"
  c_warn "── EXAM: $n faults, injected together. The clock starts when the last one lands. ──"
  local id
  for id in $picked; do
    load_meta "$id"
    c_info "arming $id"
    GB_RANGE_LIB="$GB_RANGE_LIB" bash "$SCENARIOS/$id/inject.sh" >/dev/null || die "inject failed for $id"
  done
  # Timed from here, not from the first inject: waiting for images to pull is
  # not part of anybody's diagnostic skill.
  for id in $picked; do state_add "$id" exam; done
  echo
  c_warn "  You are told nothing else. Start with kt-triage."
  echo
  printf '  Scenarios armed: %s\n' "$(echo "$picked" | tr '\n' ' ')"
  printf '  Total budget:    %s min\n\n' "$(for id in $picked; do load_meta "$id"; echo "$BUDGET"; done | paste -sd+ - | bc 2>/dev/null || echo '?')"
  echo "  ./gb range shell      then: kt-triage"
  echo "  ./gb range check      grade everything at once"
  echo
}

cmd_shell() {
  cluster_exists || die "no range cluster — gb range up <id> first"
  [ -f "$RANGE_BUNDLE/kubeconfig" ] || die "no range bundle — gb range up <id> first"
  c_info "range bundle: $RANGE_BUNDLE  (joined to the kind network so the container can reach the cluster)"
  # --rw because you are here to fix things. The range is the one cluster in
  # this repo where write mode is the correct default, and saying that out loud
  # is better than having someone discover probe mode blocks their fix.
  GB_DOCKER_ARGS="--network kind ${GB_DOCKER_ARGS:-}" "$GB_ROOT/gb" shell "$RANGE_BUNDLE" --rw
}

cmd_agent() {
  cluster_exists || die "no range cluster — gb range up <id> first"
  GB_DOCKER_ARGS="--network kind ${GB_DOCKER_ARGS:-}" "$GB_ROOT/gb" agent --bundle "$RANGE_BUNDLE" "$@"
}

usage() {
  cat <<'USAGE'
  gb range — a Kubernetes break/fix practice range.

    gb range list [tier]        the scenario library
    gb range up <id>            arm one fault (creates the cluster on first use)
    gb range up random          arm one at random
    gb range shell              a glovebox shell pointed at the range, in --rw
    gb range agent "..."        the agent, pointed at the range
    gb range check [id]         grade it — by observing the cluster, not diffing YAML
    gb range hint <id> [1-3]    a ladder: nudge, then where to look, then the answer
    gb range solve <id>         skip to the answer
    gb range status             what is armed and for how long
    gb range down [id]          put it back
    gb range down --cluster     delete the range cluster entirely
    gb range exam [n]           n faults at once, timed. This is the real thing.

  The range NEVER reads ~/.kube/config. It has its own kubeconfig, for its own
  kind cluster, and refuses to touch anything that is not it. See range_guard()
  in range/lib.sh for the five checks and why there is no --force.
USAGE
}

cmd="${1:-help}"; shift 2>/dev/null || true
case "$cmd" in
  list)   cmd_list "$@" ;;
  up|arm) cmd_up "$@" ;;
  status) cmd_status ;;
  check|grade) cmd_check "$@" ;;
  hint)   cmd_hint "$@" ;;
  solve|answer) cmd_solve "$@" ;;
  down|reset) cmd_down "$@" ;;
  exam)   cmd_exam "$@" ;;
  shell)  cmd_shell ;;
  agent)  cmd_agent "$@" ;;
  symptom) show_symptom "${1:?which scenario}" ;;
  help|-h|--help) usage ;;
  *) die "unknown range command '$cmd' — try: gb range help" ;;
esac
