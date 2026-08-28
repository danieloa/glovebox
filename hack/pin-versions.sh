#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Freeze the Dockerfile's "latest" ARGs to the current upstream releases.
#
# Run this before an assessment. Two reasons: a build that resolves "latest" can
# change under you between the rehearsal and the real thing, and GitHub's
# unauthenticated API rate limit (60/hour) will eventually bite on a shared IP.
set -euo pipefail
cd "$(dirname "$0")/.."

gh_latest() {
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" | grep -m1 '"tag_name"' | cut -d'"' -f4
}

# A plain list of "ARG=owner/repo" rather than an associative array: this
# script runs on the host, and macOS ships bash 3.2, which has no `declare -A`.
PINS="
HELM_VERSION=helm/helm
K9S_VERSION=derailed/k9s
STERN_VERSION=stern/stern
YQ_VERSION=mikefarah/yq
KREW_VERSION=kubernetes-sigs/krew
EKSCTL_VERSION=eksctl-io/eksctl
"

for entry in $PINS; do
  arg="${entry%%=*}"; repo="${entry##*=}"
  v="$(gh_latest "$repo")"
  echo "  $arg=$v"
  sed -i.bak "s|^ARG ${arg}=.*|ARG ${arg}=${v}|" Dockerfile
done

kubectl_v="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
echo "  KUBECTL_VERSION=$kubectl_v"
sed -i.bak "s|^ARG KUBECTL_VERSION=.*|ARG KUBECTL_VERSION=${kubectl_v}|" Dockerfile

kz="$(curl -fsSL 'https://api.github.com/repos/kubernetes-sigs/kustomize/releases' | grep -m1 '"tag_name": *"kustomize/' | cut -d'"' -f4 | sed 's|kustomize/||')"
echo "  KUSTOMIZE_VERSION=$kz"
sed -i.bak "s|^ARG KUSTOMIZE_VERSION=.*|ARG KUSTOMIZE_VERSION=${kz}|" Dockerfile

rm -f Dockerfile.bak
echo
echo "Dockerfile pinned. Rebuild with ./gb build --no-cache and commit the result."
