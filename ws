#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ==============================================================================
# ws — the host-side driver for the workstation container.
#
#   ./ws build [--no-cache]              build the image
#   ./ws shell [bundle-dir] [--rw|--ro]  interactive shell (default: probe mode)
#   ./ws agent [--fix] "<question>"      one-shot agent run (default: probe)
#   ./ws agent                           interactive Claude inside the container
#   ./ws scope <sa-name>                 mint a read-only kubeconfig (see below)
#   ./ws doctor                          check the host is ready
#   ./ws nuke                            remove the image and its volumes
#
# A "bundle" is whatever the assessment sent you: a directory containing a
# kubeconfig, maybe an SSH key, maybe a task description and some manifests. It
# is mounted READ-ONLY; the container copies what it needs to a writable /work.
# Point at it explicitly or run ./ws from inside it.
# ==============================================================================
set -euo pipefail

IMAGE="${WS_IMAGE:-workstation}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

c_red()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
c_ok()   { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_info() { printf '\033[1;36m%s\033[0m\n' "$*"; }
die()    { c_red "!! $*"; exit 1; }

# ------------------------------------------------------------------------------
# docker_run — the shared runtime posture for every mode.
#
# Each flag is here for a reason, and the reasons are the whole security story:
#
#   --rm                   the container is disposable. Nothing about someone
#                          else's cluster outlives the session.
#   -v bundle:/bundle:ro   their credentials are never writable, and never end
#                          up in an image layer where `docker history` would
#                          expose them.
#   --cap-drop ALL         no capabilities at all. Nothing in here needs any.
#                          (tcpdump on the container's own interface is the one
#                          casualty; you almost always want it on a node anyway.)
#   --security-opt no-new-privileges  no setuid escalation path.
#   --pids-limit / --memory  a runaway process cannot take the laptop with it.
#   --network bridge       outbound only. No published ports, nothing listening.
#
# What this is NOT: a hard boundary. A container shares the host kernel; this
# reduces blast radius, it does not contain a kernel exploit. It is the right
# posture for an assessment and you should still treat the kubeconfig as a real
# credential. docs/SECURITY.md says this at more length.
# ------------------------------------------------------------------------------
docker_run() {
  local bundle="$1" mode="$2"; shift 2
  local envs=()
  [ -n "${ANTHROPIC_API_KEY:-}" ] && envs+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
  [ -n "${AWS_PROFILE:-}" ]       && envs+=(-e "AWS_PROFILE=$AWS_PROFILE")
  [ -n "${AWS_REGION:-}" ]        && envs+=(-e "AWS_REGION=$AWS_REGION")
  # Some assessments hand you AWS keys in the task text rather than a file.
  [ -n "${AWS_ACCESS_KEY_ID:-}" ] && envs+=(
      -e "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID"
      -e "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-}"
      -e "AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN:-}")

  # WS_DOCKER_ARGS is the escape hatch for the cases the defaults cannot cover:
  #   --network kind        reach a local kind/k3d cluster's internal address
  #   --dns 10.0.0.1        an assessment behind a split-horizon resolver
  #   -v $PWD/notes:/notes  keep the write-up outside the disposable container
  # Deliberately last so it can override anything above it.
  # shellcheck disable=SC2086
  docker run --rm -it \
    --hostname workstation \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --pids-limit 512 \
    --memory 4g \
    -e "WS_MODE=$mode" \
    -e "WS_SSH_USER=${WS_SSH_USER:-root}" \
    "${envs[@]}" \
    -v "$bundle:/bundle:ro" \
    ${WS_DOCKER_ARGS:-} \
    "$IMAGE" "$@"
}

# resolve_bundle — first non-flag argument, or the current directory.
# Defaulting to CWD means `cd ~/some-assessment && ws shell` just works,
# which is how you will actually use this.
resolve_bundle() {
  local b="${1:-$PWD}"
  [ -d "$b" ] || die "not a directory: $b"
  (cd "$b" && pwd)
}

usage() {
  cat <<'USAGE'
  ws — driver for the workstation container.

    ./ws build [--no-cache]               build the image
    ./ws shell [bundle-dir] [--rw|--ro]   interactive shell   (default: probe)
    ./ws agent [--fix] "<question>"       one-shot agent run  (default: probe)
    ./ws agent                            interactive Claude in the container
    ./ws scope [sa-name] [ns]             mint a read-only kubeconfig via RBAC
    ./ws doctor                           check the host is ready
    ./ws nuke                             remove the image

  MODES   ro     reads only
          probe  + exec / port-forward — no API object is modified  (default)
          rw     may change the cluster

  A bundle is the directory the assessment sent you (kubeconfig, ssh key, task
  description). It is mounted READ-ONLY. Defaults to the current directory, so
  `cd ~/some-assessment && ws shell` is the normal way to use this.

  ANTHROPIC_API_KEY is read from your environment and passed at run time. It is
  never written to an image layer.
USAGE
}

cmd="${1:-help}"; shift 2>/dev/null || true

case "$cmd" in

  build)
    c_info "building $IMAGE (this pulls ~500MB of tooling the first time)"
    docker build "$@" -t "$IMAGE" "$HERE"
    c_ok "built $IMAGE — try: ./ws shell ~/some-assessment"
    ;;

  shell)
    mode=probe; bundle=""
    for a in "$@"; do
      case "$a" in
        --rw) mode=rw ;;
        --ro) mode=ro ;;
        --probe) mode=probe ;;
        -*) die "unknown flag $a" ;;
        *) bundle="$a" ;;
      esac
    done
    bundle="$(resolve_bundle "$bundle")"
    docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -t "$IMAGE" "$HERE"
    c_info "bundle: $bundle   mode: $mode"
    [ "$mode" = rw ] && c_red "WRITE MODE — this shell can change the cluster."
    docker_run "$bundle" "$mode" shell
    ;;

  agent)
    mode=probe; bundle=""; prompt=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --fix) mode=rw ;;
        --ro)  mode=ro ;;
        --bundle) shift; bundle="$1" ;;
        *) prompt+=("$1") ;;
      esac
      shift
    done
    bundle="$(resolve_bundle "$bundle")"
    [ -n "${ANTHROPIC_API_KEY:-}" ] || die "export ANTHROPIC_API_KEY first (it is passed at run time, never baked in)"
    docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -t "$IMAGE" "$HERE"

    # --fix is the one irreversible thing this tool can do, so it asks. Once.
    # Not a --yes flag: if you are automating this you have already lost the
    # thread of why the guard exists.
    if [ "$mode" = rw ]; then
      c_red "──────────────────────────────────────────────────────────────"
      c_red " --fix : the agent will be allowed to MODIFY this cluster."
      c_red "──────────────────────────────────────────────────────────────"
      printf ' bundle: %s\n' "$bundle"
      printf ' Continue? [y/N] '
      read -r reply
      case "$reply" in y|Y|yes) ;; *) die "aborted" ;; esac
    fi
    docker_run "$bundle" "$mode" agent "${prompt[@]}"
    ;;

  # ----------------------------------------------------------------------------
  # scope — mint a genuinely read-only kubeconfig.
  #
  # This is the honest answer to "how do I stop the agent writing to the
  # cluster". The guard shims stop mistakes; RBAC stops everything, because it is
  # enforced by the API server rather than by a wrapper the caller could bypass.
  #
  # Creates a ServiceAccount bound to the built-in `view` ClusterRole, mints a
  # token for it, and writes a kubeconfig using that token instead of your admin
  # credential. Run the agent with THAT and the read-only property is a fact
  # about the cluster, not a promise about the client.
  #
  # It needs write access to create the SA — which is why it runs on the host,
  # deliberately and by you, rather than anywhere near the agent.
  # ----------------------------------------------------------------------------
  scope)
    name="${1:-ws-readonly}"
    ns="${2:-default}"
    out="${PWD}/kubeconfig.readonly"
    command -v kubectl >/dev/null || die "kubectl not found on the host"
    c_info "creating ServiceAccount $ns/$name bound to the 'view' ClusterRole"
    kubectl -n "$ns" create serviceaccount "$name" --dry-run=client -o yaml | kubectl apply -f -
    kubectl create clusterrolebinding "$name-view" \
      --clusterrole=view --serviceaccount="$ns:$name" \
      --dry-run=client -o yaml | kubectl apply -f -
    # 8h: long enough for any assessment, short enough that a leaked token is
    # not a lasting problem.
    token="$(kubectl -n "$ns" create token "$name" --duration=8h)"
    server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
    ca="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
    cat > "$out" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: scoped
  cluster:
    server: ${server}
    certificate-authority-data: ${ca}
