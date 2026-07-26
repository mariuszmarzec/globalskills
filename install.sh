#!/usr/bin/env bash
set -euo pipefail

REPO_URL="git@github.com:mariuszmarzec/globalskills.git"
REPO_DIR="$HOME/.globalskills"
SKILLS_DIR="$REPO_DIR/skills"
LINK_DIR="$HOME/.agents/skills"

echo "Installing globalskills..."

if [ -d "$REPO_DIR" ]; then
  echo "Updating existing repo at $REPO_DIR..."
  git -C "$REPO_DIR" pull --ff-only
else
  echo "Cloning repo to $REPO_DIR..."
  git clone "$REPO_URL" "$REPO_DIR"
fi

mkdir -p "$HOME/.agents"

if [ -L "$LINK_DIR" ]; then
  echo "Symlink already exists: $LINK_DIR -> $(readlink "$LINK_DIR")"
elif [ -d "$LINK_DIR" ]; then
  echo "WARNING: $LINK_DIR is a directory, not a symlink. Skipping."
  echo "Remove it manually if you want the symlink: rm -rf $LINK_DIR"
else
  ln -s "$SKILLS_DIR" "$LINK_DIR"
  echo "Created symlink: $LINK_DIR -> $SKILLS_DIR"
fi

echo "Done. Skills available at: $LINK_DIR"
