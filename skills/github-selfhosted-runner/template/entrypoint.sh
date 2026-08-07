#!/bin/bash
set -e

cleanup() {
    echo "Removing runner..."
    ./config.sh remove --token "$RUNNER_TOKEN" || true
}

trap cleanup EXIT

# Drop stale registration files so a restarted container (e.g. after Docker
# Desktop comes back) always re-registers cleanly instead of failing with
# "already configured" + 404 when the old token expired.
rm -f .runner .credentials .credentials_rsaparams

./config.sh \
    --url "$REPO_URL" \
    --token "$RUNNER_TOKEN" \
    --name docker-runner \
    --labels docker,android \
    --unattended \
    --replace

./run.sh
