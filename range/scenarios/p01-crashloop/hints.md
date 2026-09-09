## 1
The pod has been up and down several times, so there is a previous instance
whose output still exists. Read what it said on the way out before theorising.

## 2
`kubectl logs POD --previous` prints the dead container's stdout, and this
container is polite enough to say why it gave up. Then ask where that value was
supposed to come from — `describe pod` shows the env the container actually got.

## 3
The container exits 1 because `DB_HOST` is unset. Nothing in the pod spec sets
it. Add it to the deployment — the spec, not the live pod, or the next
ReplicaSet rollout throws your fix away:

    kubectl -n scenario-p01 set env deploy/checkout DB_HOST=postgres.internal

Verify: `kubectl -n scenario-p01 get pod -w` — Ready 1/1 and RESTARTS stops
climbing. A pod that is Running is not the same as a pod that has stopped
crashing; watch it for a few seconds before you believe it.
