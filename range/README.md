# The range

A break/fix practice range: a throwaway kind cluster that breaks itself in one
known way, hands you a ticket describing the symptom, and grades your fix by
observing the cluster.

It is the inverse of the rest of glovebox. The toolkit answers *what is broken*;
the range asks it. Same container, same `kt-*` verbs, same agent — the
difference is that here somebody has already written down the answer, and you
find out whether you found it.

```bash
./gb range list                  # 24 scenarios
./gb range up p09-svc-targetport # arm one — creates the cluster on first use
./gb range shell                 # a glovebox shell pointed at it, in --rw
#   ... kt-triage, kt-net, kt-why, and fix it ...
./gb range check                 # graded
./gb range down                  # put it back
```

Stuck: `gb range hint <id>` gives a nudge, `hint <id> 2` says where to look,
`solve <id>` gives the answer with the commands.

Under a clock, which is the point:

```bash
./gb range exam 4                # four faults at once, timed, one ticket each
```

## The brief, and what the namespace is called

Arming a scenario prints a **ticket**: what a caller reported and what has
already been ruled out, written the way an incident actually arrives and never
as a diagnosis. It is also written to `BRIEF.md` inside the range bundle, so it
lands at `/work/BRIEF.md` in `gb range shell` — the same place a real
assessment puts its task description — and `gb range brief` re-reads it from
the host.

```
  ┌─ TICKET  scenario-p18
  │
  │  The notifications endpoint returns nothing. There are no unhealthy
  │  pods in the namespace — there are no pods at all. Nothing is
  │  crash-looping, nothing is Pending, and the deployment reports no errors.
  │
  └─ namespace: scenario-p18   budget: 3 min
```

The namespace is `scenario-p18`, not `p18-scaled-to-zero`. The id names the
fault, so a namespace named after it hands over the answer before the first
`kubectl` — nobody is ever told "the incident is in namespace scaled-to-zero".
`scenario_ns()` in `lib.sh` is the one place that mapping lives, and every verb
that takes an `<id>` also takes the namespace, because in exam mode the
namespace is the only name you have:

```bash
./gb range hint scenario-p18     # same as: hint p18-scaled-to-zero
```

Exam mode withholds the two things that would answer the question — the
scenario id and its title — from `status`, from `check` on anything still
broken, and from the brief. A scenario you have solved is named in full, since
there is nothing left to give away.

## What it will not do

The range is the only thing in this repo that breaks a cluster on purpose, and
the failure mode — pointing it at a customer's context because that is what
happened to be current — is not one you apologise your way out of. So
`range_guard()` in `lib.sh` requires five independent things to be true before
anything runs:

1. The range has its **own kubeconfig**, at a fixed path. It never reads
   `$KUBECONFIG` or `~/.kube/config`, so "whatever context is current" is not an
   input to this program at all. This is the check that matters; the other four
   cover someone editing that file.
2. `kind` must agree it created a cluster of this name.
3. The context in that kubeconfig must be the one kind writes.
4. The API server must be on loopback.
5. The cluster must carry a marker ConfigMap the range itself planted.

There is no `--force`. If you are arguing with that function, you are pointed at
the wrong cluster.

## Tiers

| tier | what it touches | teardown |
|---|---|---|
| `ns` | one namespace | delete the namespace |
| `cluster` | `kube-system`, a node object, a webhook config | scripted, reversible |
| `node` | `docker exec` into a node — stops the kubelet, edits a static-pod manifest | scripted, from a host-side backup |

The node tier is where the CKA-shaped failures live, because a stopped kubelet
and a broken `kube-apiserver` manifest cannot be expressed as API objects. They
are also the ones that take the cluster down while you work, which is why they
are excluded from `exam`.

## How grading works

`verify.sh` asserts on **outcomes, not edits**. The targetPort scenario passes
when an HTTP GET through the Service returns bytes — whether you patched the
Service or reconfigured the app to listen on the other port. Asserting
`.spec.ports[0].targetPort == 8080` would grade the answer key instead of the
cluster, and would fail a fix better than the one I had in mind.

Several scenarios go further and refuse fixes that make the symptom go away
without fixing anything:

- deleting the readiness probe turns the pods green and hands live traffic to
  pods that are not serving — `p06` checks the probe still exists;
- deleting the NetworkPolicy restores traffic and gives up the isolation the
  policy was added for — `p10` and `g3` check a policy still governs the
  namespace;
- recreating the PVC schedules the pod and loses the data — `g5` checks the pod
  can still read what was written before the incident;
- `cluster-admin` silences the 403 — `p13` fails a grant wider than the app
  needs.

Kubernetes is eventually consistent, so every observation that depends on a
controller reacting gets a convergence window (`GB_CONVERGE`, default 120s).
Grading a single sample marks correct work FAIL and teaches you to distrust the
grader, which is worse than having no grader.

## Coverage

24 scenarios: P1–P18 from the CKA-style problem set, plus G1–G6, the compound
ones where you fix the obvious fault and a second appears.

```
Pods           p01 crashloop · p02 imagepull · p05 oomkilled · p06 readiness
Scheduling     p03 resources · p04 taint + nodeSelector
Config         p07 missing configmap
Networking     p08 selector · p09 targetport · p10 networkpolicy · p11 coredns
Storage        p12 pvc pending
RBAC           p13 forbidden
Rollout        p14 stuck · p18 scaled to zero + paused
Nodes          p15 kubelet stopped
Control plane  p16 broken static-pod manifest
Basics         p17 wrong namespace
Compound       g1 pending→crash · g2 selector AND targetport · g3 "DNS" that is
               a NetworkPolicy · g4 two pull failures · g5 bound PVC that still
               will not schedule · g6 admission webhook with no backend
```

## Adding a scenario

A scenario is a directory with four files:

```
range/scenarios/<id>/
  meta.env     TITLE, TIER, CATEGORY, SOURCE, BUDGET, EXAM, SYMPTOM (the ticket)
  inject.sh    break it
  verify.sh    exit 0 only when genuinely fixed
  hints.md     three '## ' sections: nudge, where to look, the answer
  teardown.sh  optional — only if it touched something outside its namespace
```

The id must be a valid DNS-1123 label; its first `-`-separated field becomes
the namespace (`p18-scaled-to-zero` → `scenario-p18`), so that field has to be
unique across the library. `SYMPTOM` is the ticket the trainee is handed —
write it as the report and the ruled-out ground, never as the diagnosis, and
keep the diagnosis in `TITLE`, which exam mode hides. Scripts source `$GB_RANGE_LIB` for `rk`, `converge`, `ep_ready`, `svc_reachable`,
`node_exec` and the `pass`/`fail` contract — which is also what stops them being
run by hand against a cluster you care about.

`hack/range-selftest.sh` asserts three things per scenario: verify FAILS on
arrival, PASSES after the reference fix, and teardown leaves the cluster usable.
A scenario that grades PASS on arrival is worse than no scenario — it sends
someone hunting through a cluster that was never broken.

## Caveats

- **NetworkPolicy needs an enforcing CNI.** kindnetd only gained enforcement
  recently. `p10` and `g3` prove the deny actually denies before arming, and
  refuse to arm if it does not, rather than handing you a fault you can never
  observe.
- The cluster is three nodes and takes a couple of minutes to create. It stays
  up between scenarios; `gb range down --cluster` removes it.
- `gb range shell` runs in `--rw`. The range is the one cluster in this repo
  where write mode is the correct default.
