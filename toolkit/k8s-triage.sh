# SPDX-License-Identifier: Apache-2.0
# ==============================================================================
# k8s-triage.sh — layered triage verbs for an unfamiliar Kubernetes cluster.
#
# Descended from the toolkit I wrote for two platform-engineering take-homes,
# with every assessment-specific constant (namespace, ingress host, node IPs)
# replaced by discovery against the live cluster. Targets bash 4+ (the container's
# default shell); most verbs work under zsh too.
#
#     kt-env              point at the cluster and prove you can reach it
#     kt-triage           one screen of state across every layer
#     kt-why <pod>        why is this specific thing not running
#     kt-help             everything else
#
# DESIGN INTENT — worth stating because it explains every other choice in here:
#
#   * Read-only. Not one function writes to the cluster. Fixes are yours to
#     make, deliberately, after you have read the evidence. This is also what
#     makes the toolkit safe to hand to an agent.
#
#   * One word per layer. Each verb bundles the 3-6 commands you would otherwise
#     type one at a time, so a single word gets you the whole evidence set for
#     that layer instead of a half-remembered sequence under time pressure.
#
#   * Banners state an expectation, not a label — "NODES (want: all Ready)"
#     rather than "NODES". Under pressure you read output for a mismatch against
#     what should be there, and the header should tell you what that is.
#
#   * Bottom-up ordering, always: nodes -> workloads -> network -> ingress ->
#     TLS -> HTTP. A broken node explains a broken pod; a broken pod explains a
#     broken ingress; the reverse is never true. Fix in the order you read.
# ==============================================================================

# ---- configuration -----------------------------------------------------------
# Overridable, but every one of these auto-discovers when left unset. The
# original version of this file hardcoded a namespace and three node IPs; that
# worked for exactly one assessment and was useless for the next one.
: "${KT_NS:=}"                       # target namespace; kt-ns auto-detects
: "${KT_SSH_USER:=${WS_SSH_USER:-root}}"
: "${KT_SSH_KEY:=${WS_SSH_KEY:-}}"
: "${KT_TIMEOUT:=15s}"               # never let a wedged API server hang triage

# ==============================================================================
# INTERNAL HELPERS  (_kt_ prefix = not meant to be called directly)
# ==============================================================================

# _kt_hr <text> — labelled section divider.
# Three tables of kubectl output in a row look like one long table; this makes
# scrollback readable when you come back to write the incident up.
_kt_hr() { printf '\n\033[1;36m==== %s ====\033[0m\n' "$*"; }
_kt_note() { printf '\033[2m    %s\033[0m\n' "$*"; }
_kt_warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }

# _kt_k <args...> — the single choke point every cluster read goes through.
#
# Because ~100 call sites funnel here, the behaviour of the whole toolkit can be
# changed on one line. The request timeout is the reason it exists by default: a
# partially-failed control plane will otherwise hang `kubectl get` forever, and
# you will conclude the network is down when in fact one apiserver is wedged.
_kt_k() { kubectl --request-timeout="$KT_TIMEOUT" "$@"; }

# _kt_ns — resolve the namespace to operate on, in priority order:
#   1. explicit argument                      (kt-app payments)
#   2. $KT_NS, set by a previous `kt-ns`
#   3. the kubeconfig's own default namespace
#   4. the namespace containing the most unhealthy pods — the one you almost
#      certainly came here for
_kt_ns() {
  if [ -n "$1" ]; then echo "$1"; return; fi
  if [ -n "$KT_NS" ]; then echo "$KT_NS"; return; fi
  local ns
  ns="$(_kt_k config view --minify -o jsonpath='{..namespace}' 2>/dev/null)"
  [ -n "$ns" ] && [ "$ns" != default ] && { echo "$ns"; return; }
  ns="$(_kt_k get pods -A --no-headers 2>/dev/null \
        | awk '$4!="Running" && $4!="Completed" && $4!="Succeeded" {print $1}' \
        | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')"
  echo "${ns:-default}"
}

# _kt_pods_bad — every pod in the cluster that is not in a healthy steady state.
# The awk covers both halves of "unhealthy": a bad phase (CrashLoopBackOff,
# Pending, ImagePullBackOff) and a Running pod whose ready count is short of its
# container count (2/3), which prints as "Running" and is easy to scroll past.
_kt_pods_bad() {
  _kt_k get pods -A --no-headers 2>/dev/null | awk '
    {
      split($3, r, "/")
      if ($4 != "Running" && $4 != "Completed" && $4 != "Succeeded") print
      else if (r[1] != r[2]) print
    }'
}

# ==============================================================================
# ORIENTATION
# ==============================================================================

# ------------------------------------------------------------------------------
# kt-env — make the shell ready to talk to the cluster, and prove it.
#
# Run this first; everything else assumes it has. `cluster-info` succeeding
# WITHOUT --insecure-skip-tls-verify also confirms the API server certificate
# verifies, which rules out "my kubectl is misconfigured" before you start
# attributing failures to the cluster. That distinction is worth ten minutes.
# ------------------------------------------------------------------------------
kt-env() {
  export KUBECONFIG="${KUBECONFIG:-/work/kubeconfig}"
  [ -n "$KT_SSH_KEY" ] && [ -f "$KT_SSH_KEY" ] && chmod 600 "$KT_SSH_KEY"
  _kt_hr "IDENTITY"
  printf '    KUBECONFIG   %s\n' "$KUBECONFIG"
  printf '    context      %s\n' "$(_kt_k config current-context 2>/dev/null || echo '(none)')"
  printf '    server       %s\n' "$(_kt_k config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
  printf '    client       %s\n' "$(_kt_k version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion 2>/dev/null)"
  _kt_hr "REACHABILITY"
  _kt_k cluster-info 2>&1 | head -n 4
  _kt_hr "WHO AM I (drives what you can even see)"
  # Knowing your own permissions up front prevents the classic wasted twenty
  # minutes where an empty `get pods` looks like an empty cluster but is really
  # an RBAC denial being reported as "No resources found".
  _kt_k auth whoami 2>/dev/null || _kt_note "auth whoami unsupported on this server"
  printf '    cluster-admin? %s\n' "$(_kt_k auth can-i '*' '*' --all-namespaces 2>/dev/null)"
}

