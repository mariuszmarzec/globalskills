#!/usr/bin/env bash
set -euo pipefail

REPO_URL="git@github.com:mariuszmarzec/globalskills.git"
REPO_DIR="$HOME/.globalskills"
SKILLS_DIR="$REPO_DIR/skills"
AGENTS_DIR="$REPO_DIR/agents"
SKILLS_LINK="$HOME/.agents/skills"
AGENTS_LINK="$HOME/.config/opencode/agents"

echo "Installing globalskills..."

if [ -d "$REPO_DIR" ]; then
  echo "Updating existing repo at $REPO_DIR..."
  git -C "$REPO_DIR" pull --ff-only
else
  echo "Cloning repo to $REPO_DIR..."
  git clone "$REPO_URL" "$REPO_DIR"
fi

mkdir -p "$HOME/.agents"
mkdir -p "$HOME/.config/opencode"

if [ -L "$SKILLS_LINK" ]; then
  echo "Symlink already exists: $SKILLS_LINK -> $(readlink "$SKILLS_LINK")"
elif [ -d "$SKILLS_LINK" ]; then
  echo "WARNING: $SKILLS_LINK is a directory, not a symlink. Skipping."
  echo "Remove it manually if you want the symlink: rm -rf $SKILLS_LINK"
else
  ln -s "$SKILLS_DIR" "$SKILLS_LINK"
  echo "Created symlink: $SKILLS_LINK -> $SKILLS_DIR"
fi

if [ -L "$AGENTS_LINK" ]; then
  echo "Symlink already exists: $AGENTS_LINK -> $(readlink "$AGENTS_LINK")"
elif [ -d "$AGENTS_LINK" ]; then
  echo "WARNING: $AGENTS_LINK is a directory, not a symlink. Skipping."
  echo "Remove it manually if you want the symlink: rm -rf $AGENTS_LINK"
else
  ln -s "$AGENTS_DIR" "$AGENTS_LINK"
  echo "Created symlink: $AGENTS_LINK -> $AGENTS_DIR"
fi

echo "Done. Skills available at: $SKILLS_LINK"
echo "Done. Agents available at: $AGENTS_LINK"
