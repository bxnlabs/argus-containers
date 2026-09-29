# Starter zsh config seeded into $HOME on first container start.
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="gentoo"
DISABLE_AUTO_UPDATE="true"
plugins=(git)
source "$ZSH/oh-my-zsh.sh"

# Tool prefix (gcloud, pulumi, kubectl, helm, tailscale).
export PATH="/opt/argus/bin:$PATH"
