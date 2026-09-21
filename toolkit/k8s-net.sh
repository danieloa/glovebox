# SPDX-License-Identifier: Apache-2.0
# ==============================================================================
# k8s-net.sh — pod-level network probes, for when the API objects look fine.
#
# k8s-triage's kt-net and kt-dns answer "are the Service, the endpoints and the
# policy objects right". These answer the next question: "can this pod actually
# reach that thing" — by running the test FROM INSIDE the pod, which is the only
# vantage point that shares its network namespace, its resolv.conf and its
# NetworkPolicy. Works under bash 4+ and zsh.
#
#     kt-probe-help                 the list, with the mode each one needs
#
# MODES — these follow image/guard-kubectl.sh, not a private convention:
#
#   ro     kt-coredns, kt-netpol, and the endpoint half of kt-svc. Reads only.
#   probe  everything that execs into a pod: kt-listen, kt-conns, kt-podns, kt-p2p, kt-svc,
#          kt-tcpdump. Creates no pod, but see the ephemeral-container caveat.
#   rw     kt-netshoot, kt-netshoot-node. Both CREATE a pod (the node one a
#          privileged pod with the host filesystem mounted), so they are
#          refused unless you asked for rw on purpose.
#
# EPHEMERAL FALLBACK. Distroless and slim images have no nc / ss / nslookup. When
# the pod lacks the binary, the probe runs in an ephemeral netshoot container
# attached to the pod instead. That shares the pod's network namespace, so the
# result is honest — but an ephemeral container is a spec change to someone
# else's pod, and Kubernetes cannot remove it: it stays until the pod is
# recreated. Each fallback prints a line saying so.
#
# NAMESPACE. -n <ns> and -c <container> may appear anywhere in the arguments.
# Without -n the namespace is $KT_NS (set by kt-ns), then the kubeconfig's own.
# ==============================================================================

# SC2016: the single-quoted `sh -c` scripts below are meant to expand $1/$@ INSIDE
# the pod, not here.
# shellcheck disable=SC2016

# Pinned to the current release (v0.16 == :latest at the time of writing) and
# pulled from the project's own GHCR registry rather than Docker Hub, whose
# anonymous pull limit is the thing that fails on a shared node IP. The image is
# pulled by the NODE, not by this container. Override for a private mirror.
: "${KT_NETSHOOT_IMAGE:=ghcr.io/nicolaka/netshoot:v0.16}"

# ==============================================================================
# INTERNAL HELPERS  (_ktp_ prefix = not meant to be called directly; _kt_hr,
# _kt_note, _kt_warn and _kt_k are k8s-triage.sh's — both files are always
# sourced together by shellrc.sh)
# ==============================================================================

_ktp_usage() { printf 'usage: %s\n' "$*" >&2; return 2; }

# Reads go through _kt_k (k8s-triage.sh), so a wedged API server cannot hang a
# probe. exec/debug do NOT: a request timeout would cut a long-running stream
# (tcpdump) off mid-capture.

# _ktp_parse "$@" — pull -n/--namespace and -c/--container out of the arguments
# wherever they appear, leaving the positionals alone. Everything from a bare
# `--` on is passed through untouched (the `--` included, as a boundary marker),
# so `kt-tcpdump pod -- -c 10` reaches tcpdump instead of being eaten as a
# container name.
#
# Results land in the CALLER's locals — the caller must declare
#     local _ns="" _ctr=""; local -a _args=()
# first. bash and zsh both scope `local` dynamically, so nothing leaks.
_ktp_parse() {
  _ns=""; _ctr=""; _args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--namespace|-c|--container)
        [ $# -ge 2 ] || { _kt_warn "$1 needs a value" >&2; return 2; }
        case "$1" in -n|--namespace) _ns="$2" ;; *) _ctr="$2" ;; esac
        shift 2 ;;
      --) while [ $# -gt 0 ]; do _args+=("$1"); shift; done ;;
      *)  _args+=("$1"); shift ;;
    esac
  done
  _ns="${_ns:-${KT_NS:-}}"
}

# _ktp_curns — the namespace a service/pod name is resolved in when the user did
# not say. Only needed where the name itself goes into a lookup (kt-p2p, kt-svc);
# kubectl applies the kubeconfig default on its own everywhere else.
_ktp_curns() {
  local n="${_ns:-}"
  [ -z "$n" ] && n="$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)"
  printf '%s' "${n:-default}"
}

