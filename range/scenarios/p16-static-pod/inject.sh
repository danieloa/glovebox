#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
cp="$RANGE_CLUSTER-control-plane"
M=/etc/kubernetes/manifests/kube-apiserver.yaml
# Back the manifest up on the HOST, not on the node: teardown has to work even
# if the trainee's attempted fix made things worse, and a backup that lives
# inside the thing you broke is not a backup.
node_exec "$cp" "cat $M" > "$GB_HOME/p16.kube-apiserver.yaml.bak"
[ -s "$GB_HOME/p16.kube-apiserver.yaml.bak" ] || die "could not read the api-server manifest — refusing to break something I cannot restore"
# A flag that does not exist. The kubelet writes the pod, the api-server binary
# rejects its arguments and exits immediately, and the kubelet keeps retrying.
node_exec "$cp" "sed -i 's|    - kube-apiserver|    - kube-apiserver\\n    - --profiling-mode=aggressive|' $M"
c_dim "    edited the api-server static manifest on $cp — the API goes away in a few seconds"
wait_until 90 bash -c "! kubectl --kubeconfig '$RANGE_KUBECONFIG' --request-timeout=3s get --raw /readyz >/dev/null 2>&1" || true