# ------------------------------------------------------------------------------
# kt-ns [namespace] — set (or auto-detect) the namespace the other verbs target.
#
# With no argument it picks the namespace with the most unhealthy pods, which in
# an assessment is essentially always the one you were sent to look at.
# ------------------------------------------------------------------------------
kt-ns() {
  if [ -n "$1" ]; then
    export KT_NS="$1"
  else
    export KT_NS="$(KT_NS= _kt_ns)"
    _kt_note "auto-detected from unhealthy pod distribution"
  fi
  echo "KT_NS=$KT_NS"
  _kt_k get ns "$KT_NS" 2>/dev/null
}

# ------------------------------------------------------------------------------
# kt-triage — the intended first move: every layer, one screen, no changes.
#
# The ordering is the point. With several independent faults — and assessments
# are always built with several — a fix applied mid-diagnosis changes the
# evidence for the others, and you end up unable to say which change caused
# which improvement. Read the whole board before touching anything.
# ------------------------------------------------------------------------------
kt-triage() {
  local ns; ns="$(_kt_ns "$1")"

  _kt_hr "NODES (want: all Ready, no pressure taints)"
  _kt_k get nodes -o wide 2>&1

  _kt_hr "UNHEALTHY PODS, WHOLE CLUSTER (want: none)"
  local bad; bad="$(_kt_pods_bad)"
  if [ -z "$bad" ]; then
    _kt_note "none — every pod is Running/Completed with all containers ready"
  else
    # kubectl's own header is reused rather than hand-written, so the columns
    # line up whatever kubectl decides the widths should be. Deliberately NOT
    # piped through `column -t`: awk preserves kubectl's original spacing, and
    # re-tabulating splits fields that legitimately contain spaces
    # ("6 (3m38s ago)") across two columns.
    { _kt_k get pods -A 2>/dev/null | head -1; echo "$bad"; }
  fi

  _kt_hr "WORKLOADS in ns/$ns"
  _kt_k -n "$ns" get deploy,sts,ds,rs,pods -o wide 2>&1 | head -40

  _kt_hr "SERVICES + ENDPOINTS in ns/$ns (want: every svc has endpoints)"
  # A Service with no endpoints is the most common "the app is down but the pods
  # are fine" cause: a selector that matches nothing. It is invisible in
  # `get pods` and obvious here.
  _kt_k -n "$ns" get svc 2>/dev/null
  _kt_k -n "$ns" get endpoints 2>/dev/null

  _kt_hr "INGRESS"
  _kt_k -n "$ns" get ingress 2>/dev/null
  _kt_k get ingressclass 2>/dev/null

  _kt_hr "CERTIFICATES (cert-manager; want Ready=True)"
  _kt_k -n "$ns" get certificate,certificaterequest,order,challenge 2>/dev/null \
    || _kt_note "no cert-manager CRDs on this cluster"

  _kt_hr "STORAGE (want: no Pending PVCs)"
  _kt_k get pvc -A 2>/dev/null | grep -v Bound || _kt_note "all PVCs Bound"

  _kt_hr "RECENT WARNINGS (last 15, cluster-wide)"
  _kt_k get events -A --field-selector type=Warning \
    --sort-by=.lastTimestamp 2>/dev/null | tail -n 15

  echo
  _kt_note "next: kt-why <pod>  |  kt-nodes  |  kt-net  |  kt-ingress  |  kt-help"
}

# ==============================================================================
# LAYER A — NODES AND KUBELET
# ==============================================================================

# ------------------------------------------------------------------------------
# kt-nodes — which node is unhealthy, and crucially WHICH KIND of unhealthy.
#
# The Ready condition's status and its reason are printed side by side because
# the distinction drives everything that follows:
#
#   Ready=False    the kubelet is alive and reporting a problem. Look at the
#                  node's other conditions — disk / memory / PID pressure, CNI
#                  not ready. You can often fix this through the API.
#   Ready=Unknown  the control plane has stopped hearing from the node at all
#                  (reason NodeStatusUnknown, plus an `unreachable` taint). The
#                  kubelet or the network path to it is dead. Nothing you do
#                  through the API will fix it — go to the node. kt-ssh.
#
# Taints are shown too, since they are the reason pods will not schedule there.
# ------------------------------------------------------------------------------
kt-nodes() {
  _kt_hr "Node overview"
  _kt_k get nodes -o wide
  _kt_hr "Ready status + reason + taints"
  _kt_k get nodes -o custom-columns=\
'NAME:.metadata.name,'\
'READY:.status.conditions[?(@.type=="Ready")].status,'\
'REASON:.status.conditions[?(@.type=="Ready")].reason,'\
'KUBELET:.status.nodeInfo.kubeletVersion,'\
'TAINTS:.spec.taints[*].key'

  _kt_hr "Pressure conditions (want: all False)"
  _kt_k get nodes -o custom-columns=\
'NAME:.metadata.name,'\
'MEM:.status.conditions[?(@.type=="MemoryPressure")].status,'\
'DISK:.status.conditions[?(@.type=="DiskPressure")].status,'\
'PID:.status.conditions[?(@.type=="PIDPressure")].status'

  # Auto-describe anything not Ready and show only the Conditions block: the
  # full describe is 200 lines and the answer is always in those 12.
  local n
  for n in $(_kt_k get nodes -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready")].status!="True")]}{.metadata.name} {end}' 2>/dev/null); do
    _kt_hr "NOT READY: $n — conditions"
    _kt_k describe node "$n" | sed -n '/^Conditions:/,/^Addresses:/p'
    _kt_warn "if REASON is NodeStatusUnknown the API cannot help — try: kt-ssh $n"
  done
}

# ------------------------------------------------------------------------------
# kt-node <name> — everything about one node, including what it is actually running.
# ------------------------------------------------------------------------------
kt-node() {
  local n="$1"; [ -z "$n" ] && { echo "usage: kt-node <node>"; return 1; }
  _kt_hr "describe node/$n"
  _kt_k describe node "$n"
  _kt_hr "pods scheduled on $n"
  _kt_k get pods -A -o wide --field-selector "spec.nodeName=$n"
  _kt_hr "allocatable vs requested"
  _kt_k describe node "$n" | sed -n '/Allocated resources/,/^Events/p'
}

# ------------------------------------------------------------------------------
# kt-ssh <node-name|ip> [command...] — get onto the node itself.
#
# Resolves a node NAME to an address from the Kubernetes API rather than making
# you keep a list of IPs (the previous version of this file hardcoded three).
# Prefers ExternalIP, falls back to InternalIP.
#
# StrictHostKeyChecking is off and known_hosts points at /dev/null on purpose:
# these are throwaway hosts you will never see again, and the prompt is pure
# friction. Do not copy this habit to hosts you care about.
# ------------------------------------------------------------------------------
kt-ssh() {
  local target="$1"; shift 2>/dev/null
  [ -z "$target" ] && { echo "usage: kt-ssh <node-name|ip> [command...]"; return 1; }
  local addr="$target"
  # Anything that is not dotted-quad is treated as a node name to resolve.
  case "$target" in
    *[!0-9.]*)
      addr="$(_kt_k get node "$target" -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)"
      [ -z "$addr" ] && addr="$(_kt_k get node "$target" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"
      [ -z "$addr" ] && { _kt_warn "could not resolve an address for node $target"; return 1; }
      _kt_note "$target -> $addr" ;;
  esac
  local key=()
  [ -n "$KT_SSH_KEY" ] && key=(-i "$KT_SSH_KEY")
  ssh "${key[@]}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o LogLevel=ERROR \
      "${KT_SSH_USER}@${addr}" "$@"
}