# _ktp_need_probe — exec and debug are refused by the guard in ro. Say so up
# front, in the toolkit's own words, instead of letting the guard's exit 77 read
# as a cluster fault three lines later.
_ktp_need_probe() {
  case "${GB_MODE:-ro}" in probe|rw) return 0 ;; esac
  _kt_note "this needs exec into a pod — rerun with 'gb shell' (probe) or --rw"
  return 1
}

_ktp_need_rw() {
  [ "${GB_MODE:-ro}" = rw ] && return 0
  _kt_warn "$1 creates a pod on the cluster — refused unless GB_MODE=rw ('gb shell --rw')" >&2
  return 1
}

# _ktp_run <pod> "<bin> [bin...]" <cmd...> — run <cmd> in <pod> if every <bin> is
# installed there, otherwise in an ephemeral netshoot container attached to it.
# Reads the caller's $_ns / $_ctr (see _ktp_parse).
_ktp_run() {
  local pod=$1 bins=$2 b; shift 2
  _ktp_need_probe || return 1

  local -a nf=() cf=() tf=()
  [ -n "$_ns" ]  && nf=(-n "$_ns")
  [ -n "$_ctr" ] && { cf=(-c "$_ctr"); tf=(--target "$_ctr"); }

  # A missing pod and a missing binary both make the check below fail, and only
  # one of them should end up as "not available, using netshoot".
  _kt_k get pod "$pod" "${nf[@]}" -o name >/dev/null || return 1

  local have=1
  for b in $bins; do
    kubectl exec "$pod" "${nf[@]}" "${cf[@]}" -- sh -c 'command -v "$1"' _ "$b" >/dev/null 2>&1 || { have=0; break; }
  done

  if [ "$have" = 1 ]; then
    kubectl exec "$pod" "${nf[@]}" "${cf[@]}" -- "$@"
  else
    _kt_note "'$b' not in $pod — using ephemeral $KT_NETSHOOT_IMAGE (stays on the pod until it is recreated)"
    # --target joins the app container's PROCESS namespace too, which is what
    # lets `netstat -p` name the process behind a socket. The network namespace
    # is shared with the whole pod either way.
    #
    # Created detached and read back with `logs`, NOT attached. Both attach
    # modes fail on a short-lived command: -i also hands the probe our stdin (a
    # piped script or an agent's shell loses every following line to it), and
    # --attach races the container exiting and silently prints NOTHING — which
    # reads as "no connections" rather than as an error. A named ephemeral
    # container's logs survive its exit, so poll for termination, then read.
    local cname="ktp-$RANDOM" code=""
    kubectl debug "$pod" "${nf[@]}" "${tf[@]}" -q -c "$cname" --image="$KT_NETSHOOT_IMAGE" -- "$@" >/dev/null || return 1
    for _ in $(seq 1 90); do   # covers a cold image pull plus a few resolver timeouts
      code="$(_kt_k get pod "$pod" "${nf[@]}" -o jsonpath="{.status.ephemeralContainerStatuses[?(@.name=='$cname')].state.terminated.exitCode}" 2>/dev/null)"
      [ -n "$code" ] && break
      sleep 1
    done
    _kt_k logs "$pod" "${nf[@]}" -c "$cname"
    [ -n "$code" ] || { _kt_warn "probe container $cname had not finished after 90s — output above may be partial" >&2; return 1; }
    return "$code"
  fi
}

# ==============================================================================
# FROM INSIDE A POD
# ==============================================================================

# kt-listen <pod> [-n ns] [-c container] — listening sockets.
# Answers "is the app actually bound to the port, and on which address": a
# server listening on 127.0.0.1 is up, Ready, and unreachable from every other pod.
kt-listen() {
  local _ns="" _ctr=""; local -a _args=()
  _ktp_parse "$@" || return 2; set -- "${_args[@]}"
  [ -n "${1:-}" ] || { _ktp_usage "kt-listen <pod> [-n ns] [-c container]"; return 2; }
  _kt_hr "LISTENING SOCKETS in $1 (want: the app's port on 0.0.0.0 or ::, not 127.0.0.1)"
  _ktp_run "$1" netstat netstat -tulpn
}