contexts:
- name: scoped
  context: {cluster: scoped, user: ${name}, namespace: ${ns}}
current-context: scoped
users:
- name: ${name}
  user: {token: ${token}}
EOF
    chmod 600 "$out"
    c_ok "wrote $out (valid 8h, 'view' ClusterRole — the API server enforces this)"
    echo "   use it:  cp $out <bundle>/kubeconfig && ./ws agent \"...\""
    echo "   revoke:  kubectl delete sa -n $ns $name; kubectl delete clusterrolebinding $name-view"
    ;;

  doctor)
    c_info "host checks"
    for t in docker kubectl git; do
      printf '  %-10s %s\n' "$t" "$(command -v $t || echo 'not found')"
    done
    printf '  %-10s %s\n' "docker" "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'daemon not reachable')"
    printf '  %-10s %s\n' "image" "$(docker image inspect "$IMAGE" --format '{{.Id}} ({{.Size}} bytes)' 2>/dev/null || echo 'not built — run ./ws build')"
    printf '  %-10s %s\n' "api key" "$([ -n "${ANTHROPIC_API_KEY:-}" ] && echo 'set' || echo 'NOT SET — agent mode unavailable')"
    printf '  %-10s %s\n' "arch" "$(uname -m)"
    ;;

  nuke)
    docker rmi -f "$IMAGE" 2>/dev/null || true
    c_ok "removed image $IMAGE"
    ;;

  help|-h|--help) usage ;;
  *) die "unknown command '$cmd' — try ./ws help" ;;
esac
