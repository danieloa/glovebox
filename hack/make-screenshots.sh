#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# make-screenshots.sh — regenerate the terminal images in the README.
#
# Stands up a kind cluster, plants the five fixture faults, runs the real verbs
# against it, and renders their actual ANSI output to SVG. Nothing is typed by
# hand or touched up afterwards, which is the point: for a repo that is
# fundamentally about diagnostic output, a screenshot nobody else can reproduce
# proves nothing.
#
#     ./hack/make-screenshots.sh            build the image first if needed
#     ./hack/make-screenshots.sh --keep     leave the cluster up afterwards
#
# Requires kind and docker. Takes a couple of minutes, most of it waiting for
# the faults to actually reach their failing states — a pod is not in
# CrashLoopBackOff until it has crashed a few times.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=gb-shot
IMG=docs/img
BUNDLE="$(mktemp -d)"
KEEP=0
[ "${1:-}" = --keep ] && KEEP=1

cleanup() {
  rm -rf "$BUNDLE"
  [ "$KEEP" = 1 ] || kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v kind >/dev/null || { echo "!! kind is required"; exit 1; }
docker image inspect glovebox >/dev/null 2>&1 || ./gb build

mkdir -p "$IMG"

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "==> creating cluster $CLUSTER"
  kind create cluster --name "$CLUSTER" >/dev/null
fi
echo "==> planting fixture faults"
kubectl --context "kind-$CLUSTER" apply -f hack/selftest-faults.yaml >/dev/null
kind get kubeconfig --name "$CLUSTER" --internal > "$BUNDLE/kubeconfig"

# Wait for the faults to actually manifest. Applying the manifest is not the
# same as the cluster having reacted to it: ImagePullBackOff takes a pull
# attempt and a back-off, CrashLoopBackOff takes several restarts.
echo "==> waiting for faults to reach their failing states"
# Specifically the *BackOff* states, not the Error/ErrImagePull that precede
# them. Both are correct, but the back-off names are the ones an SRE recognises
# instantly, and a screenshot caught a few seconds too early shows the less
# legible half of the lifecycle.
for _ in $(seq 40); do
  states="$(kubectl --context "kind-$CLUSTER" -n shop get pods --no-headers 2>/dev/null | awk '{print $3}')"
  if grep -q ImagePullBackOff <<<"$states" && grep -q CrashLoopBackOff <<<"$states"; then break; fi
  sleep 5
done

# shot <file> <title> <sed-range> <command...> — run a verb inside the
# container, keep its ANSI colour, slice out the section of interest, render it.
#
# The sed range is passed as an argument rather than held in a variable used as
# `| "$FILTER" |`, which would try to execute the entire string as a single
# command name. Small thing, but it fails in a confusing way.
shot() {
  local out="$1" title="$2" range="$3"; shift 3
  echo "==> $title"
  GB_DOCKER_ARGS="--network kind" ./gb shell "$BUNDLE" <<< "$*" 2>/dev/null \
    | sed -n "$range" \
    | python3 hack/ansi2svg.py --title "$title" > "$IMG/$out"
  printf '    %s (%s bytes)\n' "$IMG/$out" "$(wc -c < "$IMG/$out" | tr -d ' ')"
}

# The unhealthy-pods block from kt-triage: its banner through to the blank line
# before the next section.
shot kt-triage-unhealthy.svg "kt-triage" '/UNHEALTHY/,/^$/p' "kt-triage"

# The endpoints block from kt-net, including both warnings and their notes.
# The range ends on the first blank line rather than on the text of the last
# note: every line carries a trailing ANSI reset, so an anchored /probe$/ does
# not match and the range silently runs to the end of the output.
shot kt-net-endpoints.svg "kt-net shop" '/ENDPOINTS/,/^$/p' "kt-net shop"

echo
echo "done. Regenerate any time; the images come from a live cluster."
