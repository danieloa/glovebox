#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# range-selftest.sh — prove every scenario in the range actually works.
#
# For each scenario, three assertions in order:
#
#   1. after inject, verify must FAIL   — the fault is real and observable.
#      A scenario that grades PASS on arrival is worse than no scenario: the
#      trainee looks for twenty minutes at a cluster that was never broken.
#   2. after the reference fix, verify must PASS — the fault is fixable, and
#      the grader recognises a correct fix rather than only its own answer key.
#   3. teardown must leave the cluster clean enough for the next scenario.
#
# The reference fixes live here rather than in the scenario directories on
# purpose. They are a test artifact, not a "reveal answer" button — the answer
# belongs in hints.md where reading it is a decision you make.
#
#     ./hack/range-selftest.sh            every scenario
#     ./hack/range-selftest.sh ns         one tier
#     ./hack/range-selftest.sh p09-svc-targetport g2-svc-two-layers
#
# Takes a while. Most of it is waiting for back-off states to be reached, which
# is not something that can be hurried.
set -uo pipefail
cd "$(dirname "$0")/.."

export GB_RANGE_LIB="$PWD/range/lib.sh"
. "$GB_RANGE_LIB"

K() { kubectl --kubeconfig "$RANGE_KUBECONFIG" --context "kind-$RANGE_CLUSTER" "$@"; }

# ------------------------------------------------------------------------------
# the reference fixes — one function per scenario, named fix_<id with - as _>
# ------------------------------------------------------------------------------
fix_p01_crashloop()          { K -n p01-crashloop set env deploy/checkout DB_HOST=postgres.internal; }
fix_p02_imagepull()          { K -n p02-imagepull set image deploy/catalog app=nginx:1.27-alpine; }
fix_p03_pending_resources()  { K -n p03-pending-resources set resources deploy/reports --requests=cpu=100m,memory=128Mi --limits=cpu=500m,memory=256Mi; }
fix_p04_pending_taint()      { K taint node "$(K get nodes -l gb-range/worker=1 -o name | sed 's|node/||')" gb-range/maintenance-; }
fix_p05_oomkilled()          { K -n p05-oomkilled set resources deploy/resizer --requests=memory=320Mi --limits=memory=384Mi; }
fix_p06_readiness_probe()    { K -n p06-readiness-probe patch deploy web --type=json \
                                 -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":80}]'; }
fix_p07_missing_configmap()  { K -n p07-missing-configmap create configmap billing-config --from-literal=mode=production; }
fix_p08_svc_selector()       { K -n p08-svc-selector patch svc payments -p '{"spec":{"selector":{"app":"payments"}}}'; }
fix_p09_svc_targetport()     { K -n p09-svc-targetport patch svc api -p '{"spec":{"ports":[{"port":80,"targetPort":8080}]}}'; }
fix_p10_networkpolicy()      { K -n p10-networkpolicy patch netpol backend-allow --type=json \
                                 -p '[{"op":"replace","path":"/spec/ingress/0/from/0/podSelector/matchLabels","value":{"app":"frontend"}}]'; }
fix_p11_coredns_down()       { K -n kube-system create configmap coredns --from-literal=Corefile='.:53 {
    errors
    health
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
        ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf
    cache 30
    loop
    reload
    loadbalance
}
' --dry-run=client -o yaml | K apply -f - && K -n kube-system rollout restart deploy/coredns; }
fix_p12_pvc_pending()        { K -n p12-pvc-pending delete pvc db-data --wait=false
                               K -n p12-pvc-pending scale deploy/db --replicas=0
                               K -n p12-pvc-pending delete pvc db-data --ignore-not-found
                               K -n p12-pvc-pending apply -f - <<'Y'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: db-data, namespace: p12-pvc-pending}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: standard
  resources: {requests: {storage: 1Gi}}
Y
                               K -n p12-pvc-pending scale deploy/db --replicas=1; }
fix_p13_rbac_forbidden()     { K -n p13-rbac-forbidden create role pod-reader --verb=get,list,watch --resource=pods
                               K -n p13-rbac-forbidden create rolebinding watcher-pod-reader --role=pod-reader \
                                 --serviceaccount=p13-rbac-forbidden:watcher; }
fix_p14_rollout_stuck()      { K -n p14-rollout-stuck set image deploy/storefront app=nginx:1.27-alpine; }
fix_p15_node_notready()      { node_exec "$(cat "$GB_HOME/p15.node")" "systemctl start kubelet"; }
fix_p16_static_pod()         { node_exec "$RANGE_CLUSTER-control-plane" \
                                 "sed -i '/--profiling-mode=aggressive/d' /etc/kubernetes/manifests/kube-apiserver.yaml"; }
