## 1
A container that dies without writing anything was not asked to stop — it was
killed. The exit code says which signal, and `describe` records the reason
under Last State.

## 2
    kubectl -n scenario-p05 get pod POD \
      -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'

`OOMKilled`, exit 137 (128 + SIGKILL). That is the kernel enforcing a cgroup
limit, not Kubernetes evicting anything, which is why there is no Event about
it and nothing in the log. Now compare what the container asks for against what
it actually uses.

## 3
`limits.memory` is 64Mi and the container buffers a 256MB frame into a
memory-backed emptyDir — which counts against the same cgroup. Raise the limit
to something the workload can actually live in:

    kubectl -n scenario-p05 set resources deploy/resizer \
      --requests=memory=320Mi --limits=memory=384Mi

Verify: RESTARTS stops rising and Last State is no longer OOMKilled. Note that
raising only the limit and not the request leaves the pod Burstable and
first-in-line for eviction; move both.
