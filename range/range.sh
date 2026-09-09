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

# resolve_id — accept either name for a scenario.
#
# The namespace is no longer the id, and in exam mode the namespace is the only
# name you are ever shown. So everything that takes a scenario also takes its
# namespace: `gb range hint scenario-p18` has to work, because during an exam
# `p18-scaled-to-zero` is a string you are not supposed to have.
resolve_id() {
  local a="$1" i
  [ -d "$SCENARIOS/$a" ] && { printf '%s' "$a"; return; }
  for i in $(scenario_ids); do
    [ "$(scenario_ns "$i")" = "$a" ] && { printf '%s' "$i"; return; }
  done
  printf '%s' "$a"   # unknown — let load_meta produce the error
}

load_meta() {
  local id; id="$(resolve_id "$1")"
  [ -d "$SCENARIOS/$id" ] || die "no such scenario: $1  (try: gb range list)"
  TITLE=""; TIER=""; CATEGORY=""; SOURCE=""; BUDGET=""; EXAM=""; SYMPTOM=""; NEEDS=""
  # shellcheck disable=SC1090
  . "$SCENARIOS/$id/meta.env"
  ID="$id"
  NS="$(scenario_ns "$id")"
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
  printf '\n    \033[1m%-22s %-14s %-7s %-13s %-5s %s\033[0m\n' ID NAMESPACE TIER CATEGORY '~MIN' TITLE
  printf '  %s\n' "$(printf '─%.0s' $(seq 1 124))"
  local id
  for id in $(scenario_ids); do
    load_meta "$id"
    [ -n "$want_tier" ] && [ "$TIER" != "$want_tier" ] && continue
    local mark=" "; state_active "$id" && mark="●"
    printf '  %s %-22s %-14s %s %-13s %-5s %s\n' "$mark" "$id" "$NS" "$(tier_colour "$TIER")" "$CATEGORY" "$BUDGET" "$TITLE"
  done
  cat <<'LEGEND'

  ● = currently armed        tiers:
                               ns       one namespace. Teardown deletes it. Always safe.
                               cluster  touches kube-system or a node object. Reversible.
                               node     docker exec into a node — stops the kubelet, edits a
                                        static-pod manifest. Breaks the cluster on purpose.

  This list is the library, so it names the fault. What you get while working a
  scenario is the namespace and the brief — never the id.

  gb range up <id>     arm one          gb range check    grade what is armed
  gb range brief       re-read a ticket gb range solve    the full answer
  gb range hint <id>   a nudge          gb range down     put it back
  gb range exam [n]    n at once, timed
LEGEND
}

cmd_up() {
  # reveal: whether the title may be printed alongside the brief. You typed
  # `up p09-svc-targetport`, so the title tells you nothing you did not just
  # say. `up random` and `up --exam` are the cases where it would.
  local mode=practice reveal=--reveal ids=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --exam) mode=exam; reveal= ;;
      random) reveal=
              ids+=("$(scenario_ids | while read -r i; do load_meta "$i"; [ "$EXAM" = true ] && echo "$i"; done | sort -R | head -1)") ;;
      -*) die "unknown flag $1" ;;
      *)  ids+=("$1") ;;
    esac
    shift
  done
  [ "${#ids[@]}" -gt 0 ] || die "which scenario? try: gb range list"

  cluster_up
  range_guard

  local id first_ns=""
  for id in "${ids[@]}"; do
    load_meta "$id"
    [ -z "$first_ns" ] && first_ns="$NS"
    state_active "$ID" && { c_warn "$NS is already armed — skipping"; continue; }
    [ "$TIER" = node ] && c_warn "$NS is a node-tier fault: it breaks the cluster itself, not just a namespace"
    c_info "arming $NS  (${BUDGET} min budget)"
    GB_RANGE_LIB="$GB_RANGE_LIB" bash "$SCENARIOS/$ID/inject.sh" || die "inject failed for $ID"
    state_add "$ID" "$mode"
  done

  write_briefs
  echo
  # shellcheck disable=SC2086  # $reveal is a flag-or-nothing, deliberately split
  for id in "${ids[@]}"; do show_brief "$id" $reveal; done
  cat <<EOF
  Work it in the container:   ./gb range shell     (the brief is at /work/BRIEF.md)
  Re-read the brief:          ./gb range brief
  Grade it:                   ./gb range check
  Stuck:                      ./gb range hint $first_ns

