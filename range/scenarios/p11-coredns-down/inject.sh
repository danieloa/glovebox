#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
# Keep the original Corefile so teardown can put it back exactly.
rk -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' > "$GB_HOME/coredns.Corefile.bak"
# A "small change to the Corefile" that does not parse. CoreDNS reloads it,
# fails to start, and crash-loops — the pods are visibly unhealthy, which is
# the honest version of this fault: the misdirection in the compound scenario
# (g3) is the one where CoreDNS is fine.
rk -n kube-system create configmap coredns --from-literal=Corefile='.:53 {
    errors
    health
    kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
    forward . /etc/resolv.conf
    cache 30
    loop
    reload
    loadbalance
}
' --dry-run=client -o yaml | rk apply -f - >/dev/null
rk -n kube-system rollout restart deploy/coredns >/dev/null
wait_state kube-system 'CrashLoopBackOff\|Error' 120 || true
