#!/usr/bin/env bash
# ==============================================================================
# install-tools.sh — fetch the workstation's binary toolchain.
#
# Runs once, as root, at image build time. Lives in its own file rather than a
# 200-line RUN layer so it stays reviewable and so version drift is fixed in one
# place.
#
# Every tool is passed in as an env var (see the ARG block in the Dockerfile).
# The literal string "latest" resolves the newest GitHub release at build time;
# anything else is used verbatim as a pinned tag. Default is "latest" so a clone
# always builds; run `hack/pin-versions.sh` to freeze the pins for reproducible
# rebuilds, which is what you want before an actual assessment.
# ==============================================================================
set -euo pipefail

# ---- arch mapping ------------------------------------------------------------
# Every upstream project spells the same two architectures differently. Resolve
# all four dialects once, up front, instead of at each call site.
#   ARCH_GO   amd64 / arm64        (Go release convention: kubectl, helm, k9s…)
#   ARCH_UNAME x86_64 / aarch64    (uname -m convention: awscli)
case "${TARGETARCH:-amd64}" in
  amd64) ARCH_GO=amd64; ARCH_UNAME=x86_64  ;;
  arm64) ARCH_GO=arm64; ARCH_UNAME=aarch64 ;;
  *) echo "unsupported TARGETARCH=${TARGETARCH:-}" >&2; exit 1 ;;
esac
echo "==> building for TARGETARCH=${TARGETARCH:-amd64} (go=$ARCH_GO uname=$ARCH_UNAME)"

BIN=/usr/local/bin
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

# ---- helpers -----------------------------------------------------------------

# say <tool> <version> — uniform progress line, so a failed build tells you which
# of a dozen downloads died without you having to count RUN steps.
say() { printf '\n\033[1;36m==> %s %s\033[0m\n' "$1" "$2"; }

# gh_latest <owner/repo> — newest release tag via the GitHub API.
#
# The response is buffered to a file before being parsed, rather than piped
# straight into grep. Piping is the obvious way to write this and it is subtly
# wrong: `grep -m1` exits the moment it matches, curl's next write hits a closed
# pipe and it exits 23, and `set -o pipefail` then kills the build with a "write
# error" that has nothing to do with writing anything. Costing an afternoon once
# is enough.
#
# /releases/latest (not /tags) is used because it skips pre-releases and drafts.
# Unauthenticated calls are rate-limited to 60/hour per IP; this script makes
# ~7, so a normal build is fine but a tight rebuild loop on a shared NAT will
# eventually trip it — the other reason to pin before you actually need this.
gh_latest() {
  local repo="$1" json="$TMP/rel.json" tag
  curl -fsSL -o "$json" "https://api.github.com/repos/${repo}/releases/latest"
  tag="$(grep -m1 '"tag_name"' "$json" | cut -d'"' -f4)"
  [ -n "$tag" ] || { echo "!! could not resolve latest release for $repo" >&2; exit 1; }
  echo "$tag"
}

# resolve <version> <owner/repo> — echo the pin, or look up "latest".
resolve() { if [ "$1" = latest ]; then gh_latest "$2"; else echo "$1"; fi; }

# strip_v <tag> — v1.2.3 -> 1.2.3. Several projects tag with a leading v but
# name the release asset without one, so both spellings are needed.
strip_v() { echo "${1#v}"; }

# dl_tar <url> [member...] — fetch a tarball to disk, then extract.
#
# Same reasoning as gh_latest: `curl | tar xz <member>` makes tar stop reading as
# soon as it has the member it was asked for, which breaks curl's pipe and fails
# the build under pipefail. Landing the archive first costs a few MB of /tmp and
# removes a whole category of confusing failure.
dl_tar() {
  local url="$1"; shift
  curl -fsSL -o "$TMP/dl.tgz" "$url"
  tar -xzf "$TMP/dl.tgz" -C "$TMP" "$@"
  rm -f "$TMP/dl.tgz"
}

# ---- kubectl -----------------------------------------------------------------
# Not on GitHub releases; the dl.k8s.io "stable.txt" pointer is the canonical
# source. Pin this to the cluster's server version when you know it: kubectl is
# supported within one minor of the API server, and a two-minor skew silently
# drops fields from `get -o yaml` output, which is a miserable thing to debug
# while you are already debugging something else.
KUBECTL_VERSION="${KUBECTL_VERSION:-latest}"
[ "$KUBECTL_VERSION" = latest ] && KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
say kubectl "$KUBECTL_VERSION"
curl -fsSLo "$BIN/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH_GO}/kubectl"
chmod 0755 "$BIN/kubectl"

# ---- helm --------------------------------------------------------------------
HELM_VERSION="$(resolve "${HELM_VERSION:-latest}" helm/helm)"
say helm "$HELM_VERSION"
dl_tar "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH_GO}.tar.gz" "linux-${ARCH_GO}/helm"
install -m 0755 "$TMP/linux-${ARCH_GO}/helm" "$BIN/helm"
rm -rf "$TMP/linux-${ARCH_GO}"

# ---- k9s ---------------------------------------------------------------------
# The single highest-value tool in here for an interview: a full-cluster TUI
# beats twenty `kubectl get` invocations when someone is watching your screen.
K9S_VERSION="$(resolve "${K9S_VERSION:-latest}" derailed/k9s)"
say k9s "$K9S_VERSION"
dl_tar "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${ARCH_GO}.tar.gz" k9s
install -m 0755 "$TMP/k9s" "$BIN/k9s" && rm -f "$TMP/k9s"