EOF
}

# ------------------------------------------------------------------------------
# the brief — the problem statement, and the only thing you are handed
#
# Before this, arming a scenario gave you a namespace and nothing else, which is
# both too little and far too much: no caller-visible symptom, no "what has
# already been ruled out", and a namespace that names the answer. A real
# exercise hands you a ticket. SYMPTOM is that ticket — deliberately written as
# what someone reports and what they already checked, never as a diagnosis.
#
# The title is a separate thing and is usually a spoiler ("GOTCHA: the Service
# is two faults, not one"), so it is printed only when you named the scenario
# yourself.
# ------------------------------------------------------------------------------
show_brief() {
  load_meta "$1"
  printf '\033[1;36m  ┌─ TICKET  %s\033[0m\n' "$NS"
  [ "${2:-}" = --reveal ] && printf '\033[1m  │  %s\033[0m\n' "$TITLE"
  printf '  │\n'
  printf '%s\n' "$SYMPTOM" | sed 's/^/  │  /'
  printf '  │\n'
  printf '  └─ namespace: %s   budget: %s min\n\n' "$NS" "$BUDGET"
}

# write_briefs — the same tickets, as a file inside the bundle.
#
# The bundle is mounted read-only at /bundle and staged into /work, which is
# where a real assessment's task description would live. Putting the brief there
# means you can re-read it without leaving the container mid-exam, and it is one
# more place the scenario id does not appear.
write_briefs() {
  local ids; ids="$(state_ids)"
  mkdir -p "$RANGE_BUNDLE" 2>/dev/null || true
  if [ -z "$ids" ]; then rm -f "$RANGE_BUNDLE/BRIEF.md"; return 0; fi
  local id
  {
    echo "# Open incidents"
    echo
    echo 'One section per ticket. Grade your work from the host with `gb range check`.'
    echo
    for id in $ids; do
      load_meta "$id"
      echo "## $NS"
      echo
      if [ "$(state_mode "$id")" != exam ]; then echo "**$TITLE**"; echo; fi
      echo "$SYMPTOM"
      echo
      echo "_Budget: ${BUDGET} min. Namespace: \`$NS\`._"
      echo
    done
  } > "$RANGE_BUNDLE/BRIEF.md"
}

cmd_brief() {
  local ids="$*"
  [ -n "$ids" ] || ids="$(state_ids)"
  [ -n "$ids" ] || { c_info "nothing armed. gb range up <id>"; return; }
  echo
  local id
  for id in $ids; do
    load_meta "$id"
    if [ "$(state_mode "$ID")" = exam ]; then show_brief "$ID"; else show_brief "$ID" --reveal; fi
  done
}

cmd_status() {
  local ids; ids="$(state_ids)"
  [ -n "$ids" ] || { c_info "nothing armed. gb range up <id>"; return; }
  printf '\n  \033[1mNAMESPACE        ELAPSED   MODE      TITLE\033[0m\n'
  printf '  %s\n' "$(printf '─%.0s' $(seq 1 78))"
  local id mode label
  for id in $ids; do
    load_meta "$id"
    mode="$(state_mode "$id")"
    # In exam mode the title is a spoiler and the id is the answer, so neither
    # is printed. `gb range brief` re-reads what you were actually given.
    label="$TITLE"
    [ "$mode" = exam ] && label="$(printf '\033[2m(brief only — gb range brief)\033[0m')"
    printf '  %-16s %-9s %-9s %s\n' "$NS" "$(elapsed_of "$id")" "$mode" "$label"
  done
  echo
}