# kt-conns <pod> [-n ns] [-c container] — established connections.
# Who is this pod really talking to right now; a stalled upstream shows up here
# long before it shows up in a log.
kt-conns() {
  local _ns="" _ctr=""; local -a _args=()
  _ktp_parse "$@" || return 2; set -- "${_args[@]}"
  [ -n "${1:-}" ] || { _ktp_usage "kt-conns <pod> [-n ns] [-c container]"; return 2; }
  _kt_hr "ESTABLISHED CONNECTIONS in $1"
  _ktp_run "$1" ss ss -tnp state established
}

# kt-podns <pod> [name] [-n ns] [-c container] — resolution as THIS pod sees it.
#
# Shows resolv.conf, then resolves the in-cluster API name, an external name, and
# yours. The two failure shapes are different problems and the output keeps the
# resolver's own words so you can tell them apart:
#     NXDOMAIN                             DNS answered: the name is wrong
#     connection timed out; no servers...  DNS did not answer: CoreDNS, kube-dns
#                                          Service, or a NetworkPolicy on port 53
kt-podns() {
  local _ns="" _ctr=""; local -a _args=()
  _ktp_parse "$@" || return 2; set -- "${_args[@]}"
  [ -n "${1:-}" ] || { _ktp_usage "kt-podns <pod> [name] [-n ns] [-c container]"; return 2; }
  _kt_hr "DNS from inside $1 (want: every name resolves; resolv.conf points at the kube-dns IP)"
  # The script gets the name as a positional parameter rather than by string
  # interpolation, so a name with a quote or a $ in it is just a name.
  _ktp_run "$1" nslookup sh -c '
    echo "--- /etc/resolv.conf"; cat /etc/resolv.conf
    for h in kubernetes.default.svc.cluster.local example.com "$@"; do
      echo "--- $h"
      out="$(nslookup "$h" 2>&1)"; rc=$?
      out="$(printf "%s\n" "$out" | grep -v "^;; Got recursion")"
      if [ "$rc" -eq 0 ]; then printf "%s\n" "$out" | tail -n +3
      else echo "FAIL: $h"; printf "%s\n" "$out" | sed "s/^/    /"; fi
    done' _ "${2:-}"
}

# kt-p2p <src-pod> <[ns/]dst-pod> [port] [-n src-ns] — pod-to-pod, by pod IP.
# Deliberately bypasses the Service and DNS: if this works and kt-svc does not, the
# fault is the Service or DNS; if this fails too, it is the path (CNI, NetworkPolicy).
# Port defaults to the destination's first containerPort; none found -> ICMP.
kt-p2p() {
  local _ns="" _ctr=""; local -a _args=()
  _ktp_parse "$@" || return 2; set -- "${_args[@]}"
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || { _ktp_usage "kt-p2p <src-pod> <[ns/]dst-pod> [port] [-n src-ns]"; return 2; }
  local src=$1 dst=$2 port=${3:-} dns_ns
  dns_ns="$(_ktp_curns)"
  case "$dst" in */*) dns_ns="${dst%%/*}"; dst="${dst#*/}" ;; esac

  local ip
  ip="$(_kt_k get pod "$dst" -n "$dns_ns" -o jsonpath='{.status.podIP}')" || return 1
  [ -n "$ip" ] || { _kt_warn "no IP for $dns_ns/$dst (not scheduled, or not started)" >&2; return 1; }
  [ -n "$port" ] || port="$(_kt_k get pod "$dst" -n "$dns_ns" -o jsonpath='{.spec.containers[0].ports[0].containerPort}')"

  if [ -n "$port" ]; then
    _kt_hr "$src -> $dns_ns/$dst ($ip:$port) (want: succeeded / open)"
    _ktp_run "$src" nc nc -zvw3 "$ip" "$port"
  else
    _kt_hr "$src -> $dns_ns/$dst ($ip) ICMP — no containerPort declared, so no TCP test"
    _ktp_run "$src" ping ping -c3 -W2 "$ip"
  fi
}

