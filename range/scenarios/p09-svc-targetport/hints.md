## 1
Refused is a much stronger signal than timed out: something answered, at the
network level, to say nothing is listening there. So the address is right and
the port is not. Two ports are involved — the one the Service publishes and the
one it forwards to.

## 2
    kubectl -n p09-svc-targetport get svc api -o yaml | grep -A3 ports
    kubectl -n p09-svc-targetport exec deploy/api -- netstat -ltn

Compare `targetPort` with what the container actually has open. Do not trust
`containerPort` for this — it is documentation, and the kubelet does not enforce
it.

## 3
`targetPort` is 80; the app listens on 8080.

    kubectl -n p09-svc-targetport patch svc api \
      -p '{"spec":{"ports":[{"port":80,"targetPort":8080}]}}'

Verify from inside the cluster, not with port-forward alone:

    kubectl -n p09-svc-targetport run t --rm -it --image=busybox:1.36 \
      --restart=Never -- wget -qO- http://api:80/

The pair worth memorising: no endpoints -> selector/readiness; endpoints but
refused -> port mapping. `kubectl get svc` shows neither.
