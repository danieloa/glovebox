# workstation

A disposable, agent-capable container for troubleshooting Kubernetes clusters
that are not yours.

Built for take-home assessments and live interview exercises: you are handed a
kubeconfig, an SSH key and a broken cluster, and you would rather not point your
laptop's shell at any of it. Start the container, work inside it, `docker rmi`
when you are done, and nothing about someone else's infrastructure ever touched
your machine.

It has two modes of use, and they are the point:

- **You drive.** A real shell — tab completion, `k9s`, `stern`, `aws`, and a
  layered triage toolkit that turns each question ("why is this pod not
  running") into one word.
- **The agent drives.** Claude Code runs inside the same container, under the
  same read-only guard rails, with a diagnostic methodology it is expected to
  follow and a transcript of every command it ran.

```bash
export ANTHROPIC_API_KEY=sk-ant-...
./ws build

cd ~/Desktop/some-assessment          # the bundle they sent you
ws shell                              # you troubleshoot
ws agent "why is the checkout service down?"   # or the agent does
ws agent --fix "fix the readiness probe"       # ...and applies it, after asking
```

---

## Why it exists

Assessment bundles come with a kubeconfig and about forty minutes. The obvious
move — `export KUBECONFIG=./kubeconfig` on your laptop — is the wrong one twice
over: you have put an unknown credential next to your own contexts, and one
absent-minded `kubectl delete` in the wrong terminal is a story you have to tell
in the debrief.

The previous version of this was a `debian:12-slim` image with `kubectl` and
`jq` in it. It worked and it was miserable: no tab completion, no `aws`, no
`k9s`, `vim-tiny`, and a bare `$` prompt that told you nothing about which
cluster you were pointed at. This is that idea done properly.

## What is in it

| | |
|---|---|
| **Kubernetes** | `kubectl` (+ completion), `k9s`, `stern`, `helm`, `kustomize`, `krew`, `kubectx`/`kubens` |
| **AWS** | `awscli v2` (+ completion), `eksctl` |
| **Network** | `dig`, `tcpdump`, `mtr`, `traceroute`, `socat`, `nc`, `telnet`, `httpie`, `ss` |
| **System** | `strace`, `lsof`, `htop`, `procps`, `ssh`, `rsync` |
| **Shell** | bash-completion, `fzf`, `ripgrep`, `bat`, `jq`, `yq`, real `vim`, a prompt that shows mode + context + namespace |
| **Agent** | Claude Code, three skills, three permission profiles |

~2GB. Versions resolve to upstream latest at build time; `hack/pin-versions.sh`
freezes them, which is what you want before an assessment you cannot rebuild
during.

## The toolkit

Read-only verbs, layered bottom-up through the stack. `kt-help` lists them all.

```
kt-env                identity, reachability, and your own RBAC
kt-triage             *** START HERE *** every layer, one screen
kt-why <pod>          why is this specific pod not running
kt-crash              every crash-looper, with exit codes
kt-image              image pull failures, with the exact image reference
kt-net                services, endpoints (ready vs not-ready), netpol, CNI
kt-dns                CoreDNS health + a real in-cluster lookup
kt-ingress            class, controller, rules, backends, logs
kt-cert / kt-tls      cert-manager chain; what certificate is actually served
kt-storage            PVCs that will not bind, and why
kt-rbac / kt-res      what an identity can do; capacity vs requests vs OOMKills
kt-snapshot           dump everything to files — the write-up, and the agent's input
kt-diff <file>        server-side dry-run: what a fix would change
```

Plus `aw-*` for the AWS layer under an EKS cluster: `aw-who`, `aw-eks`,
`aw-vpc` (subnet free-IP counts), `aw-sg`, `aw-irsa`, `aw-ecr`, `aw-triage`.

Each verb bundles the several commands that actually answer one question, so a
single word gets you the whole evidence set instead of a half-remembered
sequence under time pressure. None of them write to the cluster.

## The agent

`ws agent "<question>"` runs Claude Code inside the container with:

- **the same guard rails you have** — the `kubectl` and `aws` on its PATH refuse
  mutating verbs unless the mode allows them;
- **a methodology**, not just tools — the `k8s-triage`, `aws-eks-triage` and
  `incident-report` skills encode the order of investigation, the signals worth
  reading (exit 137 vs 143, `Ready=False` vs `Ready=Unknown`, a Service with
  endpoints that are present but not ready), and the requirement to separate
  observation from inference;
- **a transcript** — every command it ran, allowed or refused, in
  `/work/ws-audit-*.log`. That is the artifact you hand in, or scroll through
  while someone watches.

It is told to gather all the evidence before concluding anything, because these
environments are built with several independent faults and a fix applied
mid-diagnosis destroys the evidence for the ones you have not found yet.

## Modes

| Mode | kubectl | Used by |
|---|---|---|
| `ro` | reads only | `ws shell --ro`, `ws agent --ro` |
| `probe` | + `exec`, `port-forward`, `debug` — no API object is modified | **default** |
| `rw` | everything | `ws shell --rw`, `ws agent --fix` (asks first) |

`probe` is the default because most real diagnosis needs to curl a service from
inside a pod, and none of that changes anything.

**These guards stop mistakes, not attackers.** Anything holding the kubeconfig
can talk to the API server directly, without going near `kubectl`. For a real
boundary, scope the credential:

```bash
./ws scope                # mints a kubeconfig bound to the 'view' ClusterRole
```

Now read-only is a fact the API server enforces, rather than a promise the
client makes. [docs/SECURITY.md](docs/SECURITY.md) is honest about the whole
threat model, including what it does not cover.

## Usage

```bash
./ws build [--no-cache]              build the image
./ws shell [dir] [--rw|--ro]         interactive shell        (default: probe)
./ws agent [--fix] "<question>"      one-shot agent run       (default: probe)
./ws agent                           interactive Claude in the container
./ws scope [sa-name] [ns]            mint a read-only kubeconfig via RBAC
./ws doctor                          check the host is ready
./ws nuke                            remove the image
```

The bundle directory is mounted **read-only** and defaults to `$PWD`, so
`cd ~/Desktop/assessment && ws shell` is the normal way to use this. The
container copies what it needs to a writable `/work` — kubectl needs to write to
the kubeconfig, ssh refuses a key it cannot `chmod`, and you never modify the
artifacts the interviewer sent you.

Connecting to a local cluster:

```bash
WS_DOCKER_ARGS="--network kind" ws shell   # kind / k3d internal addresses
```

## Layout

```
Dockerfile              5 layers, ordered so editing a script does not re-download 400MB
ws                      the host-side driver — all docker flags and their reasons
image/
  install-tools.sh      the binary toolchain, with arch mapping and version resolution
  guard-kubectl.sh      verb allow-list; the reason `ws agent` is safe to point at a cluster
  guard-aws.sh          the same, prefix-based, for the AWS CLI
  entrypoint.sh         stages the read-only bundle into a writable /work
  shellrc.sh            completion, history, prompt, aliases
toolkit/
  k8s-triage.sh         the kt-* verbs
  aws-triage.sh         the aw-* verbs
claude/
  AGENT.md              operating instructions injected into every agent run
  settings.{ro,probe,rw}.json    permission profiles
  skills/               k8s-triage · aws-eks-triage · incident-report
  run-agent.sh
docs/
  SECURITY.md           the threat model, stated honestly
  INTERVIEW.md          how to offer this in an assessment without it backfiring
```

## Testing it

There is nothing like a broken cluster for testing a tool that diagnoses broken
clusters:

```bash
kind create cluster --name ws-selftest
kubectl apply -f hack/selftest-faults.yaml     # five deliberate, independent faults
kind get kubeconfig --name ws-selftest --internal > /tmp/b/kubeconfig
WS_DOCKER_ARGS="--network kind" ./ws shell /tmp/b
# kt-triage should show all five
```

## Licence

MIT.