# kt-svc <src-pod> <svc[.ns]> [port] [-n src-ns] — pod-to-Service: endpoints, DNS, TCP.
# The read-only half runs in any mode. Pair with kt-p2p: Service fails but pod IP
# works -> the Service (selector, targetPort, kube-proxy) or DNS is at fault.
kt-svc() {
  local _ns="" _ctr=""; local -a _args=()
  _ktp_parse "$@" || return 2; set -- "${_args[@]}"
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || { _ktp_usage "kt-svc <src-pod> <svc[.ns]> [port] [-n src-ns]"; return 2; }
  local src=$1 target=$2 port=${3:-} svc sns
  svc="${target%%.*}"
  case "$target" in *.*) sns="${target#*.}"; sns="${sns%%.*}" ;; *) sns="$(_ktp_curns)" ;; esac

  _kt_k get svc "$svc" -n "$sns" >/dev/null || return 1
  _kt_hr "ENDPOINTS for $sns/$svc (want: at least one ready address — empty means the selector matches no ready pod)"
  _kt_k get endpointslices -n "$sns" -l kubernetes.io/service-name="$svc"
  [ -n "$port" ] || port="$(_kt_k get svc "$svc" -n "$sns" -o jsonpath='{.spec.ports[0].port}')"

  _kt_hr "$src -> $svc.$sns:$port (want: name resolves, then port open)"
  _ktp_run "$src" "nslookup nc" sh -c 'nslookup "$1" && nc -zvw3 "$1" "$2"' _ "$svc.$sns.svc.cluster.local" "$port"
}

# kt-tcpdump <pod> [-n ns] [-c container] [filter...] [-- tcpdump-flags...]
# Interactive; ctrl-c to stop. Filter words work as before (`kt-tcpdump web port 53`);
# tcpdump's own flags must come after `--` so they are not mistaken for -n / -c.
# Always uses an ephemeral netshoot container — the app image never has tcpdump.
kt-tcpdump() {
  local _ns="" _ctr=""; local -a _args=()
  _ktp_parse "$@" || return 2; set -- "${_args[@]}"
  [ -n "${1:-}" ] || { _ktp_usage "kt-tcpdump <pod> [-n ns] [-c container] [filter...] [-- tcpdump-flags]"; return 2; }
  _ktp_need_probe || return 1
  local pod=$1 w; shift
  local -a nf=() tf=() flags=() filter=()
  [ -n "$_ns" ]  && nf=(-n "$_ns")
  [ -n "$_ctr" ] && tf=(--target "$_ctr")
  # tcpdump wants its flags BEFORE the filter expression, whichever order they
  # were typed in here.
  local past=0
  for w in "$@"; do
    if [ "$past" = 0 ] && [ "$w" = -- ]; then past=1
    elif [ "$past" = 1 ]; then flags+=("$w")
    else filter+=("$w"); fi
  done
  _kt_note "capturing on $pod in an ephemeral container (stays on the pod until it is recreated); ctrl-c to stop"
  kubectl debug "$pod" "${nf[@]}" "${tf[@]}" -q -it --image="$KT_NETSHOOT_IMAGE" -- tcpdump -i any -nn "${flags[@]}" "${filter[@]}"
}

# ==============================================================================
# FROM THE CLUSTER SIDE  (read-only, any mode)
# ==============================================================================

# kt-coredns [log-lines] — CoreDNS health, plus the Corefile kt-dns does not show.
kt-coredns() {
  local lines="${1:-200}"
  _kt_hr "CoreDNS pods (want: all Running and Ready)"
  _kt_k -n kube-system get pods -l k8s-app=kube-dns -o wide
  _kt_hr "kube-dns service"
  _kt_k -n kube-system get svc kube-dns
  _kt_hr "kube-dns endpoints (want: one per ready CoreDNS pod)"
  _kt_k -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns
  _kt_hr "errors in the last $lines log lines (SERVFAIL / i/o timeout / loop)"
  _kt_k -n kube-system logs -l k8s-app=kube-dns --tail="$lines" --prefix 2>/dev/null \
    | grep -Ei 'error|timeout|refused|servfail|i/o' || _kt_note "none"
  _kt_hr "Corefile"
  _kt_k -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'; echo
}

