# Offering this in an assessment

Notes to self, written down because the failure modes here are social rather
than technical and are easy to walk into.

## Ask first. Every time.

Some companies forbid AI assistance in assessments outright, some allow it if
disclosed, some actively want to see it. Using it unasked in the first group is
an instant fail, and it is the kind of fail that gets discussed after you leave
the room. There is no version of asking that costs you anything.

The offer, roughly:

> "I've built a container I use for this kind of exercise — a hardened shell
> plus an agent that can do a first pass on the diagnosis. I'm happy to use it,
> or to work without it, whichever tells you more about me. What would you
> prefer?"

That framing does two things. It discloses before you touch anything, and it
makes clear you can do the work either way — which is the actual question they
are asking.

## Have the manual path genuinely ready

If they say no, `gb shell --ro` is still a much better shell than a bare
terminal, and every `kt-*` verb is a bundle of commands you could type by hand.
Using a toolkit you wrote is not the thing anyone means by AI assistance — it is
what a working SRE's shell looks like — but do not argue the point. If they want
you in a plain terminal, work in a plain terminal, and know the underlying
commands cold. The toolkit's own source is the study guide for that: every
function documents which commands it runs and why that evidence answers that
question.

## If they say yes, show the right thing

The instinct is to demo the agent. Resist it — an LLM diagnosing a cluster is
not novel in 2026 and it is not what distinguishes you. The interesting parts
are the ones that show engineering judgement about **giving an agent access to
production**:

- **The guard shims.** A verb allow-list in front of `kubectl`, scanning the
  whole argv, splitting `config view` from `config set-credentials` and
  `rollout status` from `rollout restart`. Three modes, and `probe` — read plus
  `exec`, no API writes — because that is where real diagnosis actually lives.
- **`gb scope`.** The part that says: the shims stop mistakes, they are not a
  boundary, because anything holding the kubeconfig can talk to the API server
  directly. The real control is a ServiceAccount bound to `view`. Knowing which
  of your own controls is load-bearing is the senior signal.
- **The transcript.** Every command, allowed or refused, in `/work/gb-audit-*`.
- **The skills.** `claude/skills/k8s-triage/SKILL.md` is a written diagnostic
  methodology. It is your reasoning, legible, reviewable, and version
  controlled — which is a better artifact than any answer the model produces.

## Do not let the agent talk for you

The failure mode that ends the interview: the agent produces a plausible
diagnosis, you relay it, and someone asks "why is the readiness probe on 8080?"
and you have no answer because you did not read the evidence yourself.

So: use it for the first sweep, then verify every finding against the output
before you say it out loud. `kt-snapshot` exists partly for this — it puts the
raw evidence on disk in a form you can read at your own pace while the agent is
still working. If a claim is not supported by something you have personally
seen, do not make it.

## Suggested shape for a timed exercise

| Time | |
|---|---|
| 0–2 min | Ask. Then `gb shell`, `kt-env`, `kt-triage`. Say what you see out loud. |
| 2–5 min | `kt-snapshot` — freeze the evidence before touching anything. |
| 5–8 min | If allowed, `gb agent "..."` in one window while you read the snapshot in another. Parallel, not sequential. |
| 8–25 min | Work the faults bottom-up. Verify every agent claim against the snapshot. `kt-diff` before any change. |
| 25–35 min | Apply fixes one at a time. Verify against the original symptom, not the thing you changed. |
| 35–40 min | The write-up. `incident-report` skill, or by hand — same structure either way. |

## Practical

- **Pin versions before the day.** `hack/pin-versions.sh`, then rebuild and
  commit. A build that resolves "latest" can break under you, and GitHub's
  unauthenticated API limit is 60/hour on a shared IP — conference wifi and
  co-working spaces both count as one IP.
- **Build the image the night before.** Not while someone is watching a screen
  share. It is 2GB.
- **Check `gb doctor`** before the call.
- **Pin `KUBECTL_VERSION`** to their cluster's server minor if they tell you.
  Two minors of skew silently drops fields from `get -o yaml`, which is a
  miserable thing to debug while already debugging something else.
- **Test with `hack/selftest-faults.yaml`** on a local kind cluster so the first
  time you run `kt-triage` is not in front of an audience.

## Rehearsing the exercise itself

The fixture proves the toolkit works. It does not prepare you, because you wrote
it and you know all five answers.

`gb range` is for the other half. One unknown fault at a time, graded, with the
clock running:

```bash
./gb range exam 4      # four faults, no symptoms given, timed
./gb range shell       # then work it exactly as you would on the day
./gb range check
```

What is worth practising there, in rough order of how often it decides the
outcome:

- **`exam`, not `up`.** A single fault at a time teaches the mechanism; several
  at once teaches triage order under time pressure, which is the thing actually
  being assessed. `kt-triage` first, say what you see out loud, then pick the
  order deliberately and say why.
- **The compound scenarios (`g1`–`g6`).** Every one of them punishes declaring
  victory early: the pod leaves `Pending` and starts crash-looping, the Service
  gets endpoints and still refuses connections. Re-running triage after each fix
  is a habit you either have or do not, and it is very visible to whoever is
  watching.
- **`p16` and `p15` on a clock.** A dead API server or a stopped kubelet is
  where people freeze, because every command they know stops working. Having
  done it once, calmly, is worth more than knowing the commands.
- **`p17`.** The wrong-namespace one. It is the least interesting failure in the
  set and the most common way to lose ten minutes.

Then read the `hints.md` for anything you had to look up — level 3 is the fix,
but the reasoning is in levels 1 and 2, and that is the part you have to be able
to say out loud.

## If it breaks live

Say so, plainly, and switch to plain `kubectl`. A tool failing is not
interesting; how you respond to it is, and reaching calmly for the fallback
you already have is a better answer than any successful demo. Do not debug your
own tooling on their clock.
