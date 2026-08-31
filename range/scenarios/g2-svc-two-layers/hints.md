## 1
"Service unreachable" is a chain with two links, and they fail independently:
does the Service select any ready pods, and does it forward to a port the app
has open. Check them in that order and do not stop at the first.

## 2
    kubectl -n g2-svc-two-layers get endpointslice -l kubernetes.io/service-name=inventory

Empty — so layer 1 is the selector. After you fix it, endpoints appear and the
request *still* fails, now refused rather than hanging. That change in symptom
is the signal you have moved down a layer:

    kubectl -n g2-svc-two-layers exec deploy/inventory -- netstat -ltn

## 3
    # layer 1 — the selector says app=inventory-svc, the pods are app=inventory
    kubectl -n g2-svc-two-layers patch svc inventory \
      -p '{"spec":{"selector":{"app":"inventory"}}}'

    # layer 2 — revealed once endpoints exist: the app listens on 8080
    kubectl -n g2-svc-two-layers patch svc inventory \
      -p '{"spec":{"ports":[{"port":80,"targetPort":8080}]}}'

Read the symptom change as evidence. Hanging means nothing is receiving the
packet — selector or readiness. Connection refused means something received it
and had nothing listening — port mapping. `kubectl get svc` shows neither, which
is why it is the wrong first command for this.
