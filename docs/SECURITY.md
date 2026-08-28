# Threat model

What this protects against, what it does not, and where the real boundary is.
Written plainly because a security control you have overstated is worse than one
you never built.

## What you are actually defending against

You have been sent a kubeconfig and possibly an SSH key by someone you do not
know well, for a cluster you did not build, and you have to run commands against
it. There are three distinct risks, and they deserve different answers:

1. **You make a mistake.** A `kubectl delete` in the wrong terminal; a context
   left pointed at their cluster after the exercise ended.
2. **The agent makes a mistake.** It reaches for `scale` when you asked it to
   diagnose, or "fixes" something you never asked it to touch.
3. **The bundle is hostile.** The kubeconfig contains an `exec` credential
   plugin that runs an arbitrary binary; a manifest in the bundle is a
   payload — you were, after all, invited to run things.

## What the container gives you

Against **(3)**, and against the general problem of an unknown credential loose
on your laptop:

| Control | Effect |
|---|---|
| `--rm` + no volumes but the bundle | nothing survives the session |
| `-v bundle:/bundle:ro` | their files cannot be modified, and are never in an image layer |
| no credentials in any `COPY` or `ARG` | `docker history` reveals nothing |
| `ANTHROPIC_API_KEY` passed at run time | the key is never written to a layer |
| non-root user (`sre`, uid 1000) | no root inside the container |
| `--cap-drop ALL` | no capabilities at all |
| `--security-opt no-new-privileges` | no setuid escalation path |
| `--pids-limit 512`, `--memory 4g` | a fork bomb does not take the laptop |
| no published ports | nothing in the container is reachable from outside |
| your `~/.kube`, `~/.aws`, SSH agent are **not** mounted | your own credentials are not in scope |

**A container is a blast-radius reducer, not a hard boundary.** It shares the
host kernel. A kernel exploit escapes it. This posture is appropriate for a
hiring assessment; it is not appropriate for running something you actively
believe to be malware.

## What the guard shims give you

`/usr/local/bin/kubectl` and `/usr/local/bin/aws` are wrappers
(`image/guard-*.sh`) that scan the argument vector and refuse mutating verbs
unless `GB_MODE=rw`. They are owned by root and mode 0755: the runtime user can
execute them and cannot edit them.

The argument scan walks the whole argv rather than reading `$1`, because
`kubectl -n kube-system --context=prod delete pod x` puts the dangerous word in
position five. `--as` and `--as-group` are refused outside `rw` regardless of
verb, since impersonation defeats the point of running under a scoped identity.
`config` and `rollout` are split by subcommand — `config view` reads,
`config set-credentials` writes; `rollout status` reads, `rollout restart` does
not.

This addresses **(1)** and **(2)** well. It is a real control, and it is the
reason `gb agent` is safe to point at a cluster you care about.

**It is not a capability boundary.** Anything that can run `kubectl` can also
read `$KUBECONFIG` and issue the same request to the API server over plain
HTTPS, with `curl`, with a Python script, with anything. The shims stop
mistakes — including a model's mistakes — because a mistake goes through
`kubectl`. They do not stop a deliberate circumvention, and nothing at the CLI
layer can.

The agent is told this directly in `claude/AGENT.md`: a refusal is a policy
decision, not an obstacle, and it should stop and say so rather than route
around it. That is an instruction, and instructions are not enforcement. Which
is why:

## The real boundary is the credential

```bash
./gb scope [sa-name] [namespace]
```

This creates a ServiceAccount bound to Kubernetes' built-in `view` ClusterRole,
mints an 8-hour token for it, and writes `kubeconfig.readonly` using that token.
Run the agent against that kubeconfig and read-only stops being a promise about
the client and becomes a fact about the cluster, enforced by the API server,
which does not care what CLI the request came from.

It needs write access to create the ServiceAccount — which is exactly why it
runs on the host, deliberately, by you, and nowhere near the agent.

Revoke it when you are done:

```bash
kubectl delete sa -n <ns> <name>
kubectl delete clusterrolebinding <name>-view
```

The AWS equivalent is the same idea and is easier: assume a role with
`ReadOnlyAccess`, or attach an inline `Deny` on everything mutating. Then the
`aws` guard is a convenience rather than a control.

## Order of preference

1. **A scoped credential** (`gb scope`, or a read-only IAM role). Enforced
   server-side. Use this whenever you have the rights to create one.
2. **The guard shims + the container.** Stops every accident, including the
   agent's. This is the default and it is usually enough.
3. **Nothing.** `--rw` on a cluster you own.

## Things this does not do

- It does not sandbox the kubeconfig's `exec` credential plugins. If the bundle
  ships one, it runs inside the container as `sre` — which is why the container
  exists, but be aware that it runs at all.
- It does not filter what the agent sends to the Anthropic API. Cluster output —
  pod names, namespaces, log lines, and anything an application logged — goes
  into the context window. If the assessment involves data you are not permitted
  to send to a third party, do not use `gb agent`; `gb shell` sends nothing
  anywhere.
- It does not scan the bundle for anything.
- It does not stop you typing `GB_MODE=rw` yourself. It is a seatbelt, not a
  lock.
