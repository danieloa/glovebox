## 1
A Service is not a thing that forwards traffic; it is a label query whose result
is a list of endpoints. Ask what that query currently returns before you look at
anything else.

## 2
    kubectl -n scenario-p08 get endpointslice -l kubernetes.io/service-name=payments

Empty. So the query matches nothing — that is a statement about labels, not
about the pods' health, which is why everything else looks fine. Put the two
sides next to each other:

    kubectl -n scenario-p08 get svc payments -o jsonpath='{.spec.selector}'
    kubectl -n scenario-p08 get pods --show-labels

## 3
The Service selects `app=payment`; the pods are labelled `app=payments`. Fix
the Service, not the pods — the deployment's own selector is immutable and the
labels are correct:

    kubectl -n scenario-p08 patch svc payments -p '{"spec":{"selector":{"app":"payments"}}}'

Verify: the EndpointSlice now lists two ready addresses. This is worth
recognising instantly — empty endpoints means a selector or readiness problem,
and never a routing problem.
