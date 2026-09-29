#!/usr/bin/env bash
# Seed an empty (bind-mounted) $HOME at container start. Idempotent: only fills
# in files that are missing, never overwrites user changes. Anything baked into
# $HOME at image-build time is shadowed by the ./.home mount, so seeding happens
# here instead.
set -euo pipefail

ARGUS_TOOLS="${ARGUS_TOOLS:-/opt/argus}"
SKEL="${ARGUS_TOOLS}/share/skel"
OMZ="${ARGUS_TOOLS}/share/oh-my-zsh"

# Copy each skeleton entry into $HOME only when absent (dotfiles included).
if [ -d "$SKEL" ]; then
  shopt -s dotglob nullglob
  for src in "$SKEL"/*; do
    dest="$HOME/$(basename "$src")"
    if [ ! -e "$dest" ]; then
      cp -a "$src" "$dest"
    fi
  done
  shopt -u dotglob nullglob
fi

# Point $HOME/.oh-my-zsh at the baked install if not already present.
if [ ! -e "$HOME/.oh-my-zsh" ]; then
  ln -s "$OMZ" "$HOME/.oh-my-zsh"
fi

echo "[home-bootstrap] seeded $HOME from $SKEL"
