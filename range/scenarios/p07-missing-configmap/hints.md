## 1
Scheduled but never started is a narrow window: the kubelet accepted the pod
and then could not build the container. Whatever it could not find, it names.

## 2
`kubectl describe pod POD` -> the pod is in `CreateContainerConfigError` and
the event reads `configmap "billing-config" not found`. Confirm what does exist
in the namespace:

    kubectl -n p07-missing-configmap get cm,secret

## 3
The deployment sources `APP_MODE` from a ConfigMap key that was never created.
Create it:

    kubectl -n p07-missing-configmap create configmap billing-config \
      --from-literal=mode=production

The pod recovers on its own — the kubelet retries, no rollout needed. Verify:

    kubectl -n p07-missing-configmap exec deploy/billing -- env | grep APP_MODE

Watch the whole reference, not just the name: a ConfigMap that exists but is
missing the *key* fails identically, and so does one in the wrong namespace.
