## 1
Pod IP works, Service name does not: the network is fine and the naming layer
is not. Cluster DNS is a Deployment like any other, in kube-system. Look at it
before you look at anything in your own namespace.

## 2
    kubectl -n kube-system get pods -l k8s-app=kube-dns
    kubectl -n kube-system logs -l k8s-app=kube-dns --tail=30

CoreDNS is crash-looping and the log says exactly which line of the Corefile it
choked on. Its configuration is a ConfigMap:

    kubectl -n kube-system get cm coredns -o yaml

## 3
The Corefile is missing the closing brace on the `kubernetes` block, so it does
not parse and CoreDNS refuses to start. Edit the ConfigMap and restore the
brace:

    kubectl -n kube-system edit cm coredns
    kubectl -n kube-system rollout restart deploy/coredns

Verify by resolving, not by looking at pod status — those are different claims:

    kubectl run t --rm -it --image=busybox:1.36 --restart=Never -- \
      nslookup kubernetes.default.svc.cluster.local

Worth knowing: CoreDNS reloads the Corefile on its own within a minute or two,
but a `rollout restart` makes the feedback loop immediate.
