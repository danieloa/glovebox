## 1
No failing pods and no pods is not a bug in your triage — it is the answer.
Nothing failed here. Ask what the deployment was *told* to run.

## 2
    kubectl -n p18-scaled-to-zero get deploy notifications
    kubectl -n p18-scaled-to-zero get deploy notifications \
      -o jsonpath='{.spec.replicas} paused={.spec.paused}{"\n"}'
    kubectl -n p18-scaled-to-zero rollout history deploy/notifications

Two separate switches are off. Also worth checking on a real cluster:
`kubectl get hpa` — an HPA with `minReplicas: 0` will helpfully undo your scale.

## 3
Replicas is 0 and the rollout is paused.

    kubectl -n p18-scaled-to-zero scale deploy/notifications --replicas=3
    kubectl -n p18-scaled-to-zero rollout resume deploy/notifications

Scaling alone brings the service back and leaves a trap: a paused deployment
accepts edits to its pod template and never rolls them out, so the next release
appears to succeed and changes nothing. Fix both.

The change-cause annotation names an incident on the 14th. Worth a sentence in
the write-up — this is the failure mode where the cluster is doing exactly what
it was told and the defect is in the telling.
