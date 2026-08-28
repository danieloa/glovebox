# SPDX-License-Identifier: Apache-2.0
# ==============================================================================
# shellrc.sh — the interactive shell environment.
#
# Sourced from ~/.bashrc and ~/.zshrc. This file is the direct answer to "that
# container's shell is very unusable": completion, a prompt that tells you which
# cluster you are about to break, and the aliases you would otherwise retype
# four hundred times.
# ==============================================================================

# ---- completion --------------------------------------------------------------
# bash-completion's loader has to come first; it defines the machinery that the
# per-tool scripts in /etc/bash_completion.d register into.
if [ -n "${BASH_VERSION:-}" ]; then
  [ -f /usr/share/bash-completion/bash_completion ] && . /usr/share/bash-completion/bash_completion
  for f in /etc/bash_completion.d/*; do [ -r "$f" ] && . "$f"; done
  # `k` is aliased to kubectl below; without this it completes as an unknown
  # command, which is worse than no alias at all.
  complete -o default -F __start_kubectl k 2>/dev/null || true
fi
if [ -n "${ZSH_VERSION:-}" ]; then
  fpath=(/usr/local/share/zsh/site-functions $fpath)
  autoload -Uz compinit && compinit -u
fi

# ---- history -----------------------------------------------------------------
# Large, timestamped, appended not overwritten. The history file IS your
# write-up: at the end of an assessment, `history` is the list of everything you
# actually ran, in order, and it beats reconstructing it from memory.
export HISTSIZE=100000 HISTFILESIZE=100000
export HISTTIMEFORMAT='%F %T  '
export HISTCONTROL=ignoredups
export HISTFILE=/work/.gb_history
if [ -n "${BASH_VERSION:-}" ]; then
  shopt -s histappend cmdhist checkwinsize 2>/dev/null || true
fi

# ---- prompt ------------------------------------------------------------------
# Shows mode / context / namespace. The mode segment is colour-coded and the
# rw case is deliberately alarming: red background, the word RW spelled out.
# You should not be able to run a destructive command without having seen it.
_ws_ps1() {
  local mode="${GB_MODE:-ro}" seg ctx ns
  case "$mode" in
    rw)    seg='\[\e[41;1;37m\] RW \[\e[0m\]' ;;
    probe) seg='\[\e[43;30m\] probe \[\e[0m\]' ;;
    *)     seg='\[\e[42;30m\] ro \[\e[0m\]' ;;
  esac
  # Read context/namespace straight from the kubeconfig file rather than by
  # shelling out to kubectl on every prompt: a prompt that makes an API call is
  # a prompt that hangs for 30 seconds when the API server is the thing that is
  # broken — which, in this container, is the normal case.
  ctx="$(sed -n 's/^current-context: *//p' "${KUBECONFIG:-/nonexistent}" 2>/dev/null | head -1)"
  ns="$(sed -n 's/^ *namespace: *//p' "${KUBECONFIG:-/nonexistent}" 2>/dev/null | head -1)"
  PS1="${seg} \[\e[1;34m\]${ctx:-no-context}\[\e[0m\]:\[\e[1;35m\]${ns:-default}\[\e[0m\] \w \$ "
}
if [ -n "${BASH_VERSION:-}" ]; then PROMPT_COMMAND=_ws_ps1; fi

# ---- aliases -----------------------------------------------------------------
alias k=kubectl
alias kg='kubectl get'
alias kd='kubectl describe'
alias kl='kubectl logs'
alias kaf='kubectl apply -f'
alias kgp='kubectl get pods -o wide'
alias kga='kubectl get all -A'
alias kgn='kubectl get nodes -o wide'
# Events sorted by time, not by name — the default ordering makes the event log
# useless and is the first thing everyone reaches for.
alias kev='kubectl get events -A --sort-by=.lastTimestamp'
alias kw='kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp'
alias ktop='kubectl top pods -A --sort-by=memory'
alias kctx=kubectx
alias kns=kubens
alias ls='ls --color=auto'
alias ll='ls -alh --color=auto'
alias grep='grep --color=auto'
alias bat='batcat'      # Debian renames the binary to avoid a name clash
alias vi=vim

# ---- toolkit -----------------------------------------------------------------
for f in /opt/glovebox/toolkit/*.sh; do [ -r "$f" ] && . "$f"; done

# ---- agent shortcut ----------------------------------------------------------
# gb-diagnose "<question>" — one-shot agent run, read-only, from inside the box.
gb-diagnose() { /opt/glovebox/claude/run-agent.sh "$@"; }

export PATH="$HOME/.local/bin:$HOME/.krew/bin:$PATH"
