## 1
The pod is healthy and its API calls are not. Read the exact error — a 401 and
a 403 are different problems. 401 means the API server does not know who you
are; 403 means it knows and is saying no.

## 2
Reproduce the decision without guessing, by asking the API server the same
question the app is asking:

    kubectl auth can-i list pods \
      --as=system:serviceaccount:scenario-p13:watcher -n scenario-p13

Then look at what does exist:

    kubectl -n scenario-p13 get sa,role,rolebinding

## 3
The ServiceAccount `watcher` exists but nothing grants it anything. Create a
Role with exactly the verbs the sidecar needs and bind it:

    kubectl -n scenario-p13 create role pod-reader \
      --verb=get,list,watch --resource=pods
    kubectl -n scenario-p13 create rolebinding watcher-pod-reader \
      --role=pod-reader --serviceaccount=scenario-p13:watcher

Verify: `kubectl auth can-i ...` returns `yes` and the sidecar's log flips to
success within ten seconds — no restart needed; the token was always valid, it
is the authorisation that changed.

Binding `cluster-admin` also silences the error. It is the answer that gets
found in a post-incident review six months later.
