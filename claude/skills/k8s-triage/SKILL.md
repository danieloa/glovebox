---
name: k8s-triage
description: Systematically diagnose a broken or unfamiliar Kubernetes cluster. Use when asked why pods are failing, why a service is unreachable, why a node is NotReady, why an ingress returns errors, or for any whole-cluster health assessment. Covers CrashLoopBackOff, ImagePullBackOff, Pending pods, empty endpoints, DNS failures, TLS and certificate problems, PVC binding, RBAC denials, and resource exhaustion.
---

# Diagnosing a Kubernetes cluster you did not build

## The one rule

**Collect everything before you conclude anything.** Assessment clusters and
real incidents both usually contain more than one fault. The first symptom you
find is rarely the only one, and any fix applied mid-diagnosis changes the
evidence for every fault still undiscovered — after which you cannot tell which
change caused which improvement.

So: sweep first, hypothesise second, fix last.

## Order of work

### 1. Establish where you are

```bash
kt-env          # identity, reachability, and YOUR OWN permissions
```

Check the permissions line before anything else. An empty `kubectl get pods` is
reported identically whether the namespace is empty or RBAC is denying you the
list — and mistaking one for the other costs twenty minutes.

### 2. Sweep every layer

```bash
kt-triage       # nodes, unhealthy pods, workloads, endpoints, ingress, certs, storage, warnings
kt-snapshot     # freeze it to disk before anything changes
```

`kt-snapshot` writes describes and both log streams for every unhealthy pod to
files. Reading those files is faster and cheaper than re-querying the API, and
it gives you a consistent point-in-time view rather than a cluster shifting
underneath you.

### 3. Read bottom-up, and stop at the lowest broken layer

| Layer | Verb | A fault here explains |
|---|---|---|
| Node / kubelet | `kt-nodes`, `kt-kubelet <node>` | everything above it |
| Scheduling | `kt-why <pod>` | Pending pods |
| Container runtime | `kt-crash`, `kt-image` | CrashLoop / ImagePull |
| Service / endpoints | `kt-net` | "connection refused" from a healthy-looking app |
| DNS | `kt-dns` | intermittent everything |
| Ingress | `kt-ingress` | 404 / 502 from outside |
| TLS | `kt-cert`, `kt-tls <host>` | browser warnings, handshake failures |
| Application | `kt-logs`, `kt-http <url>` | 500s |

When `kt-net` and `kt-dns` say the objects are fine but traffic still fails, test
the path from inside a pod (`probe` mode; `kt-probe-help` lists them). Bisect with
two commands: `kt-p2p <src> <dst>` reaches the pod IP directly, `kt-svc <src> <svc>`
goes through the Service and DNS. Service fails but pod IP works -> Service or
DNS (`kt-podns`, `kt-coredns`). Both fail -> CNI or NetworkPolicy (`kt-netpol`). If both
succeed, `kt-listen` on the destination: an app bound to 127.0.0.1 is Ready and
unreachable.

A finding at a low layer retires the layers above it. A node that is
`Ready=Unknown` fully explains its pods being unreachable; do not also file the
pods as a separate fault.

## Reading the signals

**Pod phase and container state are different things.** A pod can be `Running`
with a container that is not `Ready` — `kubectl get pods` shows `1/2 Running`
and it is easy to scroll past. An unready pod is deliberately removed from its
Service's endpoints, so a failing readiness probe surfaces three layers up as a
connection error with no obvious cause.

**Exit codes classify the death:**
- `137` — SIGKILL. Almost always OOMKilled (check `lastState.terminated.reason`)
  or a failing liveness probe restarting a healthy-but-slow process.
- `143` — SIGTERM. Something asked it to stop. Look at what.
- `1` / `2` — the application chose to exit. The answer is in its logs.
- `0` on a Deployment — the process completed. It was probably never a long-
  running server, or its entrypoint is wrong.

**On a CrashLoopBackOff, read `--previous` logs.** The current container was
just restarted and has not failed yet; its logs are empty or misleading. This is
the single most common wasted step. `kt-why` prints both.

**`Ready=False` vs `Ready=Unknown` on a node** are different investigations.
`False` means the kubelet is alive and telling you what is wrong — read the other
conditions. `Unknown` means the control plane has stopped hearing from it, so
nothing you do through the API will help; get onto the node with `kt-ssh`.

**A Service with zero endpoints** is the highest-yield finding in cluster
networking. It looks completely healthy in `get svc`. It means either the
selector matches no pods (a label typo) or the pods it matches are not Ready.

**A Pending pod** has exactly two common causes and its events distinguish them:
the scheduler could not place it (insufficient resources, an untolerated taint,
a node selector matching nothing) or a volume will not bind (`kt-storage`).

## Reporting

For every fault, in this order:

1. **Evidence** — the exact event, log line, exit code, or status message.
   Quote it. A claim without a quoted line is a guess.
2. **Cause** — the mechanism, stated so someone could have predicted the symptom
   from it.
3. **Fix** — the exact command or manifest. Show it with `kt-diff` rather than
   describing it.
4. **Verification** — how you would confirm it worked, tested against the
   original symptom rather than against the thing you changed.

Separate observation from inference explicitly, and say when the evidence does
not support a conclusion. "The logs are empty, so I cannot tell whether the
process started; `exec` would settle it" is a stronger answer than a confident
guess, and any competent reader can tell the difference.
