#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=installer/line-endings.sh
. "$ROOT_DIR/installer/line-endings.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
TEST_LAUNCHER="$TMP_DIR/aicode"

printf '#!/usr/bin/env bash\r\nprintf "aicode launcher ok\\n"\r\n' > "$TEST_LAUNCHER"
chmod 600 "$TEST_LAUNCHER"
ensure_user_executable "$TEST_LAUNCHER"
mode_after_chmod="$(stat -c '%a' "$TEST_LAUNCHER" 2>/dev/null || stat -f '%Lp' "$TEST_LAUNCHER")"
[ "$mode_after_chmod" = "700" ] || {
    echo "FAIL: ensure_user_executable did not add only the user execute bit (mode $mode_after_chmod)." >&2
    exit 1
}

normalize_lf_file "$TEST_LAUNCHER"

if LC_ALL=C grep -q "$(printf '\r')" "$TEST_LAUNCHER"; then
    echo "FAIL: CR characters remain in normalized launcher." >&2
    exit 1
fi
mode_after="$(stat -c '%a' "$TEST_LAUNCHER" 2>/dev/null || stat -f '%Lp' "$TEST_LAUNCHER")"
[ "$mode_after" = "700" ] || {
    echo "FAIL: launcher permissions changed during normalization (mode $mode_after)." >&2
    exit 1
}
[ "$("$TEST_LAUNCHER")" = "aicode launcher ok" ] || {
    echo "FAIL: normalized launcher did not execute." >&2
    exit 1
}

# Normalizing an already-correct file must remain a successful no-op.
normalize_lf_file "$TEST_LAUNCHER"

grep -Fxq '*.sh text eol=lf' "$ROOT_DIR/.gitattributes"
grep -Fxq 'aicode/aicode text eol=lf' "$ROOT_DIR/.gitattributes"
grep -Fq '. "$REPO_DIR/installer/line-endings.sh"' "$ROOT_DIR/install.sh"
grep -Fq 'normalize_lf_file "$AICODE_SOURCE"' "$ROOT_DIR/install.sh"
grep -Fq 'ensure_user_executable "$AICODE_SOURCE"' "$ROOT_DIR/install.sh"

# The repository must preserve the executable bit as well; GitHub's contents
# API can otherwise leave shell launchers at mode 100644 after text updates.
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    tracked_mode="$(git -C "$ROOT_DIR" ls-files --stage -- aicode/aicode | awk 'NR == 1 { print $1 }')"
    [ "$tracked_mode" = "100755" ] || {
        echo "FAIL: aicode/aicode must be tracked as executable (Git mode $tracked_mode)." >&2
        exit 1
    }
fi

echo "PASS: aicode launcher is LF-normalized, user-executable, and tracked as executable."