# ------------------------------------------------------------------------------
# kt-kubelet <node> — the on-node half of a node investigation.
#
# Runs over SSH because if the node is Ready=Unknown the API server is by
# definition not going to tell you anything. Checks, in the order that actually
# discriminates between causes:
#   service state -> recent logs -> disk (the #1 cause of DiskPressure) ->
#   container runtime -> clock skew (certificate errors that look like auth bugs)
# ------------------------------------------------------------------------------
kt-kubelet() {
  local n="$1"; [ -z "$n" ] && { echo "usage: kt-kubelet <node-name|ip>"; return 1; }
  kt-ssh "$n" 'set -x
    sudo systemctl is-active kubelet || true
    sudo systemctl status kubelet --no-pager -l | head -30 || true
    sudo journalctl -u kubelet -n 60 --no-pager | tail -60 || true
    df -h / /var/lib/kubelet /var/lib/containerd 2>/dev/null || true
    sudo crictl ps 2>/dev/null | head -20 || sudo docker ps 2>/dev/null | head -20 || true
    date -u; uptime'
}

# ==============================================================================
# LAYER B — WORKLOADS
# ==============================================================================

# ------------------------------------------------------------------------------
# kt-app [ns] — workload state for a namespace, in dependency order.
#
# deployment -> replicaset -> pod is the chain a rollout actually travels, and
# reading it in that order tells you where it stopped: a Deployment that never
# created a new ReplicaSet is an admission/quota problem; a ReplicaSet with zero
# pods is a scheduling problem; pods that exist but are not Ready is a container
# problem. Three completely different investigations, distinguished for free.
# ------------------------------------------------------------------------------
kt-app() {
  local ns; ns="$(_kt_ns "$1")"
  _kt_hr "ns/$ns — deployments"
  _kt_k -n "$ns" get deploy -o wide 2>/dev/null
  _kt_hr "ns/$ns — statefulsets / daemonsets"
  _kt_k -n "$ns" get sts,ds -o wide 2>/dev/null
  _kt_hr "ns/$ns — replicasets (non-zero only)"
  _kt_k -n "$ns" get rs 2>/dev/null | awk 'NR==1 || $2!="0"'
  _kt_hr "ns/$ns — pods"
  _kt_k -n "$ns" get pods -o wide 2>/dev/null
  _kt_hr "ns/$ns — restart counts (high = crashing, not failing to start)"
  _kt_k -n "$ns" get pods --sort-by=.status.containerStatuses[0].restartCount \
    -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount,STATE:.status.containerStatuses[*].state' 2>/dev/null | tail -15
  _kt_hr "ns/$ns — warnings"
  _kt_k -n "$ns" get events --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -15
}

# ------------------------------------------------------------------------------
# kt-why <pod> [ns] — the single most useful verb in the file.
#
# Answers "why is this pod not running" by walking the causes in the order the
# kubelet itself hits them, and printing the one piece of evidence that settles
# each. Most of the time the answer is in the first two blocks.
#
#   scheduling      Pending with no node assigned -> the scheduler could not
#                   place it. The events say why (insufficient cpu, no matching
#                   taint toleration, unbound PVC) and nothing else will.
#   image           ImagePullBackOff / ErrImagePull -> registry, tag, or creds.
#   container start CreateContainerConfigError -> a missing ConfigMap or Secret.
#   runtime         CrashLoopBackOff -> it starts and dies. The PREVIOUS
#                   container's logs are the ones that matter; the current
#                   container has not failed yet.
#   probes          Running but not Ready -> readiness probe failing. This is
#                   the one people miss, because `get pods` says Running.
# ------------------------------------------------------------------------------
kt-why() {
  local pod="$1" ns; ns="$(_kt_ns "$2")"
  [ -z "$pod" ] && { echo "usage: kt-why <pod> [namespace]"; return 1; }

  _kt_hr "ns/$ns pod/$pod — phase and container states"
  _kt_k -n "$ns" get pod "$pod" -o custom-columns=\
'PHASE:.status.phase,'\
'NODE:.spec.nodeName,'\
'READY:.status.containerStatuses[*].ready,'\
'RESTARTS:.status.containerStatuses[*].restartCount' 2>/dev/null

  # The waiting reason + message is the single highest-value field in the whole
  # pod object and it is buried four levels deep, so it gets pulled out here.
  # jq rather than jsonpath here, because jsonpath cannot filter and would print
  # an empty "app:  — " line for every container that is running fine, burying
  # the one line that matters among the ones that do not.
  _kt_hr "WHY IT IS WAITING (reason + message)"
  local waiting
  waiting="$(_kt_k -n "$ns" get pod "$pod" -o json 2>/dev/null | jq -r '
    ((.status.initContainerStatuses // []) | map(. + {_init: true})) + (.status.containerStatuses // [])
    | .[] | select(.state.waiting != null)
    | "\(if ._init then "[init] " else "" end)\(.name): \(.state.waiting.reason) — \(.state.waiting.message // "no message")"' 2>/dev/null)"
  if [ -n "$waiting" ]; then echo "$waiting"; else _kt_note "no container is in a waiting state"; fi

  _kt_hr "LAST TERMINATION (exit code tells you which kind of dead)"
  # 137 = SIGKILL, almost always the OOM killer or a failed liveness probe.
  # 143 = SIGTERM, a normal shutdown you did not expect.
  # 1/2 = the application itself decided to exit — read its logs.
  _kt_k -n "$ns" get pod "$pod" -o jsonpath=\
'{range .status.containerStatuses[*]}{.name}{": exit="}{.lastState.terminated.exitCode}{" reason="}{.lastState.terminated.reason}{" at "}{.lastState.terminated.finishedAt}{"\n"}{end}' 2>/dev/null
  _kt_note "137=SIGKILL (OOMKilled or liveness) · 143=SIGTERM · 1/2=app exited on its own"

  _kt_hr "EVENTS for this pod"
  _kt_k -n "$ns" get events --field-selector "involvedObject.name=$pod" \
    --sort-by=.lastTimestamp 2>/dev/null | tail -20

  _kt_hr "PREVIOUS container logs (the crash itself)"
  # --previous is the point: on a CrashLoopBackOff the current container is
  # freshly started and has not failed yet, so its logs are empty or misleading.
  local prev
  prev="$(_kt_k -n "$ns" logs "$pod" --previous --tail=40 --all-containers 2>&1)"
  case "$prev" in
    ""|*"unable to retrieve"*|*"not found"*|*"previous terminated container"*)
      _kt_note "none — the container has not crashed yet, or its previous logs were rotated away" ;;
    *) echo "$prev" ;;
  esac

  _kt_hr "CURRENT logs"
  _kt_k -n "$ns" logs "$pod" --tail=40 --all-containers 2>/dev/null

  _kt_hr "PROBES + RESOURCES (Running-but-not-Ready lives here)"
  _kt_k -n "$ns" get pod "$pod" -o jsonpath=\
'{range .spec.containers[*]}{.name}{"\n  liveness:  "}{.livenessProbe}{"\n  readiness: "}{.readinessProbe}{"\n  resources: "}{.resources}{"\n"}{end}' 2>/dev/null

  _kt_hr "SCHEDULING (only interesting if PHASE=Pending)"
  _kt_k -n "$ns" get pod "$pod" -o jsonpath=\
'{"nodeSelector: "}{.spec.nodeSelector}{"\ntolerations: "}{.spec.tolerations}{"\naffinity:    "}{.spec.affinity}{"\n"}' 2>/dev/null
}

