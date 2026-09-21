#!/usr/bin/env bash
# manul-comments-remove.sh — Remove all manul-signed comments from a PR or issue.
set -uo pipefail

MANUL_DIR="${MANUL_DIR:-$HOME/.openclaw/manul}"
CONFIG="$MANUL_DIR/config.json"
SIG="— manul 🐈"

arg="${1:-}"
if [ -z "$arg" ] || [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
  echo "Usage: $0 <pr-url-or-ref-or-issue>"
  echo "Removes all manul-signed comments from a GitHub PR or issue."
  echo
  echo "Arguments:"
  echo "  <pr-url>      Full GitHub PR URL, e.g. https://github.com/owner/repo/pull/123"
  echo "  <repo#issue>  Shorthand, e.g. owner/repo#123"
  echo "  <issue>       Bare issue number (repo inferred from config.json)"
  exit 0
fi

if [[ "$arg" =~ ^[0-9]+$ ]]; then
  if [ -f "$CONFIG" ]; then
    repo="$(jq -r '.repositories[0] // empty' "$CONFIG")"
  fi
  [ -n "${repo:-}" ] || { echo "Error: cannot infer repo from bare number '$arg'"; exit 1; }
  issue="$arg"
elif [[ "$arg" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$ ]]; then
  repo="${arg%%#*}"
  issue="${arg##*#}"
elif [[ "$arg" =~ pull/[0-9]+$ ]]; then
  repo="$(echo "$arg" | sed -E 's|https?://github.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/[0-9]+.*|\1|')"
  issue="$(echo "$arg" | sed -E 's|.*/pull/([0-9]+).*|\1|')"
elif [[ "$arg" =~ issues/[0-9]+$ ]]; then
  repo="$(echo "$arg" | sed -E 's|https?://github.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/issues/[0-9]+.*|\1|')"
  issue="$(echo "$arg" | sed -E 's|.*/issues/([0-9]+).*|\1|')"
else
  echo "Error: unsupported argument format '$arg'"
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

linked_issues=()
is_pr=$(gh pr view --repo "$repo" --number "$issue" --json number 2>/dev/null | jq -r '.number // empty' 2>/dev/null || true)
if [ -n "$is_pr" ]; then
  issue_body="$(gh pr view --repo "$repo" --number "$issue" --json body 2>/dev/null | jq -r '.body // ""')"
else
  issue_body="$(gh issue view --repo "$repo" --number "$issue" --json body 2>/dev/null | jq -r '.body // ""')"
fi

if [ -n "$issue_body" ]; then
  while IFS= read -r num; do
    [ -n "$num" ] && linked_issues+=("$num")
  done < <(printf '%s' "$issue_body" | grep -oE '#[0-9]+' | sed 's/^#//' | sort -u || true)
fi

linked_issues=("${linked_issues[@]:-}")
# Remove accidental empty element.
if [ "${#linked_issues[@]}" -eq 1 ] && [ -z "${linked_issues[0]}" ]; then
  linked_issues=()
fi

if [ -z "$token" ]; then
  echo "Error: gh is not authenticated (run 'gh auth login')"
  exit 1
fi

echo "Scanning comments..."

extract_ids() {
  local api_url="$1"
  gh api --paginate "$api_url" 2>/dev/null | python3 -c "
import sys, json
sig = '$SIG'
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        page = json.loads(line)
    except Exception:
        continue
    if not isinstance(page, list):
        continue
    for c in page:
        if sig in c.get('body', ''):
            print(c['id'])
" 
}

review_ids=()
if [ -n "$is_pr" ]; then
  mapfile -t review_ids < <(extract_ids "repos/$repo/pulls/$issue/comments")
fi

issue_ids=()
mapfile -t issue_ids < <(extract_ids "repos/$repo/issues/$issue/comments")

for linked_issue in "${linked_issues[@]}"; do
  [ -n "$linked_issue" ] || continue
  mapfile -t more_ids < <(extract_ids "repos/$repo/issues/$linked_issue/comments")
  issue_ids+=("${more_ids[@]}")
  if [ ${#more_ids[@]} -gt 0 ]; then
    echo "  Found ${#more_ids[@]} matching comment(s) on linked issue #$linked_issue"
  fi
done

review_ids=($(printf '%s\n' "${review_ids[@]}" | sort -u))
issue_ids=($(printf '%s\n' "${issue_ids[@]}" | sort -u))

total=$(( ${#review_ids[@]} + ${#issue_ids[@]} ))
if [ "$total" -eq 0 ]; then
  echo "No matching comments found. Nothing to do."
  exit 0
fi

echo "Found $total comment(s) to delete:"
echo "  PR review comments: ${#review_ids[@]}"
echo "  Issue comments:      ${#issue_ids[@]}"
echo

deleted=0
failed=0

api() {
  local method="$1"; shift
  local url="$1"; shift
  curl -s -X "$method" \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    "$url" "$@"
}

for id in "${review_ids[@]}"; do
  [ -z "$id" ] && continue
  echo -n "Deleting PR review comment $id... "
  resp="$(api DELETE "https://api.github.com/repos/$repo/pulls/comments/$id" -o /tmp/manul_del_$id.txt -w "%{http_code}")"
  if [ "$resp" = "204" ]; then
    echo "ok"; deleted=$((deleted + 1))
  else
    echo "failed (HTTP $resp)"; cat /tmp/manul_del_$id.txt 2>/dev/null || true; failed=$((failed + 1))
  fi
done

for id in "${issue_ids[@]}"; do
  [ -z "$id" ] && continue
  if printf '%s\n' "${review_ids[@]}" | grep -qx "$id"; then
    continue
  fi
  echo -n "Deleting issue comment $id... "
  resp="$(api DELETE "https://api.github.com/repos/$repo/issues/comments/$id" -o /tmp/manul_del_$id.txt -w "%{http_code}")"
  if [ "$resp" = "204" ]; then
    echo "ok"; deleted=$((deleted + 1))
  else
    echo "failed (HTTP $resp)"; cat /tmp/manul_del_$id.txt 2>/dev/null || true; failed=$((failed + 1))
  fi
done

echo
echo "=== Summary ==="
echo "Deleted:  $deleted"
echo "Failed:   $failed"
echo "Total:    $total"

rm -f /tmp/manul_del_*.txt 2>/dev/null || true
exit $([ "$failed" -eq 0 ] && echo 0 || echo 1)