# ---- stern -------------------------------------------------------------------
# Multi-pod log tailing. `kubectl logs` takes one pod; stern takes a regex across
# a whole deployment, which is the difference between seeing a rollout fail and
# seeing one replica of a rollout fail.
STERN_VERSION="$(resolve "${STERN_VERSION:-latest}" stern/stern)"
say stern "$STERN_VERSION"
dl_tar "https://github.com/stern/stern/releases/download/${STERN_VERSION}/stern_$(strip_v "$STERN_VERSION")_linux_${ARCH_GO}.tar.gz" stern
install -m 0755 "$TMP/stern" "$BIN/stern" && rm -f "$TMP/stern"

# ---- kustomize ---------------------------------------------------------------
# Tagged as kustomize/vX.Y.Z inside a monorepo, so the tag contains a slash and
# has to be URL-encoded (%2F) in the download path.
KUSTOMIZE_VERSION="${KUSTOMIZE_VERSION:-latest}"
if [ "$KUSTOMIZE_VERSION" = latest ]; then
  # The kustomize binary lives in a monorepo whose releases include several other
  # products, so /releases/latest is often something else entirely — the list has
  # to be filtered for tags that actually start with "kustomize/".
  curl -fsSL -o "$TMP/kz.json" 'https://api.github.com/repos/kubernetes-sigs/kustomize/releases'
  KUSTOMIZE_VERSION="$(grep -m1 '"tag_name": *"kustomize/' "$TMP/kz.json" | cut -d'"' -f4 | sed 's|kustomize/||')"
fi
say kustomize "$KUSTOMIZE_VERSION"
dl_tar "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_${ARCH_GO}.tar.gz" kustomize
install -m 0755 "$TMP/kustomize" "$BIN/kustomize" && rm -f "$TMP/kustomize"

# ---- yq ----------------------------------------------------------------------
YQ_VERSION="$(resolve "${YQ_VERSION:-latest}" mikefarah/yq)"
say yq "$YQ_VERSION"
curl -fsSLo "$BIN/yq" "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH_GO}"
chmod 0755 "$BIN/yq"

# ---- krew --------------------------------------------------------------------
# kubectl's plugin manager. Installed as the binary only, no plugins: pulling
# plugins needs network at *runtime*, and the whole point of this image is that
# it works on a locked-down laptop or a conference wifi. `kubectl krew install X`
# is there if you want it and have the network.
KREW_VERSION="$(resolve "${KREW_VERSION:-latest}" kubernetes-sigs/krew)"
say krew "$KREW_VERSION"
dl_tar "https://github.com/kubernetes-sigs/krew/releases/download/${KREW_VERSION}/krew-linux_${ARCH_GO}.tar.gz" "./krew-linux_${ARCH_GO}"
install -m 0755 "$TMP/krew-linux_${ARCH_GO}" "$BIN/kubectl-krew"
rm -f "$TMP/krew-linux_${ARCH_GO}"

# ---- kubectx / kubens --------------------------------------------------------
# Plain shell scripts, no release asset needed. Worth having because switching
# context by hand (`kubectl config use-context …`) is exactly the kind of typo
# that points a "fix" at the wrong cluster.
say kubectx/kubens "(scripts)"
curl -fsSLo "$BIN/kubectx" https://raw.githubusercontent.com/ahmetb/kubectx/master/kubectx
curl -fsSLo "$BIN/kubens"  https://raw.githubusercontent.com/ahmetb/kubectx/master/kubens
chmod 0755 "$BIN/kubectx" "$BIN/kubens"

# ---- eksctl ------------------------------------------------------------------
EKSCTL_VERSION="$(resolve "${EKSCTL_VERSION:-latest}" eksctl-io/eksctl)"
say eksctl "$EKSCTL_VERSION"
dl_tar "https://github.com/eksctl-io/eksctl/releases/download/${EKSCTL_VERSION}/eksctl_Linux_${ARCH_GO}.tar.gz" eksctl
install -m 0755 "$TMP/eksctl" "$BIN/eksctl" && rm -f "$TMP/eksctl"

# ---- aws cli v2 --------------------------------------------------------------
# v2 ships as a self-contained bundle with its own Python, which is why it is a
# ~230MB install and why we do NOT pip install awscli (that is v1, and it is
# missing `eks get-token`, `sso login`, and half the modern APIs).
say awscli "v2 ($ARCH_UNAME)"
curl -fsSLo "$TMP/awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH_UNAME}.zip"
unzip -q "$TMP/awscliv2.zip" -d "$TMP"
"$TMP/aws/install" --bin-dir "$BIN" --install-dir /usr/local/aws-cli
rm -rf "$TMP/aws" "$TMP/awscliv2.zip"

# ---- shell completions -------------------------------------------------------
# THE fix for the original complaint. Written to /etc/bash_completion.d so they
# load for every user without anyone sourcing anything, and generated from the
# binaries just installed so they can never drift from the installed version.
say completions "(bash + zsh)"
mkdir -p /etc/bash_completion.d /usr/local/share/zsh/site-functions
kubectl completion bash  > /etc/bash_completion.d/kubectl
helm    completion bash  > /etc/bash_completion.d/helm
k9s     completion bash  > /etc/bash_completion.d/k9s      2>/dev/null || true
stern   --completion bash> /etc/bash_completion.d/stern    2>/dev/null || true
eksctl  completion bash  > /etc/bash_completion.d/eksctl   2>/dev/null || true
kubectl completion zsh   > /usr/local/share/zsh/site-functions/_kubectl
helm    completion zsh   > /usr/local/share/zsh/site-functions/_helm

# aws ships a completer binary rather than a generated script.
printf '%s\n' 'complete -C /usr/local/bin/aws_completer aws' > /etc/bash_completion.d/aws

echo
echo "==> installed:"
for t in kubectl helm k9s stern kustomize yq kubectl-krew kubectx eksctl aws; do
  printf '    %-14s %s\n' "$t" "$(command -v "$t" || echo MISSING)"
done