cmd_check() {
  local ids="${1:-}"
  [ -n "$ids" ] || ids="$(state_ids)"
  [ -n "$ids" ] || { c_info "nothing armed to check"; return 0; }
  range_guard
  local id passn=0 failn=0 mode
  echo
  for id in $ids; do
    load_meta "$id"
    mode="$(state_mode "$ID")"
    # Under exam conditions the header is the namespace only: printing the
    # title of a scenario you have not solved yet turns `check` into a hint.
    if [ "$mode" = exam ]; then
      printf '  \033[1m%-16s\033[0m\n' "$NS"
    else
      printf '  \033[1m%-16s\033[0m %s\n' "$NS" "$TITLE"
    fi
    if GB_RANGE_LIB="$GB_RANGE_LIB" bash "$SCENARIOS/$ID/verify.sh"; then
      passn=$((passn+1))
      printf '         %s elapsed, %s min budget\n' "$(elapsed_of "$ID")" "$BUDGET"
      # Solved, so there is nothing left to give away: name it.
      [ "$mode" = exam ] && c_dim "         $ID — $TITLE"
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
  ' "$SCENARIOS/$ID/hints.md"
  local max; max="$(grep -c '^## ' "$SCENARIOS/$ID/hints.md")"
  if [ "$n" -lt "$max" ]; then
    c_dim "  (more: gb range hint $NS $((n+1))  —  full answer: gb range solve $NS)"
  fi
}

cmd_solve() {
  local id="${1:-}"
  [ -n "$id" ] || id="$(state_ids | head -1)"
  [ -n "$id" ] || die "which scenario?"
  load_meta "$id"
  c_warn "  ── $NS ($ID): the answer ──"
  local max; max="$(grep -c '^## ' "$SCENARIOS/$ID/hints.md")"
  cmd_hint "$ID" "$max"
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
    c_info "tearing down $NS ($ID)"
    if [ -x "$SCENARIOS/$ID/teardown.sh" ] || [ -f "$SCENARIOS/$ID/teardown.sh" ]; then
      GB_RANGE_LIB="$GB_RANGE_LIB" bash "$SCENARIOS/$ID/teardown.sh" || c_warn "teardown reported a problem for $ID"
    fi
    rk delete namespace "$NS" --wait=false --ignore-not-found >/dev/null 2>&1 || true
    state_remove "$ID"
  done
  write_briefs
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
#
# It used to arm the faults and tell you nothing, on the theory that a blank
# cluster is the purest triage test. It is not — it is a different test. A real
# exercise opens with a ticket per incident: what a caller reported, what has
# already been ruled out, and no diagnosis. Withholding that does not measure
# triage, it measures whether you thought to run `kubectl get ns`. So the exam
# hands over every brief and withholds only the two things that would answer
# the question for you: the scenario id and its title.
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
    c_info "arming $NS"
    GB_RANGE_LIB="$GB_RANGE_LIB" bash "$SCENARIOS/$ID/inject.sh" >/dev/null || die "inject failed for $ID"
  done
  # Timed from here, not from the first inject: waiting for images to pull is
  # not part of anybody's diagnostic skill.
  for id in $picked; do state_add "$id" exam; done
  write_briefs
  echo
  c_warn "  Your tickets — one per incident, in no particular order:"
  echo
  for id in $picked; do show_brief "$id"; done
  printf '  Total budget:    %s min\n' "$(for id in $picked; do load_meta "$id"; echo "$BUDGET"; done | paste -sd+ - | bc 2>/dev/null || echo '?')"
  printf '  Namespaces:      %s\n\n' "$(for id in $picked; do load_meta "$id"; printf '%s ' "$NS"; done)"
  echo "  ./gb range shell      then: kt-triage   (the tickets are at /work/BRIEF.md)"
  echo "  ./gb range brief      re-read them from the host"
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
    gb range brief [id]         re-read the ticket(s) you were handed
    gb range shell              a glovebox shell pointed at the range, in --rw
    gb range agent "..."        the agent, pointed at the range
    gb range check [id]         grade it — by observing the cluster, not diffing YAML
    gb range hint <id> [1-3]    a ladder: nudge, then where to look, then the answer
    gb range solve <id>         skip to the answer
    gb range status             what is armed and for how long
    gb range down [id]          put it back
    gb range down --cluster     delete the range cluster entirely
    gb range exam [n]           n faults at once, timed. This is the real thing.

  Every verb that takes an <id> also takes the namespace it runs in, because in
  exam mode the namespace is the only name you have: `gb range hint scenario-p18`.
  Scenarios live in namespace scenario-<id>, which says which ticket you are on
  and nothing about what is wrong with it.

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
  brief|symptom|ticket) cmd_brief "$@" ;;
  help|-h|--help) usage ;;
  *) die "unknown range command '$cmd' — try: gb range help" ;;
esac
