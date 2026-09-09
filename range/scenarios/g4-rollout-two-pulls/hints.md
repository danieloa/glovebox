## 1
`ImagePullBackOff` is a symptom shared by four unrelated causes. Read the
Events verbatim, every time, and read them again after each change — the state
name will not change even when the reason does.

## 2
    kubectl -n scenario-g4 describe pod NEW_POD | tail -15

`manifest unknown` — the registry answered and that tag is not there. Fix the
tag and look again: the state is still ImagePullBackOff and the message is now
`pull access denied ... may require 'docker login'`. That is a different
failure. Two bugs went out in one image reference.

## 3
The reference is `docker.io/gbprivate/checkout:1.27-alpin3`: a private
repository the cluster cannot authenticate to, and a mistyped tag. The release
notes on the deployment say what it should have been.

    kubectl -n scenario-g4 set image deploy/checkout app=nginx:1.27-alpine

Under time pressure, restore service first and fix forward after:

    kubectl -n scenario-g4 rollout undo deploy/checkout

The sibling case, which reads identically and is worth recognising: the
repository is right and genuinely private, the `regcred` secret exists — in the
`default` namespace. imagePullSecrets are namespace-scoped, so a workload in
`prod` cannot use a secret in `default`. Recreate it in the workload's own
namespace and reference it there.
