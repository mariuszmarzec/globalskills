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


# Install the maintained aicode launcher as a symlink so global-skills updates
# also update the daily startup workflow. Preserve any existing local launcher.
AICODE_SOURCE="$REPO_DIR/aicode/aicode"
AICODE_DIR="$HOME/.aicode"
AICODE_LINK="$AICODE_DIR/aicode"
mkdir -p "$AICODE_DIR"
if [ -f "$AICODE_SOURCE" ]; then
  chmod +x "$AICODE_SOURCE"
  if [ -L "$AICODE_LINK" ] && [ "$(readlink -f "$AICODE_LINK" 2>/dev/null || true)" = "$(readlink -f "$AICODE_SOURCE")" ]; then
    echo "aicode launcher already points to the maintained source."
  else
    if [ -e "$AICODE_LINK" ] || [ -L "$AICODE_LINK" ]; then
      AICODE_BACKUP="$AICODE_LINK.backup.$(date -u +%Y%m%dT%H%M%SZ)"
      while [ -e "$AICODE_BACKUP" ] || [ -L "$AICODE_BACKUP" ]; do
        AICODE_BACKUP="$AICODE_BACKUP.$$"
      done
      mv -- "$AICODE_LINK" "$AICODE_BACKUP"
      echo "Preserved previous aicode launcher at $AICODE_BACKUP"
    fi
    ln -s "$AICODE_SOURCE" "$AICODE_LINK"
    echo "Linked aicode launcher: $AICODE_LINK -> $AICODE_SOURCE"
  fi
fi

echo "Done. Skills available at: $SKILLS_LINK"
echo "Done. Agents available at: $AGENTS_LINK"
