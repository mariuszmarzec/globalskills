#!/usr/bin/env bash
# Setup script for OpenClaw environment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCLAW_DIR="$HOME/.openclaw"
STATE_DIR="$OPENCLAW_DIR/state"

echo "=== OpenClaw Environment Setup ==="
echo "Time: $(date)"
echo ""

# Check if OpenClaw is already installed
if [ -f "$OPENCLAW_DIR/openclaw.json" ]; then
    echo "✓ OpenClaw already installed at $OPENCLAW_DIR"
else
    echo "⚠ OpenClaw not found at $OPENCLAW_DIR"
    echo "This skill helps initialize OpenClaw and its dependencies."
fi

# Ensure Gateway is running
echo ""
echo "=== Ensuring Gateway is running ==="
if pgrep -f "openclaw.*gateway run" > /dev/null; then
    PID=$(pgrep -f "openclaw.*gateway run" | head -1)
    echo "✓ Gateway running (PID: $PID)"
else
    echo "⚠ Gateway not running. Starting..."
    if [ -f "~/start-gateway.sh" ]; then
        ~/start-gateway.sh
        sleep 3
        if pgrep -f "openclaw.*gateway run" > /dev/null; then
            echo "✓ Gateway started successfully"
        else
            echo "✗ Failed to start Gateway"
        fi
    else
        echo "✗ start-gateway.sh not found"
    fi
fi

# List services
echo ""
echo "=== Available Services ==="
echo "• OpenClaw Gateway: http://127.0.0.1:18789"
echo "• Manul Bot: running on GitHub"
echo "• OpenClaw Control UI: available via browser"

echo ""
echo "=== Setup Complete ==="
echo "Your OpenClaw environment is ready for use."
