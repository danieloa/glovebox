## 1
Start where any Pending starts: the scheduler's event on the pod. Then — and
this is the whole exercise — watch the pod all the way to Ready rather than
declaring victory when it leaves Pending.

## 2
Layer 1 is an ordinary oversized memory request (`800Gi`). Fix it and the pod
schedules immediately, and then starts crash-looping. That is a second,
unrelated bug that was simply unreachable before, and `logs --previous` reads
it out.

## 3
    # layer 1 — the request is a unit error
    kubectl -n g1-pending-then-crash set resources deploy/indexer \
      --requests=memory=128Mi --limits=memory=256Mi

    # layer 2 — revealed once it runs: a ConfigMap that was never created
    kubectl -n g1-pending-then-crash create configmap indexer-config \
      --from-literal=url=http://search.internal:9200

The rule this scenario exists to build: **re-run your triage after every fix.**
Fixing scheduling only ever exposes the runtime; a pod that has stopped being
Pending has told you nothing about whether it works. Watch through to `1/1
Ready` with a stable restart count, every time.
