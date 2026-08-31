## 1
Reads work and writes do not. That is a very specific shape: the API server is
serving, authenticating and authorising you fine, and something is rejecting
requests after all of that. Read the error text on a failing create — it names
the component.

## 2
    kubectl -n g6-webhook-down create configmap probe --from-literal=a=b

`Internal error occurred: failed calling webhook "guard.gb-range.local": ...
connection refused`. Admission runs after authn and authz and before persistence,
which is why reads are untouched. List what is registered and find its backend:

    kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations
    kubectl -n g6-webhook-down get svc,endpointslice policy-guard

## 3
`gb-range-policy-guard` points at a Service with nothing behind it, and
`failurePolicy: Fail` means the API server refuses any write it cannot get an
opinion on. The backing deployment is gone; the configuration outlived it.

    kubectl delete validatingwebhookconfiguration gb-range-policy-guard

If the webhook were something you actually needed, the sequence is: unblock
first by setting `failurePolicy: Ignore`, restore the backing deployment, then
set it back to `Fail`. Never leave it on Ignore — a policy webhook that fails
open is a policy that is not enforced.

Order of suspicion when writes fail cluster-wide but the control plane is up:
admission webhooks first, then quotas and LimitRanges, then the API server. This
one is above the API server in that list because it fails in a way that looks
like the API server.
