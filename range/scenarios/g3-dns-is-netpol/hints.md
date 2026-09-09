## 1
Before accusing CoreDNS, establish whether it is CoreDNS. It serves the whole
cluster: if it were down, every namespace would fail, and only this one does.
Test the same lookup from a pod elsewhere.

## 2
CoreDNS is healthy, `svc/kube-dns` has ready endpoints, its logs are clean —
so the query is not being answered badly, it is not arriving. Something between
the pod and port 53 is dropping it:

    kubectl -n scenario-g3 get netpol
    kubectl -n scenario-g3 describe netpol default-deny-egress

## 3
The egress policy allows traffic to pods in this namespace and nothing else.
kube-dns lives in kube-system, so every DNS query is dropped, and every
hostname fails. Add an egress allow for DNS:

    kubectl -n scenario-g3 patch netpol default-deny-egress --type=json -p '[{
      "op":"add","path":"/spec/egress/-","value":{
        "to":[{"namespaceSelector":{},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}],
        "ports":[{"protocol":"UDP","port":53},{"protocol":"TCP","port":53}]}}]'

Both protocols: UDP for the common case, TCP for responses that do not fit in a
datagram, and a UDP-only allow fails intermittently on large answers — which is
a genuinely horrible thing to debug later.

The localiser worth keeping: **connect by pod IP, then by name.** IP works and
name fails means resolution. Both fail means the path itself. This one is the
first, and the cause is still not DNS.
