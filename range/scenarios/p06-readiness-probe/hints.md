## 1
Running and Ready are different claims. Running means the container started;
Ready means the kubelet's readiness probe succeeded. Only one of those is
failing, and the kubelet records why.

## 2
`kubectl describe pod POD` -> Events: `Readiness probe failed: dial tcp
...:8080: connect: connection refused`. Refused, not 404 — nothing is listening
on that port at all. So ask what the container *is* listening on:

    kubectl -n p06-readiness-probe exec POD -- netstat -ltn

## 3
The probe targets port 8080; nginx listens on 80 and serves `/healthz` there.
Fix the port in the deployment:

    kubectl -n p06-readiness-probe patch deploy web --type=json -p \
      '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":80}]'

Verify: pods go 1/1, and `kubectl -n p06-readiness-probe get endpointslice`
shows two ready addresses. Deleting the probe also turns the pods green and is
the wrong answer — the probe is the only thing standing between a half-started
pod and live traffic.
