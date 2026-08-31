#!/usr/bin/env bash
# Test script for setup-environment

set -euo pipefail

echo "=== Testing OpenClaw Environment ==="
echo "Time: $(date)"
echo ""

# Test 1: Check gateway
echo "Test 1: Gateway Status"
if pgrep -f "openclaw.*gateway run" > /dev/null; then
    echo "✓ Gateway is running"
else
    echo "✗ Gateway is not running"
fi

# Test 2: Check configuration
echo ""
echo "Test 2: Configuration"
if [ -f "$HOME/.openclaw/state/openclaw.json" ]; then
    MODE=$(grep '"mode"' "$HOME/.openclaw/state/openclaw.json" 2>/dev/null | head -1 | cut -d'"' -f4)
    if [ "$MODE" = "local" ]; then
        echo "✓ Gateway mode: local"
    else
        echo "⚠ Gateway mode: $MODE (expected: local)"
    fi
else
    echo "✗ Config file not found"
fi

# Test 3: Check port
echo ""
echo "Test 3: Port Accessibility"
if ss -tlnp 2>/dev/null | grep -q ':18789'; then
    echo "✓ Port 18789 is listening"
else
    echo "✗ Port 18789 is not listening"
fi

# Test 4: Check connectivity
echo ""
echo "Test 4: Basic Connectivity"
if curl -s "http://127.0.0.1:18789/" | grep -q "OpenClaw"; then
    echo "✓ Gateway responds to HTTP requests"
else
    echo "✗ Gateway not responding to HTTP"
fi

echo ""
echo "=== Tests Complete ==="
echo "Environment status checked."
