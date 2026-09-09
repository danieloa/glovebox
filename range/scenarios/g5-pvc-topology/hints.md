## 1
Bound answers "was a volume provisioned", not "can this pod reach it". They are
different questions and only the scheduler answers the second — in an event on
the pod. Read it before ruling storage out.

## 2
    kubectl -n scenario-g5 describe pod POD | tail -10

`node(s) had volume node affinity conflict`. So the volume is real, and it is
somewhere the pod is not allowed to go. Look at where each of them is pinned:

    kubectl get pv -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[*].matchExpressions[*].values[*]'
    kubectl -n scenario-g5 get deploy analytics -o jsonpath='{.spec.template.spec.nodeSelector}'
    kubectl get nodes -L topology.kubernetes.io/zone

## 3
The StorageClass is `WaitForFirstConsumer`, so the volume was created on the
node the first consumer landed on — in zone-a — and its nodeAffinity pins it
there permanently. The deployment then asks for zone-b. Both constraints are
satisfiable; not together.

    kubectl -n scenario-g5 patch deploy analytics --type=json \
      -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'

Deleting and recreating the PVC also makes the pod schedule, in zone-b, with an
empty volume. It passes `get pods` and loses the data — which is the reason this
scenario checks that the pod can still read what was written before the
incident.

The lesson: a Bound PVC does not guarantee schedulability. Volume topology and
pod placement have to agree, and on a real cluster the zone is the thing that
usually disagrees.
