## 1
It hangs rather than refusing, and the same request works from another
namespace. A packet dropped silently, for some sources and not others, is a
policy decision — not routing, not ports. Something in this namespace is
making that decision.

## 2
    kubectl -n scenario-p10 get netpol
    kubectl -n scenario-p10 describe netpol backend-allow

The rule to internalise: the moment any NetworkPolicy selects a pod, that pod
becomes default-deny for the direction the policy covers. An "allow" policy is
also a deny of everything it does not mention.

## 3
`backend-allow` permits ingress only from pods labelled `role=frontend`. The
frontend pods are labelled `app=frontend`. Fix the rule to name the label the
callers actually have:

    kubectl -n scenario-p10 patch netpol backend-allow --type=json -p \
      '[{"op":"replace","path":"/spec/ingress/0/from/0/podSelector/matchLabels","value":{"app":"frontend"}}]'

Labelling the frontend `role=frontend` instead is equally correct if that is
the convention the policy is written to. Deleting the policy is not — it makes
the symptom go away by giving up the isolation.

Verify with a real request from the real caller:

    kubectl -n scenario-p10 exec deploy/frontend -- wget -qO- -T3 http://backend/
