---
name: incident-report
description: Turn a diagnosis into the written deliverable - a take-home assessment write-up, an incident postmortem, or a handover note. Use after troubleshooting, when asked to write up findings, produce a report, document what was found, or explain a diagnosis to someone who was not present.
---

# Writing up what you found

The diagnosis is half the deliverable. For a take-home, the write-up *is* the
thing being graded: the reviewer cannot see your terminal, only what you claim
happened in it. For an incident, the write-up is what stops the same thing
happening again.

## Structure

### Summary — three sentences, no jargon
What was broken, what caused it, what state it is in now. Written so a manager
can read only this and be correctly informed. Put the number of *distinct* faults
here: "three independent faults" tells the reader immediately that this was not a
single-cause incident.

### Findings — one section per fault, ordered by layer, lowest first
For each:

- **Symptom** — what an observer saw.
- **Evidence** — the actual output. Quote the event, the exit code, the log line.
  Trim it to the lines that matter; a 200-line paste is not evidence, it is an
  invitation to skim.
- **Cause** — the mechanism, stated so the symptom becomes predictable from it.
  "The readiness probe hits `/healthz` on port 8080; the container listens on
  9090" is a cause. "The probe was misconfigured" is a restatement of the symptom.
- **Fix** — the exact command or manifest diff. Not a description of a fix.
- **Verification** — how you confirmed it, or would confirm it. Test against the
  original symptom, not against the thing you changed: a Deployment reporting
  `1/1` proves the Deployment is happy, not that the site loads.

Lowest-layer-first ordering is deliberate: it lets the reader see which faults
were causes of others and which were genuinely independent.

### What I did not do
The section that separates senior from mid-level, and the one most people omit.
State what you deliberately left alone and why — the change you would not make on
someone else's cluster without asking, the fault you found but judged out of
scope, the fix you know is a workaround rather than a cure. This is the section
that demonstrates judgement rather than throughput.

### If I had longer
Two or three specific things, with a reason each. Not "add more monitoring" —
"alert on the `readiness probe failed` event for this Deployment; it preceded the
outage by eleven minutes and nothing was watching for it."

## Rules

**Never present inference as observation.** "The pod was OOMKilled (exit 137,
`reason: OOMKilled` in `lastState`)" is an observation. "The application has a
memory leak" is an inference from one data point, and should be labelled as one.

**Quote the evidence, do not paraphrase it.** A reviewer checking your work is
checking whether the quoted line actually says what you claim.

**Show commands as run, with their output.** The audit transcript
(`/work/gb-audit-*.log`) is the record of everything the toolkit executed; it is
a legitimate appendix and it makes the report verifiable.

**State uncertainty where it exists.** "I could not determine X because Y; here
is what would settle it" is a finding, and a reader who has been in the same
position will trust the rest of the report more for it.

**Keep the fix minimal.** Propose the smallest change that addresses the cause,
and note separately anything larger you would recommend. Conflating "the fix" with
"everything I would change about this system" makes both harder to evaluate.
