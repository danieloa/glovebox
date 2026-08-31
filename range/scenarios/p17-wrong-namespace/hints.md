## 1
Everything you have looked at is healthy. Before doubting the cluster, check
that you and the incident are talking about the same place. An unqualified
`kubectl get` answers about exactly one namespace.

## 2
    kubectl config current-context
    kubectl config view --minify -o jsonpath='{..namespace}'
    kubectl get pods -A | grep orders

The last command is the one that ends this. `-A` is how you stop assuming.

## 3
The kubeconfig you were handed defaults to `p17-wrong-namespace`, so `get pods`
has been answering about staging the whole time. Production is `p17-prod`: the
Service is there, the Deployment was applied to the wrong namespace during the
release, and nothing is behind it.

    kubectl -n p17-wrong-namespace get deploy orders -o yaml \
      | kubectl -n p17-prod create -f -

Then stop being able to make this mistake again:

    kubectl config set-context --current --namespace=p17-prod

Verify: `kubectl -n p17-prod get endpointslice` lists a ready address. In
glovebox this one is cheap to avoid — the prompt shows the context and
namespace, and `kt-env` says which namespace you are about to act on before you
act on it.
