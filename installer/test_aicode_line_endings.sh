#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=installer/line-endings.sh
. "$ROOT_DIR/installer/line-endings.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
TEST_LAUNCHER="$TMP_DIR/aicode"

printf '#!/usr/bin/env bash\r\nprintf "aicode launcher ok\\n"\r\n' > "$TEST_LAUNCHER"
chmod 751 "$TEST_LAUNCHER"
mode_before="$(stat -c '%a' "$TEST_LAUNCHER" 2>/dev/null || stat -f '%Lp' "$TEST_LAUNCHER")"

normalize_lf_file "$TEST_LAUNCHER"

if LC_ALL=C grep -q "$(printf '\r')" "$TEST_LAUNCHER"; then
    echo "FAIL: CR characters remain in normalized launcher." >&2
    exit 1
fi
mode_after="$(stat -c '%a' "$TEST_LAUNCHER" 2>/dev/null || stat -f '%Lp' "$TEST_LAUNCHER")"
[ "$mode_before" = "$mode_after" ] || {
    echo "FAIL: launcher permissions changed during normalization." >&2
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

echo "PASS: aicode launcher line endings are normalized and executable."
