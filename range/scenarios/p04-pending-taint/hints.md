## 1
Pending with an idle cluster is a different failure from Pending with a full
one, and the scheduler distinguishes them in its message. Read the event text
exactly — the predicate that failed is named in it.

## 2
`kubectl describe pod POD` says something like `1 node(s) had untolerated taint
{...}, 2 node(s) didn't match Pod's node affinity/selector`. That is two
separate exclusions in one line: the selector rules out two nodes, and a taint
rules out the one that is left. Look at both:

    kubectl get nodes --show-labels
    kubectl describe node NODE | grep -i taint

## 3
Worker 1 carries `gb-range/maintenance=true:NoSchedule`, and the collector is
pinned to worker 1 by a nodeSelector because its data is there. Two correct
fixes, depending on whether the maintenance is real:

    # the node is genuinely fine — remove the taint (note the trailing dash)
    kubectl taint node NODE gb-range/maintenance-

    # or the node is under maintenance and this pod must run anyway — tolerate it
    kubectl -n p04-pending-taint patch deploy collector --type=strategic -p \
      '{"spec":{"template":{"spec":{"tolerations":[{"key":"gb-range/maintenance","operator":"Exists","effect":"NoSchedule"}]}}}}'

What is NOT a fix is deleting the nodeSelector. That makes the symptom go away
by moving the pod somewhere its data is not.
