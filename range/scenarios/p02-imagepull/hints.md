## 1
`ImagePullBackOff` is a family, not a diagnosis. The Events at the bottom of
`describe pod` carry the exact pull error, and the four causes it can be — bad
tag, bad name, missing pull secret, unreachable registry — read differently.

## 2
Look at the `Failed to pull image` event verbatim. `manifest unknown` means the
registry answered and the tag is not there; `pull access denied` means auth;
a timeout means the registry is unreachable. This one is the first.

## 3
The tag is a typo: `nginx:1.27-alpin`, missing the final `e`.

    kubectl -n scenario-p02 set image deploy/catalog app=nginx:1.27-alpine

Verify: the pod moves ImagePullBackOff -> ContainerCreating -> Running. Note
that the old ReplicaSet stays at 0 — that is correct, not a leftover fault.
