#!/bin/bash
# Daily startup script for WSL AI Dev Environment

echo "Starting AI development environment..."

export PATH="$HOME/.opencode/bin:$PATH"

if [ -f "$HOME/.config/opencode/opencode.env" ]; then
    set -a
    . "$HOME/.config/opencode/opencode.env"
    set +a
fi

if [ -z "${OPENCODE_API_KEY:-}" ]; then
    echo "OPENCODE_API_KEY is not set; OpenCode Zen will be unavailable until you add it to ~/.config/opencode/opencode.env."
fi

# Check if Ollama is running
if ! pgrep -x "ollama" > /dev/null; then
    echo "Starting Ollama..."
    nohup ollama serve > /tmp/ollama.log 2>&1 &
    sleep 3
    echo "Ollama started."
else
    echo "Ollama already running."
fi

# Ensure PostgreSQL is available for LiteLLM UI/auth
if command -v pg_isready >/dev/null 2>&1; then
    if ! pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; then
        echo "Starting PostgreSQL..."
        if command -v service >/dev/null 2>&1; then
            sudo service postgresql start >/dev/null 2>&1 || true
        fi
        if command -v pg_ctlcluster >/dev/null 2>&1; then
            pg_ctlcluster 12 main start >/dev/null 2>&1 || true
        fi
        sleep 3
    fi
    if pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; then
        echo "PostgreSQL ready."
        if ! sudo -n -u postgres psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw 'litellm' 2>/dev/null; then
            sudo -u postgres psql -c "CREATE USER litellm WITH PASSWORD 'litellm';" >/dev/null 2>&1 || true
            sudo -u postgres psql -c "CREATE DATABASE litellm OWNER litellm;" >/dev/null 2>&1 || true
        fi
    fi
else
    echo "PostgreSQL tools not installed; LiteLLM will start without DB until PostgreSQL is installed."
fi

# Check if LiteLLM is running
if ! pgrep -f "litellm" > /dev/null; then
    echo "Starting LiteLLM..."
    if [ -f "$HOME/litellm/.env" ]; then
        set -a
        . "$HOME/litellm/.env"
        set +a
    fi
    nohup litellm --config "$HOME/litellm/config.yaml" --port 4000 > /tmp/litellm.log 2>&1 &
    sleep 3
    echo "LiteLLM started."
else
    echo "LiteLLM already running."
fi

# Check if OpenClaw Gateway is running
if ! pgrep -f "openclaw gateway" > /dev/null; then
    echo "Starting OpenClaw Gateway..."
    nohup openclaw gateway --force --port 18789 > /tmp/openclaw-gateway.log 2>&1 &
    sleep 3
    echo "OpenClaw Gateway started."
else
    echo "OpenClaw Gateway already running."
fi

echo ""
echo "Environment ready!"
echo "  - Ollama: http://localhost:11434"
echo "  - LiteLLM: http://localhost:4000"
echo "  - OpenClaw Gateway: http://127.0.0.1:18789 (openclaw dashboard)"
echo ""
if [ -n "${OPENCODE_API_KEY:-}" ]; then
    echo "OpenCode Zen API key detected; LiteLLM will try the Zen route first."
else
    echo "No OPENCODE_API_KEY detected; LiteLLM will use the local Qwen fallback."
fi
echo ""
echo "Launch OpenCode: opencode"
echo "Launch OpenClaw: openclaw chat / openclaw dashboard"