# kt-netpol <pod> [-n ns] — which NetworkPolicies select this pod.
# The old SELECTOR column printed `<none>` for `podSelector: {}` — which is not
# "selects nothing" but "selects EVERY pod", i.e. the default-deny that usually
# IS the fault. The selection is worked out here instead of left to be misread.
# matchExpressions are not evaluated; those rows say so.
kt-netpol() {
  local _ns="" _ctr=""; local -a _args=()
  _ktp_parse "$@" || return 2; set -- "${_args[@]}"
  [ -n "${1:-}" ] || { _ktp_usage "kt-netpol <pod> [-n ns]"; return 2; }
  local -a nf=(); [ -n "$_ns" ] && nf=(-n "$_ns")

  local labels tbl
  tbl="$(mktemp)"
  labels="$(_kt_k get pod "$1" "${nf[@]}" -o json | jq -c '.metadata.labels // {}')" || return 1
  _kt_hr "POD LABELS of $1"
  printf '    %s\n' "$labels"

  _kt_hr "POLICIES in the namespace (any policy that selects a pod denies whatever it does not allow)"
  _kt_k get netpol "${nf[@]}" -o json | jq -r --argjson l "$labels" '
    def selects:
      (.spec.podSelector // {}) as $s
      | if (($s.matchExpressions // []) | length) > 0 then "?"
        elif (($s.matchLabels // {}) | to_entries | all(.value == $l[.key])) then "YES"
        else "no" end;
    (["POLICY", "SELECTS-POD", "TYPES", "INGRESS-RULES", "EGRESS-RULES"] | @tsv),
    (.items[] | [.metadata.name, selects, (((.spec.policyTypes // []) | join(",")) | if . == "" then "-" else . end),
                 ((.spec.ingress // []) | length), ((.spec.egress // []) | length)] | @tsv)' \
    | column -t -s "$(printf '\t')" >"$tbl"
  cat "$tbl"
  _kt_note "SELECTS-POD: YES = applies to this pod; ? = has matchExpressions, read it yourself."
  grep -q Egress "$tbl" && _kt_note "policyTypes Egress with no rule for udp/53 blocks DNS — see kt-podns."
  rm -f "$tbl"
}

# ==============================================================================
# THROWAWAY SHELLS  (rw only — these create pods)
# ==============================================================================

# kt-netshoot [-n ns] — a disposable netshoot pod with a shell; deleted on exit.
kt-netshoot() {
  local _ns="" _ctr=""; local -a _args=()
  _ktp_parse "$@" || return 2
  _ktp_need_rw kt-netshoot || return 1
  local -a nf=(); [ -n "$_ns" ] && nf=(-n "$_ns")
  kubectl run "netshoot-$RANDOM" "${nf[@]}" --rm -it --restart=Never --image="$KT_NETSHOOT_IMAGE" -- zsh
}

# kt-netshoot-node <node> — a shell in the NODE's network namespace, host fs at /host.
# --profile=sysadmin is a privileged container. That is the point (you can see
# the node's iptables and CNI interfaces) and also why it is rw-only.
kt-netshoot-node() {
  [ -n "${1:-}" ] || { _ktp_usage "kt-netshoot-node <node>"; return 2; }
  _ktp_need_rw kt-netshoot-node || return 1
  kubectl debug "node/$1" -it --profile=sysadmin --image="$KT_NETSHOOT_IMAGE" -- zsh
}

# ==============================================================================
kt-probe-help() {
  cat <<'HELP'

  k8s-net — pod-level network probes. Run from inside the pod's network namespace.

  FROM INSIDE A POD                                                                   mode
    kt-podns <pod> [name]           resolv.conf + lookups, as that pod sees them      probe
    kt-p2p <src> <[ns/]dst> [port]  pod -> pod IP (bypasses Service and DNS)          probe
    kt-svc <src> <svc[.ns]> [port]  endpoints, DNS, then TCP to the Service           ro + probe
    kt-listen <pod>                 listening sockets (bound to 127.0.0.1?)           probe
    kt-conns <pod>                  established connections                           probe
    kt-tcpdump <pod> [filter]       packet capture, ephemeral container               probe

  FROM THE CLUSTER SIDE
    kt-coredns [lines]              CoreDNS pods, svc, endpoints, errors, Corefile    ro
    kt-netpol <pod>                 which NetworkPolicies select this pod             ro

  THROWAWAY SHELLS (create a pod)
    kt-netshoot                     disposable netshoot pod, deleted on exit          rw
    kt-netshoot-node <node>         privileged, host network namespace                rw

  -n <ns> / -c <container> go anywhere; -n defaults to $KT_NS, then kubeconfig.
  Missing binary in the pod -> an ephemeral netshoot container (permanent until
  the pod is recreated). Set KT_NETSHOOT_IMAGE if nodes cannot reach Docker Hub.

  Bisect: kt-svc fails but kt-p2p works -> Service / DNS.  Both fail -> CNI / NetworkPolicy.

HELP
}
