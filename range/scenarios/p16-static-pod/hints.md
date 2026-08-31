## 1
You cannot use the API to debug the API. Everything from here happens on the
control-plane node itself, with the container runtime and the kubelet's journal.
Start by establishing that the node is fine and only the api-server is not.

## 2
    docker exec -it gb-range-control-plane crictl ps -a | grep apiserver
    docker exec -it gb-range-control-plane crictl logs <container-id> 2>&1 | tail -20
    docker exec -it gb-range-control-plane journalctl -u kubelet -e --no-pager | tail -30

The container exists, has exited, and its last words name the problem. The
api-server is a *static pod* — the kubelet runs it from a file on disk, not
from the API — so its definition is readable and editable with the API down:

    docker exec -it gb-range-control-plane ls /etc/kubernetes/manifests/

## 3
`/etc/kubernetes/manifests/kube-apiserver.yaml` has an argument the binary does
not recognise (`--profiling-mode=aggressive`), so it exits on startup. Remove
that line:

    docker exec -it gb-range-control-plane \
      sed -i '/--profiling-mode=aggressive/d' /etc/kubernetes/manifests/kube-apiserver.yaml

The kubelet watches that directory and restarts the pod on save — no command
needed. Give it 30-60 seconds and `kubectl get nodes` answers again.

The transferable part is the shape, not this flag. The same walk finds a wrong
`--etcd-servers`, a bad cert path, and an expired certificate — for that last
one, `kubeadm certs check-expiration` then `kubeadm certs renew`. And on a real
cluster the file is on the node's disk, which is why an SSH path to your control
plane is something you check *before* you need it.
