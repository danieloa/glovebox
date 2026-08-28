# SPDX-License-Identifier: Apache-2.0
# ==============================================================================
# workstation — a disposable, agent-capable SRE troubleshooting container.
#
# Built for take-home assessments and live interview exercises where you are
# handed credentials to someone else's cluster. Two properties matter:
#
#   1. NOTHING SENSITIVE IS EVER BAKED IN. No kubeconfig, no keys, no API key.
#      The assessment bundle is bind-mounted read-only at /bundle and copied to
#      a writable /work at container start; `docker rmi` leaves no trace.
#   2. It is a real shell, not a busybox. Tab completion, k9s, stern, aws — the
#      things whose absence turns a 20-minute exercise into a 40-minute one.
#
# Build:  ./ws build          Enter:  ./ws shell ~/some-assessment
# ==============================================================================

FROM debian:12-slim

# TARGETARCH is populated automatically by BuildKit (amd64 / arm64). Declared
# without a default so a build that somehow lacks it fails loudly in
# install-tools.sh rather than silently producing an x86 image on an M-series Mac.
ARG TARGETARCH

# Tool versions. "latest" resolves the newest upstream release at build time;
# hack/pin-versions.sh rewrites these to exact tags for a reproducible rebuild.
# Pin KUBECTL_VERSION to the target cluster's server minor version when you know
# it — kubectl is only supported within +/-1 minor of the API server.
ARG KUBECTL_VERSION=latest
ARG HELM_VERSION=latest
ARG K9S_VERSION=latest
ARG STERN_VERSION=latest
ARG KUSTOMIZE_VERSION=latest
ARG YQ_VERSION=latest
ARG KREW_VERSION=latest
ARG EKSCTL_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    PAGER=less \
    EDITOR=vim

# ------------------------------------------------------------------------------
# Layer 1: OS packages.
#
# Grouped by what they are FOR, because the natural question six months from now
# is "why is socat in here" and the answer should be in the file, not in my head.
# ------------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      # fetching things / TLS
      ca-certificates curl wget gnupg openssl unzip \
      # the shell itself — bash-completion is the whole point of this rebuild
      bash bash-completion zsh less \
      # editors: vim-tiny cannot even do syntax highlighting on a YAML manifest
      vim nano \
      # structured data: half of k8s triage is reshaping JSON and YAML.
      # bsdextrautils is here only for `column`, which is what turns a wall of
      # kubectl output into something readable in a screen share.
      jq git bsdextrautils \
      # DNS — CoreDNS problems are the single most common cluster fault
      dnsutils \
      # L3/L4: is it the pod, the service, the CNI, or the security group?
      iputils-ping iproute2 net-tools traceroute mtr-tiny tcpdump \
      netcat-openbsd socat telnet \
      # L7
      httpie \
      # process / syscall level: for when the container starts but does nothing
      procps psmisc lsof strace file htop \
      # node access for kubelet-level faults
      openssh-client rsync \
      # quality of life: ripgrep and fzf are what make the shell feel like a
      # workstation instead of a rescue disk
      ripgrep fzf tree bat \
      # python for ad-hoc math and one-off API calls
      python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------------------
# Layer 2: the binary toolchain (kubectl, helm, k9s, stern, aws, ...).
# Separate layer + separate script so editing the shell config below does not
# re-download 400MB of tarballs.
# ------------------------------------------------------------------------------
COPY image/install-tools.sh /tmp/install-tools.sh
RUN chmod +x /tmp/install-tools.sh && /tmp/install-tools.sh && rm -f /tmp/install-tools.sh

# ------------------------------------------------------------------------------
# Layer 3: the guard shims.
#
# `kubectl` and `aws` on PATH are wrappers that refuse mutating verbs unless
# WS_MODE=rw. They are owned by root and mode 0755, so the unprivileged runtime
# user can execute but not edit them.
#
# Read docs/SECURITY.md before you trust this: it is accident-prevention and
# defense-in-depth, NOT a capability boundary. Anything holding the kubeconfig
# can talk to the API server directly. The real boundary is RBAC — see `ws scope`.
# ------------------------------------------------------------------------------
COPY image/guard-kubectl.sh /opt/ws/libexec/guard-kubectl
COPY image/guard-aws.sh     /opt/ws/libexec/guard-aws
RUN set -eux; \
    mkdir -p /opt/ws/bin.real; \
    mv /usr/local/bin/kubectl /opt/ws/bin.real/kubectl; \
    mv /usr/local/bin/aws     /opt/ws/bin.real/aws; \
    ln -s /opt/ws/libexec/guard-kubectl /usr/local/bin/kubectl; \
    ln -s /opt/ws/libexec/guard-aws     /usr/local/bin/aws; \
    chown root:root /opt/ws/libexec/guard-kubectl /opt/ws/libexec/guard-aws; \
    chmod 0755 /opt/ws/libexec/guard-kubectl /opt/ws/libexec/guard-aws

# ------------------------------------------------------------------------------
# Layer 4: toolkit, agent config, shell environment.
# ------------------------------------------------------------------------------
COPY toolkit/       /opt/ws/toolkit/
COPY claude/        /opt/ws/claude/
COPY image/shellrc.sh   /opt/ws/shellrc.sh
COPY image/entrypoint.sh /opt/ws/entrypoint.sh
RUN chmod -R a+rX /opt/ws \
    && chmod 0755 /opt/ws/entrypoint.sh /opt/ws/claude/run-agent.sh

# ------------------------------------------------------------------------------
# Layer 5: the runtime user.
#
# Non-root, and /work is chowned explicitly: creating it via WORKDIR alone leaves
# it root-owned, and the entrypoint's copy of the kubeconfig then fails with a
# permission error that looks like a credentials problem. (Learned the hard way.)
# ------------------------------------------------------------------------------
RUN useradd -m -s /bin/bash -u 1000 sre \
    && mkdir -p /work /home/sre/.kube /home/sre/.aws /home/sre/.claude \
    && ln -s /opt/ws/claude/skills /home/sre/.claude/skills \
    && chown -R sre:sre /work /home/sre \
    && printf '%s\n' '[ -f /opt/ws/shellrc.sh ] && source /opt/ws/shellrc.sh' \
       | tee -a /home/sre/.bashrc >> /home/sre/.zshrc

USER sre
WORKDIR /work
ENV HOME=/home/sre \
    PATH=/home/sre/.local/bin:/home/sre/.krew/bin:/usr/local/bin:/usr/bin:/bin \
    KUBECONFIG=/work/kubeconfig \
    WS_MODE=ro

# ------------------------------------------------------------------------------
# Layer 6: Claude Code.
#
# Installed last and as the unprivileged user, because the native installer is
# per-user (it lands in ~/.local/bin) and because this is the layer most likely
# to be rebuilt. No credentials here: ANTHROPIC_API_KEY is passed at run time by
# ./ws, never stored in an image layer.
# ------------------------------------------------------------------------------
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && /home/sre/.local/bin/claude --version

ENTRYPOINT ["/opt/ws/entrypoint.sh"]
CMD ["shell"]
