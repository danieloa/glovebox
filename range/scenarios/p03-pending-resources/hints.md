## 1
Pending means the scheduler looked and declined. It always says why, in an
event on the pod. Read it before you look at the nodes.

## 2
`kubectl describe pod POD` -> `0/3 nodes are available: Insufficient memory,
Insufficient cpu`. Now compare what is being asked for against what a node has:
`kubectl describe node NODE` shows Allocatable versus Allocated.

## 3
The request is `900Gi` memory and `200` CPU — a unit error for what should be
`900Mi`. Right-size it in the deployment:

    kubectl -n scenario-p03 set resources deploy/reports \
      --requests=cpu=100m,memory=128Mi --limits=cpu=500m,memory=256Mi

Verify: `kubectl -n scenario-p03 get pod -o wide` now shows a NODE.
Do not fix this by deleting the requests — an unrequested pod is BestEffort and
is the first thing evicted under pressure.
