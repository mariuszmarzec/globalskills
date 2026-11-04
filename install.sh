#!/usr/bin/env bash
set -euo pipefail

REPO_URL="git@github.com:mariuszmarzec/globalskills.git"
REPO_DIR="$HOME/.globalskills"
MANUL_REPO_URL="git@github.com:mariuszmarzec/manul.git"
MANUL_REPO_DIR="$HOME/.manul-repo"
MANUL_CANONICAL_DIR="$MANUL_REPO_DIR/skills/manul-github-bot"
MANUL_BRANCH="master"
SKILLS_DIR="$REPO_DIR/skills"
AGENTS_DIR="$REPO_DIR/agents"

# Resolve files and directories without GNU readlink -f (not available on macOS).
resolve_path() {
  local path="$1" parent target
  while [ -L "$path" ]; do
    parent="$(cd -P "$(dirname "$path")" && pwd)" || return 1
    target="$(readlink "$path")" || return 1
    case "$target" in
      /*) path="$target" ;;
      *)  path="$parent/$target" ;;
    esac
  done
  parent="$(cd -P "$(dirname "$path")" && pwd)" || return 1
  printf '%s/%s\n' "$parent" "$(basename "$path")"
}

echo "Installing globalskills..."

if [ -d "$REPO_DIR" ]; then
  echo "Updating existing repo at $REPO_DIR..."
  git -C "$REPO_DIR" pull --ff-only
else
  echo "Cloning repo to $REPO_DIR..."
  git clone "$REPO_URL" "$REPO_DIR"
fi

echo "Installing standalone Manul runtime source..."
if [ -d "$MANUL_REPO_DIR/.git" ]; then
  git -C "$MANUL_REPO_DIR" fetch origin "$MANUL_BRANCH" --quiet
  git -C "$MANUL_REPO_DIR" checkout "$MANUL_BRANCH"
  git -C "$MANUL_REPO_DIR" pull --ff-only origin "$MANUL_BRANCH"
elif [ -e "$MANUL_REPO_DIR" ]; then
  echo "ERROR: $MANUL_REPO_DIR exists but is not a Git checkout." >&2
  echo "Move it aside or remove it before reinstalling Manul." >&2
  exit 1
else
  git clone --branch "$MANUL_BRANCH" "$MANUL_REPO_URL" "$MANUL_REPO_DIR"
fi

if [ ! -f "$MANUL_CANONICAL_DIR/install-manul.sh" ]; then
  echo "ERROR: standalone Manul installer is missing: $MANUL_CANONICAL_DIR/install-manul.sh" >&2
  exit 1
fi
export MANUL_CANONICAL_DIR
export MANUL_CANONICAL_ROOT="$MANUL_REPO_DIR"
export MANUL_CANONICAL_BRANCH="$MANUL_BRANCH"
export MANUL_HOST_SKILLS_DIR="$SKILLS_DIR"
echo "Manul source available at: $MANUL_CANONICAL_DIR"
echo "Host project skills available at: $MANUL_HOST_SKILLS_DIR"

# Prepare the Manul runtime and CLI. A fresh runtime is initialized only when
# no database exists; an existing database always uses the non-destructive path.
MANUL_DB="$HOME/.manul/state/manul.db"
if [ -f "$MANUL_DB" ]; then
  bash "$MANUL_CANONICAL_DIR/install-manul.sh"
else
  bash "$MANUL_CANONICAL_DIR/install-manul.sh" --init-state
fi

echo "Installing native skills and agents for OpenCode and GitHub Copilot..."
python3 "$REPO_DIR/installer/globalskills.py" --source "$REPO_DIR" install --runtime all

# Install a single-file CLI symlink. Runtime resource directories are copied,
# never linked, so the two tools cannot interfere with one another.
LOCAL_BIN="$HOME/.local/bin"
CLI_LINK="$LOCAL_BIN/globalskills"
CLI_SOURCE="$REPO_DIR/bin/globalskills"
mkdir -p "$LOCAL_BIN"
if [ -L "$CLI_LINK" ]; then
  CLI_LINK_REAL="$(resolve_path "$CLI_LINK" 2>/dev/null || true)"
  CLI_SOURCE_REAL="$(resolve_path "$CLI_SOURCE" 2>/dev/null || true)"
  if [ -n "$CLI_LINK_REAL" ] && [ "$CLI_LINK_REAL" = "$CLI_SOURCE_REAL" ]; then
    echo "Globalskills CLI already points to the maintained launcher."
  else
    CLI_BACKUP="$CLI_LINK.backup.$(date -u +%Y%m%dT%H%M%SZ)"
    while [ -e "$CLI_BACKUP" ] || [ -L "$CLI_BACKUP" ]; do CLI_BACKUP="$CLI_BACKUP.$"; done
    mv -- "$CLI_LINK" "$CLI_BACKUP"
    ln -s "$CLI_SOURCE" "$CLI_LINK"
    echo "Preserved previous CLI link at $CLI_BACKUP"
  fi
elif [ -e "$CLI_LINK" ]; then
  echo "WARNING: preserving existing non-symlink CLI at $CLI_LINK"
else
  ln -s "$CLI_SOURCE" "$CLI_LINK"
  echo "Linked Globalskills CLI: $CLI_LINK -> $CLI_SOURCE"
fi



# Install the maintained aicode launcher as a symlink so global-skills updates
# also update the daily startup workflow. Preserve any existing local launcher.
AICODE_SOURCE="$REPO_DIR/aicode/aicode"
AICODE_DIR="$HOME/.aicode"

if [ -f "$AICODE_SOURCE" ]; then
  # Do not mutate AICODE_SOURCE when ~/.aicode is an alias of the repository's
  # aicode directory. In that layout AICODE_LINK and AICODE_SOURCE are the same
  # filesystem path, so moving it aside and linking it back creates a self-link
  # and leaves the checkout dirty.
  AICODE_SOURCE_PARENT="$(cd "$(dirname "$AICODE_SOURCE")" && pwd -P)"
  AICODE_DIR_REAL="$(resolve_path "$AICODE_DIR" 2>/dev/null || true)"

  if [ -n "$AICODE_DIR_REAL" ] && [ "$AICODE_DIR_REAL" = "$AICODE_SOURCE_PARENT" ]; then
    echo "Detected ~/.aicode aliases $AICODE_SOURCE_PARENT; keeping the maintained launcher in place."
  else
    mkdir -p "$AICODE_DIR"
    AICODE_DIR_REAL="$(cd "$AICODE_DIR" && pwd -P)"
    if [ "$AICODE_DIR_REAL" = "$AICODE_SOURCE_PARENT" ]; then
      echo "Detected ~/.aicode aliases $AICODE_SOURCE_PARENT; keeping the maintained launcher in place."
    else
      AICODE_LINK="$AICODE_DIR/aicode"
      AICODE_SOURCE_REAL="$(resolve_path "$AICODE_SOURCE" 2>/dev/null || true)"
      AICODE_LINK_REAL="$(resolve_path "$AICODE_LINK" 2>/dev/null || true)"

      if [ -L "$AICODE_LINK" ] && [ -n "$AICODE_SOURCE_REAL" ] && [ "$AICODE_LINK_REAL" = "$AICODE_SOURCE_REAL" ]; then
        echo "aicode launcher already points to the maintained source."
      else
        if [ -e "$AICODE_LINK" ] || [ -L "$AICODE_LINK" ]; then
          AICODE_BACKUP="$AICODE_LINK.backup.$(date -u +%Y%m%dT%H%M%SZ)"
          while [ -e "$AICODE_BACKUP" ] || [ -L "$AICODE_BACKUP" ]; do
            AICODE_BACKUP="$AICODE_BACKUP.$"
          done
          mv -- "$AICODE_LINK" "$AICODE_BACKUP"
          echo "Preserved previous aicode launcher at $AICODE_BACKUP"
        fi
        ln -s "$AICODE_SOURCE" "$AICODE_LINK"
        echo "Linked aicode launcher: $AICODE_LINK -> $AICODE_SOURCE"
      fi
    fi
  fi
fi

echo "Done. Shared skills (OpenCode, Copilot, Manul): $HOME/.agents/skills"
echo "Done. OpenCode agents: $HOME/.config/opencode/agents"
echo "Done. Copilot agents: $HOME/.copilot/agents"
echo "Run 'globalskills status' to inspect installed resources."
