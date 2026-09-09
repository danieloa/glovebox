#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ==============================================================================
# range/lib.sh — the contract every scenario script is written against.
#
# Sourced by range.sh and, through GB_RANGE_LIB, by every inject.sh and
# verify.sh. Sourcing it is also the reason a scenario script cannot be run by
# hand: GB_RANGE_LIB is only set by the runner, so `./inject.sh` on its own dies
# before it can touch anything. That is deliberate — these scripts break
# clusters, and the only cluster they are ever allowed to break is the range.
#
# What a scenario script gets:
#
#   NS                  its own namespace (scenario_ns of the scenario id)
#   rk ...              kubectl, bound to the range kubeconfig and context
#   node_exec N cmd     run a command inside a kind node container
#   nodes_worker        list the worker node names
#   settle_pods NS N    wait for pods to stop being ContainerCreating
#   wait_until N cmd    poll cmd for N seconds, 0 if it ever succeeds
#   ep_ready NS SVC     count of READY endpoint addresses behind a Service
#   ep_total NS SVC     count of all endpoint addresses behind a Service
#   svc_reachable ...   does an HTTP GET through the Service actually work
#   dns_works NS NAME   does a lookup of NAME resolve from inside NS
#   pass / fail MSG     the verify.sh exit contract
# ==============================================================================

GB_HOME="${GB_HOME:-$HOME/.glovebox}"
RANGE_CLUSTER="${GB_RANGE_CLUSTER:-gb-range}"
RANGE_KUBECONFIG="$GB_HOME/range.kubeconfig"
RANGE_BUNDLE="$GB_HOME/range-bundle"
RANGE_STATE="$GB_HOME/range.state"
RANGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIOS="$RANGE_ROOT/scenarios"

# Images. Two, deliberately: every scenario reuses them so a range cluster pulls
# them once and every later `range up` is instant even on hotel wifi.
GB_IMG_BUSYBOX="${GB_IMG_BUSYBOX:-busybox:1.36}"
GB_IMG_NGINX="${GB_IMG_NGINX:-nginx:1.27-alpine}"

# ------------------------------------------------------------------------------
# scenario_ns — the namespace a scenario runs in.
#
# Deliberately NOT the scenario id. The id names the fault — p18-scaled-to-zero,
# g3-dns-is-netpol — and a namespace called that hands over the answer before
# the first kubectl. Nobody in a real exercise is told "the incident is in
# namespace scaled-to-zero". So the namespace is scenario-p18: enough to say
# which ticket you are on, and nothing about what is wrong with it.
#
# The letter is kept because the two pools behave differently on teardown and
# in the self-test, and because "scenario-18" and "scenario-g18" colliding on a
# renumber is a worse bug than the small amount it gives away.
#
# Lowercase and hyphenated because a namespace is a DNS-1123 label; scenarioP18
# is not a legal namespace name.
# ------------------------------------------------------------------------------
scenario_ns() { printf 'scenario-%s' "${1%%-*}"; }