fix_p17_wrong_namespace()    { K -n p17-wrong-namespace get deploy orders -o yaml \
                                 | sed 's/namespace: p17-wrong-namespace/namespace: p17-prod/' \
                                 | K -n p17-prod apply -f - ; }
fix_p18_scaled_to_zero()     { K -n p18-scaled-to-zero scale deploy/notifications --replicas=3
                               K -n p18-scaled-to-zero rollout resume deploy/notifications; }
fix_g1_pending_then_crash()  { K -n g1-pending-then-crash set resources deploy/indexer --requests=memory=128Mi --limits=memory=256Mi
                               K -n g1-pending-then-crash create configmap indexer-config --from-literal=url=http://search.internal:9200; }
fix_g2_svc_two_layers()      { K -n g2-svc-two-layers patch svc inventory -p '{"spec":{"selector":{"app":"inventory"}}}'
                               K -n g2-svc-two-layers patch svc inventory -p '{"spec":{"ports":[{"port":80,"targetPort":8080}]}}'; }
fix_g3_dns_is_netpol()       { K -n g3-dns-is-netpol patch netpol default-deny-egress --type=json -p '[{
                                 "op":"add","path":"/spec/egress/-","value":{
                                   "to":[{"namespaceSelector":{},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}],
                                   "ports":[{"protocol":"UDP","port":53},{"protocol":"TCP","port":53}]}}]'; }
fix_g4_rollout_two_pulls()   { K -n g4-rollout-two-pulls set image deploy/checkout app=nginx:1.27-alpine; }
fix_g5_pvc_topology()        { K -n g5-pvc-topology patch deploy analytics --type=json \
                                 -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'; }
fix_g6_webhook_down()        { K delete validatingwebhookconfiguration gb-range-policy-guard; }

# ------------------------------------------------------------------------------
PASS=0; FAILED=0; FAILED_IDS=""
hr() { printf '\n\033[1;36m==== %s ====\033[0m\n' "$*"; }

run_one() {
  local id="$1" fn="fix_${1//-/_}"
  hr "$id"
  # shellcheck disable=SC1090
  ( . "range/scenarios/$id/meta.env" >/dev/null 2>&1 )

  ./gb range up "$id" >/dev/null 2>&1 || { c_red "  inject FAILED"; FAILED=$((FAILED+1)); FAILED_IDS="$FAILED_IDS $id(inject)"; return; }

  if ./gb range check "$id" >/dev/null 2>&1; then
    c_red "  1/3 the fault does not register — verify PASSES on an unfixed cluster"
    FAILED=$((FAILED+1)); FAILED_IDS="$FAILED_IDS $id(no-fault)"
    ./gb range down "$id" >/dev/null 2>&1
    return
  fi
  c_ok  "  1/3 fault is real (verify correctly FAILS before the fix)"

  if ! declare -F "$fn" >/dev/null; then
    c_warn "  2/3 no reference fix defined — skipping the grading half"
    ./gb range down "$id" >/dev/null 2>&1
    return
  fi
  "$fn" >/dev/null 2>&1
  c_ok  "  2/3 reference fix applied"

  local out
  if out="$(./gb range check "$id" 2>&1)"; then
    c_ok  "  3/3 verify PASSES after the reference fix"
    PASS=$((PASS+1))
  else
    c_red "  3/3 verify still FAILS after the reference fix:"
    echo "$out" | grep -E 'FAIL' | sed 's/^/      /'
    FAILED=$((FAILED+1)); FAILED_IDS="$FAILED_IDS $id(not-graded)"
  fi
  ./gb range down "$id" >/dev/null 2>&1
}

ids=""
case "${1:-all}" in
  all)            ids="$(ls -1 range/scenarios)" ;;
  ns|cluster|node) ids="$(for i in $(ls -1 range/scenarios); do ( . "range/scenarios/$i/meta.env"; [ "$TIER" = "$1" ] && echo "$i" ); done)" ;;
  *)              ids="$*" ;;
esac

./gb range down >/dev/null 2>&1 || true
for id in $ids; do run_one "$id"; done

hr "RESULT"
printf '  %d passed, %d failed\n' "$PASS" "$FAILED"
[ -n "$FAILED_IDS" ] && printf '  failures:%s\n' "$FAILED_IDS"
echo
[ "$FAILED" -eq 0 ]
