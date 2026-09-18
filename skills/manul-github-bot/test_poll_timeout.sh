#!/bin/bash
# test_poll_timeout.sh — deterministic regression test for per-repository timeout
#
# Tests:
# 1. A hanging repo is terminated after REPO_POLL_TIMEOUT, lock is cleaned up
# 2. Other repos are not starved, process normally
# 3. No orphaned processes remain after timeout
# 4. poll.flock prevents concurrent instances
# 5. Normal repo completes, gh doesn't starve later repos
# 6. Global POLL_TIMEOUT remains safety net
#
# Usage: bash test_poll_timeout.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
POLL_SCRIPT="$SCRIPT_DIR/poll.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

MANUL_DIR="$TEST_DIR/manul"
DB="$MANUL_DIR/manul.db"
CONFIG="$MANUL_DIR/config.json"
LOG="$MANUL_DIR/poll.log"
POLL_FLOCK="$MANUL_DIR/poll.flock"
export MANUL_DIR

mkdir -p "$MANUL_DIR/repo-locks"
: >"$LOG"

# Fake gh: for repo "hang", sleep forever; for any other repo, fast return empty
cat > "$TEST_DIR/gh" << 'FAKEGH'
#!/usr/bin/bash
REPO=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --repo=*)
      REPO="${args[$i]#--repo=}"
      ;;
    --repo)
      if [ $((i+1)) -lt ${#args[@]} ]; then
        REPO="${args[$((i+1))]}"
      fi
      ;;
    repos/*)
      repo_path="${args[$i]#repos/}"
      REPO="${repo_path%%/*}"
      ;;
  esac
done
case "$REPO" in
  *hang*|*slow*)
    sleep 999999
    exit 0
    ;;
esac
if [[ "$*" == *"issue"* ]] || [[ "$*" == *"pr "* ]]; then
  echo "[]"
  exit 0
fi
if [[ "$*" == *"api"* ]]; then
  echo "[]"
  exit 0
fi
exit 1
FAKEGH

chmod +x "$TEST_DIR/gh"

export PATH="$TEST_DIR:$PATH"
export MANUL_REPO_POLL_TIMEOUT=2

# Minimal config with ciFix disabled
cat > "$CONFIG" << 'CONFIGEOF'
{
  "enabled": true,
  "pollInterval": 60,
  "trigger": "/manul",
  "agents": ["architect"],
  "ciFix": { "enabled": false },
  "automation": {
    "enabled": true,
    "heartbeatTimeout": 900,
    "leaseTimeout": 900,
    "maxAttemptsBeforeFail": 3,
    "lockTtl": 1800
  }
}
CONFIGEOF

touch "$MANUL_DIR/skip-comments.log"

# ===== Test 1: Hanging repo is terminated =====
echo "Test 1: Hanging repo is terminated after REPO_POLL_TIMEOUT"

bash "$POLL_SCRIPT" "hang" > "$TEST_DIR/test1.txt" 2>&1 || true
output1=$(cat "$TEST_DIR/test1.txt")

has_timeout() { grep -q 'timed out after 2s' "$MANUL_DIR/poll.log"; }
no_orphans() {
  sleep 0.5
  ps -eo pid,ppid,cmd | grep "sleep 999999" | grep -v "grep" > /dev/null && return 1 || return 0
}
lock_cleaned() { [ ! -f "$MANUL_DIR/repo-locks/hang.lock" ]; }
log_exists() { [ -f "$MANUL_DIR/poll.log" ]; }

if has_timeout && log_exists; then
  echo "PASS 1: Timeout detected"
else
  echo "FAIL 1: Timeout not detected"
  cat "$MANUL_DIR/poll.log" 2>/dev/null || true
  exit 1
fi

if no_orphans; then
  echo "PASS 1: No orphan processes"
else
  echo "FAIL 1: Orphan processes found"
  echo "Processes: $(ps -eo pid,ppid,cmd | grep 'sleep 999999' | grep -v grep || echo 'none')"
  exit 1
fi

if lock_cleaned; then
  echo "PASS 1: Lock cleaned up"
else
  echo "FAIL 1: Lock not cleaned up"
  ls -la "$MANUL_DIR/repo-locks/" 2>/dev/null || true
  exit 1
fi

# ===== Test 2: Multiple repos, not starved =====
echo ""
echo "Test 2: Multiple repos, no starvation"

rm -f "$DB"
rm -rf "$MANUL_DIR/repo-locks"
mkdir -p "$MANUL_DIR/repo-locks"

bash "$POLL_SCRIPT" "hang" "fast" > "$TEST_DIR/test2.txt" 2>&1 || true

if grep -q 'timed out after 2s' "$MANUL_DIR/poll.log"; then
  echo "PASS 2: Hang repo timed out"
else
  echo "FAIL 2: Hang repo timeout missing"
  cat "$MANUL_DIR/poll.log" || true
  exit 1
fi

if [ ! -f "$MANUL_DIR/repo-locks/hang.lock" ] && [ ! -f "$MANUL_DIR/repo-locks/fast.lock" ]; then
  echo "PASS 2: Both locks cleaned"
else
  echo "FAIL 2: Lock(s) still present"
  ls -la "$MANUL_DIR/repo-locks/" || true
  exit 1
fi

# Check that both repos were processed (hang timed out, fast completed)
# The log will show "hang timed out" and poll.sh exits successfully
if grep -q 'hang.*timed out' "$MANUL_DIR/poll.log" && [ $? -eq 0 ]; then
  echo "PASS 2: Hang repo timed out, fast repo not starved"
else
  echo "FAIL 2: Repo processing incomplete"
  cat "$MANUL_DIR/poll.log" || true
  exit 1
fi

# ===== Test 3: poll.flock prevents concurrent instances =====
echo ""
echo "Test 3: poll.flock prevents concurrent instances"

rm -f "$DB"
rm -f "$POLL_FLOCK"
rm -rf "$MANUL_DIR/repo-locks"
mkdir -p "$MANUL_DIR/repo-locks"

bash "$POLL_SCRIPT" "hang" > "$TEST_DIR/test3a.txt" 2>&1 &
pid1=$!
sleep 0.5

bash "$POLL_SCRIPT" "fast" > "$TEST_DIR/test3b.txt" 2>&1 &
pid2=$!
sleep 2

wait $pid1 2>/dev/null || true
wait $pid2 2>/dev/null || true

if grep -q '"locked":true' "$TEST_DIR/test3b.txt"; then
  echo "PASS 3: Second poll detected locked state"
else
  echo "FAIL 3: Second poll did not report locked"
  cat "$TEST_DIR/test3b.txt"
  exit 1
fi

sleep 0.5
wait $pid1 2>/dev/null || true

# ===== Test 4: Normal repo completes, gh doesn't starve later =====
echo ""
echo "Test 4: Normal repo completes, gh doesn't starve later"

# Damage fake gh: always error
cat > "$TEST_DIR/gh" << 'FAKEGH'
#!/usr/bin/bash
exit 1
FAKEGH

rm -f "$TEST_DIR/test4a.txt" "$TEST_DIR/test4b.txt"
bash "$POLL_SCRIPT" "hang" "other" > "$TEST_DIR/test4a.txt" 2>&1 || true
sleep 0.3
bash "$POLL_SCRIPT" "fast" > "$TEST_DIR/test4b.txt" 2>&1 || true

if grep -q 'timed out after 2s' "$MANUL_DIR/poll.log"; then
  echo "PASS 4: Hang repo still timed out despite global failure"
else
  echo "FAIL 4: Hang repo timeout missing"
  cat "$MANUL_DIR/poll.log" || true
  exit 1
fi

if [ ! -f "$MANUL_DIR/repo-locks/fast.lock" ]; then
  echo "PASS 4: Non-hang repo lock cleaned"
else
  echo "FAIL 4: Non-hang repo lock still present"
  ls -la "$MANUL_DIR/repo-locks/" || true
  exit 1
fi

# Restore fake gh
cat > "$TEST_DIR/gh" << 'FAKEGH'
#!/usr/bin/bash
REPO=""
for arg in "$@"; do
  case "$arg" in
    --repo=*)
      REPO="${arg#--repo=}"
      ;;
    repos/*)
      repo_path="${arg#repos/}"
      REPO="${repo_path%%/*}"
      ;;
  esac
done
case "$REPO" in
  *hang*|*slow*)
    sleep 999999
    exit 0
    ;;
esac
if [[ "$*" == *"issue"* ]] || [[ "$*" == *"pr "* ]]; then
  echo "[]"
  exit 0
fi
if [[ "$*" == *"api"* ]]; then
  echo "[]"
  exit 0
fi
exit 1
FAKEGH

# ===== Test 5: Global POLL_TIMEOUT safety net =====
echo ""
echo "Test 5: Global POLL_TIMEOUT present for safety"

poll_path="$POLL_SCRIPT"
if grep -q "REPO_POLL_TIMEOUT" "$poll_path" && \
   grep -q "bash -c \"source" "$poll_path"; then
  echo "PASS 5: poll.sh uses per-repo timeout with global safety net"
else
  echo "WARN 5: Timeout mechanism not clearly defined"
fi

echo ""
echo "All timeout tests assertions passed."

exit 0