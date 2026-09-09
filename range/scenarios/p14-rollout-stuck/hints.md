## 1
A stuck rollout is not one failure, it is a healthy old ReplicaSet and an
unhealthy new one. Look at both, and at the pods belonging to the new one — the
real fault is an ordinary pod failure wearing a rollout costume.

## 2
    kubectl -n scenario-p14 get rs -o wide
    kubectl -n scenario-p14 describe pod NEW_POD | tail -20
    kubectl -n scenario-p14 rollout history deploy/storefront

The new ReplicaSet has 0 available and its pod cannot pull its image. Note that
`maxUnavailable: 0` is why the site never went down and also why this can sit
here forever: no old pod is retired until a new one is ready.

## 3
The release set a tag that does not exist. Two legitimate answers, and which one
is right depends on whether you are on a clock with users watching:

    # restore service first, investigate after — the reflex under pressure
    kubectl -n scenario-p14 rollout undo deploy/storefront

    # or fix forward, if you know the correct tag
    kubectl -n scenario-p14 set image deploy/storefront app=nginx:1.27-alpine

Verify: `kubectl rollout status deploy/storefront` returns, and desired ==
updated == ready. Say out loud which of the two you chose and why — that choice
is the thing being assessed here, more than the command.
