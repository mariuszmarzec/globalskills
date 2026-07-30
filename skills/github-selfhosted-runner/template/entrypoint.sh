#!/bin/bash
set -e

cleanup() {
    echo "Removing runner..."
    ./config.sh remove --token "$RUNNER_TOKEN" || true
}

trap cleanup EXIT

./config.sh \
    --url "$REPO_URL" \
    --token "$RUNNER_TOKEN" \
    --name docker-runner \
    --labels docker,android \
    --unattended \
    --replace

./run.sh