c_red()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
c_ok()   { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_info() { printf '\033[1;36m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_dim()  { printf '\033[2m%s\033[0m\n' "$*"; }
die()    { c_red "!! $*"; exit 1; }

# ------------------------------------------------------------------------------
# range_guard — five independent reasons to believe this is the range cluster
# and not somebody's production.
#
# This is the load-bearing safety control of the whole feature, so it is worth
# being explicit about why there are five checks and not one. Every other verb
# in gb is read-only or asks first; `range up` is the only thing in this repo
# that deliberately breaks a cluster, and the failure mode — pointing it at a
# customer's context because that is what happened to be current — is not one
# you get to apologise your way out of. So:
#
#   1. the range has its OWN kubeconfig, at a fixed path. The range never reads
#      $KUBECONFIG or ~/.kube/config, so "whatever context is current" is not an
#      input to this program at all. This is the check that actually matters;
#      the other four are for the case where someone edits that file.
#   2. kind must agree it created a cluster of this name.
#   3. the context inside that kubeconfig must be the one kind writes.
#   4. the API server must be on loopback. No remote cluster reaches this far.
#   5. the cluster must carry a marker ConfigMap the range itself planted.
#
# There is no --force. If you are arguing with this function, the answer is that
# you are pointed at the wrong cluster.
# ------------------------------------------------------------------------------
range_guard() {
  [ -f "$RANGE_KUBECONFIG" ] || die "no range cluster yet — run: gb range up <scenario>"
  command -v kind    >/dev/null || die "kind is required for the range"
  command -v kubectl >/dev/null || die "kubectl is required on the host for the range"

  kind get clusters 2>/dev/null | grep -qx "$RANGE_CLUSTER" \
    || die "kind knows no cluster named '$RANGE_CLUSTER' — refusing to touch anything"

  local ctx server
  ctx="$(kubectl --kubeconfig "$RANGE_KUBECONFIG" config current-context 2>/dev/null || true)"
  [ "$ctx" = "kind-$RANGE_CLUSTER" ] \
    || die "range kubeconfig points at context '$ctx', expected 'kind-$RANGE_CLUSTER'"

  server="$(kubectl --kubeconfig "$RANGE_KUBECONFIG" config view --minify \
            -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  case "$server" in
    https://127.0.0.1:*|https://localhost:*|https://0.0.0.0:*|"https://[::1]:"*) ;;
    *) die "range API server is '$server' — the range only ever runs against loopback" ;;
  esac

  # Check 5 needs the API to answer, and one scenario (p16) deliberately stops
  # it answering. When the API is down, checks 1-4 have already established
  # provenance — kind made this cluster, under this name, on this laptop's
  # loopback — so the marker is skipped rather than deadlocking teardown of the
  # very scenario that broke it.
  if kubectl --kubeconfig "$RANGE_KUBECONFIG" --request-timeout=5s \
       get --raw /readyz >/dev/null 2>&1; then
    rk -n kube-system get configmap gb-range-marker >/dev/null 2>&1 \
      || die "cluster carries no gb-range marker — refusing to break a cluster the range did not create"
  fi
}

# kubectl, always against the range and nothing else.
rk() { kubectl --kubeconfig "$RANGE_KUBECONFIG" --context "kind-$RANGE_CLUSTER" \
               --request-timeout="${RK_TIMEOUT:-20s}" "$@"; }

# rk_quiet — for the many places where "did that object exist" is the question
# and kubectl's NotFound text on stderr is just noise.
rk_quiet() { rk "$@" 2>/dev/null; }

# ------------------------------------------------------------------------------
# node_exec — run a command inside a kind node's container.
#
# The node-tier scenarios (a stopped kubelet, a corrupted static-pod manifest)
# cannot be expressed as API objects; they live on the node filesystem, which is
# exactly why they are the ones people fail. Reaching them means docker exec.
#
# The label check is the same argument as range_guard: `docker exec` into a
# container whose name you guessed is a bad habit to build, so the container has
# to prove kind made it, for THIS cluster, before anything runs in it.
# ------------------------------------------------------------------------------
node_exec() {
  local node="$1"; shift
  local owner
  owner="$(docker inspect -f '{{index .Config.Labels "io.x-k8s.kind.cluster"}}' "$node" 2>/dev/null || true)"
  [ "$owner" = "$RANGE_CLUSTER" ] \
    || die "container '$node' is not a node of kind cluster '$RANGE_CLUSTER' (owner: ${owner:-none})"
  docker exec "$node" sh -c "$*"
}

nodes_worker() { rk get nodes -o name --no-headers 2>/dev/null \
                 | sed 's|node/||' | grep -v control-plane || true; }
node_any_worker() { nodes_worker | head -1; }

# ------------------------------------------------------------------------------
# waiting
# ------------------------------------------------------------------------------

# wait_until <seconds> <command...> — poll until it works, 0 as soon as it does.
#
# Deadline-based, against the clock, rather than counting iterations and assuming
# each costs a second. Some of the things handed to this take 45 seconds to
# answer — stable_for watches a window; svc_reachable runs a pod — and an
# iteration counter would turn "wait up to 60 seconds" into fifty minutes without
# anything looking wrong.
wait_until() {
  local secs="$1"; shift
  local deadline=$(( $(date +%s) + secs ))
  while :; do
    "$@" >/dev/null 2>&1 && return 0
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 1
  done
}

# settle_pods <ns> [seconds] — wait for the namespace to stop being in motion.
# Applying a manifest is not the same as the cluster having reacted to it: an
# ImagePullBackOff needs a pull attempt and a back-off, a CrashLoopBackOff needs
# several restarts. Scenarios that depend on a specific back-off state wait for
# that state by name; this is the generic "nothing is still ContainerCreating".
settle_pods() {
  local ns="$1" secs="${2:-45}" i=0
  while [ "$i" -lt "$secs" ]; do
    local st; st="$(rk -n "$ns" get pods --no-headers 2>/dev/null | awk '{print $3}')"
    if [ -n "$st" ] && ! grep -qE 'ContainerCreating|PodInitializing|Terminating' <<<"$st"; then return 0; fi
    sleep 2; i=$((i+2))
  done
  return 0
}

# wait_state <ns> <substring> [seconds] — wait for any pod to reach a state.
wait_state() {
  local ns="$1" want="$2" secs="${3:-120}" i=0
  while [ "$i" -lt "$secs" ]; do
    rk -n "$ns" get pods --no-headers 2>/dev/null | awk '{print $3}' | grep -q "$want" && return 0
    sleep 3; i=$((i+3))
  done
  return 1
}

# ------------------------------------------------------------------------------
# observations — the vocabulary verify.sh is written in
#
# EndpointSlices rather than the legacy Endpoints object: Endpoints is deprecated
# from 1.33 and truncates above 1000 addresses, and the toolkit's own kt-net
# reads slices, so the range and the tool it trains you on agree about what a
# working Service looks like.
# ------------------------------------------------------------------------------
_ep_json() { rk -n "$1" get endpointslice -l "kubernetes.io/service-name=$2" \
                -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' 2>/dev/null; }
ep_total() { _ep_json "$1" "$2" | grep -c . || true; }
ep_ready() { _ep_json "$1" "$2" | grep -cx true || true; }

# ------------------------------------------------------------------------------
# converge — give a correct fix time to become true.
#
# Kubernetes is eventually consistent, and a verify that samples the instant
# after a correct edit routinely sees the state from before it: patch a Service
# selector and the EndpointSlice controller needs a moment, raise a memory limit
# and the ReplicaSet needs to roll. Grading a single sample marks correct work
# FAIL and teaches the trainee to distrust the grader, which is worse than no
# grader. So every observation that depends on a controller reacting is given a
# window, and only a state that never arrives is a failure.
#
# The window is generous on purpose: a verify that takes 20 extra seconds costs
# nothing, and a false FAIL costs the exercise.
# ------------------------------------------------------------------------------
GB_CONVERGE="${GB_CONVERGE:-120}"
converge() { wait_until "$GB_CONVERGE" "$@"; }

# Predicate forms, so they can be handed to converge.
ep_atleast() { [ "$(ep_ready "$1" "$2")" -ge "$3" ]; }
ep_any()     { [ "$(ep_total "$1" "$2")" -gt 0 ]; }

# deploy_ready <ns> <name> — .status.readyReplicas == .spec.replicas, and > 0.
deploy_ready() {
  local r s
  r="$(rk_quiet -n "$1" get deploy "$2" -o jsonpath='{.status.readyReplicas}')"
  s="$(rk_quiet -n "$1" get deploy "$2" -o jsonpath='{.spec.replicas}')"
  [ -n "$s" ] && [ "${r:-0}" -gt 0 ] && [ "${r:-0}" = "$s" ]
}

# stable_for <ns> <label-selector> [seconds] — every pod's container has been
# running continuously for at least this long.
#
# The obvious test — "the restart count did not move over 15 seconds" — is wrong
# in BOTH directions, and I had it wrong in both before writing this down.
#
#   Too strict: during the rollout a fix triggers, the old crash-looping pod and
#   its replacement are both listed. "pod-a=5 pod-b=0" then "pod-b=0" compares
#   unequal, and a correct fix is graded FAIL.
#
#   Too lenient: CrashLoopBackOff backs off exponentially, up to five minutes. A
#   container that is still very much crashing sits perfectly still inside any
#   short window, so an unfixed cluster is graded PASS — which is the worse of
#   the two, because the trainee never finds out.
#
# Elapsed running time cannot be gamed by either. The signature pins the pod
# name, its restart count AND the timestamp the current container started; if it
# restarts, all three move. An unchanged signature across the window proves it
# ran for the whole window, and a non-empty startedAt proves it is running right
# now rather than waiting inside a back-off.
_STABLE_JP='{range .items[*]}{.metadata.name}|{.status.containerStatuses[0].restartCount}|{.status.containerStatuses[0].state.running.startedAt}{"\n"}{end}'

stable_for() {
  local ns="$1" sel="$2" secs="${3:-45}"
  local a b pods running
  a="$(rk -n "$ns" get pods -l "$sel" -o jsonpath="$_STABLE_JP" 2>/dev/null | grep '|' || true)"
  pods="$(printf '%s\n' "$a" | grep -c '|' || true)"
  [ "${pods:-0}" -gt 0 ] || return 1
  # A line ending in "|" has an empty startedAt — that container is not running
  # right now, it is waiting inside a back-off. Requiring at least one character
  # after the final pipe is what distinguishes the two.
  running="$(printf '%s\n' "$a" | grep -c '|[^|][^|]*$' || true)"
  [ "${running:-0}" = "${pods:-0}" ] || return 1
  sleep "$secs"
  b="$(rk -n "$ns" get pods -l "$sel" -o jsonpath="$_STABLE_JP" 2>/dev/null | grep '|' || true)"
  [ "$a" = "$b" ]
}

# ------------------------------------------------------------------------------
# wait_cluster_healthy [seconds] — the cluster has actually recovered, not merely
# started answering.
#
# /readyz returning is the API server's opinion of itself. After a control-plane
# outage or a node coming back from NotReady, kube-proxy still has service rules
# to reprogram and CoreDNS has endpoints to relearn, and for a minute afterwards
# Services resolve but do not answer. The node-tier teardowns wait for this,
# because otherwise the next scenario inherits a half-recovered cluster and
# presents symptoms that belong to the previous one — which is exactly how p17
# and p18 came to fail in a suite run and pass on their own.
# ------------------------------------------------------------------------------
_nodes_all_ready() {
  local out; out="$(rk get nodes --no-headers 2>/dev/null)"
  [ -n "$out" ] && [ -z "$(printf '%s\n' "$out" | awk '$2!="Ready"{print $1}')" ]
}
_kube_system_settled() {
  rk -n kube-system get pods --no-headers 2>/dev/null \
    | awk 'BEGIN{n=0;bad=0} {n++; split($2,a,"/"); if ($3!="Completed" && a[1]!=a[2]) bad++}
           END{exit !(n>0 && bad==0)}'
}
wait_cluster_healthy() {
  local secs="${1:-240}"
  wait_until "$secs" _nodes_all_ready      || { c_warn "    nodes did not all return Ready"; return 1; }
  wait_until "$secs" _kube_system_settled  || { c_warn "    kube-system did not settle"; return 1; }
  wait_until "$secs" ep_atleast kube-system kube-dns 1 \
                                           || { c_warn "    kube-dns has no ready endpoints"; return 1; }
  return 0
}

# probe_pod <ns> <sh-command> — run a throwaway busybox in the namespace and
# echo its stdout. In the namespace, not a neutral one, because the NetworkPolicy
# scenarios are only honest if the prober is subject to the same policies as the
# workload it is standing in for.
probe_pod() {
  local ns="$1"; shift
  local name="gb-probe-$$-$RANDOM"
  rk -n "$ns" run "$name" --restart=Never --image="$GB_IMG_BUSYBOX" \
     --labels=app=gb-probe --command -- sh -c "$*" >/dev/null 2>&1 || true
  # Poll to completion rather than `run -i --attach`: attach races the container
  # start and silently loses the output of a fast-exiting pod, which would make
  # every probe read as a failure.
  #
  # The window is 120s, not 60. A probe pod has to be scheduled, pulled and run
  # before it can say anything, and on a node that is busy — which is exactly
  # the state a cluster is in right after the fix being graded rolled out — that
  # is not always quick. A probe that times out returns empty, empty reads as
  # FAIL, and the trainee is told their correct fix did not work.
  local i=0 phase=""
  while [ "$i" -lt 120 ]; do
    phase="$(rk_quiet -n "$ns" get pod "$name" -o jsonpath='{.status.phase}')"
    case "$phase" in Succeeded|Failed) break ;; esac
    sleep 2; i=$((i+2))
  done
  case "$phase" in
    Succeeded|Failed) rk_quiet -n "$ns" logs "$name" ;;
    # Never ran. Say so on stderr rather than returning an empty string that the
    # caller cannot distinguish from "the request failed" — a probe that could
    # not run is a different fact from a service that does not answer.
    *) c_dim "    (probe pod in $ns stuck in ${phase:-Pending} after 120s — this is the grader struggling, not necessarily your fix)" >&2 ;;
  esac
  rk -n "$ns" delete pod "$name" --wait=false --ignore-not-found >/dev/null 2>&1 || true
}

# svc_reachable <ns> <svc> <port> [path] — does traffic actually get through.
#
# Verifying the OUTCOME and not the method is the whole point: a targetPort
# scenario is fixed when an HTTP GET through the Service returns bytes, whether
# you patched the Service or changed the port the container listens on. Asserting
# on `.spec.ports[0].targetPort == 8080` would grade the answer key instead of
# the cluster, and would fail a fix that was better than the one I had in mind.
svc_reachable() {
  local ns="$1" svc="$2" port="${3:-80}" path="${4:-/}" try
  # Cheap check first: a Service with nothing ready behind it cannot answer, and
  # finding that out over the API costs one request instead of a whole pod.
  converge ep_atleast "$ns" "$svc" 1 || return 1
  for try in 1 2 3; do
    probe_pod "$ns" "wget -q -T 5 -O- 'http://$svc.$ns.svc.cluster.local:$port$path' >/dev/null 2>&1 && echo GBOK || echo GBFAIL" \
      | grep -q GBOK && return 0
    sleep 5
  done
  return 1
}

# netpol_denied <seconds> <command...> — the command must start FAILING within
# the window, proving the CNI actually enforces NetworkPolicy.
#
# A single sample is not enough and getting this wrong is expensive in both
# directions. Policy programming lags pod readiness by a few seconds on every
# CNI, so a check taken the instant a pod goes Ready sees traffic that will be
# blocked a moment later and wrongly concludes the CNI ignores policy. And a CNI
# that genuinely ignores policy would arm a fault the trainee can never observe —
# they would hunt through a working system until the clock ran out. Polling for
# the deny is the only honest way to tell "not programmed yet" from "never will
# be".
netpol_denied() {
  local secs="$1"; shift
  local i=0
  while [ "$i" -lt "$secs" ]; do
    "$@" >/dev/null 2>&1 || return 0
    sleep 3; i=$((i+3))
  done
  return 1
}

# dns_works <ns> <name> — resolution from inside the namespace.
dns_works() {
  local ns="$1" name="${2:-kubernetes.default.svc.cluster.local}"
  probe_pod "$ns" "nslookup '$name' >/dev/null 2>&1 && echo GBOK || echo GBFAIL" | grep -q GBOK
}

# ------------------------------------------------------------------------------
# the verify.sh exit contract
#
#   pass            exit 0 — genuinely fixed
#   fail "reason"   exit 1 — and say which OBSERVATION failed, never which edit
#                   is missing. "Service has 0 ready endpoints" is a fact about
#                   the cluster you could have found yourself; "you forgot to fix
#                   the selector" is the answer, and the answer lives in hints.
# ------------------------------------------------------------------------------
pass() { c_ok  "   PASS  ${1:-fixed and verified}"; exit 0; }
fail() { c_red "   FAIL  $1"; exit 1; }
