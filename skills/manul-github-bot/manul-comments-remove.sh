#!/usr/bin/env bash
# manul-comments-remove.sh — Remove all manul-signed comments from a PR.
#
# Usage:
#   manul-comments-remove.sh <pr-url-or-ref>
#
# Examples:
#   manul-comments-remove.sh https://github.com/mariuszmarzec/todo/pull/14
#   manul-comments-remove.sh mariuszmarzec/todo#14
#   manul-comments-remove.sh 14                # uses repo from config.json
#
# Removes comments containing the signature "— manul 🐈" from:
#   - PR review comments
#   - PR/issue conversation comments
#
set -uo pipefail

MANUL_DIR="${MANUL_DIR:-$HOME/.openclaw/manul}"
CONFIG="$MANUL_DIR/config.json"

SIG="— manul 🐈"

# --- resolve repo + issue number ---
arg="${1:-}"
if [ -z "$arg" ]; then
  echo "Usage: $0 <pr-url-or-ref>"
  echo "Examples:"
  echo "  $0 https://github.com/mariuszmarzec/todo/pull/14"
  echo "  $0 mariuszmarzec/todo#14"
  echo "  $0 14"
  exit 1
fi

# Detect repo from config when bare number is given
if [[ "$arg" =~ ^[0-9]+$ ]]; then
  if [ -f "$CONFIG" ]; then
    repo="$(jq -r '.repositories[0] // empty' "$CONFIG")"
  fi
  if [ -z "${repo:-}" ]; then
    echo "Error: cannot infer repo from bare number '$arg' (no config.json / repositories)"
    exit 1
  fi
  issue="$arg"
elif [[ "$arg" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$ ]]; then
  repo="${arg%%#*}"
  issue="${arg##*#}"
elif [[ "$arg" =~ pull/[0-9]+$ ]]; then
  repo="$(echo "$arg" | sed -E 's|https?://github.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/[0-9]+.*|\1|')"
  issue="$(echo "$arg" | sed -E 's|.*/pull/([0-9]+).*|\1|')"
else
  echo "Error: unsupported argument format '$arg'"
  echo "Expected: PR URL, owner/repo#N, or bare number"
  exit 1
fi

if [ -z "${repo:-}" ] || [ -z "${issue:-}" ]; then
  echo "Error: could not parse repo/issue from '$arg'"
  exit 1
fi

echo "Target: $repo# $issue"
echo "Signature filter: $SIG"
echo

token="$(gh auth token 2>/dev/null)"
if [ -z "$token" ]; then
  echo "Error: gh is not authenticated (run 'gh auth login')"
  exit 1
fi

api() {
  local method="$1"; shift
  local url="$1"; shift
  curl -s -X "$method" \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    "$url" "$@"
}

# --- collect IDs to delete ---
echo "Scanning comments..."

# PR review comments
mapfile -t review_ids < <(gh api "repos/$repo/pulls/$issue/comments" --jq --arg sig "$SIG" '.[] | select(.body | contains($sig)) | .id' 2>/dev/null || true)

# Issue / PR conversation comments
mapfile -t issue_ids < <(gh api "repos/$repo/issues/$issue/comments" --jq --arg sig "$SIG" '.[] | select(.body | contains($sig)) | .id' 2>/dev/null || true)

total=$(( ${#review_ids[@]} + ${#issue_ids[@]} ))
if [ "$total" -eq 0 ]; then
  echo "No matching comments found. Nothing to do."
  exit 0
fi

echo "Found $total comment(s) to delete:"
echo "  PR review comments: ${#review_ids[@]}"
echo "  Issue comments:      ${#issue_ids[@]}"
echo

# --- delete ---
deleted=0
failed=0

for id in "${review_ids[@]}"; do
  [ -z "$id" ] && continue
  echo -n "Deleting PR review comment $id... "
  resp="$(api DELETE "https://api.github.com/repos/$repo/pulls/comments/$id" -o /tmp/manul_del_$id.txt -w "%{http_code}")"
  if [ "$resp" = "204" ]; then
    echo "ok"
    deleted=$((deleted + 1))
  else
    echo "failed (HTTP $resp)"
    body="$(cat /tmp/manul_del_$id.txt 2>/dev/null || true)"
    echo "  $body"
    failed=$((failed + 1))
  fi
done

for id in "${issue_ids[@]}"; do
  [ -z "$id" ] && continue
  # skip if this id was already removed as a review comment
  if printf '%s\n' "${review_ids[@]}" | grep -qx "$id"; then
    continue
  fi
  echo -n "Deleting issue comment $id... "
  resp="$(api DELETE "https://api.github.com/repos/$repo/issues/comments/$id" -o /tmp/manul_del_$id.txt -w "%{http_code}")"
  if [ "$resp" = "204" ]; then
    echo "ok"
    deleted=$((deleted + 1))
  else
    echo "failed (HTTP $resp)"
    body="$(cat /tmp/manul_del_$id.txt 2>/dev/null || true)"
    echo "  $body"
    failed=$((failed + 1))
  fi
done

echo
echo "=== Summary ==="
echo "Deleted:  $deleted"
echo "Failed:   $failed"
echo "Total:    $total"

# cleanup temp files
rm -f /tmp/manul_del_*.txt 2>/dev/null || true

exit $([ "$failed" -eq 0 ] && echo 0 || echo 1)