# ------------------------------------------------------------------------------
# kt-crash [ns] — every crash-looping pod, with the exit code and last words.
#
# Cluster-wide by default. Given several crashing pods, the exit codes tell you
# instantly whether you have one fault or several: a wall of 137s is a memory
# limit or a node problem; a mix of exit codes is a mix of application bugs.
# ------------------------------------------------------------------------------
kt-crash() {
  local ns_flag=(-A); [ -n "$1" ] && ns_flag=(-n "$1")
  _kt_hr "CrashLoopBackOff / Error / OOMKilled"
  local found
  found="$(_kt_k get pods "${ns_flag[@]}" -o json 2>/dev/null | jq -r '
    .items[]
    | select(
        (.status.containerStatuses // [])[]?
        | (.state.waiting.reason // "") as $w
        | (.lastState.terminated.reason // "") as $t
        | ($w | test("CrashLoop|Error|OOM")) or ($t | test("Error|OOM"))
      )
    | .metadata.namespace + "/" + .metadata.name as $p
    | (.status.containerStatuses[]
       | "\($p)  \(.name)  restarts=\(.restartCount)  exit=\(.lastState.terminated.exitCode // "-")  reason=\(.lastState.terminated.reason // .state.waiting.reason // "-")")
  ' 2>/dev/null)"
  if [ -n "$found" ]; then echo "$found"; else _kt_note "none"; return 0; fi
  _kt_note "then: kt-why <pod> [ns] for the logs behind one of them"
}

# ------------------------------------------------------------------------------
# kt-image [ns] — image pull failures, with the exact image reference.
#
# The image string is what you need and `get pods` will not show it. Nine times
# in ten the answer is visible right here: a typo'd tag, a digest that was
# garbage collected, or a private registry with no imagePullSecret attached.
# ------------------------------------------------------------------------------
kt-image() {
  local ns_flag=(-A); [ -n "$1" ] && ns_flag=(-n "$1")
  _kt_hr "ImagePullBackOff / ErrImagePull"
  # Note the capture-then-test pattern used throughout: `jq ... || _kt_note` does
  # not work, because jq exits 0 when it simply matches nothing.
  local found
  found="$(_kt_k get pods "${ns_flag[@]}" -o json 2>/dev/null | jq -r '
    .items[]
    | select((.status.containerStatuses // [])[]? | (.state.waiting.reason // "") | test("ImagePull|ErrImage|InvalidImageName"))
    | .metadata.namespace as $ns | .metadata.name as $n
    | (.status.containerStatuses[]
       | select((.state.waiting.reason // "") | test("ImagePull|ErrImage|InvalidImageName"))
       | "\($ns)/\($n)\n    image:  \(.image)\n    reason: \(.state.waiting.reason)\n    msg:    \(.state.waiting.message // "-")\n")
  ' 2>/dev/null)"
  if [ -n "$found" ]; then echo "$found"; else _kt_note "none"; return 0; fi

  _kt_hr "imagePullSecrets present on affected namespaces"
  local secrets
  secrets="$(_kt_k get sa -A -o json 2>/dev/null \
    | jq -r '.items[] | select(.imagePullSecrets) | "\(.metadata.namespace)/\(.metadata.name): \([.imagePullSecrets[].name] | join(","))"' 2>/dev/null)"
  if [ -n "$secrets" ]; then echo "$secrets"; else _kt_note "no ServiceAccount carries an imagePullSecret — fine for a public registry, fatal for a private one"; fi
  _kt_note "private registry + no pull secret is the usual cause; check the node can reach the registry with kt-ssh"
}

# ------------------------------------------------------------------------------
# kt-logs <selector-or-pod> [ns] — multi-pod log tail via stern.
#
# `kubectl logs` takes one pod. During a rollout you have two ReplicaSets' worth
# and the interesting one is whichever is failing; stern takes a regex across all
# of them, so you see the failure without first working out where to look.
# ------------------------------------------------------------------------------
kt-logs() {
  local sel="$1" ns; ns="$(_kt_ns "$2")"
  [ -z "$sel" ] && { echo "usage: kt-logs <pod-regex|label-selector> [ns]"; return 1; }
  if command -v stern >/dev/null 2>&1; then
    stern -n "$ns" --tail 50 "$sel"
  else
    _kt_k -n "$ns" logs -l "$sel" --tail=50 --all-containers --prefix
  fi
}

# ==============================================================================
# LAYER C — NETWORK
# ==============================================================================

# ------------------------------------------------------------------------------
# kt-net [ns] — service / endpoint / policy plumbing.
#
# The question this answers is "does traffic have a path", and it is asked in
# the order the packet travels: does the Service select any pods (endpoints),
# is the target port right, and is a NetworkPolicy dropping it.
#
# A Service with zero endpoints is the highest-yield finding in here. It looks
# completely healthy in `get svc` and it means the selector matches nothing —
# usually a label typo, or pods that are Running but not Ready (an unready pod
# is deliberately removed from endpoints, which is how a failing readiness probe
# silently becomes a connection refused three layers up).
# ------------------------------------------------------------------------------
kt-net() {
  local ns; ns="$(_kt_ns "$1")"
  _kt_hr "ns/$ns services"
  _kt_k -n "$ns" get svc -o wide 2>/dev/null

  _kt_hr "ENDPOINTS — ready vs not-ready per service"
  # The two failure modes look identical in `get endpoints` and mean completely
  # different things, so they are separated explicitly:
  #
  #   no addresses at all   the selector matches no pods. A label typo, or the
  #                         workload was never deployed. Fix the Service.
  #   addresses, none ready the pods exist and are failing their readiness
  #                         probe. The Service is correct; the app is not.
  #
  # EndpointSlices are the source of truth (the legacy Endpoints object is
  # derived and truncates above 1000 addresses), so the count comes from there.
  _kt_k -n "$ns" get endpointslices -o json 2>/dev/null | jq -r '
    .items[]
    | (.metadata.labels["kubernetes.io/service-name"] // .metadata.name) as $svc
    | ((.endpoints // []) | map(select(.conditions.ready == true)) | length) as $ready
    | ((.endpoints // []) | length) as $total
    | "  \($svc)\t ready=\($ready) / total=\($total)"' 2>/dev/null | column -t -s $'\t'

  local none_at_all none_ready
  none_at_all="$(_kt_k -n "$ns" get endpointslices -o json 2>/dev/null | jq -r '
    .items[] | select(((.endpoints // []) | length) == 0)
    | .metadata.labels["kubernetes.io/service-name"] // .metadata.name' 2>/dev/null)"
  none_ready="$(_kt_k -n "$ns" get endpointslices -o json 2>/dev/null | jq -r '
    .items[] | select(((.endpoints // []) | length) > 0)
    | select(((.endpoints // []) | map(select(.conditions.ready == true)) | length) == 0)
    | .metadata.labels["kubernetes.io/service-name"] // .metadata.name' 2>/dev/null)"
  [ -n "$none_at_all" ] && {
    _kt_warn "NO endpoints at all: $(echo "$none_at_all" | tr '\n' ' ')"
    _kt_note "the selector matches no pods — compare svc .spec.selector against the pod labels"
  }
  [ -n "$none_ready" ] && {
    _kt_warn "endpoints exist but NONE are ready: $(echo "$none_ready" | tr '\n' ' ')"
    _kt_note "the pods are up and failing readiness — kt-why <pod>, and look at the probe"
  }

  _kt_hr "NETWORK POLICIES (any policy = default-deny for what it does not allow)"
  _kt_k -n "$ns" get netpol 2>/dev/null || _kt_note "none in this namespace"

  _kt_hr "CNI pods"
  _kt_k -n kube-system get pods -o wide 2>/dev/null \
    | grep -Ei 'calico|cilium|flannel|weave|aws-node|kube-proxy' || _kt_note "no recognisable CNI pods"
}

# ------------------------------------------------------------------------------
# kt-dns [name] — is cluster DNS working, from inside the cluster.
#
# Two separate questions that get conflated constantly: is CoreDNS RUNNING, and
# does resolution WORK. CoreDNS can be perfectly healthy while resolution fails
# because kube-proxy has not programmed the service IP, or a NetworkPolicy is
# dropping port 53. The only honest test is a lookup from inside a pod, which is
# what the second half does.
# ------------------------------------------------------------------------------
kt-dns() {
  local name="${1:-kubernetes.default.svc.cluster.local}"
  _kt_hr "CoreDNS deployment"
  _kt_k -n kube-system get deploy,pods -l k8s-app=kube-dns -o wide 2>/dev/null \
    || _kt_k -n kube-system get pods 2>/dev/null | grep -i dns
  _kt_hr "kube-dns service (every pod's /etc/resolv.conf points at this IP)"
  _kt_k -n kube-system get svc kube-dns -o wide 2>/dev/null
  _kt_k -n kube-system get endpoints kube-dns 2>/dev/null
  _kt_hr "CoreDNS logs (SERVFAIL / i/o timeout / loop detected)"
  _kt_k -n kube-system logs -l k8s-app=kube-dns --tail=30 --all-containers 2>/dev/null | tail -30

  # ---- the actual resolution test -------------------------------------------
  # Two implementations, because the mode determines what is permitted and the
  # cheaper one is not always available:
  #
  #   rw     start a throwaway busybox. Cleanest result — a known image with
  #          known tools, and independent of whatever is deployed here.
  #   probe  exec into a pod that already exists. Creates no API object, so it
  #          is honest about `probe` meaning "no writes". The catch is that
  #          distroless and scratch images have no shell and no resolver tools,
  #          hence the fallback chain below.
  #   ro     neither is permitted. Say so rather than failing obscurely.
  _kt_hr "RESOLUTION TEST from inside the cluster: $name"
  local mode="${WS_MODE:-ro}"

  if [ "$mode" = rw ]; then
    _kt_k run "kt-dnstest-$$" --rm -i --restart=Never --image=busybox:1.36 \
        --command -- sh -c "nslookup $name; echo ---; cat /etc/resolv.conf" 2>&1 | tail -20
    return 0
  fi

  if [ "$mode" = ro ]; then
    _kt_note "a resolution test needs exec or a throwaway pod — rerun with 'ws shell' (probe) or --rw"
    _kt_note "everything above still tells you whether CoreDNS itself is healthy"
    return 0
  fi

  # probe: find a pod to borrow. Two subtleties, both learned by getting them
  # wrong:
  #
  #   * `--field-selector status.phase=Running` is not enough. A pod in
  #     CrashLoopBackOff reports phase Running between restarts, and exec-ing
  #     into it fails with `container not found` — which reads like a cluster
  #     problem and is not. Select on every container being READY instead.
  #   * prefer a pod in the namespace under investigation: a NetworkPolicy can
  #     break DNS for one namespace only, and testing from elsewhere would
  #     cheerfully report success.
  local target ns_target
  read -r ns_target target <<<"$(_kt_k get pods -A -o json 2>/dev/null | jq -r '
      .items[]
      | select(.status.phase == "Running")
      | select(((.status.containerStatuses // []) | length) > 0)
      | select(all(.status.containerStatuses[]; .ready == true))
      | "\(.metadata.namespace) \(.metadata.name)"' 2>/dev/null \
      | { grep -m1 "^$(_kt_ns "") " || head -1; })"
  if [ -z "$target" ]; then
    _kt_note "no Running pod to exec into — rerun with --rw to start a throwaway busybox"
    return 0
  fi
  _kt_note "exec'ing into $ns_target/$target (creates nothing)"
  _kt_k -n "$ns_target" exec "$target" -- sh -c "
    cat /etc/resolv.conf 2>/dev/null; echo ---
    nslookup $name 2>/dev/null || getent hosts $name || echo 'no resolver tool in this image — try --rw for a busybox'
  " 2>&1 | tail -20
}

# ------------------------------------------------------------------------------
# kt-ingress [ns] — the controller, the rule, and the path between them.
#
# Checked bottom-up: does a controller exist and is it running -> does the
# Ingress name an IngressClass that controller actually watches -> does the rule
# point at a Service that exists on a port that exists.
#
# The IngressClass check catches the quiet failure mode: an Ingress with no
# class, or a class no controller claims, is simply ignored. Nothing errors,
# nothing logs, the object just sits there looking correct forever.
# ------------------------------------------------------------------------------
kt-ingress() {
  local ns; ns="$(_kt_ns "$1")"
  _kt_hr "IngressClasses on the cluster"
  _kt_k get ingressclass -o custom-columns='NAME:.metadata.name,CONTROLLER:.spec.controller,DEFAULT:.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class' 2>/dev/null

  _kt_hr "Ingress controller pods + service"
  _kt_k get pods -A -o wide 2>/dev/null | grep -Ei 'ingress|traefik|haproxy|contour|istio-ingress' \
    || _kt_note "no ingress controller pod found — an Ingress object alone does nothing"
  _kt_k get svc -A 2>/dev/null | grep -Ei 'ingress|traefik|haproxy|contour' | head

  _kt_hr "ns/$ns ingress objects"
  _kt_k -n "$ns" get ingress -o wide 2>/dev/null
  local ing
  for ing in $(_kt_k -n "$ns" get ingress -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    _kt_hr "ingress/$ing — rules and backends"
    _kt_k -n "$ns" describe ingress "$ing" | sed -n '/^Rules:/,/^Annotations:/p'
    # Class is pulled out separately because it is the field most likely to be
    # missing and the one whose absence is silent.
    printf '    ingressClassName: %s\n' \
      "$(_kt_k -n "$ns" get ingress "$ing" -o jsonpath='{.spec.ingressClassName}' 2>/dev/null || echo '(unset — likely ignored)')"
    printf '    status.loadBalancer: %s\n' \
      "$(_kt_k -n "$ns" get ingress "$ing" -o jsonpath='{.status.loadBalancer.ingress[*].ip}{.status.loadBalancer.ingress[*].hostname}' 2>/dev/null || echo '(empty — controller has not claimed it)')"
  done

  _kt_hr "Ingress controller logs (last 30)"
  _kt_k get pods -A -o json 2>/dev/null \
    | jq -r '.items[] | select(.metadata.name | test("ingress|traefik|haproxy|contour")) | "\(.metadata.namespace) \(.metadata.name)"' 2>/dev/null \
    | head -1 | while read -r ins ipod; do
        [ -n "$ipod" ] && _kt_k -n "$ins" logs "$ipod" --tail=30 2>/dev/null | tail -30
      done
}

# ------------------------------------------------------------------------------
# kt-cert [ns] — the cert-manager chain, in issuance order.
#
# Certificate -> CertificateRequest -> Order -> Challenge is the exact sequence
# cert-manager walks, and issuance stops at the first broken link. Reading them
# in that order means the LAST object that exists is where it stopped, and its
# status message names the reason. A stuck Challenge is nearly always the HTTP-01
# solver being unreachable — which is an ingress problem wearing a TLS costume,
# so kt-ingress is the follow-up, not more certificate debugging.
# ------------------------------------------------------------------------------
kt-cert() {
  local ns; ns="$(_kt_ns "$1")"
  _kt_k get crd 2>/dev/null | grep -q cert-manager || { _kt_note "cert-manager is not installed on this cluster"; return 0; }
  _kt_hr "Issuers / ClusterIssuers (want Ready=True)"
  _kt_k get clusterissuer 2>/dev/null
  _kt_k -n "$ns" get issuer 2>/dev/null
  _kt_hr "ns/$ns certificate chain"
  _kt_k -n "$ns" get certificate,certificaterequest,order,challenge -o wide 2>/dev/null
  local c
  for c in $(_kt_k -n "$ns" get certificate -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    _kt_hr "certificate/$c — conditions"
    _kt_k -n "$ns" get certificate "$c" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null
  done
  _kt_hr "Challenges — reason for any that are pending"
  _kt_k -n "$ns" get challenge -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.state}{" — "}{.status.reason}{"\n"}{end}' 2>/dev/null
  _kt_hr "cert-manager controller logs"
  _kt_k -n cert-manager logs -l app.kubernetes.io/name=cert-manager --tail=30 2>/dev/null | tail -30
}

# ------------------------------------------------------------------------------
# kt-tls <host> [port] — what certificate is actually being served.
#
# From outside the cluster, over the real network path, because that is the only
# way to catch the cases the cluster cannot see: a load balancer terminating TLS
# with its own certificate, or the ingress controller falling back to its
# self-signed default because the Secret it wanted does not exist.
#
# `openssl s_client </dev/null` is used rather than curl since it prints the
# chain and the SANs, and the SAN list is what tells you the certificate is for
# the wrong hostname.
# ------------------------------------------------------------------------------
kt-tls() {
  local host="$1" port="${2:-443}"
  [ -z "$host" ] && { echo "usage: kt-tls <host> [port]"; return 1; }
  _kt_hr "TLS handshake to $host:$port"
  echo | openssl s_client -connect "${host}:${port}" -servername "$host" 2>&1 \
    | sed -n '/Certificate chain/,/---/p'
  _kt_hr "Served certificate: subject / issuer / validity / SANs"
  echo | openssl s_client -connect "${host}:${port}" -servername "$host" 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null
  _kt_note "issuer '(STAGING) Let's Encrypt' means the ClusterIssuer points at the staging ACME endpoint"
  _kt_note "issuer 'Kubernetes Ingress Controller Fake Certificate' means the real Secret is missing"
}

# ------------------------------------------------------------------------------
# kt-http <url> — end-to-end request with the timing broken out.
#
# The per-phase timings localise the fault without any further investigation:
# DNS slow -> resolver; connect slow -> routing or a security group; appconnect
# slow -> TLS; starttransfer slow -> the application itself.
# ------------------------------------------------------------------------------
kt-http() {
  local url="$1"; [ -z "$url" ] && { echo "usage: kt-http <url>"; return 1; }
  _kt_hr "GET $url"
  curl -sS -o /dev/null -D - -L --max-time 20 "$url" 2>&1 | head -30
  _kt_hr "timing breakdown (seconds)"
  curl -sS -o /dev/null -L --max-time 20 -w \
'    dns          %{time_namelookup}\n    tcp connect  %{time_connect}\n    tls          %{time_appconnect}\n    ttfb         %{time_starttransfer}\n    total        %{time_total}\n    http code    %{http_code}\n    final url    %{url_effective}\n' \
    "$url" 2>&1
}

# ==============================================================================
# LAYER D — STORAGE, RBAC, CAPACITY
# ==============================================================================

# ------------------------------------------------------------------------------
# kt-storage — PVCs that will not bind, and why.
#
# A Pending PVC is one of the two reasons a Pod stays Pending forever (the other
# is scheduling), and the reason is in the PVC's events, not the pod's — which is
# why a pod-only investigation goes nowhere. The StorageClass listing is here
# because "no default StorageClass" is the most common cause and is invisible
# unless you go looking for it.
# ------------------------------------------------------------------------------
kt-storage() {
  _kt_hr "StorageClasses (want exactly one marked default)"
  _kt_k get sc -o custom-columns='NAME:.metadata.name,PROVISIONER:.provisioner,DEFAULT:.metadata.annotations.storageclass\.kubernetes\.io/is-default-class,BINDING:.volumeBindingMode' 2>/dev/null
  _kt_hr "PVCs not Bound"
  _kt_k get pvc -A 2>/dev/null | awk 'NR==1 || $3!="Bound"'
  _kt_hr "PVs not Bound"
  _kt_k get pv 2>/dev/null | awk 'NR==1 || $5!="Bound"'
  local ns name
  _kt_k get pvc -A --no-headers 2>/dev/null | awk '$3!="Bound"{print $1, $2}' | while read -r ns name; do
    [ -z "$name" ] && continue
    _kt_hr "pvc/$name in ns/$ns — events"
    _kt_k -n "$ns" describe pvc "$name" | sed -n '/^Events:/,$p'
  done
  _kt_hr "CSI drivers registered"
  _kt_k get csidrivers 2>/dev/null || _kt_note "none"
}

# ------------------------------------------------------------------------------
# kt-rbac [serviceaccount] [ns] — what an identity can actually do.
#
# With no argument, checks YOUR permissions; with one, impersonates a
# ServiceAccount. This is the fastest way to explain a controller that silently
# does nothing: it is not broken, its ServiceAccount cannot list the resource it
# watches, and the only symptom is an absence of behaviour.
#
# Note that --as requires impersonation rights and is refused by the guard
# outside rw mode, deliberately — see docs/SECURITY.md.
# ------------------------------------------------------------------------------
kt-rbac() {
  local sa="$1" ns; ns="$(_kt_ns "$2")"
  local as=()
  if [ -n "$sa" ]; then
    as=(--as "system:serviceaccount:${ns}:${sa}")
    _kt_hr "permissions of system:serviceaccount:${ns}:${sa}"
  else
    _kt_hr "your own permissions"
    _kt_k auth whoami 2>/dev/null
  fi
  _kt_k auth can-i --list "${as[@]}" -n "$ns" 2>&1 | head -40
  _kt_hr "specific checks in ns/$ns"
  local verb res
  for verb in get list watch create delete; do
    for res in pods secrets configmaps deployments nodes; do
      printf '    %-7s %-12s %s\n' "$verb" "$res" "$(_kt_k auth can-i "$verb" "$res" "${as[@]}" -n "$ns" 2>/dev/null)"
    done
  done
}

# ------------------------------------------------------------------------------
# kt-res [ns] — capacity, requests, and the gap between them.
#
# Answers the two resource questions that actually cause outages: is anything
# Pending because the cluster genuinely has no room (compare requests to
# allocatable), and is anything being OOMKilled because ITS OWN limit is too low
# (a per-pod problem that has nothing to do with cluster capacity). Conflating
# those two leads to adding nodes that do not help.
# ------------------------------------------------------------------------------
kt-res() {
  local ns; ns="$(_kt_ns "$1")"
  _kt_hr "node capacity vs allocated"
  local n
  for n in $(_kt_k get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    printf '\n  --- %s ---\n' "$n"
    _kt_k describe node "$n" 2>/dev/null | sed -n '/Allocated resources/,/^Events/p' | head -12
  done
  _kt_hr "live usage (needs metrics-server)"
  _kt_k top nodes 2>/dev/null || _kt_note "metrics-server not installed — kubectl top is unavailable"
  _kt_k top pods -n "$ns" --sort-by=memory 2>/dev/null | head -15
  _kt_hr "ns/$ns requests + limits per container"
  _kt_k -n "$ns" get pods -o json 2>/dev/null | jq -r '
    .items[] | .metadata.name as $p
    | .spec.containers[]
    | "  \($p)/\(.name)  req=\(.resources.requests // {} | tostring)  lim=\(.resources.limits // {} | tostring)"' 2>/dev/null | head -30
  _kt_hr "ResourceQuota / LimitRange in ns/$ns"
  _kt_k -n "$ns" get resourcequota,limitrange 2>/dev/null || _kt_note "none"
  _kt_hr "recently OOMKilled"
  local oom
  oom="$(_kt_k get pods -A -o json 2>/dev/null | jq -r '
    .items[] | select((.status.containerStatuses // [])[]?.lastState.terminated.reason == "OOMKilled")
    | "  \(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null)"
  if [ -n "$oom" ]; then echo "$oom"; else _kt_note "none"; fi
}

# ------------------------------------------------------------------------------
# kt-events [ns] — warnings, deduplicated and newest last.
#
# Sorted by time because the default (name order) makes the event stream
# unreadable, and grouped by reason+object because a single fault emits the same
# warning every ten seconds and a raw tail shows you one fault forty times.
# ------------------------------------------------------------------------------
kt-events() {
  local ns_flag=(-A); [ -n "$1" ] && ns_flag=(-n "$1")
  _kt_hr "warnings, grouped by reason (count first)"
  _kt_k get events "${ns_flag[@]}" --field-selector type=Warning -o json 2>/dev/null | jq -r '
    .items[] | "\(.reason)\t\(.involvedObject.kind)/\(.involvedObject.name)\t\(.message[0:90])"' 2>/dev/null \
    | sort | uniq -c | sort -rn | head -25
  _kt_hr "most recent 20, chronological"
  _kt_k get events "${ns_flag[@]}" --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -20
}

# ==============================================================================
# EVIDENCE CAPTURE
# ==============================================================================

# ------------------------------------------------------------------------------
# kt-snapshot [dir] — dump the cluster's state to files.
#
# Two uses, both of which have paid for the function on their own:
#   * it is the evidence pack for the write-up. `ws shell` is --rm, and a
#     scrollback buffer is not a deliverable.
#   * it is what you feed the agent. Reading 30 files off disk is faster and far
#     cheaper than 30 round trips to an API server, and it means the agent
#     analyses a consistent point-in-time snapshot rather than a cluster that is
#     changing underneath it.
#
# Everything is captured before anything is analysed, deliberately: the first
# fix you apply invalidates the evidence for every fault you have not found yet.
# ------------------------------------------------------------------------------
kt-snapshot() {
  local dir="${1:-/work/snapshot-$(date -u +%Y%m%dT%H%M%SZ)}"
  mkdir -p "$dir"
  _kt_hr "capturing cluster state -> $dir"

  local ns; ns="$(_kt_ns "")"
  {
    _kt_k config current-context
    _kt_k version -o json 2>/dev/null
  } > "$dir/00-context.txt" 2>&1

  _kt_k get nodes -o wide          > "$dir/01-nodes.txt"        2>&1
  _kt_k get nodes -o yaml          > "$dir/01-nodes.yaml"       2>&1
  _kt_k get pods -A -o wide        > "$dir/02-pods.txt"         2>&1
  _kt_pods_bad                     > "$dir/03-pods-unhealthy.txt" 2>&1
  _kt_k get events -A --sort-by=.lastTimestamp > "$dir/04-events.txt" 2>&1
  _kt_k get svc,endpoints -A       > "$dir/05-services.txt"     2>&1
  _kt_k get ingress,ingressclass -A> "$dir/06-ingress.txt"      2>&1
  _kt_k get pvc,pv,sc -A           > "$dir/07-storage.txt"      2>&1
  _kt_k get deploy,sts,ds,rs -A -o wide > "$dir/08-workloads.txt" 2>&1
  _kt_k api-resources              > "$dir/09-api-resources.txt" 2>&1
  _kt_k top nodes                  > "$dir/10-top-nodes.txt"    2>&1
  _kt_k top pods -A                > "$dir/10-top-pods.txt"     2>&1

  # Per-unhealthy-pod detail: describe + both log streams. This is the bulk of
  # the value — it is exactly what kt-why prints, captured for every broken pod
  # at once so the analysis can be done offline.
  mkdir -p "$dir/pods"
  _kt_pods_bad | awk '{print $1, $2}' | while read -r pns pname; do
    [ -z "$pname" ] && continue
    _kt_k -n "$pns" describe pod "$pname"                         > "$dir/pods/${pns}_${pname}.describe.txt" 2>&1
    _kt_k -n "$pns" logs "$pname" --tail=200 --all-containers     > "$dir/pods/${pns}_${pname}.log"          2>&1
    _kt_k -n "$pns" logs "$pname" --previous --tail=200 --all-containers > "$dir/pods/${pns}_${pname}.previous.log" 2>&1
  done

  # The manifests of the namespace under investigation, for diffing a proposed
  # fix against what is actually deployed.
  _kt_k -n "$ns" get all -o yaml > "$dir/20-ns-${ns}-all.yaml" 2>&1

  echo
  du -sh "$dir" 2>/dev/null
  ls -1 "$dir"
  _kt_note "feed it to the agent:  ws agent \"analyse the snapshot in $dir\""
}

# ------------------------------------------------------------------------------
# kt-diff <file.yaml> — what a manifest WOULD change, without changing it.
#
# `kubectl diff` is a server-side dry-run: it sends the object to the API server,
# gets back the result of applying it, and diffs that against live state without
# ever persisting. It is the single best thing to put on screen before you touch
# an interviewer's cluster — it turns "I would change this" into a shown diff.
# ------------------------------------------------------------------------------
kt-diff() {
  local f="$1"; [ -z "$f" ] && { echo "usage: kt-diff <manifest.yaml>"; return 1; }
  _kt_hr "server-side dry-run diff of $f (nothing is applied)"
  _kt_k diff -f "$f" || true
}

# ==============================================================================
kt-help() {
  cat <<'HELP'

  k8s-triage — layered, read-only triage verbs. Work bottom-up.

  ORIENT
    kt-env                    identity, reachability, your own permissions
    kt-ns [ns]                set target namespace (no arg = auto-detect)
    kt-triage [ns]            *** START HERE *** every layer, one screen

  NODES
    kt-nodes                  Ready status + reason + pressure + taints
    kt-node <name>            everything about one node
    kt-ssh <node|ip> [cmd]    shell onto a node (resolves name -> address)
    kt-kubelet <node>         kubelet unit, journal, disk, runtime, clock

  WORKLOADS
    kt-app [ns]               deploy -> rs -> pod, in rollout order
    kt-why <pod> [ns]         *** why is this pod not running ***
    kt-crash [ns]             every crash-looper + exit codes
    kt-image [ns]             image pull failures + the exact image ref
    kt-logs <regex> [ns]      multi-pod tail (stern)

  NETWORK
    kt-net [ns]               services, endpoints, netpol, CNI
    kt-dns [name]             CoreDNS health + a real in-cluster lookup
    kt-ingress [ns]           class, controller, rules, backends, logs
    kt-cert [ns]              cert-manager chain in issuance order
    kt-tls <host> [port]      what certificate is actually served
    kt-http <url>             end-to-end request with phase timings

  CAPACITY / ACCESS
    kt-storage                PVCs that will not bind, and why
    kt-rbac [sa] [ns]         what you (or a ServiceAccount) can do
    kt-res [ns]               capacity vs requests, limits, OOMKills
    kt-events [ns]            warnings, deduplicated, newest last

  EVIDENCE
    kt-snapshot [dir]         dump everything to files (write-up + agent input)
    kt-diff <file.yaml>       server-side dry-run: what a fix would change

  AGENT
    ws-diagnose "<question>"  hand the cluster to Claude, read-only

  Nothing above writes to the cluster. Mode is WS_MODE=ro|probe|rw.

HELP
}
